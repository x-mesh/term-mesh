//! Phase S0b end-to-end check: an `OperationKind::Sync` operation, driven
//! through the real `OperationManager`, dispatches to `NetworkSyncRunner`, which
//! dials a live peer over QUIC and completes a lane exchange — proving the
//! operation machinery drives the S0 transport pipe. (`docs/design/
//! mesh-project-sync-wiring-plan.md`, phase S0b.)

#[path = "../src/sync/mod.rs"]
mod sync;

use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use ed25519_dalek::SigningKey;
use sync::{
    seed_trust_store, BootstrapDevice, DeviceTlsIdentity, NetworkSyncRunner, OperationKind,
    OperationManager, OperationStartParams, OperationState, PeerAddressResolver, ProjectRegistry,
    SyncConnection, SyncEndpoint, TrustStore,
};
use sync_protocol::{SyncHello, PROJECT_SYNC_CAPABILITY, PROTOCOL_V1};

struct FixedResolver(SocketAddr);

impl PeerAddressResolver for FixedResolver {
    fn resolve(&self, _peer_id: &str) -> Option<SocketAddr> {
        Some(self.0)
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn sync_operation_dispatches_to_network_runner_and_reaches_a_peer() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x41; 32]);
    let project = [0x42; 32];
    let device_a = [0x43; 32]; // the local device the runner speaks as
    let device_b = [0x44; 32]; // the peer (echo server)
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

    // Peer: an echo server that reflects whatever the runner sends.
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
            while let Some((lane, payload)) = connection.recv().await {
                if connection.send(lane, payload).await.is_err() {
                    break;
                }
            }
        }
    });

    // The runner, speaking as device A, resolving any peer id to the server.
    let runner = NetworkSyncRunner::new(
        identity_a,
        trust_a,
        device_a,
        project,
        2,
        Arc::new(FixedResolver(server_addr)),
        tokio::runtime::Handle::current(),
    );

    // A registered local project (any real root) so the manager can resolve a
    // held root for the operation. Its id is independent of the mesh project id
    // the runner authenticates with.
    let root_dir = tempfile::tempdir().unwrap();
    // Each SecureSqlite store needs its own 0700 directory (it validates the
    // parent dir mode + owner), so give the registry and operations DBs
    // dedicated state dirs — the same convention the sync_rpc tests use.
    let registry_state = state_dir(temporary.path(), "registry-state");
    let registry = Arc::new(ProjectRegistry::open(registry_state.join("registry.db")).unwrap());
    let record = registry.add(root_dir.path()).unwrap();
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

    // Poll to completion.
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
    // The runner reports the peer's pinned certificate hash — proof it actually
    // completed the mutual-pinned handshake with device B.
    assert_eq!(result.manifest_root, hex::encode(identity_b.certificate_hash()));
    assert_eq!(result.entries, 1);
}
