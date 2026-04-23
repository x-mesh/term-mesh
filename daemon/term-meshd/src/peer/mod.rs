//! Peer-federation host side (Phase 2.2).
//!
//! Listens on a Unix socket (path via `TERMMESH_PEER_SOCKET`), drives the
//! handshake defined in `docs/peer-federation-protocol.md`, and serves
//! surfaces. Phase 2.2 ships a single synthetic `TickSurface` so the wire
//! protocol can be exercised end-to-end before real PTY integration.

pub mod connection;
pub mod framing;
pub mod pty;
pub mod server;
pub mod surface;

pub use server::serve;
