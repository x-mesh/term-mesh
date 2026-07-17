//! `NetworkSyncRunner` — the concrete [`SyncTransport`] behind
//! `OperationKind::Sync` (Phase S0b of the mesh-project-sync wiring plan).
//!
//! It closes the loop from the operation machinery to the transport pump: given
//! a `Sync` operation carrying a peer id, it resolves the peer to a QUIC
//! endpoint, completes the mutual-pinned handshake, and drives a
//! [`SyncConnection`] to exchange a message both ways. S0b proves the operation
//! → runner → live-peer path end-to-end; S1+ replaces the placeholder control
//! exchange with real manifest-shard / oplog / chunk traffic.
//!
//! [`OperationRunner::run`](super::OperationRunner) is synchronous, so this
//! bridges into async QUIC I/O with `Handle::block_on` and polls the `cancelled`
//! flag around the blocking connect.

use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use sync_protocol::{SyncHello, PROJECT_SYNC_CAPABILITY, PROTOCOL_V1};

use super::{
    DeviceTlsIdentity, OperationResult, OperationSpec, StreamLane, SyncConnection, SyncEndpoint,
    SyncTransport, TrustStore,
};

/// How long to wait for the peer's reply on the control lane before failing the
/// operation.
const EXCHANGE_TIMEOUT: Duration = Duration::from_secs(10);

/// Resolves a peer id (as supplied to `sync.start`) to a QUIC endpoint address.
///
/// For an explicit-endpoint bootstrap this is a fixed table; Bonjour discovery
/// would implement it differently. Kept as a trait so the daemon can wire real
/// resolution later and tests can inject a loopback address.
pub trait PeerAddressResolver: Send + Sync + 'static {
    fn resolve(&self, peer_id: &str) -> Option<SocketAddr>;
}

/// Dials a peer and drives the sync exchange for an `OperationKind::Sync`
/// operation. Constructed with the local device identity + trust store + this
/// device's roster coordinates, and injected into the `OperationManager` via
/// [`OperationManager::open_with_sync_transport`](super::OperationManager::open_with_sync_transport).
pub struct NetworkSyncRunner {
    identity: DeviceTlsIdentity,
    trust: Arc<TrustStore>,
    device_id: [u8; 32],
    project_id: [u8; 32],
    roster_epoch: u64,
    resolver: Arc<dyn PeerAddressResolver>,
    handle: tokio::runtime::Handle,
}

impl NetworkSyncRunner {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        identity: DeviceTlsIdentity,
        trust: Arc<TrustStore>,
        device_id: [u8; 32],
        project_id: [u8; 32],
        roster_epoch: u64,
        resolver: Arc<dyn PeerAddressResolver>,
        handle: tokio::runtime::Handle,
    ) -> Self {
        Self {
            identity,
            trust,
            device_id,
            project_id,
            roster_epoch,
            resolver,
            handle,
        }
    }

    /// A fresh `SyncHello` with a random nonce so repeated operations are not
    /// rejected by the peer's replay cache.
    fn hello(&self) -> Result<SyncHello, String> {
        let mut nonce = [0u8; 32];
        getrandom::getrandom(&mut nonce).map_err(|_| "sync_connect_failed".to_string())?;
        Ok(SyncHello {
            project_id: self.project_id,
            device_id: self.device_id,
            roster_epoch: self.roster_epoch,
            selected_version: PROTOCOL_V1,
            version_offers: vec![PROTOCOL_V1],
            capabilities: vec![PROJECT_SYNC_CAPABILITY.into()],
            nonce,
        })
    }

    async fn exchange(
        &self,
        addr: SocketAddr,
        cancelled: Arc<AtomicBool>,
    ) -> Result<OperationResult, String> {
        let client = SyncEndpoint::client(
            SocketAddr::from((Ipv4Addr::UNSPECIFIED, 0)),
            self.trust.clone(),
            &self.identity,
        )
        .map_err(|_| "sync_connect_failed".to_string())?;
        let auth = client
            .connect(addr, self.hello()?)
            .await
            .map_err(|_| "sync_connect_failed".to_string())?;
        let peer_certificate = auth.peer.certificate_hash;
        if cancelled.load(Ordering::Acquire) {
            return Err("cancelled".to_string());
        }
        let connection = SyncConnection::start(auth);
        // S0b placeholder exchange: prove the pump carries a message both ways
        // over the operation-driven connection. S1 replaces this with a
        // manifest shard-root exchange.
        connection
            .send(StreamLane::Control, b"sync-operation-hello".to_vec())
            .await
            .map_err(|_| "sync_exchange_failed".to_string())?;
        let mut connection = connection;
        let (_lane, _payload) = tokio::time::timeout(EXCHANGE_TIMEOUT, connection.recv())
            .await
            .map_err(|_| "sync_exchange_failed".to_string())?
            .ok_or_else(|| "sync_exchange_failed".to_string())?;
        Ok(OperationResult {
            manifest_root: hex::encode(peer_certificate),
            entries: 1,
        })
    }
}

impl SyncTransport for NetworkSyncRunner {
    fn run_sync(
        &self,
        spec: &OperationSpec,
        cancelled: &Arc<AtomicBool>,
    ) -> Result<OperationResult, String> {
        let peer_id = spec
            .peer
            .as_deref()
            .ok_or_else(|| "sync_peer_unspecified".to_string())?;
        let addr = self
            .resolver
            .resolve(peer_id)
            .ok_or_else(|| "sync_peer_unknown".to_string())?;
        if cancelled.load(Ordering::Acquire) {
            return Err("cancelled".to_string());
        }
        // The runner is invoked from `spawn_blocking`, so blocking on the async
        // transport here does not stall a runtime worker.
        self.handle.block_on(self.exchange(addr, cancelled.clone()))
    }
}
