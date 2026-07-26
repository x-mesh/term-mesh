//! Peer-federation host side (Phase 2.2).
//!
//! Listens on a Unix socket (path via `TERMMESH_PEER_SOCKET`), drives the
//! handshake defined in `docs/peer-federation-protocol.md`, and serves
//! surfaces. Phase 2.2 ships a single synthetic `TickSurface` so the wire
//! protocol can be exercised end-to-end before real PTY integration.

pub mod connection;
pub mod framing;
pub mod layout;
pub mod persist;
pub mod pty;
pub mod query_filter;
pub mod server;
pub mod surface;

pub use server::serve;

use std::sync::{Arc, Mutex, OnceLock, Weak};

use peer_proto::v1::{TeamLeaderCommandRequest, TeamLeaderCommandResponse};

use self::layout::Broadcaster;

static REMOTE_LEADER_ROUTER: OnceLock<Mutex<Weak<Broadcaster>>> = OnceLock::new();

pub(crate) fn install_remote_leader_router(router: &Arc<Broadcaster>) {
    *REMOTE_LEADER_ROUTER
        .get_or_init(|| Mutex::new(Weak::new()))
        .lock()
        .unwrap() = Arc::downgrade(router);
}

pub(crate) async fn call_remote_team_leader(
    request: TeamLeaderCommandRequest,
    target_peer_id: &[u8],
) -> Result<TeamLeaderCommandResponse, String> {
    let router = REMOTE_LEADER_ROUTER
        .get()
        .and_then(|slot| slot.lock().unwrap().upgrade())
        .ok_or_else(|| "peer leader proxy is unavailable".to_string())?;
    router.call_team_leader(request, target_peer_id).await
}
