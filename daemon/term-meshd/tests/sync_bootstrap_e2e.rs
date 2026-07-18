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
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ed25519_dalek::SigningKey;
use sync::{
    ensure_device_identity, exchange_manifests, generate_project_key, load_device_tls_identity,
    load_project_key, respond_to_fetch, run_bootstrap_trust, scan_project_entries, serve_project,
    BootstrapDevice, CasLimits, CasStore, DaemonBootstrapPaths, KeychainBackend, KeychainError,
    KeychainItem, KeychainProjectKeyProvider, LocalCoordinates, NetworkSyncRunner, ObjectDomain,
    ObjectType, OperationKind, OperationManager, OperationStartParams, OperationState, ProjectId,
    ProjectRegistry, ProvisioningPeerResolver, ProvisioningSyncContextProvider, SyncConnection,
    SyncContextProvider, SyncEndpoint, SyncProvisioningStore, TrustStore,
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
    use std::os::unix::fs::PermissionsExt;
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
