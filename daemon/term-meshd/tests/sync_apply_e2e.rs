//! Phase S2b end-to-end check: a file's content transfers from a source peer,
//! lands in the destination CAS, and is applied to the destination filesystem —
//! so a file present only on A appears byte-identically on B's disk. This closes
//! the "bytes move → real file on the peer" milestone via the primitives (the
//! runner-driven fetch protocol is S2c). (`docs/design/mesh-project-sync-wiring-plan.md`.)

#[path = "../src/sync/mod.rs"]
mod sync;

use std::fs::File;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;

use ed25519_dalek::SigningKey;
use sync::{
    build_apply_plan, diff_manifests, put_plaintext, recv_object, scan_project_entries,
    seed_trust_store, send_object, ApplyAction, ApplyPlan, ApplyPlanEntry, ApplyPrecondition,
    ApplyStore, BootstrapDevice, CasError, CasLimits, CasStore, DeviceTlsIdentity, EntryKind, KeyId,
    ObjectDomain, ObjectType, ProjectId, ProjectKey, ProjectKeyMaterial, ProjectKeyProvider,
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

fn cas(dir: &std::path::Path) -> CasStore {
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
async fn transferred_object_is_applied_to_the_destination_filesystem() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x41; 32]);
    let project = [0x42; 32];
    let device_a = [0x43; 32];
    let device_b = [0x44; 32];
    let identity_a = DeviceTlsIdentity::generate().unwrap();
    let identity_b = DeviceTlsIdentity::generate().unwrap();
    let project_id = ProjectId::from_bytes(project);

    let trust_a = Arc::new(
        TrustStore::open(temporary.path().join("trust_a.sqlite3"), project_id, recovery.verifying_key().to_bytes()).unwrap(),
    );
    let trust_b = Arc::new(
        TrustStore::open(temporary.path().join("trust_b.sqlite3"), project_id, recovery.verifying_key().to_bytes()).unwrap(),
    );
    let roster = [
        BootstrapDevice { device_id: device_a, certificate_hash: identity_a.certificate_hash(), epoch: 1 },
        BootstrapDevice { device_id: device_b, certificate_hash: identity_b.certificate_hash(), epoch: 2 },
    ];
    seed_trust_store(&trust_a, project_id, &recovery, &roster).unwrap();
    seed_trust_store(&trust_b, project_id, &recovery, &roster).unwrap();

    // Source tree holds a root-level `report.txt`; the destination tree is empty.
    let source_root = tempfile::tempdir().unwrap();
    let content: Vec<u8> = (0..3000).map(|i| (i * 7 + 3) as u8).collect();
    std::fs::write(source_root.path().join("report.txt"), &content).unwrap();
    let dest_root = tempfile::tempdir().unwrap();

    // Scan the source to get the manifest entry (its content_hash is what apply
    // verifies the transferred object against).
    let source_fd = File::open(source_root.path()).unwrap();
    let entry = scan_project_entries(&source_fd)
        .unwrap()
        .into_iter()
        .find(|e| e.relative_path == "report.txt" && e.kind == EntryKind::File)
        .expect("source manifest has the file");

    // Put the file's bytes into the source CAS.
    let cas_source = cas(&temporary.path().join("cas_source"));
    let cas_dest = cas(&temporary.path().join("cas_dest"));
    let domain = ObjectDomain { project_id, object_type: ObjectType::FILE, version: 1 };
    let object_id = put_plaintext(&cas_source, domain, &ProjectKey::new(KEY_BYTES), KEY_ID, &content).unwrap();

    // Connect and transfer the object source -> dest.
    let server = SyncEndpoint::server(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), trust_a.clone(), &identity_a).unwrap();
    let client = SyncEndpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), trust_b.clone(), &identity_b).unwrap();
    let address = server.local_addr().unwrap();
    let (accepted, connected) = tokio::join!(
        server.accept(hello(project, device_a, 2, 1)),
        client.connect(address, hello(project, device_b, 2, 2)),
    );
    let conn_source = SyncConnection::start(accepted.unwrap());
    let mut conn_dest = SyncConnection::start(connected.unwrap());
    let (send_result, recv_result) = tokio::join!(
        send_object(&conn_source, &cas_source, domain, object_id, content.len() as u64),
        recv_object(&mut conn_dest, &cas_dest, domain, object_id, content.len() as u64),
    );
    send_result.expect("send_object");
    recv_result.expect("recv_object");

    // Apply the transferred object to the destination filesystem.
    let apply_store =
        ApplyStore::open(state_dir(temporary.path(), "apply-state").join("apply.db")).unwrap();
    let plan = ApplyPlan {
        operation_id: [7; 16],
        project: project_id,
        target_manifest_root: [0; 32],
        frontier: Vec::new(),
        entries: vec![ApplyPlanEntry {
            relative_path: "report.txt".to_string(),
            action: ApplyAction::File {
                object_id,
                content_hash: entry.content_hash,
                length: entry.length,
                executable: entry.executable,
            },
            precondition: ApplyPrecondition::Absent,
        }],
    };
    apply_store
        .apply(dest_root.path(), &cas_dest, domain, &plan)
        .expect("apply to destination filesystem");

    // The file exists on B's disk, byte-identical to A's.
    let applied = std::fs::read(dest_root.path().join("report.txt")).expect("applied file exists");
    assert_eq!(applied, content, "applied file differs from source");
}

/// Phase S2c follow-up: a directory, a file nested inside it, and a symlink
/// beside the file all apply together onto an empty destination. Proves
/// `build_apply_plan` emits the directory first so the nested leaf has a parent
/// to land in (add-only, `Absent` preconditions).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn nested_directory_file_and_symlink_apply_together() {
    let temporary = tempfile::tempdir().unwrap();
    let project = [0x42; 32];
    let project_id = ProjectId::from_bytes(project);
    let domain = ObjectDomain {
        project_id,
        object_type: ObjectType::FILE,
        version: 1,
    };

    // Source tree: `sub/report.txt` plus a `sub/link -> report.txt` symlink.
    let source_root = tempfile::tempdir().unwrap();
    std::fs::create_dir(source_root.path().join("sub")).unwrap();
    let content = b"nested-report".to_vec();
    std::fs::write(source_root.path().join("sub/report.txt"), &content).unwrap();
    std::os::unix::fs::symlink("report.txt", source_root.path().join("sub/link")).unwrap();

    // Empty destination: every path (dir, file, symlink) is fetched.
    let source_entries = scan_project_entries(&File::open(source_root.path()).unwrap()).unwrap();
    let diff = diff_manifests(&[], &source_entries);

    // Stage the file's bytes into the destination CAS, as the fetch would.
    let cas_dest = cas(&temporary.path().join("cas_dest"));
    let key = ProjectKey::new(KEY_BYTES);
    let object_id = put_plaintext(&cas_dest, domain, &key, KEY_ID, &content).unwrap();
    let mut object_ids = std::collections::HashMap::new();
    object_ids.insert("sub/report.txt".to_string(), object_id);

    // Build + apply the plan onto an empty destination root (no local entries).
    let plan = build_apply_plan(project_id, [9; 16], &diff.fetch, &object_ids, &[]);
    let apply_store =
        ApplyStore::open(state_dir(temporary.path(), "apply-state").join("apply.db")).unwrap();
    let dest_root = tempfile::tempdir().unwrap();
    apply_store
        .apply(dest_root.path(), &cas_dest, domain, &plan)
        .expect("apply nested tree to destination filesystem");

    // The directory was created, the nested file carries the source bytes, and
    // the symlink points where it did on the source.
    assert!(dest_root.path().join("sub").is_dir(), "sub/ created first");
    let applied =
        std::fs::read(dest_root.path().join("sub/report.txt")).expect("nested file exists");
    assert_eq!(applied, content, "nested file differs from source");
    let link = std::fs::read_link(dest_root.path().join("sub/link")).expect("symlink exists");
    assert_eq!(link, std::path::Path::new("report.txt"), "symlink target");
}

/// Phase S2c follow-up: a file that already exists on the destination with older
/// bytes is overwritten with the source's bytes, guarded by a `Present`
/// precondition over the destination's current fingerprint (so a concurrently
/// edited file would be refused instead of clobbered).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn file_overwrite_replaces_existing_content() {
    let temporary = tempfile::tempdir().unwrap();
    let project = [0x42; 32];
    let project_id = ProjectId::from_bytes(project);
    let domain = ObjectDomain {
        project_id,
        object_type: ObjectType::FILE,
        version: 1,
    };

    // Destination already holds report.txt with the OLD content.
    let dest_root = tempfile::tempdir().unwrap();
    let old = b"old-content".to_vec();
    std::fs::write(dest_root.path().join("report.txt"), &old).unwrap();
    let dest_entries = scan_project_entries(&File::open(dest_root.path()).unwrap()).unwrap();

    // Source has report.txt with NEW content; the diff is exactly one overwrite.
    let source_root = tempfile::tempdir().unwrap();
    let new = b"brand-new-content".to_vec();
    std::fs::write(source_root.path().join("report.txt"), &new).unwrap();
    let source_entries = scan_project_entries(&File::open(source_root.path()).unwrap()).unwrap();
    let diff = diff_manifests(&dest_entries, &source_entries);
    assert_eq!(diff.fetch.len(), 1);

    // Stage the new bytes into the destination CAS, as the fetch would.
    let cas_dest = cas(&temporary.path().join("cas_dest"));
    let key = ProjectKey::new(KEY_BYTES);
    let object_id = put_plaintext(&cas_dest, domain, &key, KEY_ID, &new).unwrap();
    let mut object_ids = std::collections::HashMap::new();
    object_ids.insert("report.txt".to_string(), object_id);

    // The plan guards the overwrite with the destination's current fingerprint.
    let plan = build_apply_plan(project_id, [3; 16], &diff.fetch, &object_ids, &dest_entries);
    assert!(
        matches!(plan.entries[0].precondition, ApplyPrecondition::Present(_)),
        "an existing path must be overwritten under a Present precondition"
    );

    let apply_store =
        ApplyStore::open(state_dir(temporary.path(), "apply-state").join("apply.db")).unwrap();
    apply_store
        .apply(dest_root.path(), &cas_dest, domain, &plan)
        .expect("overwrite applies to destination filesystem");

    let applied = std::fs::read(dest_root.path().join("report.txt")).expect("file exists");
    assert_eq!(applied, new, "overwrite did not replace the old content");
}
