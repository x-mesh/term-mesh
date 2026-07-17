//! `NetworkSyncRunner` — the concrete [`SyncTransport`] behind
//! `OperationKind::Sync` (Phases S0b–S1 of the mesh-project-sync wiring plan).
//!
//! It closes the loop from the operation machinery to the transport pump: given
//! a `Sync` operation carrying a peer id, it scans the local project, dials the
//! peer, completes the mutual-pinned QUIC handshake, swaps manifests over the
//! `SyncOperation` lane, and computes the [`ManifestDiff`](super::ManifestDiff)
//! that would make the local tree converge to the peer's. S1 proves the diff;
//! S2 turns `fetch` entries into CAS transfers + a real `ApplyPlan`.
//!
//! [`OperationRunner::run`](super::OperationRunner) is synchronous, so this
//! bridges into async QUIC I/O with `Handle::block_on` and polls the `cancelled`
//! flag around the connect.

use std::fs::File;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use sync_protocol::{SyncHello, PROJECT_SYNC_CAPABILITY, PROTOCOL_V1};

use super::{
    build_apply_plan, decode_manifest_batch, diff_manifests, encode_manifest_batches,
    run_fetch_pull, ApplyStore, CasStore, DeviceTlsIdentity, ManifestBuilder, ManifestEntry,
    ManifestScanner, ObjectDomain, ObjectType, OperationResult, OperationSpec, ProjectId,
    ScanCheckpoint, ScanError, ScanLimits, ScanObserver, ScanReason, StreamLane, SyncConnection,
    SyncEndpoint, SyncTransport, TrustStore,
};

/// How long to wait for the next manifest batch on the sync-operation lane
/// before failing the operation.
const EXCHANGE_TIMEOUT: Duration = Duration::from_secs(30);

/// Cap on the total entries accepted from a peer's manifest across all batches
/// (untrusted input); matches `plan.rs`'s per-batch `MAX_ENTRIES`.
const MAX_MANIFEST_ENTRIES: usize = 4_000_000;

/// Resolves a peer id (as supplied to `sync.start`) to a QUIC endpoint address.
///
/// For an explicit-endpoint bootstrap this is a fixed table; Bonjour discovery
/// would implement it differently. Kept as a trait so the daemon can wire real
/// resolution later and tests can inject a loopback address.
pub trait PeerAddressResolver: Send + Sync + 'static {
    fn resolve(&self, peer_id: &str) -> Option<SocketAddr>;
}

/// Accumulates every `ManifestEntry` the scanner emits, in scan (canonical)
/// order.
struct CollectingObserver {
    entries: Arc<Mutex<Vec<ManifestEntry>>>,
}

impl ScanObserver for CollectingObserver {
    fn checkpoint(&self, _checkpoint: ScanCheckpoint, _relative_path: &str) {}
    fn entry(&self, entry: &ManifestEntry) -> Result<(), ScanError> {
        self.entries.lock().unwrap().push(entry.clone());
        Ok(())
    }
}

/// Scan a project root (held directory descriptor) into its full manifest entry
/// list, in canonical order. Shared by the runner and by test peers.
pub fn scan_project_entries(root: &File) -> Result<Vec<ManifestEntry>, String> {
    let entries = Arc::new(Mutex::new(Vec::new()));
    let observer = Box::new(CollectingObserver {
        entries: entries.clone(),
    });
    let scanner = ManifestScanner::with_observer(ScanLimits::default(), observer)
        .map_err(|_| "scan_initialization_failed".to_string())?;
    scanner
        .scan_descriptor(root, ScanReason::Initial)
        .map_err(|_| "manifest_scan_failed".to_string())?;
    let collected = entries.lock().unwrap().clone();
    Ok(collected)
}

/// The canonical manifest root over `entries` (BLAKE3 rolling hash). Entries
/// must be in canonical order (as [`scan_project_entries`] returns them).
fn manifest_root(entries: &[ManifestEntry]) -> Result<[u8; 32], String> {
    let mut builder = ManifestBuilder::new();
    for entry in entries {
        builder
            .push(entry)
            .map_err(|_| "manifest_scan_failed".to_string())?;
    }
    Ok(builder.finish().root.0)
}

/// Symmetric manifest swap over the `SyncOperation` lane: send `local`, receive
/// the peer's. Both sides call this; each sends first (non-blocking enqueue)
/// then awaits the other's, so there is no ordering deadlock.
pub async fn exchange_manifests(
    connection: &mut SyncConnection,
    local: &[ManifestEntry],
) -> Result<Vec<ManifestEntry>, String> {
    let sender = connection.sender();
    let batches = encode_manifest_batches(local);
    // Send all local batches and receive all remote batches CONCURRENTLY. A
    // large manifest pages into many messages; "send everything, then receive"
    // would fill both peers' flow-control windows and deadlock, so the two
    // directions run together.
    let send = async move {
        for batch in batches {
            sender
                .send(StreamLane::SyncOperation, batch)
                .await
                .map_err(|_| "sync_exchange_failed".to_string())?;
        }
        Ok::<(), String>(())
    };
    let (send_result, recv_result) = tokio::join!(send, recv_manifest(connection));
    send_result?;
    recv_result
}

/// Receive a peer's manifest, reassembled from batch messages until the final
/// flag. Non-`SyncOperation` lane traffic is ignored (not fatal), and the total
/// is bounded against [`MAX_MANIFEST_ENTRIES`].
async fn recv_manifest(connection: &mut SyncConnection) -> Result<Vec<ManifestEntry>, String> {
    let mut entries = Vec::new();
    loop {
        let (lane, payload) = tokio::time::timeout(EXCHANGE_TIMEOUT, connection.recv())
            .await
            .map_err(|_| "sync_exchange_failed".to_string())?
            .ok_or_else(|| "sync_exchange_failed".to_string())?;
        if lane != StreamLane::SyncOperation {
            continue;
        }
        let (is_final, batch) =
            decode_manifest_batch(&payload).map_err(|_| "sync_exchange_failed".to_string())?;
        entries.extend(batch);
        if entries.len() > MAX_MANIFEST_ENTRIES {
            return Err("sync_exchange_failed".to_string());
        }
        if is_final {
            return Ok(entries);
        }
    }
}

/// Dials a peer and drives the manifest exchange for an `OperationKind::Sync`
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
    /// CAS the initiator stages fetched objects into before applying them; its
    /// key provider must be able to decrypt what the peer sends (both sides
    /// share the same project key).
    cas: Arc<CasStore>,
    /// Applies the fetched objects to the working tree. Wrapped in a `Mutex`
    /// because `ApplyStore` owns a rusqlite `Connection` (`Send` but not
    /// `Sync`), while a `SyncTransport` must be `Sync`.
    apply_store: Arc<Mutex<ApplyStore>>,
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
        cas: Arc<CasStore>,
        apply_store: Arc<Mutex<ApplyStore>>,
    ) -> Self {
        Self {
            identity,
            trust,
            device_id,
            project_id,
            roster_epoch,
            resolver,
            handle,
            cas,
            apply_store,
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
        spec: &OperationSpec,
        addr: SocketAddr,
        cancelled: Arc<AtomicBool>,
    ) -> Result<OperationResult, String> {
        // Scan the local project before dialing so the manifest is ready to swap.
        let local_entries = scan_project_entries(spec.held_root.descriptor())?;
        if cancelled.load(Ordering::Acquire) {
            return Err("cancelled".to_string());
        }
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
        if cancelled.load(Ordering::Acquire) {
            return Err("cancelled".to_string());
        }
        let mut connection = SyncConnection::start(auth);
        let remote_entries = exchange_manifests(&mut connection, &local_entries).await?;
        let diff = diff_manifests(&local_entries, &remote_entries);
        let fetched = diff.fetch.len() as u64;
        if cancelled.load(Ordering::Acquire) {
            return Err("cancelled".to_string());
        }

        // S2 last mile: pull the files we lack from the peer over the ordered
        // SyncOperation lane, staging each into the CAS, then apply them to the
        // working tree so the local project converges to the peer's.
        let project = ProjectId::from_bytes(self.project_id);
        let domain = ObjectDomain {
            project_id: project,
            object_type: ObjectType::FILE,
            version: 1,
        };
        let resolved = run_fetch_pull(&mut connection, &self.cas, domain, &diff.fetch).await?;
        // `operation_id` seeds apply's deterministic temp/backup/trash names; a
        // fresh random id per run keeps concurrent applies from colliding
        // (durable per-operation ids arrive with oplog tracking — see plan.rs).
        let mut operation_id = [0u8; 16];
        getrandom::getrandom(&mut operation_id).map_err(|_| "sync_apply_failed".to_string())?;
        let plan = build_apply_plan(project, operation_id, &diff.fetch, &resolved, &local_entries);
        if !plan.entries.is_empty() {
            let store = self
                .apply_store
                .lock()
                .map_err(|_| "sync_apply_failed".to_string())?;
            store
                .apply(spec.held_root.canonical_path(), &self.cas, domain, &plan)
                .map_err(|_| "sync_apply_failed".to_string())?;
        }

        Ok(OperationResult {
            // Local manifest root (identifies the tree this diff was computed
            // against); `entries` reports how many paths were fetched to
            // converge (0 when the trees already matched).
            manifest_root: hex::encode(manifest_root(&local_entries)?),
            entries: fetched,
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
        self.handle
            .block_on(self.exchange(spec, addr, cancelled.clone()))
    }
}
