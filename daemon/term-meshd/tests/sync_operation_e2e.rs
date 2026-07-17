//! Phase S0b + S1 + S2 end-to-end check: a `Sync` operation, driven through the
//! real `OperationManager`, dispatches to `NetworkSyncRunner`, which dials a
//! live peer over QUIC, swaps manifests, computes the diff between the two
//! project trees (S0b + S1), then fetches the files it lacks and applies them to
//! its working tree (S2 last mile) — so a file present only on the peer appears
//! on the initiator's disk, driven end-to-end by the operation machinery.
//! (`docs/design/mesh-project-sync-wiring-plan.md`.)

#[path = "../src/sync/mod.rs"]
mod sync;

use std::fs::File;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ed25519_dalek::SigningKey;
use sync::{
    exchange_manifests, respond_to_fetch, scan_project_entries, seed_trust_store, ApplyStore,
    BootstrapDevice, CasError, CasLimits, CasStore, DeviceTlsIdentity, KeyId, NetworkSyncRunner,
    ObjectDomain, ObjectType, OperationKind, OperationManager, OperationStartParams, OperationState,
    PeerAddressResolver, ProjectId, ProjectKey, ProjectKeyMaterial, ProjectKeyProvider,
    ProjectRegistry, SyncConnection, SyncContext, SyncContextProvider, SyncEndpoint, TrustStore,
};
use sync_protocol::{SyncHello, PROJECT_SYNC_CAPABILITY, PROTOCOL_V1};

/// Both CAS peers share this project key so the initiator can decrypt what the
/// responder encrypts (a documented CAS invariant).
const KEY_BYTES: [u8; 32] = [0x5c; 32];
const KEY_ID: KeyId = KeyId([0x11; 16]);

struct FixedResolver(SocketAddr);

impl PeerAddressResolver for FixedResolver {
    fn resolve(&self, _peer_id: &str) -> Option<SocketAddr> {
        Some(self.0)
    }
}

/// Returns one pre-built context for every project (the test syncs a single
/// project); the daemon's real provider opens per-project stores by id.
struct FixedContextProvider(Arc<SyncContext>);

impl SyncContextProvider for FixedContextProvider {
    fn context_for(&self, _project_id: &str) -> Result<Arc<SyncContext>, String> {
        Ok(self.0.clone())
    }
}

struct FixedKeyProvider;

impl ProjectKeyProvider for FixedKeyProvider {
    fn current_project_key(&self, _project: ProjectId) -> Result<ProjectKeyMaterial, CasError> {
        Ok(ProjectKeyMaterial {
            key_id: KEY_ID,
            key: ProjectKey::new(KEY_BYTES),
        })
    }
    fn project_key(&self, _project: ProjectId, _key_id: KeyId) -> Result<ProjectKey, CasError> {
        Ok(ProjectKey::new(KEY_BYTES))
    }
}

fn cas_store(dir: &std::path::Path) -> CasStore {
    CasStore::open(dir, CasLimits::default(), Arc::new(FixedKeyProvider)).unwrap()
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn sync_operation_exchanges_manifests_and_finds_the_diff() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x41; 32]);
    let project = [0x42; 32];
    let device_a = [0x43; 32]; // local device (the runner)
    let device_b = [0x44; 32]; // peer (source of truth)
    let identity_a = DeviceTlsIdentity::generate().unwrap();
    let identity_b = DeviceTlsIdentity::generate().unwrap();
    let project_id = sync::ProjectId::from_bytes(project);

    let trust_a = Arc::new(
        TrustStore::open(
            temporary.path().join("trust_a.sqlite3"),
            project_id,
            recovery.verifying_key().to_bytes(),
        )
        .unwrap(),
    );
    let trust_b = Arc::new(
        TrustStore::open(
            temporary.path().join("trust_b.sqlite3"),
            project_id,
            recovery.verifying_key().to_bytes(),
        )
        .unwrap(),
    );
    let roster = [
        BootstrapDevice {
            device_id: device_a,
            identity: &identity_a,
            epoch: 1,
        },
        BootstrapDevice {
            device_id: device_b,
            identity: &identity_b,
            epoch: 2,
        },
    ];
    seed_trust_store(&trust_a, project_id, &recovery, &roster).unwrap();
    seed_trust_store(&trust_b, project_id, &recovery, &roster).unwrap();

    // Two project trees sharing `shared.txt` (identical bytes → not in the
    // diff); the peer additionally has `extra.txt`, which the runner lacks.
    let local_root = tempfile::tempdir().unwrap();
    std::fs::write(local_root.path().join("shared.txt"), b"same-content").unwrap();
    let peer_root = tempfile::tempdir().unwrap();
    std::fs::write(peer_root.path().join("shared.txt"), b"same-content").unwrap();
    std::fs::write(peer_root.path().join("extra.txt"), b"only-on-the-peer").unwrap();
    let peer_root_path = peer_root.path().to_path_buf();

    // Peer: accept, then run the symmetric manifest exchange from its own tree.
    let server = SyncEndpoint::server(
        SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
        trust_b.clone(),
        &identity_b,
    )
    .unwrap();
    let server_addr = server.local_addr().unwrap();
    let cas_source = cas_store(&temporary.path().join("cas_source"));
    let responder_key = ProjectKey::new(KEY_BYTES);
    let domain = ObjectDomain {
        project_id,
        object_type: ObjectType::FILE,
        version: 1,
    };
    let _server_task = tokio::spawn(async move {
        if let Ok(auth) = server.accept(hello(project, device_b, 2, 7)).await {
            let mut connection = SyncConnection::start(auth);
            let root = File::open(&peer_root_path).unwrap();
            let entries = scan_project_entries(&root).unwrap();
            if exchange_manifests(&mut connection, &entries).await.is_ok() {
                // S2: answer the initiator's fetch request from our own tree.
                let _ = respond_to_fetch(
                    &mut connection,
                    &cas_source,
                    &peer_root_path,
                    domain,
                    &responder_key,
                    KEY_ID,
                    &entries,
                )
                .await;
                // Hold the connection open until the initiator has drained the
                // response and hung up; dropping it right after `respond_to_fetch`
                // would reset the still-in-flight `done`/chunk streams before they
                // flush, so the initiator would see `fetch_closed`. (A real daemon
                // keeps peer connections in a session pool; this models that.)
                while connection.recv().await.is_some() {}
            }
        }
    });

    // The initiator's per-project context: identity + roster coordinates, the
    // trust store, and the CAS (shares the peer's project key) + apply store the
    // fetched objects land through.
    let cas_runner = Arc::new(cas_store(&temporary.path().join("cas_runner")));
    let apply_store = Arc::new(Mutex::new(
        ApplyStore::open(state_dir(temporary.path(), "apply-state").join("apply.db")).unwrap(),
    ));
    let context = Arc::new(SyncContext {
        identity: identity_a,
        trust: trust_a,
        device_id: device_a,
        project_id: project,
        roster_epoch: 2,
        cas: cas_runner,
        apply_store,
    });
    let runner = NetworkSyncRunner::new(
        Arc::new(FixedContextProvider(context)),
        Arc::new(FixedResolver(server_addr)),
        tokio::runtime::Handle::current(),
    );

    // Register the runner's local tree as a project so the manager can hold its
    // root for the operation. Each SecureSqlite store gets its own 0700 dir.
    let registry_state = state_dir(temporary.path(), "registry-state");
    let registry = Arc::new(ProjectRegistry::open(registry_state.join("registry.db")).unwrap());
    let record = registry.add(local_root.path()).unwrap();
    let op_project_id = record.project_id.to_string();

    let ops_state = state_dir(temporary.path(), "sync-state");
    let manager = OperationManager::open_with_sync_transport(
        ops_state.join("operations.db"),
        registry,
        Arc::new(runner),
    )
    .unwrap();

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
        let record = manager
            .status(&started.operation_id, &op_project_id)
            .unwrap();
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
    // The diff must be exactly one fetch: the peer's `extra.txt`. `shared.txt`
    // is byte-identical on both sides and must not appear.
    assert_eq!(result.entries, 1, "expected exactly one file to fetch (extra.txt)");

    // S2 last mile: the fetched file was applied to the initiator's working
    // tree, so `extra.txt` now exists on the local root with the peer's bytes.
    let applied = std::fs::read(local_root.path().join("extra.txt"))
        .expect("extra.txt applied to the initiator's project root");
    assert_eq!(applied, b"only-on-the-peer", "applied file differs from the peer");
}
