use std::array;
use std::collections::VecDeque;
use std::sync::Arc;

use tokio::sync::{mpsc, OwnedSemaphorePermit, Semaphore};

const LANE_COUNT: usize = 4;
const BASE_QUANTUM: usize = 64 * 1024;
const TOTAL_INFLIGHT_BYTES: usize = 32 * 1024 * 1024;
const TOTAL_MESSAGES: usize = 256;
const BLOB_MESSAGE_LIMIT: usize = sync_protocol::MAX_BLOB_ENVELOPE_BYTES + 112;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum StreamLane {
    Control = 0,
    Terminal = 1,
    SyncOperation = 2,
    Blob = 3,
}

impl StreamLane {
    fn index(self) -> usize {
        self as usize
    }
    fn weight(self) -> usize {
        [8, 4, 2, 1][self.index()]
    }
    fn message_limit(self) -> usize {
        [64 * 1024, 1024 * 1024, 8 * 1024 * 1024, BLOB_MESSAGE_LIMIT][self.index()]
    }
    fn queue_limit(self) -> usize {
        [64, 128, 32, 8][self.index()]
    }
}

struct QueuedFrame {
    lane: StreamLane,
    payload: Vec<u8>,
    _bytes: OwnedSemaphorePermit,
    _slot: OwnedSemaphorePermit,
}

pub struct RoutedFrame(QueuedFrame);

impl RoutedFrame {
    pub fn lane(&self) -> StreamLane {
        self.0.lane
    }
    pub fn payload(&self) -> &[u8] {
        &self.0.payload
    }
    pub fn into_payload(self) -> Vec<u8> {
        self.0.payload
    }
}

#[derive(Clone)]
pub struct StreamRouterSender {
    ingress: mpsc::Sender<QueuedFrame>,
    bytes: Arc<Semaphore>,
    slots: [Arc<Semaphore>; LANE_COUNT],
}

impl StreamRouterSender {
    pub async fn send(&self, lane: StreamLane, payload: Vec<u8>) -> Result<(), RouterError> {
        if payload.is_empty()
            || payload.len() > lane.message_limit()
            || payload.len() > u32::MAX as usize
        {
            return Err(RouterError::MessageLimit);
        }
        let slot = self.slots[lane.index()]
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| RouterError::Closed)?;
        let bytes = self
            .bytes
            .clone()
            .acquire_many_owned(payload.len() as u32)
            .await
            .map_err(|_| RouterError::Closed)?;
        self.ingress
            .send(QueuedFrame {
                lane,
                payload,
                _bytes: bytes,
                _slot: slot,
            })
            .await
            .map_err(|_| RouterError::Closed)
    }
}

pub struct StreamRouter {
    ingress: mpsc::Receiver<QueuedFrame>,
    queues: [VecDeque<QueuedFrame>; LANE_COUNT],
    deficits: [usize; LANE_COUNT],
    cursor: usize,
}

impl StreamRouter {
    pub fn bounded() -> (StreamRouterSender, Self) {
        let (sender, ingress) = mpsc::channel(TOTAL_MESSAGES);
        let slots = array::from_fn(|index| {
            let lane = [
                StreamLane::Control,
                StreamLane::Terminal,
                StreamLane::SyncOperation,
                StreamLane::Blob,
            ][index];
            Arc::new(Semaphore::new(lane.queue_limit()))
        });
        (
            StreamRouterSender {
                ingress: sender,
                bytes: Arc::new(Semaphore::new(TOTAL_INFLIGHT_BYTES)),
                slots,
            },
            Self {
                ingress,
                queues: array::from_fn(|_| VecDeque::new()),
                deficits: [0; LANE_COUNT],
                cursor: 0,
            },
        )
    }

    pub async fn next(&mut self) -> Option<RoutedFrame> {
        loop {
            while let Ok(frame) = self.ingress.try_recv() {
                self.queues[frame.lane.index()].push_back(frame);
            }
            if let Some(frame) = self.schedule() {
                return Some(RoutedFrame(frame));
            }
            let frame = self.ingress.recv().await?;
            self.queues[frame.lane.index()].push_back(frame);
        }
    }

    fn schedule(&mut self) -> Option<QueuedFrame> {
        if self.queues.iter().all(VecDeque::is_empty) {
            return None;
        }
        loop {
            for _ in 0..LANE_COUNT {
                let index = self.cursor;
                self.cursor = (self.cursor + 1) % LANE_COUNT;
                let lane = [
                    StreamLane::Control,
                    StreamLane::Terminal,
                    StreamLane::SyncOperation,
                    StreamLane::Blob,
                ][index];
                self.deficits[index] =
                    self.deficits[index].saturating_add(BASE_QUANTUM * lane.weight());
                if let Some(front) = self.queues[index].front() {
                    if front.payload.len() <= self.deficits[index] {
                        self.deficits[index] -= front.payload.len();
                        return self.queues[index].pop_front();
                    }
                } else {
                    self.deficits[index] = 0;
                }
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RouterError {
    MessageLimit,
    Closed,
}

impl std::fmt::Display for RouterError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{self:?}")
    }
}
impl std::error::Error for RouterError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn boundary_plus_one_is_rejected() {
        let (sender, _) = StreamRouter::bounded();
        assert_eq!(
            sender
                .send(StreamLane::Control, vec![0; 64 * 1024 + 1])
                .await,
            Err(RouterError::MessageLimit)
        );
    }

    #[tokio::test]
    async fn blob_is_not_starved_by_control_flood() {
        let (sender, mut router) = StreamRouter::bounded();
        sender
            .send(StreamLane::Blob, vec![1; BASE_QUANTUM])
            .await
            .unwrap();
        for _ in 0..64 {
            sender
                .send(StreamLane::Control, vec![2; BASE_QUANTUM])
                .await
                .unwrap();
        }
        let mut blob_index = None;
        for index in 0..16 {
            if router.next().await.unwrap().lane() == StreamLane::Blob {
                blob_index = Some(index);
                break;
            }
        }
        assert!(
            blob_index.is_some(),
            "blob exceeded deterministic starvation bound"
        );
    }

    #[tokio::test]
    async fn dropped_frame_releases_byte_and_lane_permits() {
        let (sender, mut router) = StreamRouter::bounded();
        for _ in 0..8 {
            sender
                .send(StreamLane::Blob, vec![0; 4 * 1024 * 1024])
                .await
                .unwrap();
        }
        for _ in 0..8 {
            drop(router.next().await.unwrap());
        }
        sender
            .send(StreamLane::Blob, vec![0; 4 * 1024 * 1024])
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn full_control_lane_does_not_block_other_lanes() {
        let (sender, mut router) = StreamRouter::bounded();
        for _ in 0..64 {
            sender
                .send(StreamLane::Control, vec![1; 1024])
                .await
                .unwrap();
        }
        let mut pending = Vec::new();
        for _ in 0..16 {
            let sender = sender.clone();
            pending.push(tokio::spawn(async move {
                sender.send(StreamLane::Control, vec![2; 1024]).await
            }));
        }
        tokio::task::yield_now().await;
        sender
            .send(StreamLane::Terminal, vec![3; 1024])
            .await
            .unwrap();
        sender.send(StreamLane::Blob, vec![4; 1024]).await.unwrap();
        let mut terminal = None;
        let mut blob = None;
        for index in 0..16 {
            match router.next().await.unwrap().lane() {
                StreamLane::Terminal => terminal = Some(index),
                StreamLane::Blob => blob = Some(index),
                _ => {}
            }
            if terminal.is_some() && blob.is_some() {
                break;
            }
        }
        assert!(terminal.is_some() && blob.is_some());
        for task in pending {
            task.abort();
        }
    }

    #[tokio::test]
    async fn cancellation_releases_lane_slot_while_waiting_for_global_bytes() {
        let (sender, _router) = StreamRouter::bounded();
        for _ in 0..4 {
            sender
                .send(StreamLane::SyncOperation, vec![0; 8 * 1024 * 1024])
                .await
                .unwrap();
        }
        let waiting = {
            let sender = sender.clone();
            tokio::spawn(async move { sender.send(StreamLane::Terminal, vec![0; 1024]).await })
        };
        tokio::task::yield_now().await;
        assert_eq!(
            sender.slots[StreamLane::Terminal.index()].available_permits(),
            127
        );
        waiting.abort();
        let _ = waiting.await;
        assert_eq!(
            sender.slots[StreamLane::Terminal.index()].available_permits(),
            128
        );
    }
}
