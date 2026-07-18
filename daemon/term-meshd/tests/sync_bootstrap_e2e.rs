//! Phase S3 (in-process): the real bootstrap → provisioning → sync chain.
//!
//! Where `sync_operation_e2e.rs` hand-assembles a `FixedContextProvider` +
//! `FixedResolver`, this drives the whole thing through what `bootstrap-trust`
//! actually writes: two in-process daemons are provisioned with
//! `run_bootstrap_trust` (real per-project trust store, keychain identity + DEK,
//! provisioning coordinates + peer address book), then the initiator resolves its
//! `SyncContext` from those stores via `ProvisioningSyncContextProvider` and its
//! peer address via `ProvisioningPeerResolver`. A real `Sync` operation then
//! moves a file that exists only on the peer onto the initiator's disk.
//!
//! This is the proof that the bootstrap flow feeds a real sync end-to-end — the
//! `SyncContextProvider` seam the daemon (P0) will wire behind its socket.

#[path = "../src/sync/mod.rs"]
mod sync;

use std::collections::HashMap;
use std::fs::File;
use std::net::{Ipv4Addr, SocketAddr};
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ed25519_dalek::SigningKey;
use sync::{
    ensure_device_identity, exchange_manifests, generate_project_key, load_device_tls_identity,
    load_project_key, receive_push, respond_to_fetch, run_bootstrap_trust, scan_project_entries,
    serve_project, ApplyStore, BootstrapDevice, CasLimits, CasStore, ConflictKind,
    DaemonBootstrapPaths,
    KeychainBackend, KeychainError, KeychainItem, KeychainProjectKeyProvider, LocalCoordinates,
    NetworkSyncRunner, ObjectDomain, ObjectId, ObjectType, OperationKind, OperationManager,
    OperationStartParams, OperationState, ProjectId, ProjectRegistry, ProvisioningPeerResolver,
    ProvisioningSyncContextProvider, SyncConnection, SyncContextProvider, SyncEndpoint,
    SyncProvisioningStore, TrustStore,
};
use sync_protocol::{SyncHello, PROJECT_SYNC_CAPABILITY, PROTOCOL_V1};
use zeroize::Zeroizing;

/// A process-memory keychain — the e2e is cross-platform, so it does not touch
/// the macOS Keychain. Bootstrap persists each daemon's identity + DEK here.
#[derive(Default)]
struct MemoryKeychain {
    values: Mutex<HashMap<(String, String), Vec<u8>>>,
}

impl KeychainBackend for MemoryKeychain {
    fn put(&self, item: &KeychainItem, secret: &[u8]) -> Result<(), KeychainError> {
        self.values
            .lock()
            .map_err(|_| KeychainError::Poisoned)?
            .insert((item.service.clone(), item.account.clone()), secret.to_vec());
        Ok(())
    }
    fn get(&self, item: &KeychainItem) -> Result<Zeroizing<Vec<u8>>, KeychainError> {
        self.values
            .lock()
            .map_err(|_| KeychainError::Poisoned)?
            .get(&(item.service.clone(), item.account.clone()))
            .cloned()
            .map(Zeroizing::new)
            .ok_or(KeychainError::NotFound)
    }
    fn delete(&self, item: &KeychainItem) -> Result<(), KeychainError> {
        self.values
            .lock()
            .map_err(|_| KeychainError::Poisoned)?
            .remove(&(item.service.clone(), item.account.clone()));
        Ok(())
    }
}

fn hello(project: [u8; 32], device: [u8; 32], epoch: u64, nonce: u8) -> SyncHello {
    SyncHello {
        project_id: project,
        device_id: device,
        roster_epoch: epoch,
        selected_version: PROTOCOL_V1,
        version_offers: vec![PROTOCOL_V1],
        capabilities: vec![PROJECT_SYNC_CAPABILITY.into()],
        nonce: [nonce; 32],
    }
}

/// A dedicated 0700 state directory for a SecureSqlite store under `base`.
fn state_dir(base: &std::path::Path, name: &str) -> std::path::PathBuf {
    let dir = base.join(name);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    dir
}

/// The bootstrap paths for one daemon rooted at its own state dir, matching the
/// layout `ProvisioningSyncContextProvider` reads.
fn bootstrap_paths(state_root: &std::path::Path, project: ProjectId) -> DaemonBootstrapPaths {
    DaemonBootstrapPaths {
        trust_db: state_root
            .join("projects")
            .join(hex::encode(project.as_bytes()))
            .join("trust.sqlite3"),
        provisioning_db: state_root.join("prov.db"),
    }
}

fn project_cas(state_root: &std::path::Path, project: ProjectId, keychain: Arc<dyn KeychainBackend>) -> CasStore {
    let dir = state_root
        .join("projects")
        .join(hex::encode(project.as_bytes()))
        .join("cas");
    CasStore::open(
        dir,
        CasLimits::default(),
        Arc::new(KeychainProjectKeyProvider::new(keychain)),
    )
    .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn bootstrap_then_sync_moves_a_file_from_peer_to_initiator() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x41; 32]);
    let device_a = [0x43; 32]; // initiator (the runner)
    let device_b = [0x44; 32]; // peer (source of truth)

    // Two in-process daemons, each with its own keychain + state dir.
    let keychain_a: Arc<dyn KeychainBackend> = Arc::new(MemoryKeychain::default());
    let keychain_b: Arc<dyn KeychainBackend> = Arc::new(MemoryKeychain::default());
    let state_a = temporary.path().join("daemon-a");
    let state_b = temporary.path().join("daemon-b");

    // Two project trees sharing `shared.txt` (identical → not in the diff); the
    // peer additionally has `extra.txt`, which the initiator lacks.
    let local_root = tempfile::tempdir().unwrap();
    std::fs::write(local_root.path().join("shared.txt"), b"same-content").unwrap();
    let peer_root = tempfile::tempdir().unwrap();
    std::fs::write(peer_root.path().join("shared.txt"), b"same-content").unwrap();
    std::fs::write(peer_root.path().join("extra.txt"), b"only-on-the-peer").unwrap();
    let peer_root_path = peer_root.path().to_path_buf();

    // The initiator registers its tree; the registry-assigned id IS the project
    // id everything provisions against.
    let registry_state = state_dir(temporary.path(), "registry-state");
    let registry = Arc::new(ProjectRegistry::open(registry_state.join("registry.db")).unwrap());
    let record = registry.add(local_root.path()).unwrap();
    let project = record.project_id;
    let project_bytes = *project.as_bytes();
    let op_project_id = project.to_string();

    // ── Identity phase: each daemon's real cert hash feeds the roster. ─────────
    let hash_a = ensure_device_identity(&*keychain_a, project, device_a)
        .unwrap()
        .certificate_hash();
    let hash_b = ensure_device_identity(&*keychain_b, project, device_b)
        .unwrap()
        .certificate_hash();
    let dek = generate_project_key().unwrap();
    let roster = [
        BootstrapDevice { device_id: device_a, certificate_hash: hash_a, epoch: 1 },
        BootstrapDevice { device_id: device_b, certificate_hash: hash_b, epoch: 2 },
    ];

    // ── Apply phase, peer (B) first — it does not dial, so it has no peers. ────
    run_bootstrap_trust(
        &*keychain_b,
        &bootstrap_paths(&state_b, project),
        project,
        &recovery,
        &dek,
        LocalCoordinates { device_id: device_b, roster_epoch: 2 },
        &roster,
        &[],
    )
    .unwrap();

    // Peer server, built from B's provisioned identity + trust.
    let identity_b = load_device_tls_identity(&*keychain_b, project_bytes, device_b).unwrap();
    let trust_b = Arc::new(
        TrustStore::open_existing(
            state_b
                .join("projects")
                .join(hex::encode(project_bytes))
                .join("trust.sqlite3"),
            project,
        )
        .unwrap(),
    );
    let server = SyncEndpoint::server(
        SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
        trust_b.clone(),
        &identity_b,
    )
    .unwrap();
    let server_addr = server.local_addr().unwrap();

    // ── Apply phase, initiator (A) — its address book points at B. ────────────
    run_bootstrap_trust(
        &*keychain_a,
        &bootstrap_paths(&state_a, project),
        project,
        &recovery,
        &dek,
        LocalCoordinates { device_id: device_a, roster_epoch: 1 },
        &roster,
        &[("peer-b".to_string(), server_addr)],
    )
    .unwrap();

    // Peer serves its tree: accept, swap manifests, answer the fetch from its CAS
    // (keyed by the shared DEK it was provisioned with).
    let dek_b = load_project_key(&*keychain_b, project_bytes).unwrap();
    let cas_source = project_cas(&state_b, project, keychain_b.clone());
    let domain = ObjectDomain {
        project_id: project,
        object_type: ObjectType::FILE,
        version: 1,
    };
    // A responder must serve BOTH phases, exactly like `serve_connection`: the
    // initiator always runs a push phase (empty here) and blocks on its ack, so a
    // fetch-only responder would hang it until the fetch timeout.
    let responder_apply = std::sync::Mutex::new(
        ApplyStore::open(state_dir(temporary.path(), "responder-apply").join("apply.db")).unwrap(),
    );
    let _server_task = tokio::spawn(async move {
        if let Ok(auth) = server.accept(hello(project_bytes, device_b, 2, 7)).await {
            let mut connection = SyncConnection::start(auth);
            let root = File::open(&peer_root_path).unwrap();
            let entries = scan_project_entries(&root).unwrap();
            if exchange_manifests(&mut connection, &entries).await.is_ok() {
                let _ = respond_to_fetch(
                    &mut connection,
                    &cas_source,
                    &peer_root_path,
                    domain,
                    &dek_b.key,
                    dek_b.key_id,
                    &entries,
                )
                .await;
                let _ = receive_push(
                    &mut connection,
                    &cas_source,
                    &peer_root_path,
                    domain,
                    &responder_apply,
                    project,
                    &entries,
                )
                .await;
                // Hold the connection open until the initiator drains the response
                // and hangs up (a real daemon keeps peer sessions pooled).
                while connection.recv().await.is_some() {}
            }
        }
    });

    // Initiator resolves its per-project context + the peer address from the
    // stores bootstrap wrote — the real provider seam, not a fixed stub.
    let provisioning_a = Arc::new(SyncProvisioningStore::open(state_a.join("prov.db")).unwrap());
    let provider = Arc::new(ProvisioningSyncContextProvider::new(
        keychain_a.clone(),
        provisioning_a.clone(),
        &state_a,
    ));
    let resolver = Arc::new(ProvisioningPeerResolver::new(provisioning_a));
    let runner = NetworkSyncRunner::new(provider, resolver, tokio::runtime::Handle::current());

    let ops_state = state_dir(temporary.path(), "sync-state");
    let manager = OperationManager::open_with_sync_transport(
        ops_state.join("operations.db"),
        registry,
        Arc::new(runner),
    )
    .unwrap();

    let started = manager
        .start(OperationStartParams {
            request_id: "cd".repeat(16),
            project_id: op_project_id.clone(),
            kind: OperationKind::Sync,
            peer: Some("peer-b".to_string()),
        })
        .await
        .unwrap();

    let mut finished = None;
    for _ in 0..150 {
        let record = manager.status(&started.operation_id, &op_project_id).unwrap();
        if record.state.is_terminal() {
            finished = Some(record);
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let record = finished.expect("sync operation did not terminate in time");
    assert_eq!(
        record.state,
        OperationState::Succeeded,
        "sync op failed: {:?}",
        record.error_code
    );
    let result = record.result.expect("succeeded operation carries a result");
    assert_eq!(result.entries, 1, "expected exactly one file to fetch (extra.txt)");

    // The fetched file was applied to the initiator's tree, byte-identical.
    let applied = std::fs::read(local_root.path().join("extra.txt"))
        .expect("extra.txt applied to the initiator's project root");
    assert_eq!(applied, b"only-on-the-peer", "applied file differs from the peer");
}

/// As above, but the peer is served by the REAL daemon responder (`serve_project`)
/// resolving its context from provisioned stores — not a hand-driven task. This
/// is the in-process proof of the accept half before the hardware e2e.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn serve_project_responds_to_a_real_sync() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x51; 32]);
    let device_a = [0x53; 32];
    let device_b = [0x54; 32];

    let keychain_a: Arc<dyn KeychainBackend> = Arc::new(MemoryKeychain::default());
    let keychain_b: Arc<dyn KeychainBackend> = Arc::new(MemoryKeychain::default());
    let state_a = temporary.path().join("daemon-a");
    let state_b = temporary.path().join("daemon-b");

    let local_root = tempfile::tempdir().unwrap();
    std::fs::write(local_root.path().join("shared.txt"), b"same-content").unwrap();
    let peer_root = tempfile::tempdir().unwrap();
    std::fs::write(peer_root.path().join("shared.txt"), b"same-content").unwrap();
    std::fs::write(peer_root.path().join("extra.txt"), b"only-on-the-peer").unwrap();

    // A assigns the project id; B registers ITS tree under the SAME id
    // (`add_with_id`) so the responder can resolve its root.
    let registry_a_state = state_dir(temporary.path(), "registry-a");
    let registry_a = Arc::new(ProjectRegistry::open(registry_a_state.join("registry.db")).unwrap());
    let project = registry_a.add(local_root.path()).unwrap().project_id;
    let project_bytes = *project.as_bytes();
    let op_project_id = project.to_string();

    let registry_b_state = state_dir(temporary.path(), "registry-b");
    let registry_b = Arc::new(ProjectRegistry::open(registry_b_state.join("registry.db")).unwrap());
    registry_b.add_with_id(peer_root.path(), project).unwrap();

    // Provision both daemons for the project.
    let hash_a = ensure_device_identity(&*keychain_a, project, device_a)
        .unwrap()
        .certificate_hash();
    let hash_b = ensure_device_identity(&*keychain_b, project, device_b)
        .unwrap()
        .certificate_hash();
    let dek = generate_project_key().unwrap();
    let roster = [
        BootstrapDevice { device_id: device_a, certificate_hash: hash_a, epoch: 1 },
        BootstrapDevice { device_id: device_b, certificate_hash: hash_b, epoch: 2 },
    ];
    run_bootstrap_trust(
        &*keychain_b,
        &bootstrap_paths(&state_b, project),
        project,
        &recovery,
        &dek,
        LocalCoordinates { device_id: device_b, roster_epoch: 2 },
        &roster,
        &[],
    )
    .unwrap();

    // Peer (B): resolve its context + root + DEK from the provisioned stores and
    // hand them to the real daemon responder.
    let provisioning_b = Arc::new(SyncProvisioningStore::open(state_b.join("prov.db")).unwrap());
    let provider_b =
        ProvisioningSyncContextProvider::new(keychain_b.clone(), provisioning_b, &state_b);
    let context_b = provider_b.context_for(&op_project_id).unwrap();
    let root_b = registry_b.resolve_root(project).unwrap();
    let dek_b = load_project_key(&*keychain_b, project_bytes).unwrap();
    let server = SyncEndpoint::server(
        SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
        context_b.trust.clone(),
        &context_b.identity,
    )
    .unwrap();
    let server_addr = server.local_addr().unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let _server_task = tokio::spawn(serve_project(
        server,
        context_b,
        root_b,
        dek_b.key,
        dek_b.key_id,
        stop.clone(),
    ));

    // Initiator (A): provision with B's address, build the real provider + runner.
    run_bootstrap_trust(
        &*keychain_a,
        &bootstrap_paths(&state_a, project),
        project,
        &recovery,
        &dek,
        LocalCoordinates { device_id: device_a, roster_epoch: 1 },
        &roster,
        &[("peer-b".to_string(), server_addr)],
    )
    .unwrap();
    let provisioning_a = Arc::new(SyncProvisioningStore::open(state_a.join("prov.db")).unwrap());
    let provider = Arc::new(ProvisioningSyncContextProvider::new(
        keychain_a.clone(),
        provisioning_a.clone(),
        &state_a,
    ));
    let resolver = Arc::new(ProvisioningPeerResolver::new(provisioning_a));
    let runner = NetworkSyncRunner::new(provider, resolver, tokio::runtime::Handle::current());

    let ops_state = state_dir(temporary.path(), "sync-state");
    let manager = OperationManager::open_with_sync_transport(
        ops_state.join("operations.db"),
        registry_a,
        Arc::new(runner),
    )
    .unwrap();

    let started = manager
        .start(OperationStartParams {
            request_id: "ef".repeat(16),
            project_id: op_project_id.clone(),
            kind: OperationKind::Sync,
            peer: Some("peer-b".to_string()),
        })
        .await
        .unwrap();

    let mut finished = None;
    for _ in 0..150 {
        let record = manager.status(&started.operation_id, &op_project_id).unwrap();
        if record.state.is_terminal() {
            finished = Some(record);
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let record = finished.expect("sync operation did not terminate in time");
    assert_eq!(
        record.state,
        OperationState::Succeeded,
        "sync op failed: {:?}",
        record.error_code
    );
    assert_eq!(record.result.unwrap().entries, 1);
    let applied = std::fs::read(local_root.path().join("extra.txt"))
        .expect("extra.txt applied to the initiator's project root");
    assert_eq!(applied, b"only-on-the-peer");
    stop.store(true, std::sync::atomic::Ordering::Release);
}

/// Bidirectional: the initiator (A) holds a file the peer (B) lacks and B holds a
/// file A lacks. One sync converges BOTH trees — A fetches B's file and pushes its
/// own, driven by the real runner + `serve_project` responder.
///
/// Then, with a base established, both peers edit the SAME file differently. That
/// path must survive untouched on both sides: a conflict is reported, not applied
/// in either direction.
///
/// Finally each peer deletes a different file, and both deletions propagate —
/// while the unresolved conflict stays put.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn bidirectional_sync_converges_conflicts_and_propagates_deletes() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x61; 32]);
    let device_a = [0x63; 32];
    let device_b = [0x64; 32];

    let keychain_a: Arc<dyn KeychainBackend> = Arc::new(MemoryKeychain::default());
    let keychain_b: Arc<dyn KeychainBackend> = Arc::new(MemoryKeychain::default());
    let state_a = temporary.path().join("daemon-a");
    let state_b = temporary.path().join("daemon-b");

    // A has a-only.txt; B has b-only.txt; both share shared.txt.
    //
    // Each tree gets its OWN parent directory. `PathSandbox` puts its apply work
    // directory (`.term-mesh-apply-<project>`) in the *parent* of the root, so two
    // roots for the same project sharing a parent — which sibling `tempdir()`s
    // under $TMPDIR would be — would make A's fetch-apply and B's push-apply
    // collide in one work directory. Real peers are on different machines; only
    // this in-process test can produce that aliasing.
    let a_home = tempfile::tempdir().unwrap();
    let local_root = tempfile::tempdir_in(a_home.path()).unwrap();
    std::fs::write(local_root.path().join("shared.txt"), b"same-content").unwrap();
    std::fs::write(local_root.path().join("a-only.txt"), b"lives-on-A").unwrap();
    // Distinct permissions per file: sync must reproduce each one rather than
    // install everything at a fixed default. Creating all files 0600 quietly
    // narrows a shared file; creating all of them 0644 quietly widens a private
    // one — both are wrong, so the mode has to travel with the file.
    std::fs::set_permissions(
        local_root.path().join("a-only.txt"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    std::fs::write(local_root.path().join("private.txt"), b"secret").unwrap();
    std::fs::set_permissions(
        local_root.path().join("private.txt"),
        std::fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let b_home = tempfile::tempdir().unwrap();
    let peer_root = tempfile::tempdir_in(b_home.path()).unwrap();
    std::fs::write(peer_root.path().join("shared.txt"), b"same-content").unwrap();
    std::fs::write(peer_root.path().join("b-only.txt"), b"lives-on-B").unwrap();

    let registry_a_state = state_dir(temporary.path(), "registry-a");
    let registry_a = Arc::new(ProjectRegistry::open(registry_a_state.join("registry.db")).unwrap());
    let project = registry_a.add(local_root.path()).unwrap().project_id;
    let project_bytes = *project.as_bytes();
    let op_project_id = project.to_string();

    let registry_b_state = state_dir(temporary.path(), "registry-b");
    let registry_b = Arc::new(ProjectRegistry::open(registry_b_state.join("registry.db")).unwrap());
    registry_b.add_with_id(peer_root.path(), project).unwrap();

    let hash_a = ensure_device_identity(&*keychain_a, project, device_a).unwrap().certificate_hash();
    let hash_b = ensure_device_identity(&*keychain_b, project, device_b).unwrap().certificate_hash();
    let dek = generate_project_key().unwrap();
    let roster = [
        BootstrapDevice { device_id: device_a, certificate_hash: hash_a, epoch: 1 },
        BootstrapDevice { device_id: device_b, certificate_hash: hash_b, epoch: 2 },
    ];
    run_bootstrap_trust(
        &*keychain_b,
        &bootstrap_paths(&state_b, project),
        project,
        &recovery,
        &dek,
        LocalCoordinates { device_id: device_b, roster_epoch: 2 },
        &roster,
        &[],
    )
    .unwrap();

    let provisioning_b = Arc::new(SyncProvisioningStore::open(state_b.join("prov.db")).unwrap());
    let provider_b = ProvisioningSyncContextProvider::new(keychain_b.clone(), provisioning_b, &state_b);
    let context_b = provider_b.context_for(&op_project_id).unwrap();
    let root_b = registry_b.resolve_root(project).unwrap();
    let dek_b = load_project_key(&*keychain_b, project_bytes).unwrap();
    let server = SyncEndpoint::server(
        SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
        context_b.trust.clone(),
        &context_b.identity,
    )
    .unwrap();
    let server_addr = server.local_addr().unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let _server_task = tokio::spawn(serve_project(server, context_b, root_b, dek_b.key, dek_b.key_id, stop.clone()));

    run_bootstrap_trust(
        &*keychain_a,
        &bootstrap_paths(&state_a, project),
        project,
        &recovery,
        &dek,
        LocalCoordinates { device_id: device_a, roster_epoch: 1 },
        &roster,
        &[("peer-b".to_string(), server_addr)],
    )
    .unwrap();
    let provisioning_a = Arc::new(SyncProvisioningStore::open(state_a.join("prov.db")).unwrap());
    let provider = Arc::new(ProvisioningSyncContextProvider::new(keychain_a.clone(), provisioning_a.clone(), &state_a));
    let resolver = Arc::new(ProvisioningPeerResolver::new(provisioning_a));
    let runner = NetworkSyncRunner::new(provider.clone(), resolver, tokio::runtime::Handle::current());

    let ops_state = state_dir(temporary.path(), "sync-state");
    let manager = OperationManager::open_with_sync_transport(ops_state.join("operations.db"), registry_a, Arc::new(runner)).unwrap();

    let started = manager
        .start(OperationStartParams {
            request_id: "ab".repeat(16),
            project_id: op_project_id.clone(),
            kind: OperationKind::Sync,
            peer: Some("peer-b".to_string()),
        })
        .await
        .unwrap();

    let mut finished = None;
    for _ in 0..150 {
        let record = manager.status(&started.operation_id, &op_project_id).unwrap();
        if record.state.is_terminal() {
            finished = Some(record);
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let record = finished.expect("sync operation did not terminate in time");
    assert_eq!(record.state, OperationState::Succeeded, "sync op failed: {:?}", record.error_code);

    // A fetched B's file; B applied A's pushed file — both trees converged.
    // Modes travelled with the content, in both directions.
    let mode_of = |path: &std::path::Path| {
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    };
    assert_eq!(
        mode_of(&peer_root.path().join("a-only.txt")),
        0o755,
        "the pushed executable lost its permissions on the peer",
    );
    assert_eq!(
        mode_of(&local_root.path().join("b-only.txt")),
        0o644,
        "the fetched file did not land with the peer's permissions",
    );
    assert_eq!(
        mode_of(&peer_root.path().join("private.txt")),
        0o600,
        "an owner-only file must not be widened by syncing it",
    );

    let a_got_b = std::fs::read(local_root.path().join("b-only.txt")).expect("A fetched b-only.txt");
    assert_eq!(a_got_b, b"lives-on-B");
    let b_got_a = std::fs::read(peer_root.path().join("a-only.txt")).expect("B received the pushed a-only.txt");
    assert_eq!(b_got_a, b"lives-on-A");
    // shared.txt untouched on both.
    assert_eq!(std::fs::read(local_root.path().join("shared.txt")).unwrap(), b"same-content");

    // The base advanced to the converged state, and each base FILE carries the CAS
    // object it landed on — the anchor a later three-way merge reads to tell "I
    // changed this" apart from "they changed this".
    let context_a = provider.context_for(&op_project_id).unwrap();
    let (base, base_objects) = {
        let store = context_a.apply_store.lock().unwrap();
        (
            store.load_base_manifest(project).unwrap(),
            store.load_base_objects(project).unwrap(),
        )
    };
    let base_paths: Vec<&str> = base.iter().map(|e| e.relative_path.as_str()).collect();
    assert!(base_paths.contains(&"a-only.txt"), "pushed path in base: {base_paths:?}");
    assert!(base_paths.contains(&"b-only.txt"), "fetched path in base: {base_paths:?}");
    // `shared.txt` was identical on both sides, so the reconcile skipped it and it
    // never entered the base — which is exactly why every base path has an object.
    assert_eq!(
        base_objects.keys().map(String::as_str).collect::<Vec<_>>(),
        vec!["a-only.txt", "b-only.txt", "private.txt"],
    );
    // Each recorded id is the content address of the agreed bytes, and the object
    // it names is really in CAS — so a later merge can read the base, not just
    // learn that one existed.
    let domain = ObjectDomain { project_id: project, object_type: ObjectType::FILE, version: 1 };
    for (path, expected) in [("a-only.txt", &b"lives-on-A"[..]), ("b-only.txt", &b"lives-on-B"[..])] {
        assert_eq!(
            base_objects[path],
            ObjectId::for_plaintext(domain, expected),
            "base object for {path} does not address the agreed content",
        );
        assert!(
            context_a.cas.get_live(domain, base_objects[path]).unwrap().is_some(),
            "base object for {path} missing from CAS",
        );
    }

    // ── Second sync: both peers edit the same file differently. ───────────────
    // `a-only.txt` is in the base now, so the reconcile can tell that BOTH sides
    // moved away from the agreed content — the one case where neither version may
    // be applied.
    std::fs::write(local_root.path().join("a-only.txt"), b"edited-by-A").unwrap();
    std::fs::write(peer_root.path().join("a-only.txt"), b"edited-by-B").unwrap();

    let second = manager
        .start(OperationStartParams {
            request_id: "cd".repeat(16),
            project_id: op_project_id.clone(),
            kind: OperationKind::Sync,
            peer: Some("peer-b".to_string()),
        })
        .await
        .unwrap();
    let mut finished = None;
    for _ in 0..150 {
        let record = manager.status(&second.operation_id, &op_project_id).unwrap();
        if record.state.is_terminal() {
            finished = Some(record);
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let record = finished.expect("second sync did not terminate in time");
    // The run still succeeds — a conflict blocks one path, not the whole sync.
    assert_eq!(
        record.state,
        OperationState::Succeeded,
        "second sync failed: {:?}",
        record.error_code
    );

    // Neither side was overwritten. This is the guarantee: pulling the peer's
    // side of a conflict stages it in CAS for classification but never applies it.
    assert_eq!(
        std::fs::read(local_root.path().join("a-only.txt")).unwrap(),
        b"edited-by-A",
        "A's edit was clobbered by the peer's version",
    );
    assert_eq!(
        std::fs::read(peer_root.path().join("a-only.txt")).unwrap(),
        b"edited-by-B",
        "B's edit was clobbered by the pushed version",
    );

    // The base for the conflicting path did NOT advance — it still holds what the
    // two peers last agreed on, so the next run sees the same divergence rather
    // than silently adopting one side.
    let (base_after, base_objects_after) = {
        let store = context_a.apply_store.lock().unwrap();
        (
            store.load_base_manifest(project).unwrap(),
            store.load_base_objects(project).unwrap(),
        )
    };
    let conflicted = base_after
        .iter()
        .find(|entry| entry.relative_path == "a-only.txt")
        .expect("a-only.txt still in the base");
    assert_eq!(
        conflicted.content_hash,
        *blake3::hash(b"lives-on-A").as_bytes(),
        "the base advanced to one side of an unresolved conflict",
    );
    // The base OBJECT must not drift away from the base manifest either. The
    // peer's version was staged in CAS for classification, and adopting it here
    // would resolve the conflict behind the user's back.
    assert_eq!(
        base_objects_after["a-only.txt"],
        ObjectId::for_plaintext(domain, b"lives-on-A"),
        "the base object adopted the peer's side of an unresolved conflict",
    );

    // The conflict was recorded, classified, and stored — it outlives the
    // operation, so it can be listed and resolved from another process later.
    let stored = {
        let store = context_a.apply_store.lock().unwrap();
        store.load_conflicts(domain).unwrap()
    };
    assert_eq!(stored.len(), 1, "one unresolved conflict recorded");
    let record = stored.iter().next().unwrap();
    assert_eq!(record.paths(), ["a-only.txt".to_string()]);
    assert_eq!(record.kind(), &ConflictKind::Text);
    // All three sides are on hand, so resolving needs no second round trip.
    assert_eq!(record.base().unwrap().bytes(), b"lives-on-A");
    assert_eq!(record.local().unwrap().bytes(), b"edited-by-A");
    assert_eq!(record.remote().unwrap().bytes(), b"edited-by-B");

    // ── Third sync: a deletion on each side propagates to the other. ──────────
    // `b-only.txt` is in the base and untouched since, so removing it locally is
    // an unambiguous delete (had either side edited it, it would be a conflict).
    // `shared.txt` never entered the base — both peers always had it identically —
    // so deleting it on B alone still reads as a remote-side change from A's view.
    std::fs::remove_file(local_root.path().join("b-only.txt")).unwrap();
    std::fs::write(peer_root.path().join("gets-deleted.txt"), b"doomed").unwrap();
    // `shared.txt` was identical on both peers from the very first sync, so it was
    // never transferred. It still belongs to the agreed state, and deleting it on
    // one side must propagate rather than be pushed back.
    std::fs::remove_file(peer_root.path().join("shared.txt")).unwrap();

    // Give B's copy a base first: one sync fetches it, the next can delete it.
    for (request, _label) in [("de".repeat(16), "seed"), ("ef".repeat(16), "delete")] {
        if request.starts_with("ef") {
            std::fs::remove_file(peer_root.path().join("gets-deleted.txt")).unwrap();
        }
        let op = manager
            .start(OperationStartParams {
                request_id: request,
                project_id: op_project_id.clone(),
                kind: OperationKind::Sync,
                peer: Some("peer-b".to_string()),
            })
            .await
            .unwrap();
        let mut done = None;
        for _ in 0..150 {
            let record = manager.status(&op.operation_id, &op_project_id).unwrap();
            if record.state.is_terminal() {
                done = Some(record);
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let record = done.expect("sync did not terminate in time");
        assert_eq!(
            record.state,
            OperationState::Succeeded,
            "sync failed: {:?}",
            record.error_code
        );
    }

    // A's deletion reached B (delete_remote, carried in the push manifest)...
    assert!(
        !peer_root.path().join("b-only.txt").exists(),
        "A's delete did not propagate to the peer"
    );
    // ...and B's deletion reached A (delete_local, applied from the reconcile).
    assert!(
        !local_root.path().join("gets-deleted.txt").exists(),
        "the peer's delete did not propagate to A"
    );
    // A path both peers already had is agreed state too: deleting it propagates
    // instead of coming back. Before the base recorded converged paths, A saw
    // this as a file the peer never had and pushed it straight back.
    assert!(
        !local_root.path().join("shared.txt").exists(),
        "the peer's delete of a never-transferred file did not reach A"
    );
    assert!(
        !peer_root.path().join("shared.txt").exists(),
        "shared.txt was resurrected on the peer"
    );
    // Deletions do not take neighbours with them.
    assert_eq!(
        std::fs::read(local_root.path().join("a-only.txt")).unwrap(),
        b"edited-by-A",
        "the unresolved conflict is still untouched",
    );

    stop.store(true, std::sync::atomic::Ordering::Release);
}
