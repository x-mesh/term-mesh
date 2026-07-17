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
    inbound: mpsc::Receiver<(StreamLane, Vec<u8>)>,
    send_pump: JoinHandle<()>,
    recv_demux: JoinHandle<()>,
}

impl SyncConnection {
    /// Start the pump over an authenticated connection.
    pub fn start(auth: AuthenticatedConnection) -> Self {
        let (outbound, router) = StreamRouter::bounded();
        let (inbound_tx, inbound) = mpsc::channel(INBOUND_CAPACITY);
        let send_pump = tokio::spawn(send_loop(auth.connection.clone(), router));
        let recv_demux = tokio::spawn(recv_loop(auth.connection.clone(), inbound_tx));
        Self {
            auth,
            outbound,
            inbound,
            send_pump,
            recv_demux,
        }
    }

    /// The authenticated peer identity (device id, roster epoch, cert hash).
    pub fn peer(&self) -> &TransportPeerSnapshot {
        &self.auth.peer
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

    /// Receive the next inbound `(lane, payload)`, or `None` once the peer closed
    /// the connection and all in-flight messages have drained.
    pub async fn recv(&mut self) -> Option<(StreamLane, Vec<u8>)> {
        self.inbound.recv().await
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

/// Accept inbound uni streams and deliver each decoded message to `inbound`.
/// Reads streams sequentially: correct + ordered for S0, and the blob lane's own
/// back-pressure lives in S2's transfer loop, not here. Exits when the peer
/// closes the connection or the inbound receiver is dropped.
async fn recv_loop(connection: Connection, inbound: mpsc::Sender<(StreamLane, Vec<u8>)>) {
    loop {
        let stream = match connection.accept_uni().await {
            Ok(stream) => stream,
            Err(_) => break,
        };
        match read_message(stream).await {
            Ok(message) => {
                if inbound.send(message).await.is_err() {
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
