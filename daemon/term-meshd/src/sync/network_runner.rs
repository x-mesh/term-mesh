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

use std::collections::HashSet;
use std::fs::File;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use sync_protocol::{SyncHello, PROJECT_SYNC_CAPABILITY, PROTOCOL_V1};

use super::{
    build_apply_plan, decode_manifest_batch, encode_manifest_batches, reconcile_bidirectional,
    apply_deletes, check_delete_guard, run_fetch_pull, run_push,
    scan_conflicts, ApplyStore, CasStore, DeviceTlsIdentity, FetchEntry, ManifestBuilder,
    ManifestEntry, ManifestScanner, ObjectDomain, ObjectType, OperationResult, OperationSpec,
    ProjectId, ScanCheckpoint, ScanError, ScanLimits, ScanObserver, ScanReason, StreamLane,
    SyncConnection, SyncEndpoint, SyncTransport, TrustStore,
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
    scan_project_entries_cancellable(root, None)
}

/// As [`scan_project_entries`], but polls `cancellation` (when given) so a long
/// walk of a large project stops promptly on a cancelled operation instead of
/// running to completion first.
pub fn scan_project_entries_cancellable(
    root: &File,
    cancellation: Option<Arc<AtomicBool>>,
) -> Result<Vec<ManifestEntry>, String> {
    let entries = Arc::new(Mutex::new(Vec::new()));
    let observer = Box::new(CollectingObserver {
        entries: entries.clone(),
    });
    let scanner = match cancellation {
        Some(flag) => {
            ManifestScanner::with_observer_and_cancellation(ScanLimits::default(), observer, flag)
        }
        None => ManifestScanner::with_observer(ScanLimits::default(), observer),
    }
    .map_err(|_| "scan_initialization_failed".to_string())?;
    scanner
        .scan_descriptor(root, ScanReason::Initial)
        .map_err(|error| match error {
            ScanError::Cancelled => "cancelled".to_string(),
            _ => "manifest_scan_failed".to_string(),
        })?;
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
/// flag. The manifest rides the `SyncOperation` lane; the total is bounded
/// against [`MAX_MANIFEST_ENTRIES`].
async fn recv_manifest(connection: &mut SyncConnection) -> Result<Vec<ManifestEntry>, String> {
    let mut entries = Vec::new();
    loop {
        let payload =
            tokio::time::timeout(EXCHANGE_TIMEOUT, connection.recv_lane(StreamLane::SyncOperation))
                .await
                .map_err(|_| "sync_exchange_failed".to_string())?
                .ok_or_else(|| "sync_exchange_failed".to_string())?;
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

/// Everything a sync operation needs that is scoped to a single project: this
/// device's TLS identity + roster coordinates, the project's trust store, and
/// the CAS + apply store the fetched objects flow through. One daemon syncs many
/// projects, so the runner does not own these — it resolves them per operation
/// from a [`SyncContextProvider`] keyed by the operation's project.
pub struct SyncContext {
    pub identity: DeviceTlsIdentity,
    pub trust: Arc<TrustStore>,
    pub device_id: [u8; 32],
    pub project_id: [u8; 32],
    pub roster_epoch: u64,
    /// CAS the initiator stages fetched objects into before applying them; its
    /// key provider must decrypt what the peer sends (both sides share the key).
    pub cas: Arc<CasStore>,
    /// Applies the fetched objects to the working tree. `Mutex` because
    /// `ApplyStore` owns a rusqlite `Connection` (`Send` but not `Sync`) while a
    /// `SyncTransport` must be `Sync`.
    pub apply_store: Arc<Mutex<ApplyStore>>,
}

/// Resolves the per-project [`SyncContext`] for an operation. The daemon's
/// implementation opens (and caches) each project's stores and loads its device
/// identity; a project not yet provisioned for sync returns an error rather than
/// a context. Tests inject a fixed context.
pub trait SyncContextProvider: Send + Sync + 'static {
    /// `project_id` is the operation's project id string (`OperationSpec::project_id`).
    fn context_for(&self, project_id: &str) -> Result<Arc<SyncContext>, String>;
}

/// Dials a peer and drives a full `OperationKind::Sync` operation: it resolves
/// the operation's per-project [`SyncContext`], scans and exchanges manifests,
/// then fetches and applies the diff. Injected into the `OperationManager` via
/// [`OperationManager::open_with_sync_transport`](super::OperationManager::open_with_sync_transport).
pub struct NetworkSyncRunner {
    provider: Arc<dyn SyncContextProvider>,
    resolver: Arc<dyn PeerAddressResolver>,
    handle: tokio::runtime::Handle,
}

impl NetworkSyncRunner {
    pub fn new(
        provider: Arc<dyn SyncContextProvider>,
        resolver: Arc<dyn PeerAddressResolver>,
        handle: tokio::runtime::Handle,
    ) -> Self {
        Self {
            provider,
            resolver,
            handle,
        }
    }

    /// A fresh `SyncHello` with a random nonce so repeated operations are not
    /// rejected by the peer's replay cache.
    fn hello(ctx: &SyncContext) -> Result<SyncHello, String> {
        let mut nonce = [0u8; 32];
        getrandom::getrandom(&mut nonce).map_err(|_| "sync_connect_failed".to_string())?;
        Ok(SyncHello {
            project_id: ctx.project_id,
            device_id: ctx.device_id,
            roster_epoch: ctx.roster_epoch,
            selected_version: PROTOCOL_V1,
            version_offers: vec![PROTOCOL_V1],
            capabilities: vec![PROJECT_SYNC_CAPABILITY.into()],
            nonce,
        })
    }

    async fn exchange(
        &self,
        ctx: &SyncContext,
        spec: &OperationSpec,
        addr: SocketAddr,
        cancelled: Arc<AtomicBool>,
    ) -> Result<OperationResult, String> {
        // Scan the local project before dialing so the manifest is ready to swap.
        // The scan is itself cancellation-aware, so a large tree's walk stops
        // promptly rather than running to completion after a cancel.
        let local_entries =
            scan_project_entries_cancellable(spec.held_root.descriptor(), Some(cancelled.clone()))?;
        if cancelled.load(Ordering::Acquire) {
            return Err("cancelled".to_string());
        }
        // Race the network portion against a cancellation watcher: a cancel
        // during a long await — connect, the up-to-30s manifest exchange, or the
        // fetch — is then observed within ~100ms instead of only at the step
        // boundaries (dropping the future tears down the connection). `biased`
        // polls the work branch first, so a run that has *just* completed (and
        // already applied to disk) is reported as its real result rather than
        // being spuriously relabelled "cancelled" when the flag flips in the same
        // poll.
        tokio::select! {
            biased;
            result = self.exchange_over_network(ctx, spec, addr, &local_entries, &cancelled) => result,
            () = cancelled_watch(&cancelled) => Err("cancelled".to_string()),
        }
    }

    async fn exchange_over_network(
        &self,
        ctx: &SyncContext,
        spec: &OperationSpec,
        addr: SocketAddr,
        local_entries: &[ManifestEntry],
        cancelled: &Arc<AtomicBool>,
    ) -> Result<OperationResult, String> {
        let client = SyncEndpoint::client(
            SocketAddr::from((Ipv4Addr::UNSPECIFIED, 0)),
            ctx.trust.clone(),
            &ctx.identity,
        )
        .map_err(|_| "sync_connect_failed".to_string())?;
        let auth = client
            .connect(addr, Self::hello(ctx)?)
            .await
            .map_err(|_| "sync_connect_failed".to_string())?;
        if cancelled.load(Ordering::Acquire) {
            return Err("cancelled".to_string());
        }
        let mut connection = SyncConnection::start(auth);
        let remote_entries = exchange_manifests(&mut connection, local_entries).await?;
        if cancelled.load(Ordering::Acquire) {
            return Err("cancelled".to_string());
        }

        let project = ProjectId::from_bytes(ctx.project_id);
        let domain = ObjectDomain {
            project_id: project,
            object_type: ObjectType::FILE,
            version: 1,
        };

        // Three-way against the last-synced base: what the local must pull from
        // the peer, and what it must push to the peer, converging both sides.
        // (Deletes + conflicts are computed but their application is deferred to a
        // follow-up; this wires the fetch/push core of bidirectional sync.)
        let (base, base_objects_before) = {
            let store = ctx
                .apply_store
                .lock()
                .map_err(|_| "sync_apply_failed".to_string())?;
            (
                store
                    .load_base_manifest(project)
                    .map_err(|_| "sync_apply_failed".to_string())?,
                // Snapshot: the conflict scan reads the base as it stood BEFORE
                // this run advances it.
                store
                    .load_base_objects(project)
                    .map_err(|_| "sync_apply_failed".to_string())?,
            )
        };
        let plan = reconcile_bidirectional(&base, local_entries, &remote_entries);

        // FETCH: pull remote-only changes, plus the peer's side of every
        // conflicting path. The conflicting ones are requested but deliberately
        // kept OUT of the apply plan below — they are staged in CAS only, so the
        // three-way scan can read them without overwriting the local edit.
        let mut wanted = plan.fetch.clone();
        wanted.extend(
            plan.conflicts
                .iter()
                .filter_map(|conflict| conflict.remote.clone()),
        );
        let resolved = run_fetch_pull(&mut connection, &ctx.cas, domain, &wanted).await?;
        // `operation_id` seeds apply's deterministic temp/backup/trash names; a
        // fresh random id per run keeps concurrent applies from colliding.
        let mut operation_id = [0u8; 16];
        getrandom::getrandom(&mut operation_id).map_err(|_| "sync_apply_failed".to_string())?;
        // Built from `plan.fetch`, NOT `wanted`: a conflicting path must not be
        // applied. `build_apply_plan` iterates the entries it is given, so the
        // extra staged objects in `resolved` are simply unused here.
        let apply_plan = build_apply_plan(project, operation_id, &plan.fetch, &resolved, local_entries);
        if !apply_plan.entries.is_empty() {
            let store = ctx
                .apply_store
                .lock()
                .map_err(|_| "sync_apply_failed".to_string())?;
            store
                .apply(spec.held_root.canonical_path(), &ctx.cas, domain, &apply_plan)
                .map_err(|_| "sync_apply_failed".to_string())?;
        }
        // DELETE (local): paths the peer removed and this side had not touched
        // since the base. Guarded, because "the peer has nothing" is what a
        // partial manifest also looks like.
        let removed_locally = if plan.delete_local.is_empty() {
            Vec::new()
        } else {
            check_delete_guard(plan.delete_local.len(), local_entries.len())?;
            apply_local_deletes(
                &ctx,
                spec.held_root.canonical_path(),
                domain,
                project,
                &plan.delete_local,
                local_entries,
            )?
        };
        let deleted_locally = removed_locally.len();
        if cancelled.load(Ordering::Acquire) {
            return Err("cancelled".to_string());
        }

        // PUSH: stream local-only changes to the peer, which applies them.
        let dek = ctx
            .cas
            .current_project_key(project)
            .map_err(|_| "sync_key_unavailable".to_string())?;
        let pushed = run_push(
            &mut connection,
            &ctx.cas,
            spec.held_root.canonical_path(),
            domain,
            &dek.key,
            dek.key_id,
            &plan.push,
            &plan.delete_remote,
        )
        .await?;

        // Advance the base for the paths that just converged (fetch → the remote
        // value, push → the local value). Unchanged/delete/conflict paths keep
        // their old base so deferred work still shows up as a diff next time.
        //
        // The base's CAS objects move with it. Every path that enters the base
        // does so through a fetch or a push, and both put the content in CAS, so
        // the object id is always known here — a path identical on both sides is
        // skipped by the reconcile and never reaches the base at all.
        {
            let mut base_map: std::collections::HashMap<String, ManifestEntry> = base
                .iter()
                .map(|entry| (entry.relative_path.clone(), entry.clone()))
                .collect();
            let mut object_map = base_objects_before.clone();
            // Paths the two sides already agree on are agreed state: without them
            // the base only knows what it moved, and deleting a file both peers
            // had from the start looks to the other side like an unknown addition
            // and gets pushed back. They carry no CAS object (nothing was
            // transferred), which `scan_conflicts` accounts for.
            for entry in &plan.converged {
                base_map.insert(entry.relative_path.clone(), entry.clone());
            }
            for entry in plan.fetch.iter().chain(plan.push.iter()) {
                base_map.insert(entry.relative_path.clone(), fetch_to_manifest(entry));
            }
            // Deletes this side actually performed have converged, so the base
            // forgets them. A delete the plans skipped — a directory that could
            // not be emptied — is NOT in this list and stays outstanding.
            for path in &removed_locally {
                base_map.remove(path);
            }
            // A delete pushed to the peer is only converged once the peer really
            // dropped it, and the push ack carries a count rather than per-path
            // results — so `delete_remote` cannot be forgotten here. Dropping it
            // regardless was a resurrection bug: the peer refused a directory,
            // the base forgot it anyway, and on the next pass the peer's copy
            // read as an unknown addition and was fetched straight back.
            //
            // Instead, forget what both manifests agree is gone. That converges
            // one pass later than the optimistic version (these manifests were
            // exchanged before this run's deletes landed) at the cost of one
            // idempotent re-proposal, and it is self-correcting either way: a
            // delete the peer honoured disappears from its next manifest, while
            // one it refused keeps being re-proposed instead of coming back.
            let remote_paths: HashSet<&str> = remote_entries
                .iter()
                .map(|entry| entry.relative_path.as_str())
                .collect();
            let local_paths: HashSet<&str> = local_entries
                .iter()
                .map(|entry| entry.relative_path.as_str())
                .collect();
            base_map.retain(|path, _| {
                remote_paths.contains(path.as_str()) || local_paths.contains(path.as_str())
            });
            // Only the paths whose base entry just advanced. `resolved` also holds
            // the staged REMOTE side of every conflicting path — adopting those
            // would leave the base manifest on the old content while its object
            // pointed at the peer's, quietly resolving a conflict nobody decided.
            for entry in plan.fetch.iter().chain(plan.push.iter()) {
                let path = &entry.relative_path;
                if let Some(object_id) = resolved.get(path).or_else(|| pushed.get(path)) {
                    object_map.insert(path.clone(), *object_id);
                }
            }
            // Drop objects for paths no longer in the base, so the table cannot
            // grow forever with ids whose base entry is gone.
            object_map.retain(|path, _| base_map.contains_key(path));
            let base_prime: Vec<ManifestEntry> = base_map.into_values().collect();
            let store = ctx
                .apply_store
                .lock()
                .map_err(|_| "sync_apply_failed".to_string())?;
            store
                .save_base_manifest(project, &base_prime)
                .map_err(|_| "sync_apply_failed".to_string())?;
            store
                .save_base_objects(project, &object_map)
                .map_err(|_| "sync_apply_failed".to_string())?;
        }

        // Classify what diverged on both sides. Reading the base needs the object
        // map as it was BEFORE this run advanced it, which is why the scan takes
        // `base_objects_before` rather than re-reading the store.
        let scan = scan_conflicts(
            &plan.conflicts,
            &ctx.cas,
            domain,
            spec.held_root.canonical_path(),
            &resolved,
            &base_objects_before,
        )?;

        // Conflicting paths were left untouched on both peers; record what they
        // are so a user can resolve them later, from another process. Whole-set
        // replacement, so a conflict that has since been resolved or edited away
        // does not linger.
        {
            let store = ctx
                .apply_store
                .lock()
                .map_err(|_| "sync_apply_failed".to_string())?;
            store
                .save_conflicts(project, &scan.set)
                .map_err(|_| "conflict_store_failed".to_string())?;
        }

        Ok(OperationResult {
            manifest_root: hex::encode(manifest_root(local_entries)?),
            // Paths that moved this run: fetched-and-applied + pushed + deleted.
            entries: (apply_plan.entries.len() + plan.push.len() + deleted_locally) as u64,
        })
    }
}

/// Remove `paths` locally, returning the ones that really went away.
///
/// Delegates to [`apply_deletes`], which both sides share so the initiator and
/// the responder cannot drift on a rule this destructive. The caller feeds the
/// returned paths to the base, so a delete that did not land stays outstanding
/// and is re-proposed next sync instead of being forgotten.
fn apply_local_deletes(
    ctx: &SyncContext,
    root: &std::path::Path,
    domain: ObjectDomain,
    project: ProjectId,
    paths: &[String],
    local: &[ManifestEntry],
) -> Result<Vec<String>, String> {
    apply_deletes(
        root,
        &ctx.cas,
        &ctx.apply_store,
        domain,
        project,
        paths,
        local,
        "sync_apply_failed",
    )
}


/// A pushed/fetched `FetchEntry` back to a `ManifestEntry` (identical fields) so
/// it can seed the advanced base manifest.
fn fetch_to_manifest(entry: &FetchEntry) -> ManifestEntry {
    ManifestEntry {
        relative_path: entry.relative_path.clone(),
        kind: entry.kind,
        executable: entry.executable,
        mode: entry.mode,
        length: entry.length,
        content_hash: entry.content_hash,
        symlink_target: entry.symlink_target.clone(),
    }
}

/// Resolves once `flag` is set, polling it every ~100ms. Lets an async body be
/// raced against cancellation with `select!` even though the flag is a plain
/// atomic rather than a future — the runner is handed an `Arc<AtomicBool>`, not
/// a cancellation token.
async fn cancelled_watch(flag: &AtomicBool) {
    while !flag.load(Ordering::Acquire) {
        tokio::time::sleep(Duration::from_millis(100)).await;
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
        // Resolve this operation's per-project context (identity, trust, stores).
        // A project not provisioned for sync fails here rather than dialing.
        let ctx = self.provider.context_for(&spec.project_id)?;
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
            .block_on(self.exchange(&ctx, spec, addr, cancelled.clone()))
    }
}
