use std::fs::File;
use std::io::{self, Write};
use std::mem::ManuallyDrop;
use std::os::fd::AsRawFd;
use std::os::fd::FromRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OpenFlags, OptionalExtension, TransactionBehavior};

use super::path_sandbox::{PathFingerprint, PathIdentity, PathSandbox, PathSandboxError};
use super::project_lock::{acquire_project_file_lease_at, ProjectLockError};
use super::sqlite_openat_vfs::OpenAtVfs;
use super::{CasError, CasStore, ObjectDomain, ObjectId, ObjectType, ProjectId};

const APP_ID: i64 = 0x544d_4150;
const VERSION: i64 = 3;
const APPLY_SCHEMA: &[(&str, &str)] = &[
    ("operations", "CREATE TABLE operations(operation_id BLOB PRIMARY KEY CHECK(length(operation_id)=16),project BLOB NOT NULL CHECK(length(project)=32),target_root BLOB NOT NULL CHECK(length(target_root)=32),frontier BLOB NOT NULL,phase TEXT NOT NULL CHECK(phase IN('prepared','applying','committed','rolled_back','blocked')),created_at_ms INTEGER NOT NULL CHECK(created_at_ms>=0)) STRICT"),
    ("entries", "CREATE TABLE entries(operation_id BLOB NOT NULL CHECK(length(operation_id)=16),ordinal INTEGER NOT NULL CHECK(ordinal>=0),path TEXT NOT NULL,action TEXT NOT NULL CHECK(action IN('file','directory','symlink','delete')),expected_absent INTEGER NOT NULL CHECK(expected_absent IN(0,1)),original_digest BLOB CHECK(original_digest IS NULL OR length(original_digest)=32),temp_name TEXT NOT NULL,backup_name TEXT NOT NULL,installed_digest BLOB CHECK(installed_digest IS NULL OR length(installed_digest)=32),installed_dev INTEGER CHECK(installed_dev IS NULL OR installed_dev>=0),installed_ino INTEGER CHECK(installed_ino IS NULL OR installed_ino>=0),phase TEXT NOT NULL CHECK(phase IN('planned','temp_durable','backup_intent','backup_durable','install_intent','installed_durable')),recovery_phase TEXT NOT NULL CHECK(recovery_phase IN('none','rollback_intent','rollback_durable','cleanup_intent','cleanup_durable')),PRIMARY KEY(operation_id,ordinal),UNIQUE(operation_id,path),FOREIGN KEY(operation_id) REFERENCES operations(operation_id)) STRICT"),
    ("visible_state", "CREATE TABLE visible_state(project BLOB PRIMARY KEY CHECK(length(project)=32),manifest_root BLOB NOT NULL CHECK(length(manifest_root)=32),frontier BLOB NOT NULL,generation INTEGER NOT NULL CHECK(generation>0)) STRICT"),
    ("one_active_operation", "CREATE UNIQUE INDEX one_active_operation ON operations(project) WHERE phase NOT IN('committed','rolled_back')"),
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApplyAction {
    File {
        object_id: ObjectId,
        content_hash: [u8; 32],
        length: u64,
        executable: bool,
    },
    Directory {
        executable: bool,
    },
    Symlink {
        target: String,
    },
    Delete,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApplyPrecondition {
    Absent,
    Present(PathFingerprint),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApplyPlanEntry {
    pub relative_path: String,
    pub action: ApplyAction,
    pub precondition: ApplyPrecondition,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApplyPlan {
    pub operation_id: [u8; 16],
    pub project: ProjectId,
    pub target_manifest_root: [u8; 32],
    pub frontier: Vec<u8>,
    pub entries: Vec<ApplyPlanEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VisibleState {
    pub manifest_root: [u8; 32],
    pub frontier: Vec<u8>,
    pub generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApplyBoundary {
    Prepared,
    TempDurable(usize),
    BackupIntent(usize),
    SecondPrecheck(usize),
    BackupDurable(usize),
    BetweenBackupInstall(usize),
    InstallIntent(usize),
    InstalledDurable(usize),
    Committed,
    CleanupDurable(usize),
    RollbackDurable(usize),
    RolledBack,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApplyIoPoint {
    TempWrite,
    TempFsync,
    TempWorkFsync,
    BackupRename,
    InstallRename,
    BackupParentFsync,
    BackupWorkFsync,
    InstallFileFsync,
    InstallParentFsync,
    RollbackTrashRename,
    RollbackTrashParentFsync,
    RollbackTrashWorkFsync,
    RollbackRestoreRename,
    RollbackRestoreFileFsync,
    RollbackRestoreParentFsync,
    RollbackRestoreWorkFsync,
    RollbackTrashUnlink,
    RollbackTrashUnlinkFsync,
    CleanupUnlink,
}

pub trait ApplyCrashHook {
    fn after_boundary(&self, boundary: ApplyBoundary) -> Result<(), ApplyError>;
    fn before_io(&self, _: ApplyIoPoint) -> Result<(), ApplyError> {
        Ok(())
    }
    fn after_io(&self, _: ApplyIoPoint) -> Result<(), ApplyError> {
        Ok(())
    }
}

struct NoCrash;
impl ApplyCrashHook for NoCrash {
    fn after_boundary(&self, _: ApplyBoundary) -> Result<(), ApplyError> {
        Ok(())
    }
}

pub struct ApplyStore {
    path: PathBuf,
    state_dir: File,
    state_dev: u64,
    state_ino: u64,
    database_name: String,
    connection: ManuallyDrop<Mutex<Connection>>,
    _vfs: Arc<OpenAtVfs>,
}

impl ApplyStore {
    pub fn open(path: impl Into<PathBuf>) -> Result<Self, ApplyError> {
        Self::open_inner(path, || {})
    }

    #[cfg(test)]
    pub fn open_with_hook(
        path: impl Into<PathBuf>,
        after_preflight: impl FnOnce(),
    ) -> Result<Self, ApplyError> {
        Self::open_inner(path, after_preflight)
    }

    fn open_inner(
        path: impl Into<PathBuf>,
        after_preflight: impl FnOnce(),
    ) -> Result<Self, ApplyError> {
        let path = path.into();
        let parent = path.parent().ok_or(ApplyError::Corrupt)?;
        let created_parent = !parent.exists();
        if created_parent {
            std::fs::create_dir_all(parent)?;
            std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
        }
        let state_dir = open_secure_state_dir(parent)?;
        let state_metadata = state_dir.metadata()?;
        let database_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .filter(|name| !name.is_empty() && !name.contains('/'))
            .ok_or(ApplyError::Corrupt)?
            .to_owned();
        validate_database_files(&state_dir, &database_name)?;
        after_preflight();
        let vfs = OpenAtVfs::register(&state_dir, &database_name)?;
        let database_metadata = entry_metadata(&state_dir, &database_name)?;
        if database_metadata.is_some_and(|stat| stat.st_size != 0) {
            if let Err(error) = preflight_existing(Path::new(&database_name), vfs.name()) {
                quarantine_database_set_at(&state_dir, &database_name)?;
                return Err(error);
            }
        }
        let connection = Connection::open_with_flags_and_vfs(
            &database_name,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_NOFOLLOW
                | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
            vfs.name(),
        )?;
        configure(&connection)?;
        if connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))? == 0 {
            let tx = connection.unchecked_transaction()?;
            for (_, sql) in APPLY_SCHEMA {
                tx.execute_batch(sql)?;
            }
            tx.pragma_update(None, "application_id", APP_ID)?;
            tx.pragma_update(None, "user_version", VERSION)?;
            tx.commit()?;
        }
        validate_schema(&connection)?;
        validate_database_files(&state_dir, &database_name)?;
        let reopened = open_secure_state_dir(parent)?;
        let reopened_metadata = reopened.metadata()?;
        if reopened_metadata.dev() != state_metadata.dev()
            || reopened_metadata.ino() != state_metadata.ino()
        {
            return Err(ApplyError::Corrupt);
        }
        Ok(Self {
            path: descriptor_directory_path(&state_dir)?.join(&database_name),
            state_dir,
            state_dev: state_metadata.dev(),
            state_ino: state_metadata.ino(),
            database_name,
            connection: ManuallyDrop::new(Mutex::new(connection)),
            _vfs: vfs,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    #[cfg(test)]
    pub fn sqlite_test_execute_batch(&self, sql: &str) -> Result<(), ApplyError> {
        let connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        connection.execute_batch(sql)?;
        Ok(())
    }

    #[cfg(test)]
    pub fn sqlite_test_query_i64(&self, sql: &str) -> Result<i64, ApplyError> {
        let connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        Ok(connection.query_row(sql, [], |row| row.get(0))?)
    }

    #[cfg(test)]
    pub fn sqlite_test_busy_timeout(&self, millis: u64) -> Result<(), ApplyError> {
        let connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        connection.busy_timeout(std::time::Duration::from_millis(millis))?;
        Ok(())
    }

    pub fn fingerprint_path(
        root: &Path,
        project: ProjectId,
        relative_path: &str,
    ) -> Result<Option<PathFingerprint>, ApplyError> {
        Ok(PathSandbox::open(root, project)?.fingerprint(relative_path)?)
    }

    pub fn visible_state(&self, project: ProjectId) -> Result<Option<VisibleState>, ApplyError> {
        let connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        connection
            .query_row(
                "SELECT manifest_root,frontier,generation FROM visible_state WHERE project=?1",
                [project.as_bytes().as_slice()],
                |row| {
                    let root: Vec<u8> = row.get(0)?;
                    let generation: i64 = row.get(2)?;
                    Ok((root, row.get(1)?, generation))
                },
            )
            .optional()?
            .map(|(root, frontier, generation)| {
                Ok(VisibleState {
                    manifest_root: root.try_into().map_err(|_| ApplyError::Corrupt)?,
                    frontier,
                    generation: u64::try_from(generation).map_err(|_| ApplyError::Corrupt)?,
                })
            })
            .transpose()
    }

    pub fn apply(
        &self,
        root: &Path,
        cas: &CasStore,
        domain: ObjectDomain,
        plan: &ApplyPlan,
    ) -> Result<VisibleState, ApplyError> {
        self.apply_with_hook(root, cas, domain, plan, &NoCrash)
    }

    pub fn apply_with_hook(
        &self,
        root: &Path,
        cas: &CasStore,
        domain: ObjectDomain,
        plan: &ApplyPlan,
        hook: &dyn ApplyCrashHook,
    ) -> Result<VisibleState, ApplyError> {
        self.revalidate_state_dir()?;
        if domain.project_id != plan.project
            || domain.object_type != ObjectType::FILE
            || plan.entries.is_empty()
        {
            return Err(ApplyError::Binding);
        }
        let _lease = acquire_project_file_lease_at(&self.state_dir, plan.project)?;
        let sandbox = PathSandbox::open(root, plan.project)?;
        self.recover_locked(&sandbox, plan.project, hook)?;
        sandbox.validate_plan_paths(
            plan.entries
                .iter()
                .map(|entry| entry.relative_path.as_str()),
        )?;
        validate_plan(plan)?;
        for ordinal in 0..plan.entries.len() {
            let (temp, backup, trash) = deterministic_names(plan.operation_id, ordinal);
            if sandbox.work_exists(&temp)?
                || sandbox.work_exists(&backup)?
                || sandbox.work_exists(&trash)?
            {
                return Err(ApplyError::Corrupt);
            }
        }
        self.insert_plan(plan)?;
        hook.after_boundary(ApplyBoundary::Prepared)?;

        let result = self.apply_entries(&sandbox, cas, domain, plan, hook);
        if let Err(error) = result {
            if matches!(
                error,
                ApplyError::Sandbox(
                    PathSandboxError::Blocked
                        | PathSandboxError::TargetExists {
                            backup_present: true
                        }
                )
            ) {
                self.mark_blocked(plan.operation_id)?;
                return Err(error);
            }
            let _ = self.rollback_operation(&sandbox, plan.operation_id, hook);
            return Err(error);
        }
        let state = self.commit_visible(plan)?;
        hook.after_boundary(ApplyBoundary::Committed)?;
        self.cleanup_operation(&sandbox, plan.operation_id, hook)?;
        Ok(state)
    }

    pub fn recover(&self, root: &Path, project: ProjectId) -> Result<(), ApplyError> {
        self.revalidate_state_dir()?;
        let _lease = acquire_project_file_lease_at(&self.state_dir, project)?;
        let sandbox = PathSandbox::open(root, project)?;
        self.recover_locked(&sandbox, project, &NoCrash)
    }

    #[cfg(test)]
    pub fn recover_with_hook(
        &self,
        root: &Path,
        project: ProjectId,
        hook: &dyn ApplyCrashHook,
    ) -> Result<(), ApplyError> {
        self.revalidate_state_dir()?;
        let _lease = acquire_project_file_lease_at(&self.state_dir, project)?;
        let sandbox = PathSandbox::open(root, project)?;
        self.recover_locked(&sandbox, project, hook)
    }

    fn recover_locked(
        &self,
        sandbox: &PathSandbox,
        project: ProjectId,
        hook: &dyn ApplyCrashHook,
    ) -> Result<(), ApplyError> {
        let operations = {
            let connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
            let mut statement = connection.prepare("SELECT operation_id,phase FROM operations WHERE project=?1 AND phase!='rolled_back'")?;
            let rows = statement.query_map([project.as_bytes().as_slice()], |row| {
                Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, String>(1)?))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        for (operation, phase) in operations {
            let operation: [u8; 16] = operation.try_into().map_err(|_| ApplyError::Corrupt)?;
            if phase == "blocked" {
                continue;
            } else if phase == "committed" {
                self.cleanup_operation(sandbox, operation, hook)?;
            } else {
                self.rollback_operation(sandbox, operation, hook)?;
            }
        }
        Ok(())
    }

    fn insert_plan(&self, plan: &ApplyPlan) -> Result<(), ApplyError> {
        let mut connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let changed = tx.execute(
            "INSERT INTO operations(operation_id,project,target_root,frontier,phase,created_at_ms)VALUES(?1,?2,?3,?4,'prepared',?5)",
            params![plan.operation_id, plan.project.as_bytes().as_slice(), plan.target_manifest_root, plan.frontier, now_ms()?],
        )?;
        expect_one(changed)?;
        for (ordinal, entry) in plan.entries.iter().enumerate() {
            let (temp, backup, _) = deterministic_names(plan.operation_id, ordinal);
            let changed = tx.execute(
                "INSERT INTO entries(operation_id,ordinal,path,action,expected_absent,original_digest,temp_name,backup_name,phase,recovery_phase)VALUES(?1,?2,?3,?4,?5,?6,?7,?8,'planned','none')",
                params![plan.operation_id, ordinal as i64, entry.relative_path, action_name(&entry.action), i64::from(matches!(entry.precondition, ApplyPrecondition::Absent)), match &entry.precondition { ApplyPrecondition::Absent => None, ApplyPrecondition::Present(fingerprint) => Some(fingerprint.digest()) }, temp, backup],
            )?;
            expect_one(changed)?;
        }
        tx.commit()?;
        Ok(())
    }

    fn apply_entries(
        &self,
        sandbox: &PathSandbox,
        cas: &CasStore,
        domain: ObjectDomain,
        plan: &ApplyPlan,
        hook: &dyn ApplyCrashHook,
    ) -> Result<(), ApplyError> {
        self.set_operation_phase(plan.operation_id, "applying")?;
        for (ordinal, entry) in plan.entries.iter().enumerate() {
            let (temp, backup, _) = deterministic_names(plan.operation_id, ordinal);
            match &entry.action {
                ApplyAction::File {
                    object_id,
                    content_hash,
                    length,
                    executable,
                } => {
                    let mut file =
                        sandbox.create_temp_file(&temp, if *executable { 0o700 } else { 0o600 })?;
                    hook.before_io(ApplyIoPoint::TempWrite)?;
                    let mut writer = HashingWriter::new(&mut file);
                    let copied = cas.copy_verified_plaintext(domain, *object_id, &mut writer)?;
                    hook.after_io(ApplyIoPoint::TempWrite)?;
                    let (written, actual_hash) = writer.finish();
                    if copied != *length || written != *length || actual_hash != *content_hash {
                        return Err(ApplyError::Binding);
                    }
                    if unsafe {
                        libc::fchmod(file.as_raw_fd(), if *executable { 0o700 } else { 0o600 })
                    } != 0
                    {
                        return Err(io::Error::last_os_error().into());
                    }
                    hook.before_io(ApplyIoPoint::TempFsync)?;
                    file.sync_all()?;
                    hook.after_io(ApplyIoPoint::TempFsync)?;
                    sandbox.sync_temp_work(hook)?;
                }
                ApplyAction::Directory { executable } => {
                    sandbox.create_temp_directory(
                        &temp,
                        if *executable { 0o700 } else { 0o600 },
                        hook,
                    )?;
                }
                ApplyAction::Symlink { target } => {
                    sandbox.create_temp_symlink(&temp, target, hook)?;
                }
                ApplyAction::Delete => {}
            }
            if !matches!(entry.action, ApplyAction::Delete) {
                let installed_digest = sandbox
                    .fingerprint_work(&temp)?
                    .ok_or(ApplyError::Corrupt)?
                    .digest();
                self.set_installed_digest(plan.operation_id, ordinal, installed_digest)?;
                self.transition_entry(plan.operation_id, ordinal, "planned", "temp_durable")?;
                hook.after_boundary(ApplyBoundary::TempDurable(ordinal))?;
            }
            let first = sandbox.inspect(&entry.relative_path)?;
            if !precondition_matches(&entry.precondition, first.fingerprint.as_ref()) {
                return Err(ApplyError::StalePrecondition(entry.relative_path.clone()));
            }
            self.transition_entry(
                plan.operation_id,
                ordinal,
                if matches!(entry.action, ApplyAction::Delete) {
                    "planned"
                } else {
                    "temp_durable"
                },
                "backup_intent",
            )?;
            hook.after_boundary(ApplyBoundary::BackupIntent(ordinal))?;
            let handle = sandbox.inspect(&entry.relative_path)?;
            if !precondition_matches(&entry.precondition, handle.fingerprint.as_ref()) {
                return Err(ApplyError::StalePrecondition(entry.relative_path.clone()));
            }
            hook.after_boundary(ApplyBoundary::SecondPrecheck(ordinal))?;
            if let ApplyPrecondition::Present(expected) = &entry.precondition {
                sandbox.move_target_to_backup(&handle, &backup, expected, hook)?;
            }
            self.transition_entry(
                plan.operation_id,
                ordinal,
                "backup_intent",
                "backup_durable",
            )?;
            hook.after_boundary(ApplyBoundary::BackupDurable(ordinal))?;
            hook.after_boundary(ApplyBoundary::BetweenBackupInstall(ordinal))?;
            self.transition_entry(
                plan.operation_id,
                ordinal,
                "backup_durable",
                "install_intent",
            )?;
            hook.after_boundary(ApplyBoundary::InstallIntent(ordinal))?;
            if !matches!(entry.action, ApplyAction::Delete) {
                let identity = sandbox.install_temp(&temp, &handle, hook)?;
                self.set_installed_identity(plan.operation_id, ordinal, identity)?;
                sandbox.sync_installed(&handle, hook)?;
            }
            self.transition_entry(
                plan.operation_id,
                ordinal,
                "install_intent",
                "installed_durable",
            )?;
            hook.after_boundary(ApplyBoundary::InstalledDurable(ordinal))?;
        }
        Ok(())
    }

    fn commit_visible(&self, plan: &ApplyPlan) -> Result<VisibleState, ApplyError> {
        let mut connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let generation: i64 = tx.query_row(
            "SELECT COALESCE((SELECT generation FROM visible_state WHERE project=?1),0)+1",
            [plan.project.as_bytes().as_slice()],
            |row| row.get(0),
        )?;
        tx.execute(
            "INSERT INTO visible_state(project,manifest_root,frontier,generation)VALUES(?1,?2,?3,?4) ON CONFLICT(project) DO UPDATE SET manifest_root=excluded.manifest_root,frontier=excluded.frontier,generation=excluded.generation",
            params![plan.project.as_bytes().as_slice(), plan.target_manifest_root, plan.frontier, generation],
        ).and_then(expect_one)?;
        tx.execute(
            "UPDATE operations SET phase='committed' WHERE operation_id=?1 AND phase='applying'",
            [plan.operation_id.as_slice()],
        )
        .and_then(expect_one)?;
        tx.commit()?;
        Ok(VisibleState {
            manifest_root: plan.target_manifest_root,
            frontier: plan.frontier.clone(),
            generation: generation as u64,
        })
    }

    fn rollback_operation(
        &self,
        sandbox: &PathSandbox,
        operation: [u8; 16],
        hook: &dyn ApplyCrashHook,
    ) -> Result<(), ApplyError> {
        let entries = self.load_entries(operation)?;
        for entry in entries.into_iter().rev() {
            if entry.recovery_phase == "rollback_durable" {
                continue;
            }
            if entry.recovery_phase == "none" {
                self.transition_recovery(operation, entry.ordinal, "none", "rollback_intent")?;
            } else if entry.recovery_phase != "rollback_intent" {
                return Err(ApplyError::Corrupt);
            }
            let backup_exists = sandbox.work_exists(&entry.backup)?;
            let temp_exists = sandbox.work_exists(&entry.temp)?;
            let trash_exists = sandbox.work_exists(&entry.trash)?;
            let expected_absent_install_completed = entry.expected_absent
                && (entry.phase == "installed_durable"
                    || (entry.phase == "install_intent" && !temp_exists));
            let rollback_already_applied = !backup_exists
                && (trash_exists
                    || (expected_absent_install_completed
                        && sandbox.target_identity(&entry.path)?.is_none()));
            if trash_exists && !backup_exists {
                let current = sandbox
                    .fingerprint(&entry.path)?
                    .map(|value| value.digest());
                let restored = if entry.expected_absent {
                    current.is_none()
                } else {
                    current == entry.original_digest
                };
                if !restored {
                    self.mark_blocked(operation)?;
                    return Err(PathSandboxError::Blocked.into());
                }
                sandbox.finalize_rollback_target(
                    &entry.path,
                    entry.expected_absent,
                    entry.original_digest,
                    hook,
                )?;
                sandbox.remove_rollback_trash(&entry.trash, hook)?;
            }
            if backup_exists {
                if sandbox.target_identity(&entry.path)?.is_some() {
                    let Some(installed_digest) = entry.installed_digest else {
                        self.mark_blocked(operation)?;
                        return Err(PathSandboxError::Blocked.into());
                    };
                    let (Some(device), Some(inode)) = (entry.installed_dev, entry.installed_ino)
                    else {
                        self.mark_blocked(operation)?;
                        return Err(PathSandboxError::Blocked.into());
                    };
                    if let Err(error) = sandbox.move_installed_to_trash(
                        &entry.path,
                        &entry.trash,
                        installed_digest,
                        PathIdentity { device, inode },
                        hook,
                    ) {
                        if matches!(error, ApplyError::Sandbox(PathSandboxError::Blocked)) {
                            self.mark_blocked(operation)?;
                        }
                        return Err(error);
                    }
                }
                if let Err(error) =
                    sandbox.restore_backup_exclusive(&entry.backup, &entry.path, hook)
                {
                    self.mark_blocked(operation)?;
                    return Err(match error {
                        ApplyError::Sandbox(PathSandboxError::Io(ref io_error))
                            if io_error.kind() == io::ErrorKind::AlreadyExists =>
                        {
                            PathSandboxError::Blocked.into()
                        }
                        other => other,
                    });
                }
                sandbox.finalize_rollback_target(
                    &entry.path,
                    entry.expected_absent,
                    entry.original_digest,
                    hook,
                )?;
                sandbox.remove_rollback_trash(&entry.trash, hook)?;
            } else if !rollback_already_applied && expected_absent_install_completed {
                let (Some(installed_digest), Some(device), Some(inode)) = (
                    entry.installed_digest,
                    entry.installed_dev,
                    entry.installed_ino,
                ) else {
                    self.mark_blocked(operation)?;
                    return Err(PathSandboxError::Blocked.into());
                };
                if let Err(error) = sandbox.move_installed_to_trash(
                    &entry.path,
                    &entry.trash,
                    installed_digest,
                    PathIdentity { device, inode },
                    hook,
                ) {
                    if matches!(error, ApplyError::Sandbox(PathSandboxError::Blocked)) {
                        self.mark_blocked(operation)?;
                    }
                    return Err(error);
                }
                sandbox.finalize_rollback_target(
                    &entry.path,
                    entry.expected_absent,
                    entry.original_digest,
                    hook,
                )?;
                sandbox.remove_rollback_trash(&entry.trash, hook)?;
            }
            sandbox.remove_work_entry(&entry.temp)?;
            sandbox.finalize_rollback_target(
                &entry.path,
                entry.expected_absent,
                entry.original_digest,
                hook,
            )?;
            self.transition_recovery(
                operation,
                entry.ordinal,
                "rollback_intent",
                "rollback_durable",
            )?;
            hook.after_boundary(ApplyBoundary::RollbackDurable(entry.ordinal))?;
        }
        let connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        connection
            .execute(
                "UPDATE operations SET phase='rolled_back' WHERE operation_id=?1 AND phase!='committed' AND phase!='rolled_back'",
                [operation.as_slice()],
            )
            .and_then(expect_one)?;
        hook.after_boundary(ApplyBoundary::RolledBack)?;
        Ok(())
    }

    fn cleanup_operation(
        &self,
        sandbox: &PathSandbox,
        operation: [u8; 16],
        hook: &dyn ApplyCrashHook,
    ) -> Result<(), ApplyError> {
        for entry in self.load_entries(operation)? {
            if entry.recovery_phase == "cleanup_durable" {
                continue;
            }
            if entry.recovery_phase == "none" {
                self.transition_recovery(operation, entry.ordinal, "none", "cleanup_intent")?;
            } else if entry.recovery_phase != "cleanup_intent" {
                return Err(ApplyError::Corrupt);
            }
            hook.before_io(ApplyIoPoint::CleanupUnlink)?;
            sandbox.remove_work_entry(&entry.temp)?;
            sandbox.remove_work_entry(&entry.backup)?;
            hook.after_io(ApplyIoPoint::CleanupUnlink)?;
            self.transition_recovery(
                operation,
                entry.ordinal,
                "cleanup_intent",
                "cleanup_durable",
            )?;
            hook.after_boundary(ApplyBoundary::CleanupDurable(entry.ordinal))?;
        }
        Ok(())
    }

    fn load_entries(&self, operation: [u8; 16]) -> Result<Vec<JournalEntry>, ApplyError> {
        let connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        let mut statement = connection.prepare("SELECT ordinal,path,expected_absent,original_digest,temp_name,backup_name,installed_digest,installed_dev,installed_ino,phase,recovery_phase FROM entries WHERE operation_id=?1 ORDER BY ordinal")?;
        let rows = statement.query_map([operation.as_slice()], |row| {
            let ordinal = row.get::<_, i64>(0)? as usize;
            Ok(JournalEntry {
                ordinal,
                path: row.get(1)?,
                expected_absent: row.get::<_, i64>(2)? != 0,
                original_digest: row
                    .get::<_, Option<Vec<u8>>>(3)?
                    .map(|digest| digest.try_into())
                    .transpose()
                    .map_err(|_| rusqlite::Error::InvalidQuery)?,
                temp: row.get(4)?,
                backup: row.get(5)?,
                trash: deterministic_names(operation, ordinal).2,
                installed_digest: row
                    .get::<_, Option<Vec<u8>>>(6)?
                    .map(|digest| digest.try_into())
                    .transpose()
                    .map_err(|_| rusqlite::Error::InvalidQuery)?,
                installed_dev: row.get::<_, Option<i64>>(7)?.map(|value| value as u64),
                installed_ino: row.get::<_, Option<i64>>(8)?.map(|value| value as u64),
                phase: row.get(9)?,
                recovery_phase: row.get(10)?,
            })
        })?;
        let entries = rows.collect::<Result<Vec<_>, _>>()?;
        for (ordinal, entry) in entries.iter().enumerate() {
            let (temp, backup, trash) = deterministic_names(operation, ordinal);
            super::path_sandbox::validate_relative(&entry.path)?;
            if entry.ordinal != ordinal
                || entry.temp != temp
                || entry.backup != backup
                || entry.trash != trash
            {
                return Err(ApplyError::Corrupt);
            }
        }
        Ok(entries)
    }

    fn set_operation_phase(&self, operation: [u8; 16], phase: &str) -> Result<(), ApplyError> {
        if phase != "applying" {
            return Err(ApplyError::Corrupt);
        }
        let connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        connection
            .execute(
                "UPDATE operations SET phase=?2 WHERE operation_id=?1 AND phase='prepared'",
                params![operation, phase],
            )
            .and_then(expect_one)?;
        Ok(())
    }

    fn transition_entry(
        &self,
        operation: [u8; 16],
        ordinal: usize,
        from: &str,
        to: &str,
    ) -> Result<(), ApplyError> {
        let connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        connection
            .execute(
                "UPDATE entries SET phase=?4 WHERE operation_id=?1 AND ordinal=?2 AND phase=?3",
                params![operation, ordinal as i64, from, to],
            )
            .and_then(expect_one)?;
        Ok(())
    }

    fn set_installed_digest(
        &self,
        operation: [u8; 16],
        ordinal: usize,
        digest: [u8; 32],
    ) -> Result<(), ApplyError> {
        let connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        connection
            .execute(
                "UPDATE entries SET installed_digest=?3 WHERE operation_id=?1 AND ordinal=?2 AND installed_digest IS NULL AND phase='planned'",
                params![operation, ordinal as i64, digest],
            )
            .and_then(expect_one)?;
        Ok(())
    }

    fn set_installed_identity(
        &self,
        operation: [u8; 16],
        ordinal: usize,
        identity: PathIdentity,
    ) -> Result<(), ApplyError> {
        let device = i64::try_from(identity.device).map_err(|_| ApplyError::Corrupt)?;
        let inode = i64::try_from(identity.inode).map_err(|_| ApplyError::Corrupt)?;
        let connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        connection
            .execute(
                "UPDATE entries SET installed_dev=?3,installed_ino=?4 WHERE operation_id=?1 AND ordinal=?2 AND installed_dev IS NULL AND installed_ino IS NULL AND phase='install_intent'",
                params![operation, ordinal as i64, device, inode],
            )
            .and_then(expect_one)?;
        Ok(())
    }

    fn transition_recovery(
        &self,
        operation: [u8; 16],
        ordinal: usize,
        from: &str,
        to: &str,
    ) -> Result<(), ApplyError> {
        let connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        connection
            .execute(
                "UPDATE entries SET recovery_phase=?4 WHERE operation_id=?1 AND ordinal=?2 AND recovery_phase=?3",
                params![operation, ordinal as i64, from, to],
            )
            .and_then(expect_one)?;
        Ok(())
    }

    fn mark_blocked(&self, operation: [u8; 16]) -> Result<(), ApplyError> {
        let connection = self.connection.lock().map_err(|_| ApplyError::Poisoned)?;
        connection
            .execute(
                "UPDATE operations SET phase='blocked' WHERE operation_id=?1 AND phase IN('prepared','applying')",
                [operation.as_slice()],
            )
            .and_then(expect_one)?;
        Ok(())
    }

    fn revalidate_state_dir(&self) -> Result<(), ApplyError> {
        let metadata = self.state_dir.metadata()?;
        if metadata.dev() != self.state_dev || metadata.ino() != self.state_ino {
            return Err(ApplyError::Corrupt);
        }
        validate_database_files(&self.state_dir, &self.database_name)
    }
}

impl Drop for ApplyStore {
    fn drop(&mut self) {
        // SQLite may call VFS callbacks while closing WAL/SHM. Close the connection
        // explicitly before `_vfs` unregisters and frees its callback context.
        unsafe { ManuallyDrop::drop(&mut self.connection) };
    }
}

fn descriptor_directory_path(directory: &File) -> Result<PathBuf, ApplyError> {
    #[cfg(target_os = "macos")]
    {
        let mut buffer = vec![0_u8; libc::PATH_MAX as usize];
        if unsafe { libc::fcntl(directory.as_raw_fd(), libc::F_GETPATH, buffer.as_mut_ptr()) } != 0
        {
            return Err(io::Error::last_os_error().into());
        }
        let length = buffer
            .iter()
            .position(|byte| *byte == 0)
            .ok_or(ApplyError::Corrupt)?;
        return Ok(PathBuf::from(std::ffi::OsStr::from_bytes(
            &buffer[..length],
        )));
    }
    #[cfg(target_os = "linux")]
    {
        Ok(std::fs::read_link(format!(
            "/proc/self/fd/{}",
            directory.as_raw_fd()
        ))?)
    }
}

struct JournalEntry {
    ordinal: usize,
    path: String,
    expected_absent: bool,
    original_digest: Option<[u8; 32]>,
    temp: String,
    backup: String,
    trash: String,
    installed_digest: Option<[u8; 32]>,
    installed_dev: Option<u64>,
    installed_ino: Option<u64>,
    phase: String,
    recovery_phase: String,
}

struct HashingWriter<'a> {
    writer: &'a mut File,
    hasher: blake3::Hasher,
    written: u64,
}
impl<'a> HashingWriter<'a> {
    fn new(writer: &'a mut File) -> Self {
        Self {
            writer,
            hasher: blake3::Hasher::new(),
            written: 0,
        }
    }
    fn finish(self) -> (u64, [u8; 32]) {
        (self.written, *self.hasher.finalize().as_bytes())
    }
}
impl Write for HashingWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let written = self.writer.write(bytes)?;
        self.hasher.update(&bytes[..written]);
        self.written = self
            .written
            .checked_add(written as u64)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "length overflow"))?;
        Ok(written)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.writer.flush()
    }
}

fn validate_plan(plan: &ApplyPlan) -> Result<(), ApplyError> {
    if plan.entries.len() > 1_000_000 || plan.frontier.len() > 16 * 1024 * 1024 {
        return Err(ApplyError::Limit);
    }
    let mut seen = std::collections::BTreeSet::new();
    for entry in &plan.entries {
        if entry.relative_path.len() > 4096 {
            return Err(ApplyError::Limit);
        }
        if !seen.insert(&entry.relative_path) {
            return Err(ApplyError::Binding);
        }
        match &entry.action {
            ApplyAction::File {
                length,
                executable: _,
                object_id: _,
                content_hash: _,
            } if *length > 50 * 1024 * 1024 * 1024 => return Err(ApplyError::Limit),
            ApplyAction::Symlink { target } if target.len() > 4095 => {
                return Err(ApplyError::Limit)
            }
            _ => {}
        }
    }
    Ok(())
}

fn precondition_matches(expected: &ApplyPrecondition, actual: Option<&PathFingerprint>) -> bool {
    match (expected, actual) {
        (ApplyPrecondition::Absent, None) => true,
        (ApplyPrecondition::Present(expected), Some(actual)) => {
            expected == actual && expected.digest() == actual.digest()
        }
        _ => false,
    }
}

fn action_name(action: &ApplyAction) -> &'static str {
    match action {
        ApplyAction::File { .. } => "file",
        ApplyAction::Directory { .. } => "directory",
        ApplyAction::Symlink { .. } => "symlink",
        ApplyAction::Delete => "delete",
    }
}

fn deterministic_names(operation: [u8; 16], ordinal: usize) -> (String, String, String) {
    let prefix = hex::encode(operation);
    (
        format!("{prefix}-{ordinal}.tmp"),
        format!("{prefix}-{ordinal}.bak"),
        format!("{prefix}-{ordinal}.trash"),
    )
}

fn now_ms() -> Result<i64, ApplyError> {
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| ApplyError::Corrupt)?
        .as_millis();
    i64::try_from(millis).map_err(|_| ApplyError::Corrupt)
}

fn expect_one(changed: usize) -> Result<usize, rusqlite::Error> {
    if changed == 1 {
        Ok(changed)
    } else {
        Err(rusqlite::Error::StatementChangedRows(changed))
    }
}

fn configure(connection: &Connection) -> Result<(), ApplyError> {
    connection.pragma_update(None, "journal_mode", "WAL")?;
    let journal_mode: String =
        connection.pragma_query_value(None, "journal_mode", |row| row.get(0))?;
    if journal_mode.to_ascii_lowercase() != "wal" {
        return Err(ApplyError::Corrupt);
    }
    connection.pragma_update(None, "synchronous", "FULL")?;
    connection.pragma_update(None, "wal_autocheckpoint", 0)?;
    connection.pragma_update(None, "foreign_keys", "ON")?;
    connection.busy_timeout(std::time::Duration::from_secs(5))?;
    Ok(())
}

fn open_secure_state_dir(path: &Path) -> Result<File, ApplyError> {
    let path =
        std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|_| ApplyError::Corrupt)?;
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error().into());
    }
    let directory = unsafe { File::from_raw_fd(fd) };
    let metadata = directory.metadata()?;
    if !metadata.file_type().is_dir()
        || metadata.permissions().mode() & 0o777 != 0o700
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() < 2
    {
        return Err(ApplyError::Corrupt);
    }
    Ok(directory)
}

fn entry_metadata(directory: &File, name: &str) -> Result<Option<libc::stat>, ApplyError> {
    let name = std::ffi::CString::new(name).map_err(|_| ApplyError::Corrupt)?;
    let mut stat = std::mem::MaybeUninit::uninit();
    if unsafe {
        libc::fstatat(
            directory.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::NotFound {
            return Ok(None);
        }
        return Err(error.into());
    }
    Ok(Some(unsafe { stat.assume_init() }))
}

fn validate_database_files(directory: &File, database: &str) -> Result<(), ApplyError> {
    let directory_metadata = directory.metadata()?;
    for name in [
        database.to_owned(),
        format!("{database}-wal"),
        format!("{database}-shm"),
    ] {
        let Some(stat) = entry_metadata(directory, &name)? else {
            continue;
        };
        if stat.st_mode & libc::S_IFMT != libc::S_IFREG
            || stat.st_uid != unsafe { libc::geteuid() }
            || stat.st_nlink != 1
            || stat.st_dev as u64 != directory_metadata.dev()
        {
            return Err(ApplyError::Corrupt);
        }
    }
    Ok(())
}

fn validate_schema(connection: &Connection) -> Result<(), ApplyError> {
    if connection.query_row("PRAGMA application_id", [], |row| row.get::<_, i64>(0))? != APP_ID
        || connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))? != VERSION
        || connection.query_row("PRAGMA quick_check", [], |row| row.get::<_, String>(0))? != "ok"
    {
        return Err(ApplyError::Schema);
    }
    let mut statement = connection.prepare(
        "SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
        ))
    })?;
    let actual = rows.collect::<Result<Vec<_>, _>>()?;
    if actual.len() != APPLY_SCHEMA.len() {
        return Err(ApplyError::Schema);
    }
    for (kind, name, sql) in actual {
        let expected = APPLY_SCHEMA
            .iter()
            .find(|(candidate, _)| *candidate == name)
            .ok_or(ApplyError::Schema)?;
        let expected_kind = if expected.1.starts_with("CREATE UNIQUE INDEX") {
            "index"
        } else {
            "table"
        };
        if kind != expected_kind || sql.as_deref() != Some(expected.1) {
            return Err(ApplyError::Schema);
        }
    }
    Ok(())
}

fn preflight_existing(path: &Path, vfs: &str) -> Result<(), ApplyError> {
    let connection = Connection::open_with_flags_and_vfs(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_NO_MUTEX
            | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        vfs,
    )?;
    validate_schema(&connection)
}

fn quarantine_database_set_at(directory: &File, database: &str) -> Result<(), ApplyError> {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| ApplyError::Corrupt)?
        .as_nanos();
    for suffix in ["", "-wal", "-shm"] {
        let source = format!("{database}{suffix}");
        if entry_metadata(directory, &source)?.is_some() {
            let destination = format!("{database}.quarantine-{stamp}{suffix}");
            let source = std::ffi::CString::new(source).map_err(|_| ApplyError::Corrupt)?;
            let destination =
                std::ffi::CString::new(destination).map_err(|_| ApplyError::Corrupt)?;
            #[cfg(target_os = "macos")]
            let result = unsafe {
                libc::renameatx_np(
                    directory.as_raw_fd(),
                    source.as_ptr(),
                    directory.as_raw_fd(),
                    destination.as_ptr(),
                    libc::RENAME_EXCL,
                )
            };
            #[cfg(target_os = "linux")]
            let result = unsafe {
                libc::renameat2(
                    directory.as_raw_fd(),
                    source.as_ptr(),
                    directory.as_raw_fd(),
                    destination.as_ptr(),
                    libc::RENAME_NOREPLACE,
                )
            };
            if result != 0 {
                return Err(io::Error::last_os_error().into());
            }
        }
    }
    directory.sync_all()?;
    Ok(())
}

#[derive(Debug)]
pub enum ApplyError {
    Io(io::Error),
    Sql(rusqlite::Error),
    Cas(CasError),
    Sandbox(PathSandboxError),
    Lock(ProjectLockError),
    Schema,
    Corrupt,
    Binding,
    Limit,
    Poisoned,
    StalePrecondition(String),
    CrashInjected,
}

impl From<io::Error> for ApplyError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}
impl From<rusqlite::Error> for ApplyError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Sql(value)
    }
}
impl From<CasError> for ApplyError {
    fn from(value: CasError) -> Self {
        Self::Cas(value)
    }
}
impl From<PathSandboxError> for ApplyError {
    fn from(value: PathSandboxError) -> Self {
        Self::Sandbox(value)
    }
}
impl From<ProjectLockError> for ApplyError {
    fn from(value: ProjectLockError) -> Self {
        Self::Lock(value)
    }
}
impl std::fmt::Display for ApplyError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{self:?}")
    }
}
impl std::error::Error for ApplyError {}
