//! Lane ↔ QUIC stream pump for the mesh sync transport (Phase S0 of
//! `docs/design/mesh-project-sync-wiring-plan.md`).
//!
//! [`SyncEndpoint`](super::SyncEndpoint) hands back a raw authenticated
//! `quinn::Connection`; [`StreamRouter`] is a purely in-memory,
//! lane-prioritized, back-pressured outbound queue. Nothing connected the two —
//! this module is that missing bridge. [`SyncConnection`] wraps an
//! [`AuthenticatedConnection`] and runs two background tasks:
//!
//! - a **send pump** that drains the router and writes each frame to a fresh
//!   outbound QUIC stream, tagged with its [`StreamLane`];
//! - a **receive demux** that accepts inbound QUIC streams, reads each message,
//!   and delivers `(lane, payload)` to an inbound channel.
//!
//! Framing (S0): **one message per unidirectional stream**, `[lane: u8][payload]`,
//! then `finish()`. This is the minimal correct wire that later phases build on;
//! long-lived per-lane streams / `StreamPreface` framing are a throughput
//! optimization deferred to the blob-transfer phase (S2), not a correctness need.

use quinn::Connection;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use super::{AuthenticatedConnection, StreamLane, StreamRouter, StreamRouterSender, TransportPeerSnapshot};

/// Upper bound on a single inbound message (1-byte lane tag + the largest lane
/// message limit; the router caps outbound to the same via `send`).
const MAX_MESSAGE_BYTES: usize = 1 + 8 * 1024 * 1024 + sync_protocol::MAX_BLOB_ENVELOPE_BYTES;

/// Depth of the delivered-inbound channel before the demux applies
/// back-pressure by pausing stream reads.
const INBOUND_CAPACITY: usize = 256;

#[derive(Debug)]
pub enum SyncConnectionError {
    /// The outbound queue (or the connection behind it) is closed.
    Closed,
}

/// The receiving end of the per-lane inbound queues. Each [`StreamLane`] lands in
/// its own channel so a consumer can drain one lane (e.g. Blob chunks) without
/// discarding another lane's messages (e.g. SyncOperation control): the earlier
/// single-channel demux forced callers to filter-and-drop, so bulk transfer and
/// control could not share a connection. Bounded, so a stalled reader applies
/// back-pressure rather than growing without limit.
struct LaneInbound {
    control: mpsc::Receiver<Vec<u8>>,
    terminal: mpsc::Receiver<Vec<u8>>,
    sync_operation: mpsc::Receiver<Vec<u8>>,
    blob: mpsc::Receiver<Vec<u8>>,
}

/// The sending end the demux routes each decoded message into, by lane.
struct LaneOutbound {
    control: mpsc::Sender<Vec<u8>>,
    terminal: mpsc::Sender<Vec<u8>>,
    sync_operation: mpsc::Sender<Vec<u8>>,
    blob: mpsc::Sender<Vec<u8>>,
}

impl LaneOutbound {
    fn for_lane(&self, lane: StreamLane) -> &mpsc::Sender<Vec<u8>> {
        match lane {
            StreamLane::Control => &self.control,
            StreamLane::Terminal => &self.terminal,
            StreamLane::SyncOperation => &self.sync_operation,
            StreamLane::Blob => &self.blob,
        }
    }
}

/// An authenticated peer connection with a running lane↔QUIC pump.
///
/// Enqueue outbound messages with [`SyncConnection::send`] (lane-prioritized and
/// back-pressured through the router); receive inbound messages with
/// [`SyncConnection::recv`]. The pump tasks are aborted on drop.
pub struct SyncConnection {
    /// Held whole so its connection-count semaphore permit (a private field of
    /// `AuthenticatedConnection`) stays alive for the pump's lifetime — dropping
    /// it early would free the endpoint's conn slot while the connection is
    /// still in use. `quinn::Connection` is `Arc`-backed, so the pump tasks hold
    /// cheap clones.
    auth: AuthenticatedConnection,
    outbound: StreamRouterSender,
    inbound: LaneInbound,
    send_pump: JoinHandle<()>,
    recv_demux: JoinHandle<()>,
}

impl SyncConnection {
    /// Start the pump over an authenticated connection.
    pub fn start(auth: AuthenticatedConnection) -> Self {
        let (outbound, router) = StreamRouter::bounded();
        let (control_tx, control) = mpsc::channel(INBOUND_CAPACITY);
        let (terminal_tx, terminal) = mpsc::channel(INBOUND_CAPACITY);
        let (sync_operation_tx, sync_operation) = mpsc::channel(INBOUND_CAPACITY);
        let (blob_tx, blob) = mpsc::channel(INBOUND_CAPACITY);
        let senders = LaneOutbound {
            control: control_tx,
            terminal: terminal_tx,
            sync_operation: sync_operation_tx,
            blob: blob_tx,
        };
        let send_pump = tokio::spawn(send_loop(auth.connection.clone(), router));
        let recv_demux = tokio::spawn(recv_loop(auth.connection.clone(), senders));
        Self {
            auth,
            outbound,
            inbound: LaneInbound {
                control,
                terminal,
                sync_operation,
                blob,
            },
            send_pump,
            recv_demux,
        }
    }

    /// The authenticated peer identity (device id, roster epoch, cert hash).
    pub fn peer(&self) -> &TransportPeerSnapshot {
        &self.auth.peer
    }

    /// Whether the peer advertised `capability` in its hello. Used to keep a
    /// wire choice off the link until the far side has said it understands it.
    pub fn peer_supports(&self, capability: &str) -> bool {
        self.auth
            .peer_capabilities
            .iter()
            .any(|advertised| advertised == capability)
    }

    /// A cloneable handle for enqueuing outbound messages from other tasks.
    pub fn sender(&self) -> StreamRouterSender {
        self.outbound.clone()
    }

    /// Enqueue one outbound message on `lane`. Awaits router back-pressure;
    /// errors only if the connection/pump has closed or the payload violates the
    /// lane's size bound.
    pub async fn send(&self, lane: StreamLane, payload: Vec<u8>) -> Result<(), SyncConnectionError> {
        self.outbound
            .send(lane, payload)
            .await
            .map_err(|_| SyncConnectionError::Closed)
    }

    /// Receive the next inbound message on `lane` specifically, or `None` once the
    /// connection closed and that lane's queue has drained. Messages on other
    /// lanes stay queued in their own channels — they are not consumed or lost —
    /// so a caller can drain one lane while another lane's traffic accumulates.
    pub async fn recv_lane(&mut self, lane: StreamLane) -> Option<Vec<u8>> {
        match lane {
            StreamLane::Control => self.inbound.control.recv().await,
            StreamLane::Terminal => self.inbound.terminal.recv().await,
            StreamLane::SyncOperation => self.inbound.sync_operation.recv().await,
            StreamLane::Blob => self.inbound.blob.recv().await,
        }
    }

    /// Receive the next inbound `(lane, payload)` from whichever lane has one
    /// ready, or `None` once the peer closed the connection and every lane has
    /// drained. Use [`SyncConnection::recv_lane`] when a caller wants one lane
    /// specifically without draining the others.
    pub async fn recv(&mut self) -> Option<(StreamLane, Vec<u8>)> {
        tokio::select! {
            Some(payload) = self.inbound.control.recv() => Some((StreamLane::Control, payload)),
            Some(payload) = self.inbound.terminal.recv() => Some((StreamLane::Terminal, payload)),
            Some(payload) = self.inbound.sync_operation.recv() => Some((StreamLane::SyncOperation, payload)),
            Some(payload) = self.inbound.blob.recv() => Some((StreamLane::Blob, payload)),
            else => None,
        }
    }
}

impl Drop for SyncConnection {
    fn drop(&mut self) {
        self.send_pump.abort();
        self.recv_demux.abort();
    }
}

/// Drain the router and write each frame to its own outbound uni stream. Exits
/// when the router closes (all senders dropped) or a write fails (connection
/// gone).
async fn send_loop(connection: Connection, mut router: StreamRouter) {
    while let Some(frame) = router.next().await {
        let lane = frame.lane();
        let payload = frame.into_payload();
        if write_message(&connection, lane, &payload).await.is_err() {
            break;
        }
    }
}

async fn write_message(
    connection: &Connection,
    lane: StreamLane,
    payload: &[u8],
) -> Result<(), ()> {
    let mut stream = connection.open_uni().await.map_err(|_| ())?;
    stream.write_all(&[lane as u8]).await.map_err(|_| ())?;
    stream.write_all(payload).await.map_err(|_| ())?;
    // `finish` schedules the FIN; the QUIC stack flushes the buffered write even
    // after the SendStream is dropped (same pattern as the hello exchange).
    stream.finish().map_err(|_| ())?;
    Ok(())
}

/// Accept inbound uni streams and deliver each decoded message to its lane's
/// queue. Reads streams sequentially, so per-lane order matches send order (the
/// fetch/manifest protocols rely on it) — a big blob stream still blocks reading
/// the next stream, which per-lane concurrent reads would fix, but that is a
/// throughput optimization, not a correctness need. Exits when the peer closes
/// the connection or a lane's receiver is dropped (the whole `SyncConnection`
/// went away).
async fn recv_loop(connection: Connection, lanes: LaneOutbound) {
    loop {
        let stream = match connection.accept_uni().await {
            Ok(stream) => stream,
            Err(_) => break,
        };
        match read_message(stream).await {
            Ok((lane, payload)) => {
                if lanes.for_lane(lane).send(payload).await.is_err() {
                    break;
                }
            }
            // A malformed / reset stream drops that one message; the connection
            // stays up for the next.
            Err(()) => continue,
        }
    }
}

async fn read_message(mut stream: quinn::RecvStream) -> Result<(StreamLane, Vec<u8>), ()> {
    let buffer = stream
        .read_to_end(MAX_MESSAGE_BYTES)
        .await
        .map_err(|_| ())?;
    let (lane_tag, payload) = buffer.split_first().ok_or(())?;
    Ok((lane_from_tag(*lane_tag).ok_or(())?, payload.to_vec()))
}

/// Inverse of `lane as u8`. Kept in lockstep with [`StreamLane`]'s `#[repr(u8)]`.
fn lane_from_tag(tag: u8) -> Option<StreamLane> {
    match tag {
        0 => Some(StreamLane::Control),
        1 => Some(StreamLane::Terminal),
        2 => Some(StreamLane::SyncOperation),
        3 => Some(StreamLane::Blob),
        _ => None,
    }
}
