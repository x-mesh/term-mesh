//! Phase S2c end-to-end check: the initiator computes a diff, fetches the files
//! it lacks from the peer over the ordered SyncOperation lane, and applies them
//! to its filesystem — so a file present only on the peer appears on the
//! initiator's disk, driven by the fetch protocol (not a hand-placed CAS
//! object). (`docs/design/mesh-project-sync-wiring-plan.md`, phase S2c.)

#[path = "../src/sync/mod.rs"]
mod sync;

use std::fs::File;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;

use ed25519_dalek::SigningKey;
use sync::{
    build_apply_plan, diff_manifests, respond_to_fetch, run_fetch_pull, scan_project_entries,
    seed_trust_store, ApplyStore, BootstrapDevice, CasError, CasLimits, CasStore, DeviceTlsIdentity,
    KeyId, ObjectDomain, ObjectType, ProjectId, ProjectKey, ProjectKeyMaterial, ProjectKeyProvider,
    SyncConnection, SyncEndpoint, TrustStore,
};
use sync_protocol::{SyncHello, PROJECT_SYNC_CAPABILITY, PROTOCOL_V1};

const KEY_BYTES: [u8; 32] = [0x5c; 32];
const KEY_ID: KeyId = KeyId([0x11; 16]);

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
async fn fetch_pulls_and_applies_a_missing_file() {
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
        BootstrapDevice { device_id: device_a, identity: &identity_a, epoch: 1 },
        BootstrapDevice { device_id: device_b, identity: &identity_b, epoch: 2 },
    ];
    seed_trust_store(&trust_a, project_id, &recovery, &roster).unwrap();
    seed_trust_store(&trust_b, project_id, &recovery, &roster).unwrap();

    // Peer (A) has `extra.txt`; the initiator (B) starts empty.
    let source_root = tempfile::tempdir().unwrap();
    let content: Vec<u8> = (0..5000).map(|i| (i * 13 + 1) as u8).collect();
    std::fs::write(source_root.path().join("extra.txt"), &content).unwrap();
    let dest_root = tempfile::tempdir().unwrap();

    let source_entries = scan_project_entries(&File::open(source_root.path()).unwrap()).unwrap();
    let dest_entries = scan_project_entries(&File::open(dest_root.path()).unwrap()).unwrap();
    // B's diff against A: it must fetch exactly `extra.txt`.
    let diff = diff_manifests(&dest_entries, &source_entries);
    assert_eq!(diff.fetch.len(), 1);

    let cas_source = cas_store(&temporary.path().join("cas_source"));
    let cas_dest = cas_store(&temporary.path().join("cas_dest"));
    let domain = ObjectDomain { project_id, object_type: ObjectType::FILE, version: 1 };

    // Authenticated connection.
    let server = SyncEndpoint::server(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), trust_a.clone(), &identity_a).unwrap();
    let client = SyncEndpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), trust_b.clone(), &identity_b).unwrap();
    let address = server.local_addr().unwrap();
    let (accepted, connected) = tokio::join!(
        server.accept(hello(project, device_a, 2, 1)),
        client.connect(address, hello(project, device_b, 2, 2)),
    );
    let mut conn_source = SyncConnection::start(accepted.unwrap());
    let mut conn_dest = SyncConnection::start(connected.unwrap());

    // B pulls its fetch list while A responds from its manifest.
    let source_root_path = source_root.path().to_path_buf();
    let responder_key = ProjectKey::new(KEY_BYTES);
    let (pull, respond) = tokio::join!(
        run_fetch_pull(&mut conn_dest, &cas_dest, domain, &diff.fetch),
        respond_to_fetch(
            &mut conn_source,
            &cas_source,
            &source_root_path,
            domain,
            &responder_key,
            KEY_ID,
            &source_entries,
        ),
    );
    respond.expect("respond_to_fetch");
    let resolved = pull.expect("run_fetch_pull");
    assert!(resolved.contains_key("extra.txt"));

    // Apply the fetched object to B's filesystem.
    let apply_store = ApplyStore::open(state_dir(temporary.path(), "apply-state").join("apply.db")).unwrap();
    let plan = build_apply_plan(project_id, [9; 16], &diff.fetch, &resolved, &dest_entries);
    apply_store.apply(dest_root.path(), &cas_dest, domain, &plan).expect("apply");

    let applied = std::fs::read(dest_root.path().join("extra.txt")).expect("applied file exists");
    assert_eq!(applied, content, "applied file differs from peer");
}
