#[path = "../src/sync/mod.rs"]
mod sync;

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;

use sync::{
    encrypt_chunk, ApplyAction, ApplyBoundary, ApplyCrashHook, ApplyError, ApplyIoPoint, ApplyPlan,
    ApplyPlanEntry, ApplyPrecondition, ApplyStore, CasError, CasLimits, CasStore, HeadDecision,
    KeyId, ObjectDomain, ObjectId, ObjectType, PathFingerprint, PathKind, ProjectId, ProjectKey,
    ProjectKeyMaterial, ProjectKeyProvider, ReconcileError, ReconcileStore, TransportPeerSnapshot,
};

const KEY: [u8; 32] = [0x63; 32];

struct FixedKeys;
impl ProjectKeyProvider for FixedKeys {
    fn current_project_key(&self, _: ProjectId) -> Result<ProjectKeyMaterial, CasError> {
        Ok(ProjectKeyMaterial {
            key_id: KeyId([1; 16]),
            key: ProjectKey::new(KEY),
        })
    }

    fn project_key(&self, _: ProjectId, key_id: KeyId) -> Result<ProjectKey, CasError> {
        if key_id != KeyId([1; 16]) {
            return Err(CasError::KeyUnavailable(key_id));
        }
        Ok(ProjectKey::new(KEY))
    }
}

struct CrashAt(ApplyBoundary);
impl ApplyCrashHook for CrashAt {
    fn after_boundary(&self, boundary: ApplyBoundary) -> Result<(), ApplyError> {
        if boundary == self.0 {
            Err(ApplyError::CrashInjected)
        } else {
            Ok(())
        }
    }
}

struct FailIo(ApplyIoPoint, i32);
impl ApplyCrashHook for FailIo {
    fn after_boundary(&self, _: ApplyBoundary) -> Result<(), ApplyError> {
        Ok(())
    }

    fn before_io(&self, point: ApplyIoPoint) -> Result<(), ApplyError> {
        if point == self.0 {
            Err(ApplyError::Io(std::io::Error::from_raw_os_error(self.1)))
        } else {
            Ok(())
        }
    }
}

struct EditAfterPrecheck(std::path::PathBuf);
impl ApplyCrashHook for EditAfterPrecheck {
    fn after_boundary(&self, boundary: ApplyBoundary) -> Result<(), ApplyError> {
        if boundary == ApplyBoundary::BackupIntent(0) {
            fs::write(&self.0, b"last second local edit").unwrap();
        }
        Ok(())
    }
}

enum SwapKind {
    Parent {
        parent: std::path::PathBuf,
        outside: std::path::PathBuf,
    },
    Target {
        target: std::path::PathBuf,
        outside_target: std::path::PathBuf,
    },
}
struct SwapAfterPrecheck(SwapKind);
impl ApplyCrashHook for SwapAfterPrecheck {
    fn after_boundary(&self, boundary: ApplyBoundary) -> Result<(), ApplyError> {
        if boundary != ApplyBoundary::BackupIntent(0) {
            return Ok(());
        }
        match &self.0 {
            SwapKind::Parent { parent, outside } => {
                fs::rename(parent, parent.with_extension("saved")).unwrap();
                std::os::unix::fs::symlink(outside, parent).unwrap();
            }
            SwapKind::Target {
                target,
                outside_target,
            } => {
                fs::remove_file(target).unwrap();
                std::os::unix::fs::symlink(outside_target, target).unwrap();
            }
        }
        Ok(())
    }
}

struct PausePrepared {
    ready: std::sync::mpsc::Sender<()>,
    release: std::sync::Mutex<std::sync::mpsc::Receiver<()>>,
}

struct CreateAfterSecondPrecheck(std::path::PathBuf);
impl ApplyCrashHook for CreateAfterSecondPrecheck {
    fn after_boundary(&self, boundary: ApplyBoundary) -> Result<(), ApplyError> {
        if boundary == ApplyBoundary::SecondPrecheck(0) {
            fs::write(&self.0, b"new local target").unwrap();
        }
        Ok(())
    }
}

struct EditAfterSecondPrecheck(std::path::PathBuf);
impl ApplyCrashHook for EditAfterSecondPrecheck {
    fn after_boundary(&self, boundary: ApplyBoundary) -> Result<(), ApplyError> {
        if boundary == ApplyBoundary::SecondPrecheck(0) {
            fs::write(&self.0, b"edited after precheck").unwrap();
        }
        Ok(())
    }
}

struct CreateBetweenBackupAndInstall(std::path::PathBuf);
impl ApplyCrashHook for CreateBetweenBackupAndInstall {
    fn after_boundary(&self, boundary: ApplyBoundary) -> Result<(), ApplyError> {
        if boundary == ApplyBoundary::BetweenBackupInstall(0) {
            fs::write(&self.0, b"local race winner").unwrap();
        }
        Ok(())
    }
}

struct EditDirectoryAfterPrecheck(std::path::PathBuf);
impl ApplyCrashHook for EditDirectoryAfterPrecheck {
    fn after_boundary(&self, boundary: ApplyBoundary) -> Result<(), ApplyError> {
        if boundary == ApplyBoundary::BackupIntent(0) {
            fs::write(self.0.join("child"), b"subtree changed").unwrap();
        }
        Ok(())
    }
}

struct CrashDuringRollback;
impl ApplyCrashHook for CrashDuringRollback {
    fn after_boundary(&self, boundary: ApplyBoundary) -> Result<(), ApplyError> {
        if boundary == ApplyBoundary::RollbackDurable(0) {
            return Err(ApplyError::CrashInjected);
        }
        Ok(())
    }
    fn before_io(&self, point: ApplyIoPoint) -> Result<(), ApplyError> {
        if point == ApplyIoPoint::InstallRename {
            Err(ApplyError::Io(std::io::Error::from_raw_os_error(libc::EIO)))
        } else {
            Ok(())
        }
    }
}

struct ProcessExitAt(String);
impl ApplyCrashHook for ProcessExitAt {
    fn after_boundary(&self, boundary: ApplyBoundary) -> Result<(), ApplyError> {
        let key = match boundary {
            ApplyBoundary::Prepared => "prepared",
            ApplyBoundary::TempDurable(0) => "temp_durable",
            ApplyBoundary::BackupIntent(0) => "backup_intent",
            ApplyBoundary::SecondPrecheck(0) => "second_precheck",
            ApplyBoundary::BackupDurable(0) => "backup_durable",
            ApplyBoundary::BetweenBackupInstall(0) => "between",
            ApplyBoundary::InstallIntent(0) => "install_intent",
            ApplyBoundary::InstalledDurable(0) => "installed_durable",
            ApplyBoundary::Committed => "committed",
            ApplyBoundary::CleanupDurable(0) => "cleanup",
            ApplyBoundary::RollbackDurable(0) => "rollback_durable",
            ApplyBoundary::RolledBack => "rolled_back",
            _ => "",
        };
        if self.0 == key {
            unsafe { libc::_exit(86) }
        }
        Ok(())
    }

    fn before_io(&self, point: ApplyIoPoint) -> Result<(), ApplyError> {
        let key = match point {
            ApplyIoPoint::TempWrite => "temp_write_before",
            ApplyIoPoint::TempFsync => "temp_fsync_before",
            ApplyIoPoint::TempWorkFsync => "temp_work_fsync_before",
            ApplyIoPoint::BackupRename => "backup_rename_before",
            ApplyIoPoint::BackupParentFsync => "backup_parent_fsync_before",
            ApplyIoPoint::BackupWorkFsync => "backup_work_fsync_before",
            ApplyIoPoint::InstallRename => "install_rename_before",
            ApplyIoPoint::InstallFileFsync => "install_file_fsync_before",
            ApplyIoPoint::InstallParentFsync => "install_parent_fsync_before",
            ApplyIoPoint::RollbackTrashRename => "rollback_trash_rename_before",
            ApplyIoPoint::RollbackTrashParentFsync => "rollback_trash_parent_fsync_before",
            ApplyIoPoint::RollbackTrashWorkFsync => "rollback_trash_work_fsync_before",
            ApplyIoPoint::RollbackRestoreRename => "rollback_restore_rename_before",
            ApplyIoPoint::RollbackRestoreFileFsync => "rollback_restore_file_fsync_before",
            ApplyIoPoint::RollbackRestoreParentFsync => "rollback_restore_parent_fsync_before",
            ApplyIoPoint::RollbackRestoreWorkFsync => "rollback_restore_work_fsync_before",
            ApplyIoPoint::RollbackTrashUnlink => "rollback_trash_unlink_before",
            ApplyIoPoint::RollbackTrashUnlinkFsync => "rollback_trash_unlink_fsync_before",
            ApplyIoPoint::CleanupUnlink => "cleanup_before",
        };
        if self.0 == key {
            unsafe { libc::_exit(86) }
        }
        if self.0.starts_with("rollback_") && point == ApplyIoPoint::InstallFileFsync {
            return Err(ApplyError::Io(std::io::Error::from_raw_os_error(libc::EIO)));
        }
        Ok(())
    }

    fn after_io(&self, point: ApplyIoPoint) -> Result<(), ApplyError> {
        let key = match point {
            ApplyIoPoint::TempWrite => "temp_write",
            ApplyIoPoint::TempFsync => "temp_fsync",
            ApplyIoPoint::TempWorkFsync => "temp_work_fsync",
            ApplyIoPoint::BackupRename => "backup_rename",
            ApplyIoPoint::BackupParentFsync => "backup_parent_fsync",
            ApplyIoPoint::BackupWorkFsync => "backup_work_fsync",
            ApplyIoPoint::InstallRename => "install_rename",
            ApplyIoPoint::InstallFileFsync => "install_file_fsync",
            ApplyIoPoint::InstallParentFsync => "install_parent_fsync",
            ApplyIoPoint::RollbackTrashRename => "rollback_trash_rename",
            ApplyIoPoint::RollbackTrashParentFsync => "rollback_trash_parent_fsync",
            ApplyIoPoint::RollbackTrashWorkFsync => "rollback_trash_work_fsync",
            ApplyIoPoint::RollbackRestoreRename => "rollback_restore_rename",
            ApplyIoPoint::RollbackRestoreFileFsync => "rollback_restore_file_fsync",
            ApplyIoPoint::RollbackRestoreParentFsync => "rollback_restore_parent_fsync",
            ApplyIoPoint::RollbackRestoreWorkFsync => "rollback_restore_work_fsync",
            ApplyIoPoint::RollbackTrashUnlink => "rollback_trash_unlink",
            ApplyIoPoint::RollbackTrashUnlinkFsync => "rollback_trash_unlink_fsync",
            ApplyIoPoint::CleanupUnlink => "cleanup_unlink",
        };
        if self.0 == key {
            unsafe { libc::_exit(86) }
        }
        Ok(())
    }
}
impl ApplyCrashHook for PausePrepared {
    fn after_boundary(&self, boundary: ApplyBoundary) -> Result<(), ApplyError> {
        if boundary == ApplyBoundary::Prepared {
            self.ready.send(()).unwrap();
            self.release.lock().unwrap().recv().unwrap();
        }
        Ok(())
    }
}

fn domain(project: ProjectId) -> ObjectDomain {
    ObjectDomain {
        project_id: project,
        object_type: ObjectType::FILE,
        version: 1,
    }
}

fn install(cas: &CasStore, domain: ObjectDomain, bytes: &[u8]) -> ObjectId {
    let id = ObjectId::for_plaintext(domain, bytes);
    let mut stage = cas.begin_stage(domain, id, bytes.len() as u64).unwrap();
    let envelope = encrypt_chunk(
        &ProjectKey::new(KEY),
        domain,
        id,
        bytes.len() as u64,
        0,
        bytes,
    )
    .unwrap();
    stage.write_encrypted_chunk(0, &envelope).unwrap();
    stage.finish().unwrap();
    id
}

fn fingerprint(bytes: &[u8]) -> PathFingerprint {
    PathFingerprint {
        kind: PathKind::File,
        content_hash: *blake3::hash(bytes).as_bytes(),
        length: bytes.len() as u64,
        executable: false,
        symlink_target: None,
    }
}

fn replacement_plan(
    project: ProjectId,
    operation: u8,
    object_id: ObjectId,
    old: &[u8],
    new: &[u8],
) -> ApplyPlan {
    ApplyPlan {
        operation_id: [operation; 16],
        project,
        target_manifest_root: [operation; 32],
        frontier: vec![operation],
        entries: vec![ApplyPlanEntry {
            relative_path: "nested/file.txt".to_owned(),
            action: ApplyAction::File {
                object_id,
                content_hash: *blake3::hash(new).as_bytes(),
                length: new.len() as u64,
                executable: false,
            },
            precondition: ApplyPrecondition::Present(fingerprint(old)),
        }],
    }
}

#[test]
fn committed_visible_state_never_precedes_durable_file() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("project");
    fs::create_dir_all(root.join("nested")).unwrap();
    let old = b"local old";
    let new = b"remote new";
    fs::write(root.join("nested/file.txt"), old).unwrap();
    let project = ProjectId::from_bytes([3; 32]);
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let domain = domain(project);
    let object_id = install(&cas, domain, new);
    let store = ApplyStore::open(temporary.path().join("state/apply.sqlite")).unwrap();
    let plan = replacement_plan(project, 1, object_id, old, new);

    let visible = store.apply(&root, &cas, domain, &plan).unwrap();
    assert_eq!(fs::read(root.join("nested/file.txt")).unwrap(), new);
    assert_eq!(visible.manifest_root, [1; 32]);
    assert_eq!(store.visible_state(project).unwrap(), Some(visible));
}

#[test]
fn injected_crash_before_commit_rolls_back_and_reopen_converges() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("project");
    fs::create_dir_all(root.join("nested")).unwrap();
    let old = b"old";
    let new = b"new";
    fs::write(root.join("nested/file.txt"), old).unwrap();
    let project = ProjectId::from_bytes([4; 32]);
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let object_domain = domain(project);
    let object_id = install(&cas, object_domain, new);
    let database = temporary.path().join("state/apply.sqlite");
    let store = ApplyStore::open(&database).unwrap();
    let plan = replacement_plan(project, 2, object_id, old, new);

    assert!(matches!(
        store.apply_with_hook(
            &root,
            &cas,
            object_domain,
            &plan,
            &CrashAt(ApplyBoundary::InstalledDurable(0))
        ),
        Err(ApplyError::CrashInjected)
    ));
    assert_eq!(fs::read(root.join("nested/file.txt")).unwrap(), old);
    assert!(store.visible_state(project).unwrap().is_none());
    drop(store);

    let reopened = ApplyStore::open(database).unwrap();
    reopened.recover(&root, project).unwrap();
    assert_eq!(fs::read(root.join("nested/file.txt")).unwrap(), old);
    assert!(reopened.visible_state(project).unwrap().is_none());
}

#[test]
fn stale_precondition_and_unicode_case_collisions_mutate_nothing() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("project");
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join("file.txt"), b"edited after plan").unwrap();
    let project = ProjectId::from_bytes([5; 32]);
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let object_domain = domain(project);
    let new = b"remote";
    let object_id = install(&cas, object_domain, new);
    let store = ApplyStore::open(temporary.path().join("state/apply.sqlite")).unwrap();
    let stale = ApplyPlan {
        operation_id: [3; 16],
        project,
        target_manifest_root: [3; 32],
        frontier: vec![3],
        entries: vec![ApplyPlanEntry {
            relative_path: "file.txt".to_owned(),
            action: ApplyAction::File {
                object_id,
                content_hash: *blake3::hash(new).as_bytes(),
                length: new.len() as u64,
                executable: false,
            },
            precondition: ApplyPrecondition::Present(fingerprint(b"before edit")),
        }],
    };
    assert!(matches!(
        store.apply(&root, &cas, object_domain, &stale),
        Err(ApplyError::StalePrecondition(_))
    ));
    assert_eq!(
        fs::read(root.join("file.txt")).unwrap(),
        b"edited after plan"
    );

    let collision = ApplyPlan {
        operation_id: [4; 16],
        project,
        target_manifest_root: [4; 32],
        frontier: vec![4],
        entries: vec![
            ApplyPlanEntry {
                relative_path: "Foo".to_owned(),
                action: ApplyAction::Delete,
                precondition: ApplyPrecondition::Absent,
            },
            ApplyPlanEntry {
                relative_path: "foo".to_owned(),
                action: ApplyAction::Delete,
                precondition: ApplyPrecondition::Absent,
            },
        ],
    };
    assert!(matches!(
        store.apply(&root, &cas, object_domain, &collision),
        Err(ApplyError::Sandbox(_))
    ));
    assert!(store.visible_state(project).unwrap().is_none());
}

#[test]
fn every_apply_boundary_reopens_to_committed_or_rolled_back() {
    let boundaries = [
        ApplyBoundary::Prepared,
        ApplyBoundary::TempDurable(0),
        ApplyBoundary::BackupIntent(0),
        ApplyBoundary::BackupDurable(0),
        ApplyBoundary::InstallIntent(0),
        ApplyBoundary::InstalledDurable(0),
        ApplyBoundary::Committed,
        ApplyBoundary::CleanupDurable(0),
    ];
    for (index, boundary) in boundaries.into_iter().enumerate() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().join("project");
        fs::create_dir_all(&root).unwrap();
        let old = b"old boundary";
        let new = b"new boundary";
        fs::write(root.join("file.txt"), old).unwrap();
        let project = ProjectId::from_bytes([20 + index as u8; 32]);
        let cas = CasStore::open(
            temporary.path().join("cas"),
            CasLimits::default(),
            Arc::new(FixedKeys),
        )
        .unwrap();
        let object_domain = domain(project);
        let object_id = install(&cas, object_domain, new);
        let database = temporary.path().join("state/apply.sqlite");
        let store = ApplyStore::open(&database).unwrap();
        let plan = ApplyPlan {
            operation_id: [40 + index as u8; 16],
            project,
            target_manifest_root: [40 + index as u8; 32],
            frontier: vec![index as u8],
            entries: vec![ApplyPlanEntry {
                relative_path: "file.txt".to_owned(),
                action: ApplyAction::File {
                    object_id,
                    content_hash: *blake3::hash(new).as_bytes(),
                    length: new.len() as u64,
                    executable: false,
                },
                precondition: ApplyPrecondition::Present(fingerprint(old)),
            }],
        };
        assert!(matches!(
            store.apply_with_hook(&root, &cas, object_domain, &plan, &CrashAt(boundary)),
            Err(ApplyError::CrashInjected)
        ));
        drop(store);

        let reopened = ApplyStore::open(&database).unwrap();
        reopened.recover(&root, project).unwrap();
        let committed = matches!(
            boundary,
            ApplyBoundary::Committed | ApplyBoundary::CleanupDurable(_)
        );
        assert_eq!(
            fs::read(root.join("file.txt")).unwrap(),
            if committed {
                new.as_slice()
            } else {
                old.as_slice()
            }
        );
        assert_eq!(
            reopened.visible_state(project).unwrap().is_some(),
            committed
        );
        let phase: String = rusqlite::Connection::open(&database)
            .unwrap()
            .query_row(
                "SELECT phase FROM operations WHERE operation_id=?1",
                [plan.operation_id.as_slice()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            phase,
            if committed {
                "committed"
            } else {
                "rolled_back"
            }
        );
    }
}

#[test]
fn traversal_unicode_and_symlink_ancestor_corpus_cannot_escape_root() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("project");
    let outside = temporary.path().join("outside");
    fs::create_dir_all(&root).unwrap();
    fs::create_dir_all(&outside).unwrap();
    std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();
    fs::write(root.join("É"), b"existing").unwrap();
    let project = ProjectId::from_bytes([90; 32]);
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let object_domain = domain(project);
    let store = ApplyStore::open(temporary.path().join("state/apply.sqlite")).unwrap();

    let corpora = [
        vec!["../escape"],
        vec!["/absolute"],
        vec!["a//b"],
        vec!["a/./b"],
        vec!["link/escape"],
        vec!["é"],
        vec!["é", "e\u{301}"],
    ];
    for (index, paths) in corpora.into_iter().enumerate() {
        let plan = ApplyPlan {
            operation_id: [100 + index as u8; 16],
            project,
            target_manifest_root: [100 + index as u8; 32],
            frontier: vec![index as u8],
            entries: paths
                .into_iter()
                .map(|path| ApplyPlanEntry {
                    relative_path: path.to_owned(),
                    action: ApplyAction::Delete,
                    precondition: ApplyPrecondition::Absent,
                })
                .collect(),
        };
        let result = store.apply(&root, &cas, object_domain, &plan);
        let rejected = if index == 5 {
            matches!(
                result,
                Err(ApplyError::Sandbox(_) | ApplyError::StalePrecondition(_))
            )
        } else {
            matches!(result, Err(ApplyError::Sandbox(_)))
        };
        assert!(rejected, "corpus {index} unexpectedly returned {result:?}");
    }
    assert!(fs::read_dir(&outside).unwrap().next().is_none());
    assert!(store.visible_state(project).unwrap().is_none());
}

#[test]
fn files_directories_symlinks_and_deletes_apply_as_one_visible_generation() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("project");
    fs::create_dir_all(root.join("old-dir")).unwrap();
    fs::write(root.join("old-dir/child"), b"old child").unwrap();
    fs::write(root.join("delete-me"), b"delete me").unwrap();
    let project = ProjectId::from_bytes([91; 32]);
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let object_domain = domain(project);
    let contents = b"installed file";
    let object_id = install(&cas, object_domain, contents);
    let store = ApplyStore::open(temporary.path().join("state/apply.sqlite")).unwrap();
    let old_directory = ApplyStore::fingerprint_path(&root, project, "old-dir")
        .unwrap()
        .unwrap();
    let plan = ApplyPlan {
        operation_id: [92; 16],
        project,
        target_manifest_root: [92; 32],
        frontier: vec![9, 2],
        entries: vec![
            ApplyPlanEntry {
                relative_path: "new-dir".to_owned(),
                action: ApplyAction::Directory { executable: true },
                precondition: ApplyPrecondition::Absent,
            },
            ApplyPlanEntry {
                relative_path: "new-dir/file".to_owned(),
                action: ApplyAction::File {
                    object_id,
                    content_hash: *blake3::hash(contents).as_bytes(),
                    length: contents.len() as u64,
                    executable: false,
                },
                precondition: ApplyPrecondition::Absent,
            },
            ApplyPlanEntry {
                relative_path: "new-link".to_owned(),
                action: ApplyAction::Symlink {
                    target: "new-dir/file".to_owned(),
                },
                precondition: ApplyPrecondition::Absent,
            },
            ApplyPlanEntry {
                relative_path: "delete-me".to_owned(),
                action: ApplyAction::Delete,
                precondition: ApplyPrecondition::Present(fingerprint(b"delete me")),
            },
            ApplyPlanEntry {
                relative_path: "old-dir".to_owned(),
                action: ApplyAction::Directory { executable: true },
                precondition: ApplyPrecondition::Present(old_directory),
            },
        ],
    };

    store.apply(&root, &cas, object_domain, &plan).unwrap();
    assert_eq!(fs::read(root.join("new-dir/file")).unwrap(), contents);
    assert_eq!(
        fs::read_link(root.join("new-link")).unwrap(),
        std::path::Path::new("new-dir/file")
    );
    assert!(!root.join("delete-me").exists());
    assert!(root.join("old-dir").is_dir());
    assert!(fs::read_dir(root.join("old-dir")).unwrap().next().is_none());
    assert_eq!(store.visible_state(project).unwrap().unwrap().generation, 1);
}

#[test]
fn disk_full_and_permission_failpoints_never_advance_visible_state() {
    let points = [
        ApplyIoPoint::TempWrite,
        ApplyIoPoint::TempFsync,
        ApplyIoPoint::TempWorkFsync,
        ApplyIoPoint::BackupRename,
        ApplyIoPoint::BackupParentFsync,
        ApplyIoPoint::BackupWorkFsync,
        ApplyIoPoint::InstallRename,
        ApplyIoPoint::InstallFileFsync,
        ApplyIoPoint::InstallParentFsync,
    ];
    for (index, point) in points.into_iter().enumerate() {
        for errno in [libc::ENOSPC, libc::EACCES] {
            let temporary = tempfile::tempdir().unwrap();
            let root = temporary.path().join("project");
            fs::create_dir_all(&root).unwrap();
            let old = b"old failpoint";
            let new = b"new failpoint";
            fs::write(root.join("file"), old).unwrap();
            let project = ProjectId::from_bytes([120 + index as u8; 32]);
            let cas = CasStore::open(
                temporary.path().join("cas"),
                CasLimits::default(),
                Arc::new(FixedKeys),
            )
            .unwrap();
            let object_domain = domain(project);
            let object_id = install(&cas, object_domain, new);
            let store = ApplyStore::open(temporary.path().join("state/apply.sqlite")).unwrap();
            let plan = ApplyPlan {
                operation_id: [130 + index as u8 + (errno == libc::EACCES) as u8; 16],
                project,
                target_manifest_root: [130 + index as u8; 32],
                frontier: vec![index as u8],
                entries: vec![ApplyPlanEntry {
                    relative_path: "file".to_owned(),
                    action: ApplyAction::File {
                        object_id,
                        content_hash: *blake3::hash(new).as_bytes(),
                        length: new.len() as u64,
                        executable: false,
                    },
                    precondition: ApplyPrecondition::Present(fingerprint(old)),
                }],
            };
            assert!(matches!(
                store.apply_with_hook(&root, &cas, object_domain, &plan, &FailIo(point, errno)),
                Err(ApplyError::Io(_))
            ));
            assert_eq!(fs::read(root.join("file")).unwrap(), old);
            assert!(store.visible_state(project).unwrap().is_none());
        }
    }
}

#[test]
fn local_edit_after_precheck_is_rejected_before_backup_rename() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("project");
    fs::create_dir_all(&root).unwrap();
    let old = b"old planned";
    let new = b"remote target";
    let target = root.join("file");
    fs::write(&target, old).unwrap();
    let project = ProjectId::from_bytes([150; 32]);
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let object_domain = domain(project);
    let object_id = install(&cas, object_domain, new);
    let store = ApplyStore::open(temporary.path().join("state/apply.sqlite")).unwrap();
    let plan = ApplyPlan {
        operation_id: [151; 16],
        project,
        target_manifest_root: [151; 32],
        frontier: vec![1, 5, 1],
        entries: vec![ApplyPlanEntry {
            relative_path: "file".to_owned(),
            action: ApplyAction::File {
                object_id,
                content_hash: *blake3::hash(new).as_bytes(),
                length: new.len() as u64,
                executable: false,
            },
            precondition: ApplyPrecondition::Present(fingerprint(old)),
        }],
    };
    assert!(matches!(
        store.apply_with_hook(
            &root,
            &cas,
            object_domain,
            &plan,
            &EditAfterPrecheck(target.clone())
        ),
        Err(ApplyError::StalePrecondition(_))
    ));
    assert_eq!(fs::read(target).unwrap(), b"last second local edit");
    assert!(store.visible_state(project).unwrap().is_none());
}

#[test]
fn apply_and_reconcile_share_the_project_flock_in_both_directions() {
    let temporary = tempfile::tempdir().unwrap();
    let state = temporary.path().join("state");
    let root = temporary.path().join("project");
    fs::create_dir_all(&root).unwrap();
    let old = b"old lock";
    let new = b"new lock";
    fs::write(root.join("file"), old).unwrap();
    let project = ProjectId::from_bytes([170; 32]);
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let object_domain = domain(project);
    let object_id = install(&cas, object_domain, new);
    let plan = ApplyPlan {
        operation_id: [171; 16],
        project,
        target_manifest_root: [171; 32],
        frontier: vec![1, 7, 1],
        entries: vec![ApplyPlanEntry {
            relative_path: "file".to_owned(),
            action: ApplyAction::File {
                object_id,
                content_hash: *blake3::hash(new).as_bytes(),
                length: new.len() as u64,
                executable: false,
            },
            precondition: ApplyPrecondition::Present(fingerprint(old)),
        }],
    };
    let apply = ApplyStore::open(state.join("apply.sqlite")).unwrap();
    let reconcile = ReconcileStore::open(&state.join("heads.sqlite"), project).unwrap();
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let root_for_thread = root.clone();
    let apply_thread = std::thread::spawn(move || {
        apply.apply_with_hook(
            &root_for_thread,
            &cas,
            object_domain,
            &plan,
            &PausePrepared {
                ready: ready_tx,
                release: std::sync::Mutex::new(release_rx),
            },
        )
    });
    ready_rx.recv().unwrap();
    assert!(matches!(
        reconcile.test_project_lease_is_available(),
        Err(ReconcileError::ProjectBusy)
    ));
    release_tx.send(()).unwrap();
    apply_thread.join().unwrap().unwrap();

    let second_root = temporary.path().join("project-two");
    fs::create_dir_all(&second_root).unwrap();
    fs::write(second_root.join("file"), old).unwrap();
    let second_project = ProjectId::from_bytes([172; 32]);
    let second_cas = CasStore::open(
        temporary.path().join("cas-two"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let second_domain = domain(second_project);
    let second_id = install(&second_cas, second_domain, new);
    let second_apply = ApplyStore::open(state.join("apply-two.sqlite")).unwrap();
    let second_reconcile =
        ReconcileStore::open(&state.join("heads-two.sqlite"), second_project).unwrap();
    let second_plan = ApplyPlan {
        operation_id: [173; 16],
        project: second_project,
        target_manifest_root: [173; 32],
        frontier: vec![1, 7, 3],
        entries: vec![ApplyPlanEntry {
            relative_path: "file".to_owned(),
            action: ApplyAction::File {
                object_id: second_id,
                content_hash: *blake3::hash(new).as_bytes(),
                length: new.len() as u64,
                executable: false,
            },
            precondition: ApplyPrecondition::Present(fingerprint(old)),
        }],
    };
    let (held_tx, held_rx) = std::sync::mpsc::channel();
    let (unlock_tx, unlock_rx) = std::sync::mpsc::channel();
    let reconcile_thread = std::thread::spawn(move || {
        second_reconcile.test_with_project_lease(|| {
            held_tx.send(()).unwrap();
            unlock_rx.recv().unwrap();
        })
    });
    held_rx.recv().unwrap();
    assert!(matches!(
        second_apply.apply(&second_root, &second_cas, second_domain, &second_plan),
        Err(ApplyError::Lock(_))
    ));
    assert_eq!(fs::read(second_root.join("file")).unwrap(), old);
    unlock_tx.send(()).unwrap();
    reconcile_thread.join().unwrap().unwrap();
}

#[test]
fn parent_and_target_symlink_swaps_after_precheck_fail_before_rename() {
    for parent_swap in [true, false] {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().join("project");
        let parent = root.join("nested");
        let outside = temporary.path().join("outside");
        fs::create_dir_all(&parent).unwrap();
        fs::create_dir_all(&outside).unwrap();
        let old = b"old race";
        let new = b"new race";
        fs::write(parent.join("file"), old).unwrap();
        fs::write(outside.join("victim"), b"outside intact").unwrap();
        let project = ProjectId::from_bytes([180 + parent_swap as u8; 32]);
        let cas = CasStore::open(
            temporary.path().join("cas"),
            CasLimits::default(),
            Arc::new(FixedKeys),
        )
        .unwrap();
        let object_domain = domain(project);
        let object_id = install(&cas, object_domain, new);
        let store = ApplyStore::open(temporary.path().join("state/apply.sqlite")).unwrap();
        let plan = ApplyPlan {
            operation_id: [182 + parent_swap as u8; 16],
            project,
            target_manifest_root: [182 + parent_swap as u8; 32],
            frontier: vec![1, 8, 2],
            entries: vec![ApplyPlanEntry {
                relative_path: "nested/file".to_owned(),
                action: ApplyAction::File {
                    object_id,
                    content_hash: *blake3::hash(new).as_bytes(),
                    length: new.len() as u64,
                    executable: false,
                },
                precondition: ApplyPrecondition::Present(fingerprint(old)),
            }],
        };
        let swap = if parent_swap {
            SwapKind::Parent {
                parent: parent.clone(),
                outside: outside.clone(),
            }
        } else {
            SwapKind::Target {
                target: parent.join("file"),
                outside_target: outside.join("victim"),
            }
        };
        assert!(store
            .apply_with_hook(&root, &cas, object_domain, &plan, &SwapAfterPrecheck(swap))
            .is_err());
        assert_eq!(fs::read(outside.join("victim")).unwrap(), b"outside intact");
        assert!(store.visible_state(project).unwrap().is_none());
    }
}

#[test]
fn corrupt_truncated_and_wrong_key_cas_objects_never_publish_a_temp() {
    for variant in 0..3 {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().join("project");
        fs::create_dir_all(&root).unwrap();
        let old = b"old cas";
        let new = b"new cas payload";
        fs::write(root.join("file"), old).unwrap();
        let project = ProjectId::from_bytes([190 + variant; 32]);
        let cas_root = temporary.path().join("cas");
        let cas = CasStore::open(&cas_root, CasLimits::default(), Arc::new(FixedKeys)).unwrap();
        let object_domain = domain(project);
        let object_id = install(&cas, object_domain, new);
        let live = cas_root.join("live").join(format!("{object_id}.cas"));
        match variant {
            0 => std::fs::OpenOptions::new()
                .write(true)
                .open(&live)
                .unwrap()
                .set_len(110)
                .unwrap(),
            1 => {
                use std::io::{Seek, SeekFrom, Write};
                let mut file = std::fs::OpenOptions::new().write(true).open(&live).unwrap();
                file.seek(SeekFrom::Start(120)).unwrap();
                file.write_all(&[0xff]).unwrap();
                file.sync_all().unwrap();
            }
            _ => {
                use std::io::{Seek, SeekFrom, Write};
                let mut file = std::fs::OpenOptions::new().write(true).open(&live).unwrap();
                file.seek(SeekFrom::Start(76)).unwrap();
                file.write_all(&[9; 16]).unwrap();
                file.sync_all().unwrap();
            }
        }
        let store = ApplyStore::open(temporary.path().join("state/apply.sqlite")).unwrap();
        let plan = ApplyPlan {
            operation_id: [195 + variant; 16],
            project,
            target_manifest_root: [195 + variant; 32],
            frontier: vec![variant],
            entries: vec![ApplyPlanEntry {
                relative_path: "file".to_owned(),
                action: ApplyAction::File {
                    object_id,
                    content_hash: *blake3::hash(new).as_bytes(),
                    length: new.len() as u64,
                    executable: false,
                },
                precondition: ApplyPrecondition::Present(fingerprint(old)),
            }],
        };
        assert!(matches!(
            store.apply(&root, &cas, object_domain, &plan),
            Err(ApplyError::Cas(_))
        ));
        assert_eq!(fs::read(root.join("file")).unwrap(), old);
        assert!(store.visible_state(project).unwrap().is_none());
    }
}

#[test]
fn accepted_reconcile_head_is_not_visible_until_apply_commits() {
    let temporary = tempfile::tempdir().unwrap();
    let state = temporary.path().join("state");
    fs::create_dir_all(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    let root = temporary.path().join("project");
    fs::create_dir_all(&root).unwrap();
    let old = b"accepted old";
    let new = b"accepted new";
    fs::write(root.join("file"), old).unwrap();
    let project = ProjectId::from_bytes([210; 32]);
    let peer = TransportPeerSnapshot {
        project_id: project,
        device_id: [211; 32],
        roster_epoch: 1,
        certificate_hash: [212; 32],
    };
    let remote = BTreeMap::from([([211; 32], 1)]);
    let target_root = [213; 32];
    let reconcile = ReconcileStore::open(&state.join("heads.sqlite"), project).unwrap();
    let candidate = match reconcile.offer(&peer, target_root, &remote, false).unwrap() {
        HeadDecision::Initial(id) => id,
        other => panic!("unexpected decision {other:?}"),
    };
    reconcile.commit_candidate_unchecked(candidate).unwrap();
    assert!(reconcile.is_current(&peer, target_root, &remote).unwrap());

    let apply = ApplyStore::open(state.join("apply.sqlite")).unwrap();
    assert!(apply.visible_state(project).unwrap().is_none());
    assert_eq!(fs::read(root.join("file")).unwrap(), old);

    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let object_domain = domain(project);
    let object_id = install(&cas, object_domain, new);
    let plan = ApplyPlan {
        operation_id: [214; 16],
        project,
        target_manifest_root: target_root,
        frontier: vec![2, 1, 1],
        entries: vec![ApplyPlanEntry {
            relative_path: "file".to_owned(),
            action: ApplyAction::File {
                object_id,
                content_hash: *blake3::hash(new).as_bytes(),
                length: new.len() as u64,
                executable: false,
            },
            precondition: ApplyPrecondition::Present(fingerprint(old)),
        }],
    };
    apply.apply(&root, &cas, object_domain, &plan).unwrap();
    assert_eq!(
        apply.visible_state(project).unwrap().unwrap().manifest_root,
        target_root
    );
    assert_eq!(fs::read(root.join("file")).unwrap(), new);
}

#[test]
fn absent_target_created_after_second_precheck_is_never_overwritten_or_removed() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("project");
    fs::create_dir_all(&root).unwrap();
    let project = ProjectId::from_bytes([220; 32]);
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let object_domain = domain(project);
    let remote = b"remote target";
    let object_id = install(&cas, object_domain, remote);
    let target = root.join("file");
    let store = ApplyStore::open(temporary.path().join("state/apply.sqlite")).unwrap();
    let plan = ApplyPlan {
        operation_id: [221; 16],
        project,
        target_manifest_root: [221; 32],
        frontier: vec![2, 2, 1],
        entries: vec![ApplyPlanEntry {
            relative_path: "file".to_owned(),
            action: ApplyAction::File {
                object_id,
                content_hash: *blake3::hash(remote).as_bytes(),
                length: remote.len() as u64,
                executable: false,
            },
            precondition: ApplyPrecondition::Absent,
        }],
    };
    assert!(store
        .apply_with_hook(
            &root,
            &cas,
            object_domain,
            &plan,
            &CreateAfterSecondPrecheck(target.clone())
        )
        .is_err());
    assert_eq!(fs::read(target).unwrap(), b"new local target");
    assert!(store.visible_state(project).unwrap().is_none());
}

#[test]
fn recursive_directory_fingerprint_detects_subtree_edit_before_rename() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("project");
    let directory = root.join("tree");
    fs::create_dir_all(&directory).unwrap();
    fs::write(directory.join("child"), b"before").unwrap();
    let project = ProjectId::from_bytes([222; 32]);
    let expected = ApplyStore::fingerprint_path(&root, project, "tree")
        .unwrap()
        .unwrap();
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let object_domain = domain(project);
    let store = ApplyStore::open(temporary.path().join("state/apply.sqlite")).unwrap();
    let plan = ApplyPlan {
        operation_id: [223; 16],
        project,
        target_manifest_root: [223; 32],
        frontier: vec![2, 2, 3],
        entries: vec![ApplyPlanEntry {
            relative_path: "tree".to_owned(),
            action: ApplyAction::Delete,
            precondition: ApplyPrecondition::Present(expected),
        }],
    };
    assert!(matches!(
        store.apply_with_hook(
            &root,
            &cas,
            object_domain,
            &plan,
            &EditDirectoryAfterPrecheck(directory.clone())
        ),
        Err(ApplyError::StalePrecondition(_))
    ));
    assert_eq!(
        fs::read(directory.join("child")).unwrap(),
        b"subtree changed"
    );
}

#[test]
fn rollback_durable_reopen_never_deletes_a_later_local_file() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("project");
    fs::create_dir_all(&root).unwrap();
    let old = b"old rollback";
    let remote = b"remote rollback";
    let target = root.join("file");
    fs::write(&target, old).unwrap();
    let project = ProjectId::from_bytes([224; 32]);
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let object_domain = domain(project);
    let object_id = install(&cas, object_domain, remote);
    let database = temporary.path().join("state/apply.sqlite");
    let store = ApplyStore::open(&database).unwrap();
    let plan = ApplyPlan {
        operation_id: [225; 16],
        project,
        target_manifest_root: [225; 32],
        frontier: vec![2, 2, 5],
        entries: vec![ApplyPlanEntry {
            relative_path: "file".to_owned(),
            action: ApplyAction::File {
                object_id,
                content_hash: *blake3::hash(remote).as_bytes(),
                length: remote.len() as u64,
                executable: false,
            },
            precondition: ApplyPrecondition::Present(fingerprint(old)),
        }],
    };
    assert!(store
        .apply_with_hook(&root, &cas, object_domain, &plan, &CrashDuringRollback)
        .is_err());
    fs::write(&target, b"later local file").unwrap();
    drop(store);
    let reopened = ApplyStore::open(database).unwrap();
    reopened.recover(&root, project).unwrap();
    assert_eq!(fs::read(target).unwrap(), b"later local file");
}

#[test]
fn edit_after_second_precheck_is_restored_when_backup_fingerprint_changes() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("project");
    fs::create_dir_all(&root).unwrap();
    let target = root.join("file");
    fs::write(&target, b"expected old").unwrap();
    let project = ProjectId::from_bytes([226; 32]);
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let object_domain = domain(project);
    let remote = b"remote replacement";
    let object_id = install(&cas, object_domain, remote);
    let store = ApplyStore::open(temporary.path().join("state/apply.sqlite")).unwrap();
    let plan = ApplyPlan {
        operation_id: [227; 16],
        project,
        target_manifest_root: [227; 32],
        frontier: vec![2, 2, 7],
        entries: vec![ApplyPlanEntry {
            relative_path: "file".to_owned(),
            action: ApplyAction::File {
                object_id,
                content_hash: *blake3::hash(remote).as_bytes(),
                length: remote.len() as u64,
                executable: false,
            },
            precondition: ApplyPrecondition::Present(fingerprint(b"expected old")),
        }],
    };
    assert!(store
        .apply_with_hook(
            &root,
            &cas,
            object_domain,
            &plan,
            &EditAfterSecondPrecheck(target.clone())
        )
        .is_err());
    assert_eq!(fs::read(target).unwrap(), b"edited after precheck");
    assert!(store.visible_state(project).unwrap().is_none());
}

#[test]
fn local_target_between_backup_and_install_blocks_without_overwrite() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("project");
    fs::create_dir_all(&root).unwrap();
    let target = root.join("file");
    fs::write(&target, b"expected old").unwrap();
    let project = ProjectId::from_bytes([228; 32]);
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(FixedKeys),
    )
    .unwrap();
    let object_domain = domain(project);
    let remote = b"remote replacement";
    let object_id = install(&cas, object_domain, remote);
    let store = ApplyStore::open(temporary.path().join("state/apply.sqlite")).unwrap();
    let plan = ApplyPlan {
        operation_id: [229; 16],
        project,
        target_manifest_root: [229; 32],
        frontier: vec![2, 2, 9],
        entries: vec![ApplyPlanEntry {
            relative_path: "file".to_owned(),
            action: ApplyAction::File {
                object_id,
                content_hash: *blake3::hash(remote).as_bytes(),
                length: remote.len() as u64,
                executable: false,
            },
            precondition: ApplyPrecondition::Present(fingerprint(b"expected old")),
        }],
    };
    assert!(store
        .apply_with_hook(
            &root,
            &cas,
            object_domain,
            &plan,
            &CreateBetweenBackupAndInstall(target.clone())
        )
        .is_err());
    store.recover(&root, project).unwrap();
    assert_eq!(fs::read(target).unwrap(), b"local race winner");
    assert!(store.visible_state(project).unwrap().is_none());
}

#[test]
fn apply_database_and_sidecar_symlinks_are_rejected_without_touching_external_files() {
    for sidecar in ["", "-wal", "-shm"] {
        let temporary = tempfile::tempdir().unwrap();
        let state = temporary.path().join("state");
        fs::create_dir_all(&state).unwrap();
        fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
        let external = temporary.path().join("external");
        fs::write(&external, b"untouched").unwrap();
        let database = state.join("apply.sqlite");
        if sidecar.is_empty() {
            std::os::unix::fs::symlink(&external, &database).unwrap();
        } else {
            let valid = ApplyStore::open(&database).unwrap();
            drop(valid);
            let sidecar_path = state.join(format!("apply.sqlite{sidecar}"));
            if sidecar_path.exists() {
                fs::remove_file(&sidecar_path).unwrap();
            }
            std::os::unix::fs::symlink(&external, sidecar_path).unwrap();
        }
        assert!(ApplyStore::open(&database).is_err());
        assert_eq!(fs::read(&external).unwrap(), b"untouched");
    }
}

#[test]
fn apply_database_rejects_hardlinks_fifos_and_unsafe_modes() {
    for kind in ["hardlink", "fifo", "mode"] {
        let temporary = tempfile::tempdir().unwrap();
        let state = temporary.path().join("state");
        fs::create_dir(&state).unwrap();
        fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
        let database = state.join("apply.sqlite");
        let external = temporary.path().join("external");
        fs::write(&external, b"external stays unchanged").unwrap();
        match kind {
            "hardlink" => fs::hard_link(&external, &database).unwrap(),
            "fifo" => {
                let path = std::ffi::CString::new(database.as_os_str().as_encoded_bytes()).unwrap();
                assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
            }
            "mode" => {
                fs::write(&database, []).unwrap();
                fs::set_permissions(&database, fs::Permissions::from_mode(0o644)).unwrap();
            }
            _ => unreachable!(),
        }
        assert!(ApplyStore::open(&database).is_err(), "kind {kind}");
        assert_eq!(fs::read(&external).unwrap(), b"external stays unchanged");
    }
}

#[test]
fn sqlite_vfs_registry_reuses_live_entry_and_reopens_after_last_drop() {
    let temporary = tempfile::tempdir().unwrap();
    let database = temporary.path().join("state/apply.sqlite");
    let first = ApplyStore::open(&database).unwrap();
    let second = ApplyStore::open(&database).unwrap();
    drop(first);
    assert!(second
        .visible_state(ProjectId::from_bytes([234; 32]))
        .unwrap()
        .is_none());
    drop(second);
    let reopened = ApplyStore::open(&database).unwrap();
    drop(reopened);
}

#[test]
fn open_sqlite_handles_confine_mutations_when_state_parent_is_swapped() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("project");
    fs::create_dir_all(root.join("nested")).unwrap();
    let old = b"held sqlite old";
    let remote = b"held sqlite remote";
    fs::write(root.join("nested/file.txt"), old).unwrap();
    let project = ProjectId::from_bytes([232; 32]);
    let cas = Arc::new(
        CasStore::open(
            temporary.path().join("cas"),
            CasLimits::default(),
            Arc::new(FixedKeys),
        )
        .unwrap(),
    );
    let object_domain = domain(project);
    let object_id = install(&cas, object_domain, remote);
    let state = temporary.path().join("state");
    let held_state = temporary.path().join("held-state");
    let store = Arc::new(ApplyStore::open(state.join("apply.sqlite")).unwrap());
    let plan = replacement_plan(project, 233, object_id, old, remote);
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let worker_store = Arc::clone(&store);
    let worker_cas = Arc::clone(&cas);
    let worker_root = root.clone();
    let worker = std::thread::spawn(move || {
        worker_store.apply_with_hook(
            &worker_root,
            &worker_cas,
            object_domain,
            &plan,
            &PausePrepared {
                ready: ready_tx,
                release: std::sync::Mutex::new(release_rx),
            },
        )
    });
    ready_rx.recv().unwrap();
    fs::rename(&state, &held_state).unwrap();
    fs::create_dir(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    let external = temporary.path().join("external-db-bytes");
    fs::write(&external, b"untouched external sqlite bytes").unwrap();
    for suffix in ["", "-wal", "-shm"] {
        std::os::unix::fs::symlink(&external, state.join(format!("apply.sqlite{suffix}"))).unwrap();
    }
    release_tx.send(()).unwrap();
    worker.join().unwrap().unwrap();
    assert_eq!(
        fs::read(&external).unwrap(),
        b"untouched external sqlite bytes"
    );
    assert!(held_state
        .join("apply.sqlite")
        .metadata()
        .unwrap()
        .is_file());
    for suffix in ["-wal", "-shm"] {
        let sidecar = held_state.join(format!("apply.sqlite{suffix}"));
        if sidecar.exists() {
            assert!(sidecar.metadata().unwrap().is_file());
        }
    }
    assert_eq!(fs::read(root.join("nested/file.txt")).unwrap(), remote);
    store.recover(&root, project).unwrap();
    assert!(!state.join(".term-mesh-project-locks").exists());
    drop(store);
    let reopened = ApplyStore::open(held_state.join("apply.sqlite")).unwrap();
    assert!(reopened.visible_state(project).unwrap().is_some());
}

#[test]
fn sqlite_open_preflight_parent_swap_never_mutates_replacement_directory() {
    let temporary = tempfile::tempdir().unwrap();
    let state = temporary.path().join("state");
    let held_state = temporary.path().join("held-state");
    let external = temporary.path().join("external-db-bytes");
    fs::write(&external, b"untouched open-race bytes").unwrap();
    let result = ApplyStore::open_with_hook(state.join("apply.sqlite"), || {
        fs::rename(&state, &held_state).unwrap();
        fs::create_dir(&state).unwrap();
        fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
        for suffix in ["", "-wal", "-shm"] {
            std::os::unix::fs::symlink(&external, state.join(format!("apply.sqlite{suffix}")))
                .unwrap();
        }
    });
    assert!(matches!(result, Err(ApplyError::Corrupt)));
    assert_eq!(fs::read(&external).unwrap(), b"untouched open-race bytes");
    for suffix in ["", "-wal", "-shm"] {
        assert!(state.join(format!("apply.sqlite{suffix}")).is_symlink());
    }
    let held = ApplyStore::open(held_state.join("apply.sqlite")).unwrap();
    drop(held);
}

#[test]
fn sqlite_shm_coordinates_writer_checkpointer_and_reader_across_apply_stores() {
    let temporary = tempfile::tempdir().unwrap();
    let database = temporary.path().join("state/apply.sqlite");
    let writer = ApplyStore::open(&database).unwrap();
    let reader = ApplyStore::open(&database).unwrap();
    let contender = ApplyStore::open(&database).unwrap();
    let checkpointer = ApplyStore::open(&database).unwrap();
    contender.sqlite_test_busy_timeout(0).unwrap();
    checkpointer.sqlite_test_busy_timeout(0).unwrap();

    writer
        .sqlite_test_execute_batch(
            "CREATE TABLE shm_lock_test(value INTEGER NOT NULL); INSERT INTO shm_lock_test VALUES(1)",
        )
        .unwrap();
    reader.sqlite_test_execute_batch("BEGIN").unwrap();
    assert_eq!(
        reader
            .sqlite_test_query_i64("SELECT value FROM shm_lock_test")
            .unwrap(),
        1
    );
    writer
        .sqlite_test_execute_batch("BEGIN IMMEDIATE; UPDATE shm_lock_test SET value=2")
        .unwrap();
    assert!(contender
        .sqlite_test_execute_batch("BEGIN IMMEDIATE")
        .is_err());
    assert_eq!(
        reader
            .sqlite_test_query_i64("SELECT value FROM shm_lock_test")
            .unwrap(),
        1
    );
    assert_eq!(
        checkpointer
            .sqlite_test_query_i64("PRAGMA wal_checkpoint(TRUNCATE)")
            .unwrap(),
        1
    );
    writer.sqlite_test_execute_batch("COMMIT").unwrap();
    assert_eq!(
        reader
            .sqlite_test_query_i64("SELECT value FROM shm_lock_test")
            .unwrap(),
        1
    );
    assert_eq!(
        checkpointer
            .sqlite_test_query_i64("PRAGMA wal_checkpoint(TRUNCATE)")
            .unwrap(),
        1
    );
    reader.sqlite_test_execute_batch("COMMIT").unwrap();
    assert_eq!(
        checkpointer
            .sqlite_test_query_i64("PRAGMA wal_checkpoint(TRUNCATE)")
            .unwrap(),
        0
    );
    assert_eq!(
        contender
            .sqlite_test_query_i64("SELECT value FROM shm_lock_test")
            .unwrap(),
        2
    );
}

#[test]
fn subprocess_sqlite_dms_holder_child() {
    let Ok(database) = std::env::var("TM_SQLITE_DMS_DB") else {
        return;
    };
    let ready = std::path::PathBuf::from(std::env::var("TM_SQLITE_DMS_READY").unwrap());
    let _store = ApplyStore::open(database).unwrap();
    fs::write(&ready, b"ready").unwrap();
    loop {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}

#[test]
fn sqlite_dms_truncates_stale_shm_and_survives_opener_crash_reopen_race() {
    let temporary = tempfile::tempdir().unwrap();
    let database = temporary.path().join("state/apply.sqlite");
    drop(ApplyStore::open(&database).unwrap());
    let shm = database.with_file_name("apply.sqlite-shm");
    fs::write(&shm, vec![0xa5; 65_536]).unwrap();
    fs::set_permissions(&shm, fs::Permissions::from_mode(0o600)).unwrap();

    let holder = std::process::Command::new(std::env::current_exe().unwrap())
        .arg("subprocess_sqlite_dms_holder_child")
        .arg("--exact")
        .arg("--nocapture")
        .env("TM_SQLITE_DMS_DB", &database)
        .env("TM_SQLITE_DMS_READY", temporary.path().join("ready"))
        .spawn()
        .unwrap();
    let mut holder = holder;
    let ready = temporary.path().join("ready");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !ready.exists() && std::time::Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(ready.exists());
    assert!(fs::metadata(&shm).unwrap().len() < 65_536);

    let concurrent = ApplyStore::open(&database).unwrap();
    holder.kill().unwrap();
    holder.wait().unwrap();
    drop(concurrent);
    let reopened = ApplyStore::open(&database).unwrap();
    // The current apply schema version — bump alongside `VERSION` in apply.rs.
    assert_eq!(
        reopened
            .sqlite_test_query_i64("PRAGMA user_version")
            .unwrap(),
        4
    );
}

#[cfg(target_os = "macos")]
#[test]
fn sqlite_open_repeated_parent_swaps_are_confined_to_held_directory() {
    use std::sync::atomic::{AtomicBool, Ordering};

    let temporary = tempfile::tempdir().unwrap();
    let state = temporary.path().join("state");
    let decoy = temporary.path().join("decoy");
    fs::create_dir(&decoy).unwrap();
    fs::set_permissions(&decoy, fs::Permissions::from_mode(0o700)).unwrap();
    let external = temporary.path().join("external-repeated-swap");
    fs::write(&external, b"untouched repeated swap bytes").unwrap();
    for suffix in ["", "-wal", "-shm", "-journal"] {
        std::os::unix::fs::symlink(&external, decoy.join(format!("apply.sqlite{suffix}"))).unwrap();
    }
    let stop = Arc::new(AtomicBool::new(false));
    let worker_slot = Arc::new(std::sync::Mutex::new(None));
    let hook_stop = Arc::clone(&stop);
    let hook_slot = Arc::clone(&worker_slot);
    let hook_state = state.clone();
    let hook_decoy = decoy.clone();
    let result = ApplyStore::open_with_hook(state.join("apply.sqlite"), move || {
        let state = std::ffi::CString::new(hook_state.as_os_str().as_encoded_bytes()).unwrap();
        let decoy = std::ffi::CString::new(hook_decoy.as_os_str().as_encoded_bytes()).unwrap();
        *hook_slot.lock().unwrap() = Some(std::thread::spawn(move || {
            while !hook_stop.load(Ordering::Acquire) {
                let changed = unsafe {
                    libc::renameatx_np(
                        libc::AT_FDCWD,
                        state.as_ptr(),
                        libc::AT_FDCWD,
                        decoy.as_ptr(),
                        libc::RENAME_SWAP,
                    )
                };
                assert_eq!(changed, 0);
            }
        }));
    });
    stop.store(true, Ordering::Release);
    worker_slot.lock().unwrap().take().unwrap().join().unwrap();
    assert!(result.is_ok() || matches!(result, Err(ApplyError::Corrupt)));
    drop(result);
    assert_eq!(
        fs::read(&external).unwrap(),
        b"untouched repeated swap bytes"
    );
    let decoy_location = [&state, &decoy]
        .into_iter()
        .find(|directory| directory.join("apply.sqlite").is_symlink())
        .unwrap();
    for suffix in ["", "-wal", "-shm", "-journal"] {
        assert!(decoy_location
            .join(format!("apply.sqlite{suffix}"))
            .is_symlink());
    }
}

#[test]
fn subprocess_apply_crash_child() {
    let Ok(boundary) = std::env::var("TM_APPLY_CRASH_BOUNDARY") else {
        return;
    };
    let root = std::path::PathBuf::from(std::env::var("TM_APPLY_ROOT").unwrap());
    let cas_root = std::path::PathBuf::from(std::env::var("TM_APPLY_CAS").unwrap());
    let database = std::path::PathBuf::from(std::env::var("TM_APPLY_DB").unwrap());
    let project = ProjectId::from_bytes([230; 32]);
    let object_domain = domain(project);
    let remote = b"subprocess remote";
    let object_id = ObjectId::for_plaintext(object_domain, remote);
    let cas = CasStore::open(cas_root, CasLimits::default(), Arc::new(FixedKeys)).unwrap();
    let store = ApplyStore::open(database).unwrap();
    if std::env::var_os("TM_APPLY_RECOVER_ONLY").is_some() {
        let result = store.recover_with_hook(&root, project, &ProcessExitAt(boundary));
        panic!("recovery crash hook did not exit: {result:?}");
    }
    let plan = if std::env::var_os("TM_APPLY_EXPECTED_ABSENT").is_some() {
        ApplyPlan {
            operation_id: [231; 16],
            project,
            target_manifest_root: [231; 32],
            frontier: vec![231],
            entries: vec![ApplyPlanEntry {
                relative_path: "nested/file.txt".to_owned(),
                action: ApplyAction::File {
                    object_id,
                    content_hash: *blake3::hash(remote).as_bytes(),
                    length: remote.len() as u64,
                    executable: false,
                },
                precondition: ApplyPrecondition::Absent,
            }],
        }
    } else {
        replacement_plan(project, 231, object_id, b"subprocess old", remote)
    };
    let result = store.apply_with_hook(&root, &cas, object_domain, &plan, &ProcessExitAt(boundary));
    panic!("crash hook did not exit: {result:?}");
}

#[test]
fn real_subprocess_exit_at_every_apply_durability_class_converges() {
    let boundaries = [
        "prepared",
        "temp_write_before",
        "temp_write",
        "temp_fsync_before",
        "temp_fsync",
        "temp_work_fsync_before",
        "temp_work_fsync",
        "temp_durable",
        "backup_intent",
        "second_precheck",
        "backup_rename_before",
        "backup_rename",
        "backup_parent_fsync_before",
        "backup_parent_fsync",
        "backup_work_fsync_before",
        "backup_work_fsync",
        "backup_durable",
        "between",
        "install_intent",
        "install_rename_before",
        "install_rename",
        "install_file_fsync_before",
        "install_file_fsync",
        "install_parent_fsync_before",
        "install_parent_fsync",
        "rollback_trash_rename_before",
        "rollback_trash_rename",
        "rollback_trash_parent_fsync_before",
        "rollback_trash_parent_fsync",
        "rollback_trash_work_fsync_before",
        "rollback_trash_work_fsync",
        "rollback_restore_rename_before",
        "rollback_restore_rename",
        "rollback_restore_file_fsync_before",
        "rollback_restore_file_fsync",
        "rollback_restore_parent_fsync_before",
        "rollback_restore_parent_fsync",
        "rollback_restore_work_fsync_before",
        "rollback_restore_work_fsync",
        "rollback_trash_unlink_before",
        "rollback_trash_unlink",
        "rollback_trash_unlink_fsync_before",
        "rollback_trash_unlink_fsync",
        "rollback_durable",
        "installed_durable",
        "committed",
        "cleanup",
    ];
    for boundary in boundaries {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().join("project");
        fs::create_dir_all(root.join("nested")).unwrap();
        fs::write(root.join("nested/file.txt"), b"subprocess old").unwrap();
        let cas_root = temporary.path().join("cas");
        let project = ProjectId::from_bytes([230; 32]);
        let object_domain = domain(project);
        let cas = CasStore::open(&cas_root, CasLimits::default(), Arc::new(FixedKeys)).unwrap();
        install(&cas, object_domain, b"subprocess remote");
        drop(cas);
        let database = temporary.path().join("state/apply.sqlite");
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("subprocess_apply_crash_child")
            .arg("--exact")
            .arg("--nocapture")
            .env("TM_APPLY_CRASH_BOUNDARY", boundary)
            .env("TM_APPLY_ROOT", &root)
            .env("TM_APPLY_CAS", &cas_root)
            .env("TM_APPLY_DB", &database)
            .status()
            .unwrap();
        assert_eq!(status.code(), Some(86), "boundary {boundary}");
        let reopened = ApplyStore::open(&database).unwrap();
        let recovery = reopened.recover(&root, project);
        if boundary == "install_rename" {
            assert!(matches!(recovery, Err(ApplyError::Sandbox(_))));
            reopened.recover(&root, project).unwrap();
            assert_eq!(
                fs::read(root.join("nested/file.txt")).unwrap(),
                b"subprocess remote"
            );
            assert!(reopened.visible_state(project).unwrap().is_none());
            continue;
        }
        recovery.unwrap();
        let committed = matches!(boundary, "committed" | "cleanup");
        assert_eq!(
            fs::read(root.join("nested/file.txt")).unwrap(),
            if committed {
                b"subprocess remote".as_slice()
            } else {
                b"subprocess old".as_slice()
            },
            "boundary {boundary}"
        );
        assert_eq!(
            reopened.visible_state(project).unwrap().is_some(),
            committed
        );
    }
}

#[test]
fn rollback_second_crash_and_power_loss_matrix_converges() {
    let boundaries = [
        "rollback_trash_rename_before",
        "rollback_trash_rename",
        "rollback_restore_rename_before",
        "rollback_restore_rename",
        "rollback_trash_unlink_before",
        "rollback_trash_unlink",
        "rollback_durable",
    ];
    for expected_absent in [false, true] {
        for boundary in boundaries {
            if expected_absent && boundary.starts_with("rollback_restore_rename") {
                continue;
            }
            let temporary = tempfile::tempdir().unwrap();
            let root = temporary.path().join("project");
            fs::create_dir_all(root.join("nested")).unwrap();
            if !expected_absent {
                fs::write(root.join("nested/file.txt"), b"subprocess old").unwrap();
            }
            let cas_root = temporary.path().join("cas");
            let project = ProjectId::from_bytes([230; 32]);
            let object_domain = domain(project);
            let cas = CasStore::open(&cas_root, CasLimits::default(), Arc::new(FixedKeys)).unwrap();
            install(&cas, object_domain, b"subprocess remote");
            drop(cas);
            let database = temporary.path().join("state/apply.sqlite");

            let mut first = std::process::Command::new(std::env::current_exe().unwrap());
            first
                .arg("subprocess_apply_crash_child")
                .arg("--exact")
                .arg("--nocapture")
                .env("TM_APPLY_CRASH_BOUNDARY", "installed_durable")
                .env("TM_APPLY_ROOT", &root)
                .env("TM_APPLY_CAS", &cas_root)
                .env("TM_APPLY_DB", &database);
            if expected_absent {
                first.env("TM_APPLY_EXPECTED_ABSENT", "1");
            }
            assert_eq!(first.status().unwrap().code(), Some(86));

            let second = std::process::Command::new(std::env::current_exe().unwrap())
                .arg("subprocess_apply_crash_child")
                .arg("--exact")
                .arg("--nocapture")
                .env("TM_APPLY_CRASH_BOUNDARY", boundary)
                .env("TM_APPLY_RECOVER_ONLY", "1")
                .env("TM_APPLY_ROOT", &root)
                .env("TM_APPLY_CAS", &cas_root)
                .env("TM_APPLY_DB", &database)
                .status()
                .unwrap();
            assert_eq!(second.code(), Some(86), "second crash at {boundary}");

            let reopened = ApplyStore::open(&database).unwrap();
            reopened.recover(&root, project).unwrap_or_else(|error| {
                panic!(
                    "final recovery failed absent={expected_absent} boundary={boundary}: {error:?}"
                )
            });
            if expected_absent {
                assert!(!root.join("nested/file.txt").exists(), "{boundary}");
            } else {
                assert_eq!(
                    fs::read(root.join("nested/file.txt")).unwrap(),
                    b"subprocess old",
                    "{boundary}"
                );
            }
            assert!(reopened.visible_state(project).unwrap().is_none());
        }
    }
}

#[test]
fn rollback_recreated_installed_target_preserves_target_and_backup_then_blocks() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().join("project");
    fs::create_dir_all(root.join("nested")).unwrap();
    fs::write(root.join("nested/file.txt"), b"subprocess old").unwrap();
    let cas_root = temporary.path().join("cas");
    let project = ProjectId::from_bytes([230; 32]);
    let object_domain = domain(project);
    let cas = CasStore::open(&cas_root, CasLimits::default(), Arc::new(FixedKeys)).unwrap();
    install(&cas, object_domain, b"subprocess remote");
    drop(cas);
    let database = temporary.path().join("state/apply.sqlite");
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .arg("subprocess_apply_crash_child")
        .arg("--exact")
        .arg("--nocapture")
        .env("TM_APPLY_CRASH_BOUNDARY", "installed_durable")
        .env("TM_APPLY_ROOT", &root)
        .env("TM_APPLY_CAS", &cas_root)
        .env("TM_APPLY_DB", &database)
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(86));
    let target = root.join("nested/file.txt");
    fs::remove_file(&target).unwrap();
    fs::write(&target, b"subprocess remote").unwrap();
    let reopened = ApplyStore::open(&database).unwrap();
    assert!(matches!(
        reopened.recover(&root, project),
        Err(ApplyError::Sandbox(_))
    ));
    reopened.recover(&root, project).unwrap();
    assert_eq!(fs::read(&target).unwrap(), b"subprocess remote");
    let work = fs::read_dir(temporary.path())
        .unwrap()
        .filter_map(Result::ok)
        .find(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".term-mesh-apply-")
        })
        .unwrap()
        .path();
    let backup = fs::read_dir(work)
        .unwrap()
        .filter_map(Result::ok)
        .find(|entry| entry.file_name().to_string_lossy().ends_with(".bak"))
        .unwrap()
        .path();
    assert_eq!(fs::read(backup).unwrap(), b"subprocess old");
    assert!(reopened.visible_state(project).unwrap().is_none());
}

/// The base object map is what makes a three-way merge possible: it names the
/// CAS object each base file held, which the manifest's `content_hash` cannot do
/// (an `ObjectId` also binds the domain and length).
#[test]
fn base_objects_round_trip_and_replace_the_previous_set() {
    let temporary = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([9; 32]);
    let store = ApplyStore::open(temporary.path().join("state/apply.sqlite")).unwrap();

    assert!(store.load_base_objects(project).unwrap().is_empty());

    let mut objects = BTreeMap::new();
    objects.insert("a.txt".to_string(), ObjectId([1; 32]));
    objects.insert("dir/b.txt".to_string(), ObjectId([2; 32]));
    store.save_base_objects(project, &objects).unwrap();
    assert_eq!(store.load_base_objects(project).unwrap(), objects);

    // A save replaces the whole set — the base manifest is written whole, so a
    // path dropped from the base must not keep a stale object id.
    let mut next = BTreeMap::new();
    next.insert("dir/b.txt".to_string(), ObjectId([3; 32]));
    store.save_base_objects(project, &next).unwrap();
    assert_eq!(store.load_base_objects(project).unwrap(), next);

    // Scoped per project.
    let other = ProjectId::from_bytes([10; 32]);
    assert!(store.load_base_objects(other).unwrap().is_empty());
}

/// A database written before the base tables existed must still open. The schema
/// check compares the table set exactly, so without an additive migration an
/// older `apply.sqlite` would fail to open at all — taking its in-flight apply
/// journal, and the crash recovery that depends on it, with it.
#[test]
fn a_database_predating_the_base_tables_migrates_on_open() {
    let temporary = tempfile::tempdir().unwrap();
    let database = temporary.path().join("state/apply.sqlite");
    let project = ProjectId::from_bytes([11; 32]);

    let store = ApplyStore::open(&database).unwrap();
    // Rewind to what a pre-base-manifest database looked like.
    store
        .sqlite_test_execute_batch(
            "DROP TABLE base_objects; DROP TABLE base_manifests; PRAGMA user_version=3;",
        )
        .unwrap();
    drop(store);

    let reopened = ApplyStore::open(&database).unwrap();
    assert!(reopened.load_base_manifest(project).unwrap().is_empty());
    assert!(reopened.load_base_objects(project).unwrap().is_empty());

    let mut objects = BTreeMap::new();
    objects.insert("a.txt".to_string(), ObjectId([7; 32]));
    reopened.save_base_objects(project, &objects).unwrap();
    assert_eq!(reopened.load_base_objects(project).unwrap(), objects);
}
