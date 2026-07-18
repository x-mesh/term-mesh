//! Push-protocol end-to-end check (BD-3, bidirectional sync): the initiator
//! streams its local-changed files to the peer, which stages them into CAS and
//! applies them to its own filesystem — so a file present only on the initiator
//! appears on the peer's disk, driven by the push protocol (the mirror of the
//! fetch protocol). This is the "send" half that makes sync bidirectional.

#[path = "../src/sync/mod.rs"]
mod sync;

use std::fs::File;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;

use ed25519_dalek::SigningKey;
use sync::{
    diff_manifests, receive_push, run_push, scan_project_entries, seed_trust_store, ApplyStore,
    BootstrapDevice, CasError, CasLimits, CasStore, DeviceTlsIdentity, KeyId, ObjectDomain,
    ObjectType, ProjectId, ProjectKey, ProjectKeyMaterial, ProjectKeyProvider, SyncConnection,
    SyncEndpoint, TrustStore,
};
use sync_protocol::{SyncHello, PROJECT_SYNC_CAPABILITY, PROTOCOL_V1};

const KEY_BYTES: [u8; 32] = [0x5c; 32];
const KEY_ID: KeyId = KeyId([0x11; 16]);

struct FixedKeyProvider;

impl ProjectKeyProvider for FixedKeyProvider {
    fn current_project_key(&self, _project: ProjectId) -> Result<ProjectKeyMaterial, CasError> {
        Ok(ProjectKeyMaterial { key_id: KEY_ID, key: ProjectKey::new(KEY_BYTES) })
    }
    fn project_key(&self, _project: ProjectId, _key_id: KeyId) -> Result<ProjectKey, CasError> {
        Ok(ProjectKey::new(KEY_BYTES))
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

fn cas_store(dir: &std::path::Path) -> CasStore {
    CasStore::open(dir, CasLimits::default(), Arc::new(FixedKeyProvider)).unwrap()
}

fn state_dir(base: &std::path::Path, name: &str) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let dir = base.join(name);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    dir
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn push_streams_and_applies_a_local_file_to_the_peer() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x41; 32]);
    let project = [0x42; 32];
    let device_a = [0x43; 32];
    let device_b = [0x44; 32];
    let identity_a = DeviceTlsIdentity::generate().unwrap();
    let identity_b = DeviceTlsIdentity::generate().unwrap();
    let project_id = ProjectId::from_bytes(project);

    let trust_a = Arc::new(TrustStore::open(temporary.path().join("trust_a.sqlite3"), project_id, recovery.verifying_key().to_bytes()).unwrap());
    let trust_b = Arc::new(TrustStore::open(temporary.path().join("trust_b.sqlite3"), project_id, recovery.verifying_key().to_bytes()).unwrap());
    let roster = [
        BootstrapDevice { device_id: device_a, certificate_hash: identity_a.certificate_hash(), epoch: 1 },
        BootstrapDevice { device_id: device_b, certificate_hash: identity_b.certificate_hash(), epoch: 2 },
    ];
    seed_trust_store(&trust_a, project_id, &recovery, &roster).unwrap();
    seed_trust_store(&trust_b, project_id, &recovery, &roster).unwrap();

    // Initiator (A) holds a nested file the peer (B) lacks; B starts empty.
    let source_root = tempfile::tempdir().unwrap();
    let content: Vec<u8> = (0..5000).map(|i| (i * 7 + 3) as u8).collect();
    std::fs::create_dir(source_root.path().join("sub")).unwrap();
    std::fs::write(source_root.path().join("sub/pushed.bin"), &content).unwrap();
    let dest_root = tempfile::tempdir().unwrap();

    // A pushes its full manifest (the file + its ancestor dir); B is empty.
    // (`diff_manifests(&[], &source)` yields every source entry as a FetchEntry —
    // exactly what BidiPlan.push carries in the wired path.)
    let source_entries = scan_project_entries(&File::open(source_root.path()).unwrap()).unwrap();
    let push_entries = diff_manifests(&[], &source_entries).fetch;
    let dest_entries = scan_project_entries(&File::open(dest_root.path()).unwrap()).unwrap();

    let cas_source = cas_store(&temporary.path().join("cas_source"));
    let cas_dest = cas_store(&temporary.path().join("cas_dest"));
    let domain = ObjectDomain { project_id, object_type: ObjectType::FILE, version: 1 };

    let server = SyncEndpoint::server(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), trust_a.clone(), &identity_a).unwrap();
    let client = SyncEndpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), trust_b.clone(), &identity_b).unwrap();
    let address = server.local_addr().unwrap();
    let (accepted, connected) = tokio::join!(
        server.accept(hello(project, device_a, 2, 1)),
        client.connect(address, hello(project, device_b, 2, 2)),
    );
    let mut conn_source = SyncConnection::start(accepted.unwrap()); // A (pusher)
    let mut conn_dest = SyncConnection::start(connected.unwrap()); // B (receiver)

    let apply_store = std::sync::Mutex::new(
        ApplyStore::open(state_dir(temporary.path(), "apply-state").join("apply.db")).unwrap(),
    );
    let source_root_path = source_root.path().to_path_buf();
    let dest_root_path = dest_root.path().to_path_buf();
    let key = ProjectKey::new(KEY_BYTES);

    // A pushes while B receives + applies.
    let (pushed, received) = tokio::join!(
        run_push(&mut conn_source, &cas_source, &source_root_path, domain, &key, KEY_ID, &push_entries, &[]),
        receive_push(&mut conn_dest, &cas_dest, &dest_root_path, domain, &apply_store, project_id, &dest_entries),
    );
    pushed.expect("run_push");
    let applied = received.expect("receive_push");
    assert!(applied >= 1, "at least the file was applied");

    let got = std::fs::read(dest_root.path().join("sub/pushed.bin")).expect("pushed file exists on peer");
    assert_eq!(got, content, "pushed file differs from the initiator");
}
