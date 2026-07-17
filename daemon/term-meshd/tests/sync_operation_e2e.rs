//! Phase S0b + S1 end-to-end check: a `Sync` operation, driven through the real
//! `OperationManager`, dispatches to `NetworkSyncRunner`, which dials a live
//! peer over QUIC, swaps manifests, and computes the diff between the two
//! project trees. Proves the operation machinery drives the transport pipe
//! (S0b) and that the manifest exchange finds exactly the differing files (S1).
//! No bytes are moved (that is S2). (`docs/design/mesh-project-sync-wiring-plan.md`.)

#[path = "../src/sync/mod.rs"]
mod sync;

use std::fs::File;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use ed25519_dalek::SigningKey;
use sync::{
    exchange_manifests, scan_project_entries, seed_trust_store, BootstrapDevice, DeviceTlsIdentity,
    NetworkSyncRunner, OperationKind, OperationManager, OperationStartParams, OperationState,
    PeerAddressResolver, ProjectRegistry, SyncConnection, SyncEndpoint, TrustStore,
};
use sync_protocol::{SyncHello, PROJECT_SYNC_CAPABILITY, PROTOCOL_V1};

struct FixedResolver(SocketAddr);

impl PeerAddressResolver for FixedResolver {
    fn resolve(&self, _peer_id: &str) -> Option<SocketAddr> {
        Some(self.0)
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
    let _server_task = tokio::spawn(async move {
        if let Ok(auth) = server.accept(hello(project, device_b, 2, 7)).await {
            let mut connection = SyncConnection::start(auth);
            let root = File::open(&peer_root_path).unwrap();
            let entries = scan_project_entries(&root).unwrap();
            let _ = exchange_manifests(&mut connection, &entries).await;
        }
    });

    let runner = NetworkSyncRunner::new(
        identity_a,
        trust_a,
        device_a,
        project,
        2,
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
}
