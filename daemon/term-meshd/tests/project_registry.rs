#[path = "../src/sync/mod.rs"]
mod sync;

use std::fs;
use std::os::unix::fs::symlink;

use sync::{ManifestScanner, ProjectId, ProjectRegistry, RegistryError, ScanLimits, ScanReason};

fn registry_db(temp: &tempfile::TempDir) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let state = temp.path().join("sync-state");
    fs::create_dir_all(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    state.join("registry.sqlite")
}

fn make_private(path: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}

#[test]
fn project_id_survives_root_move_and_registry_reopen() {
    let temp = tempfile::tempdir().unwrap();
    let database = registry_db(&temp);
    let old_root = temp.path().join("project-before-move");
    let new_root = temp.path().join("project-after-move");
    fs::create_dir(&old_root).unwrap();

    let project_id = {
        let registry = ProjectRegistry::open(&database).unwrap();
        let added = registry.add(&old_root).unwrap();
        assert_eq!(registry.path(), database);
        fs::rename(&old_root, &new_root).unwrap();
        registry.relocate(added.project_id, &new_root).unwrap();
        added.project_id
    };

    let reopened = ProjectRegistry::open(&database).unwrap();
    let project = reopened.get(project_id).unwrap().unwrap();
    assert_eq!(project.project_id, project_id);
    assert_eq!(
        ProjectId::from_bytes(*project.project_id.as_bytes()),
        project_id
    );
    assert_eq!(project.root_path, fs::canonicalize(new_root).unwrap());
}

#[test]
fn failed_sync_state_transaction_preserves_committed_values() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("project");
    fs::create_dir(&root).unwrap();
    let registry = ProjectRegistry::open(registry_db(&temp)).unwrap();
    let project = registry.add(&root).unwrap();

    let committed_manifest = [0x11; 32];
    registry
        .update_sync_state(project.project_id, committed_manifest, 7)
        .unwrap();

    let error = registry
        .update_sync_state(project.project_id, [0x22; 32], 6)
        .unwrap_err();
    assert!(matches!(
        error,
        RegistryError::EpochRegression {
            committed: 7,
            proposed: 6
        }
    ));

    let unchanged = registry.get(project.project_id).unwrap().unwrap();
    assert_eq!(unchanged.active_manifest, Some(committed_manifest));
    assert_eq!(unchanged.roster_epoch, 7);
}

#[test]
fn corrupt_registry_is_quarantined_without_replacement() {
    let temp = tempfile::tempdir().unwrap();
    let database = registry_db(&temp);
    let corrupt_fixture = b"not-a-sqlite-registry\x00keep-this-byte-for-byte";
    fs::write(&database, corrupt_fixture).unwrap();
    make_private(&database);

    let error = match ProjectRegistry::open(&database) {
        Ok(_) => panic!("corrupt registry must not open"),
        Err(error) => error,
    };
    assert!(matches!(error, RegistryError::Quarantined { .. }));
    assert_eq!(fs::read(&database).unwrap(), corrupt_fixture);
}

#[test]
fn schema_constraint_drift_is_quarantined_without_modification() {
    let temp = tempfile::tempdir().unwrap();
    let database = registry_db(&temp);
    {
        let connection = rusqlite::Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE sync_projects (
                     project_id BLOB PRIMARY KEY NOT NULL,
                     root_path TEXT NOT NULL UNIQUE,
                     active_manifest BLOB,
                     roster_epoch INTEGER NOT NULL DEFAULT 0,
                     created_at_ms INTEGER NOT NULL
                 ) STRICT;
                 PRAGMA application_id = 1414352979;
                 PRAGMA user_version = 1;",
            )
            .unwrap();
    }
    make_private(&database);
    let original = fs::read(&database).unwrap();

    let error = match ProjectRegistry::open(&database) {
        Ok(_) => panic!("constraint-drifted registry must not open"),
        Err(error) => error,
    };
    assert!(matches!(error, RegistryError::Quarantined { .. }));
    assert_eq!(fs::read(&database).unwrap(), original);
}

#[test]
fn partial_unique_root_index_is_quarantined_without_modification() {
    let temp = tempfile::tempdir().unwrap();
    let database = registry_db(&temp);
    {
        let connection = rusqlite::Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE sync_projects (
                     project_id BLOB PRIMARY KEY NOT NULL CHECK(length(project_id) = 32),
                     root_path TEXT NOT NULL,
                     active_manifest BLOB CHECK(active_manifest IS NULL OR length(active_manifest) = 32),
                     roster_epoch INTEGER NOT NULL DEFAULT 0 CHECK(roster_epoch >= 0),
                     created_at_ms INTEGER NOT NULL
                 ) STRICT;
                 CREATE UNIQUE INDEX root_path_partial
                     ON sync_projects(root_path) WHERE 0;
                 PRAGMA application_id = 1414352979;
                 PRAGMA user_version = 1;",
            )
            .unwrap();
    }
    make_private(&database);
    let original = fs::read(&database).unwrap();

    let error = match ProjectRegistry::open(&database) {
        Ok(_) => panic!("partial root uniqueness must not satisfy schema v1"),
        Err(error) => error,
    };
    assert!(matches!(error, RegistryError::Quarantined { .. }));
    assert_eq!(fs::read(&database).unwrap(), original);
}

#[test]
fn check_text_hidden_in_comments_cannot_spoof_canonical_ddl() {
    let temp = tempfile::tempdir().unwrap();
    let database = registry_db(&temp);
    {
        let connection = rusqlite::Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE sync_projects (
                     project_id BLOB PRIMARY KEY NOT NULL,
                     root_path TEXT NOT NULL UNIQUE,
                     active_manifest BLOB,
                     roster_epoch INTEGER NOT NULL DEFAULT 0,
                     created_at_ms INTEGER NOT NULL,
                     /* CHECK(length(project_id) = 32)
                        CHECK(active_manifest IS NULL OR length(active_manifest) = 32)
                        CHECK(roster_epoch >= 0) */
                     CHECK(1)
                 ) STRICT;
                 PRAGMA application_id = 1414352979;
                 PRAGMA user_version = 1;",
            )
            .unwrap();
    }
    make_private(&database);
    let original = fs::read(&database).unwrap();

    let error = match ProjectRegistry::open(&database) {
        Ok(_) => panic!("CHECK text in comments must not satisfy schema v1"),
        Err(error) => error,
    };
    assert!(matches!(error, RegistryError::Quarantined { .. }));
    assert_eq!(fs::read(&database).unwrap(), original);
}

#[test]
fn exact_and_symlink_alias_roots_are_rejected_as_duplicates() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("project");
    let alias = temp.path().join("project-alias");
    fs::create_dir(&root).unwrap();
    symlink(&root, &alias).unwrap();
    let registry = ProjectRegistry::open(registry_db(&temp)).unwrap();
    let project = registry.add(&root).unwrap();

    assert!(registry.add(&root).is_err());
    assert!(registry.add(&alias).is_err());
    assert_eq!(
        registry.get(project.project_id).unwrap().unwrap().root_path,
        fs::canonicalize(root).unwrap()
    );
}

#[test]
fn failed_relocate_to_owned_root_preserves_both_records() {
    let temp = tempfile::tempdir().unwrap();
    let first_root = temp.path().join("first");
    let second_root = temp.path().join("second");
    fs::create_dir(&first_root).unwrap();
    fs::create_dir(&second_root).unwrap();
    let registry = ProjectRegistry::open(registry_db(&temp)).unwrap();
    let first = registry.add(&first_root).unwrap();
    let second = registry.add(&second_root).unwrap();

    assert!(registry.relocate(first.project_id, &second_root).is_err());
    assert_eq!(
        registry.get(first.project_id).unwrap().unwrap().root_path,
        fs::canonicalize(&first_root).unwrap()
    );
    assert_eq!(
        registry.get(second.project_id).unwrap().unwrap().root_path,
        fs::canonicalize(&second_root).unwrap()
    );
}

#[test]
fn list_returns_all_projects_in_stable_root_order() {
    let temp = tempfile::tempdir().unwrap();
    let first_root = temp.path().join("alpha");
    let second_root = temp.path().join("beta");
    fs::create_dir(&first_root).unwrap();
    fs::create_dir(&second_root).unwrap();
    let registry = ProjectRegistry::open(registry_db(&temp)).unwrap();
    let second = registry.add(&second_root).unwrap();
    let first = registry.add(&first_root).unwrap();

    let projects = registry.list().unwrap();
    assert_eq!(projects.len(), 2);
    assert_eq!(projects[0].project_id, first.project_id);
    assert_eq!(projects[1].project_id, second.project_id);
}

#[test]
fn resolved_root_holds_identity_and_detects_path_replacement() {
    use std::os::unix::fs::MetadataExt;

    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("project");
    let original = temp.path().join("project-original");
    fs::create_dir(&root).unwrap();
    let registry = ProjectRegistry::open(registry_db(&temp)).unwrap();
    let project = registry.add(&root).unwrap();
    let held = registry.resolve_root(project.project_id).unwrap();
    let held_inode = held.descriptor().metadata().unwrap().ino();

    fs::rename(&root, &original).unwrap();
    fs::create_dir(&root).unwrap();

    assert_eq!(held.descriptor().metadata().unwrap().ino(), held_inode);
    assert!(matches!(
        held.revalidate(),
        Err(RegistryError::RootIdentityChanged(_))
    ));
}

#[test]
fn registry_database_rejects_insecure_modes_and_symlinked_files() {
    use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};

    let good = tempfile::tempdir().unwrap();
    let database = registry_db(&good);
    drop(ProjectRegistry::open(&database).unwrap());
    assert_eq!(fs::metadata(&database).unwrap().mode() & 0o777, 0o600);

    let wrong_mode = tempfile::tempdir().unwrap();
    let database = registry_db(&wrong_mode);
    fs::write(&database, b"bad").unwrap();
    fs::set_permissions(&database, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(matches!(
        ProjectRegistry::open(&database),
        Err(RegistryError::Security)
    ));

    let wrong_directory = tempfile::tempdir().unwrap();
    let database = registry_db(&wrong_directory);
    fs::set_permissions(
        database.parent().unwrap(),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    assert!(matches!(
        ProjectRegistry::open(&database),
        Err(RegistryError::Security)
    ));

    for suffix in ["", "-wal", "-shm"] {
        let temp = tempfile::tempdir().unwrap();
        let database = registry_db(&temp);
        let target = temp.path().join("target");
        fs::write(&target, b"target").unwrap();
        symlink(&target, format!("{}{suffix}", database.display())).unwrap();
        assert!(matches!(
            ProjectRegistry::open(&database),
            Err(RegistryError::Security)
        ));
    }
}

#[test]
fn descriptor_scan_ignores_transient_path_swap() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("project");
    let held_path = temp.path().join("held-project");
    let replacement = temp.path().join("replacement");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("original"), b"trusted").unwrap();
    let registry = ProjectRegistry::open(registry_db(&temp)).unwrap();
    let project = registry.add(&root).unwrap();
    let held = registry.resolve_root(project.project_id).unwrap();

    fs::rename(&root, &held_path).unwrap();
    fs::create_dir(&root).unwrap();
    fs::write(root.join("replacement"), b"untrusted").unwrap();
    let (manifest, _) = ManifestScanner::new(ScanLimits::default())
        .unwrap()
        .scan_descriptor(held.descriptor(), ScanReason::Initial)
        .unwrap();
    assert_eq!(manifest.entry_count, 1);

    fs::rename(&root, &replacement).unwrap();
    fs::rename(&held_path, &root).unwrap();
    held.revalidate().unwrap();
}

#[test]
fn extra_sqlite_master_object_is_quarantined() {
    let temp = tempfile::tempdir().unwrap();
    let database = registry_db(&temp);
    drop(ProjectRegistry::open(&database).unwrap());
    rusqlite::Connection::open(&database)
        .unwrap()
        .execute_batch("CREATE TABLE unexpected(value TEXT) STRICT;")
        .unwrap();
    make_private(&database);
    assert!(matches!(
        ProjectRegistry::open(&database),
        Err(RegistryError::Quarantined { .. })
    ));
}
