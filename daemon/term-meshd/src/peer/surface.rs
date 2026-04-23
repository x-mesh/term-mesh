//! Host-side surface abstractions for peer-federation.
//!
//! Phase 2.2 provides a single synthetic surface (`TickSurface`) that emits
//! deterministic PtyData on a 1-second interval. This exists to validate the
//! wire protocol end-to-end before real PTY integration arrives in Phase 2.3.

use std::sync::Arc;
use std::time::Duration;

use peer_proto::v1::{envelope, Envelope, PtyData, SurfaceInfo};
use tokio::sync::{mpsc, Notify};
use tokio::task::JoinHandle;

/// Canonical descriptor returned to clients via `ListSurfaces`.
pub fn tick_surface_info(surface_id: &[u8]) -> SurfaceInfo {
    SurfaceInfo {
        surface_id: surface_id.to_vec(),
        workspace_name: "peer-poc".into(),
        title: "synthetic tick stream".into(),
        cols: 80,
        rows: 24,
        surface_type: "terminal".into(),
        attachable: true,
    }
}

pub struct AttachHandle {
    // Retained for Phase 2.3 where detach/resume logic needs them.
    #[allow(dead_code)]
    pub surface_id: Vec<u8>,
    #[allow(dead_code)]
    pub initial_byte_seq: u64,
    pub cancel: Arc<Notify>,
    pub task: JoinHandle<()>,
}

/// Spawn a TickSurface attach that emits PtyData into `outgoing_tx` until
/// `cancel` is notified or the channel is closed.
///
/// The first frame starts at `byte_seq = initial_byte_seq` and each subsequent
/// frame advances by the emitted payload length, matching the protocol's
/// "cumulative byte offset since attach" semantics.
pub fn spawn_tick_surface(
    surface_id: Vec<u8>,
    initial_byte_seq: u64,
    outgoing_tx: mpsc::Sender<Envelope>,
    seq_counter: Arc<std::sync::atomic::AtomicU64>,
) -> AttachHandle {
    let cancel = Arc::new(Notify::new());
    let cancel_for_task = cancel.clone();
    let surface_id_for_task = surface_id.clone();

    let task = tokio::spawn(async move {
        let mut tick = 0u64;
        let mut byte_seq = initial_byte_seq;
        let mut interval = tokio::time::interval(Duration::from_secs(1));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                biased;
                _ = cancel_for_task.notified() => break,
                _ = interval.tick() => {
                    tick += 1;
                    let payload = format!("[host] tick {tick}\r\n").into_bytes();
                    let payload_len = payload.len() as u64;
                    let env = Envelope {
                        seq: seq_counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1,
                        correlation_id: 0,
                        payload: Some(envelope::Payload::PtyData(PtyData {
                            surface_id: surface_id_for_task.clone(),
                            byte_seq,
                            payload,
                        })),
                    };
                    byte_seq += payload_len;
                    if outgoing_tx.send(env).await.is_err() {
                        break;
                    }
                }
            }
        }
    });

    AttachHandle {
        surface_id,
        initial_byte_seq,
        cancel,
        task,
    }
}
