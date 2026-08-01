use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{CStr, CString};
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Component, Path};
use unicode_casefold::UnicodeCaseFold;
use unicode_normalization::UnicodeNormalization;

use super::apply::{ApplyCrashHook, ApplyError, ApplyIoPoint};
use super::ProjectId;

const PRECONDITION_DOMAIN: &[u8] = b"term-mesh apply precondition v1\0";
const DIRECTORY_DOMAIN: &[u8] = b"term-mesh apply directory v1\0";
const MAX_FINGERPRINT_ENTRIES: u64 = 1_000_000;
const MAX_FINGERPRINT_BYTES: u64 = 50 * 1024 * 1024 * 1024;
const MAX_FINGERPRINT_DEPTH: usize = 128;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathKind {
    File,
    Directory,
    Symlink,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathFingerprint {
    pub kind: PathKind,
    pub content_hash: [u8; 32],
    pub length: u64,
    pub executable: bool,
    pub symlink_target: Option<String>,
}

/// The fingerprint an EMPTY directory of `mode` produces.
///
/// A directory's fingerprint is recursive over its children, so it cannot be
/// rebuilt from a manifest entry — but the childless case has no recursion left
/// in it and is fully determined by the mode. That is exactly the precondition a
/// directory delete needs: "still a directory, still this mode, and nothing is
/// left inside it". Anything created under the path since the scan — including
/// files the scanner never tracked — makes the real fingerprint differ, and the
/// delete is refused rather than carrying that content off.
///
/// Kept in lockstep with `fingerprint_entry`'s `S_IFDIR` arm by
/// `empty_directory_fingerprint_matches_a_real_one`, which fingerprints an
/// actual empty directory and compares.
pub fn empty_directory_fingerprint(mode: u16) -> PathFingerprint {
    let mode = u32::from(mode) & 0o777;
    let mut hasher = blake3::Hasher::new();
    hasher.update(DIRECTORY_DOMAIN);
    hasher.update(&mode.to_be_bytes());
    PathFingerprint {
        kind: PathKind::Directory,
        content_hash: *hasher.finalize().as_bytes(),
        // `fingerprint_entry` reports a directory's length as the number of
        // entries beneath it. Empty means zero.
        length: 0,
        executable: mode & 0o111 != 0,
        symlink_target: None,
    }
}

impl PathFingerprint {
    pub fn digest(&self) -> [u8; 32] {
        let mut hasher = blake3::Hasher::new();
        hasher.update(PRECONDITION_DOMAIN);
        hasher.update(&[match self.kind {
            PathKind::File => 1,
            PathKind::Directory => 2,
            PathKind::Symlink => 3,
        }]);
        hasher.update(&self.content_hash);
        hasher.update(&self.length.to_be_bytes());
        hasher.update(&[u8::from(self.executable)]);
        if let Some(target) = &self.symlink_target {
            hasher.update(&(target.len() as u64).to_be_bytes());
            hasher.update(target.as_bytes());
        } else {
            hasher.update(&0_u64.to_be_bytes());
        }
        *hasher.finalize().as_bytes()
    }
}

pub(crate) struct PathSandbox {
    root: File,
    root_parent: File,
    root_name: CString,
    root_dev: u64,
    root_ino: u64,
    work: File,
}

pub(crate) struct TargetHandle {
    path: String,
    parent: File,
    parent_dev: u64,
    parent_ino: u64,
    name: CString,
    pub(crate) fingerprint: Option<PathFingerprint>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PathIdentity {
    pub(crate) device: u64,
    pub(crate) inode: u64,
}

#[derive(Debug)]
pub enum PathSandboxError {
    Io(io::Error),
    InvalidPath,
    InvalidRoot,
    InvalidWorkDirectory,
    Collision { first: String, second: String },
    ChangedDuringRead,
    FingerprintLimit,
    Blocked,
    TargetExists { backup_present: bool },
    UnsupportedType,
}

impl From<io::Error> for PathSandboxError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

impl PathSandbox {
    pub(crate) fn open(root_path: &Path, project: ProjectId) -> Result<Self, PathSandboxError> {
        let root_parent_path = root_path.parent().ok_or(PathSandboxError::InvalidRoot)?;
        let root_name = root_path.file_name().ok_or(PathSandboxError::InvalidRoot)?;
        let root_parent = open_path_directory(root_parent_path)?;
        let root_name = c_name_bytes(root_name.as_bytes())?;
        let root = open_directory_at(root_parent.as_raw_fd(), &root_name)?;
        let root_meta = root.metadata()?;
        if !root_meta.file_type().is_dir() {
            return Err(PathSandboxError::InvalidRoot);
        }
        let work_name = CString::new(format!(".term-mesh-apply-{project}"))
            .map_err(|_| PathSandboxError::InvalidWorkDirectory)?;
        if unsafe { libc::mkdirat(root_parent.as_raw_fd(), work_name.as_ptr(), 0o700) } != 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::EEXIST) {
                return Err(PathSandboxError::Io(error));
            }
        } else {
            root_parent.sync_all()?;
        }
        let work = open_directory_at(root_parent.as_raw_fd(), &work_name)?;
        let work_meta = work.metadata()?;
        if !work_meta.file_type().is_dir()
            || work_meta.permissions().mode() & 0o777 != 0o700
            || work_meta.uid() != unsafe { libc::geteuid() }
            || work_meta.nlink() < 2
            || work_meta.dev() != root_meta.dev()
        {
            return Err(PathSandboxError::InvalidWorkDirectory);
        }
        Ok(Self {
            root,
            root_parent,
            root_name,
            root_dev: root_meta.dev(),
            root_ino: root_meta.ino(),
            work,
        })
    }

    pub(crate) fn validate_plan_paths<'a>(
        &self,
        paths: impl IntoIterator<Item = &'a str>,
    ) -> Result<(), PathSandboxError> {
        self.revalidate_root()?;
        validate_existing_tree(&self.root)?;
        let mut per_parent: BTreeMap<String, Vec<String>> = BTreeMap::new();
        let mut exact = BTreeSet::new();
        for path in paths {
            let components = validate_relative(path)?;
            if !exact.insert(path.to_owned()) {
                return Err(PathSandboxError::Collision {
                    first: path.to_owned(),
                    second: path.to_owned(),
                });
            }
            for index in 0..components.len() {
                let parent = components[..index].join("/");
                per_parent
                    .entry(parent)
                    .or_default()
                    .push(components[index].clone());
            }
        }
        for (parent, desired) in per_parent {
            check_name_collisions(&desired)?;
            let parent_file = match self.open_relative_dir(&parent) {
                Ok(file) => file,
                Err(PathSandboxError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {
                    continue;
                }
                Err(error) => return Err(error),
            };
            let existing = entry_names(&parent_file)?;
            let desired_set: BTreeSet<_> = desired.iter().cloned().collect();
            let mut combined = desired.clone();
            combined.extend(
                existing
                    .into_iter()
                    .filter(|name| !desired_set.contains(name)),
            );
            check_name_collisions(&combined)?;
        }
        Ok(())
    }

    pub(crate) fn fingerprint(
        &self,
        path: &str,
    ) -> Result<Option<PathFingerprint>, PathSandboxError> {
        Ok(self.inspect(path)?.fingerprint)
    }

    pub(crate) fn inspect(&self, path: &str) -> Result<TargetHandle, PathSandboxError> {
        self.revalidate_root()?;
        let (parent, name) = self.open_parent(path, false)?;
        let parent_stat = fstat(parent.as_raw_fd())?;
        let target_stat = match stat_at(parent.as_raw_fd(), &name) {
            Ok(stat) => stat,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(TargetHandle {
                    path: path.to_owned(),
                    parent,
                    parent_dev: parent_stat.st_dev as u64,
                    parent_ino: parent_stat.st_ino as u64,
                    name,
                    fingerprint: None,
                })
            }
            Err(error) => return Err(error.into()),
        };
        let mut budget = FingerprintBudget::default();
        let fingerprint =
            fingerprint_entry(parent.as_raw_fd(), &name, target_stat, 0, &mut budget)?;
        Ok(TargetHandle {
            path: path.to_owned(),
            parent,
            parent_dev: parent_stat.st_dev as u64,
            parent_ino: parent_stat.st_ino as u64,
            name,
            fingerprint: Some(fingerprint),
        })
    }

    pub(crate) fn create_temp_file(&self, name: &str, mode: u32) -> Result<File, PathSandboxError> {
        self.revalidate_root()?;
        let name = c_name(name)?;
        let fd = unsafe {
            libc::openat(
                self.work.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                mode & 0o777,
            )
        };
        if fd < 0 {
            return Err(PathSandboxError::Io(io::Error::last_os_error()));
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }

    pub(crate) fn create_temp_symlink(
        &self,
        name: &str,
        target: &str,
        hook: &dyn ApplyCrashHook,
    ) -> Result<(), ApplyError> {
        self.revalidate_root()?;
        validate_symlink_target(target)?;
        let name = c_name(name)?;
        let target = CString::new(target).map_err(|_| PathSandboxError::InvalidPath)?;
        hook.before_io(ApplyIoPoint::TempWrite)?;
        if unsafe { libc::symlinkat(target.as_ptr(), self.work.as_raw_fd(), name.as_ptr()) } != 0 {
            return Err(PathSandboxError::Io(io::Error::last_os_error()).into());
        }
        hook.after_io(ApplyIoPoint::TempWrite)?;
        hook.before_io(ApplyIoPoint::TempWorkFsync)?;
        self.work.sync_all()?;
        hook.after_io(ApplyIoPoint::TempWorkFsync)?;
        Ok(())
    }

    pub(crate) fn create_temp_directory(
        &self,
        name: &str,
        mode: u32,
        hook: &dyn ApplyCrashHook,
    ) -> Result<(), ApplyError> {
        self.revalidate_root()?;
        let name = c_name(name)?;
        hook.before_io(ApplyIoPoint::TempWrite)?;
        if unsafe {
            libc::mkdirat(
                self.work.as_raw_fd(),
                name.as_ptr(),
                (mode & 0o777) as libc::mode_t,
            )
        } != 0
        {
            return Err(PathSandboxError::Io(io::Error::last_os_error()).into());
        }
        hook.after_io(ApplyIoPoint::TempWrite)?;
        let directory = open_directory_at(self.work.as_raw_fd(), &name)?;
        hook.before_io(ApplyIoPoint::TempFsync)?;
        directory.sync_all()?;
        hook.after_io(ApplyIoPoint::TempFsync)?;
        hook.before_io(ApplyIoPoint::TempWorkFsync)?;
        self.work.sync_all()?;
        hook.after_io(ApplyIoPoint::TempWorkFsync)?;
        Ok(())
    }

    pub(crate) fn sync_temp_work(&self, hook: &dyn ApplyCrashHook) -> Result<(), ApplyError> {
        hook.before_io(ApplyIoPoint::TempWorkFsync)?;
        self.work.sync_all()?;
        hook.after_io(ApplyIoPoint::TempWorkFsync)?;
        Ok(())
    }

    pub(crate) fn move_target_to_backup(
        &self,
        handle: &TargetHandle,
        backup: &str,
        expected: &PathFingerprint,
        hook: &dyn ApplyCrashHook,
    ) -> Result<(), ApplyError> {
        self.revalidate_handle(handle)?;
        hook.before_io(ApplyIoPoint::BackupRename)?;
        rename_exclusive_at(
            handle.parent.as_raw_fd(),
            &handle.name,
            self.work.as_raw_fd(),
            &c_name(backup)?,
        )?;
        hook.after_io(ApplyIoPoint::BackupRename)?;
        hook.before_io(ApplyIoPoint::BackupParentFsync)?;
        handle.parent.sync_all()?;
        hook.after_io(ApplyIoPoint::BackupParentFsync)?;
        hook.before_io(ApplyIoPoint::BackupWorkFsync)?;
        self.work.sync_all()?;
        hook.after_io(ApplyIoPoint::BackupWorkFsync)?;
        let actual = self.fingerprint_work(backup)?;
        if actual.as_ref() != Some(expected) {
            match rename_exclusive_at(
                self.work.as_raw_fd(),
                &c_name(backup)?,
                handle.parent.as_raw_fd(),
                &handle.name,
            ) {
                Ok(()) => {
                    handle.parent.sync_all()?;
                    self.work.sync_all()?;
                    return Err(PathSandboxError::ChangedDuringRead.into());
                }
                Err(error) if is_exists_error(&error) => {
                    return Err(PathSandboxError::Blocked.into())
                }
                Err(error) => return Err(PathSandboxError::Io(error).into()),
            }
        }
        Ok(())
    }

    pub(crate) fn install_temp(
        &self,
        temp: &str,
        handle: &TargetHandle,
        hook: &dyn ApplyCrashHook,
    ) -> Result<PathIdentity, ApplyError> {
        self.revalidate_handle(handle)?;
        hook.before_io(ApplyIoPoint::InstallRename)?;
        if let Err(error) = rename_exclusive_at(
            self.work.as_raw_fd(),
            &c_name(temp)?,
            handle.parent.as_raw_fd(),
            &handle.name,
        ) {
            return Err(if is_exists_error(&error) {
                PathSandboxError::TargetExists {
                    backup_present: handle.fingerprint.is_some(),
                }
            } else {
                PathSandboxError::Io(error)
            }
            .into());
        }
        hook.after_io(ApplyIoPoint::InstallRename)?;
        self.target_identity(&handle.path)?
            .ok_or(ApplyError::Corrupt)
    }

    pub(crate) fn sync_installed(
        &self,
        handle: &TargetHandle,
        hook: &dyn ApplyCrashHook,
    ) -> Result<(), ApplyError> {
        hook.before_io(ApplyIoPoint::InstallFileFsync)?;
        sync_entry(handle.parent.as_raw_fd(), &handle.name)?;
        hook.after_io(ApplyIoPoint::InstallFileFsync)?;
        hook.before_io(ApplyIoPoint::InstallParentFsync)?;
        handle.parent.sync_all()?;
        hook.after_io(ApplyIoPoint::InstallParentFsync)?;
        Ok(())
    }

    pub(crate) fn restore_backup(&self, backup: &str, path: &str) -> Result<(), PathSandboxError> {
        self.revalidate_root()?;
        let (parent, name) = self.open_parent(path, false)?;
        let _ = unlink_at(parent.as_raw_fd(), &name, false);
        rename_at(
            self.work.as_raw_fd(),
            &c_name(backup)?,
            parent.as_raw_fd(),
            &name,
        )?;
        sync_entry(parent.as_raw_fd(), &name)?;
        parent.sync_all()?;
        self.work.sync_all()?;
        Ok(())
    }

    pub(crate) fn remove_target_if_exists(&self, path: &str) -> Result<(), PathSandboxError> {
        self.revalidate_root()?;
        let (parent, name) = self.open_parent(path, false)?;
        match stat_at(parent.as_raw_fd(), &name) {
            Ok(stat) => unlink_at(
                parent.as_raw_fd(),
                &name,
                stat.st_mode & libc::S_IFMT == libc::S_IFDIR,
            )?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error.into()),
        }
        parent.sync_all()?;
        Ok(())
    }

    pub(crate) fn remove_work_entry(&self, name: &str) -> Result<(), PathSandboxError> {
        let name = c_name(name)?;
        match stat_at(self.work.as_raw_fd(), &name) {
            Ok(stat) if stat.st_mode & libc::S_IFMT == libc::S_IFDIR => {
                remove_tree_at(self.work.as_raw_fd(), &name)?
            }
            Ok(_) => unlink_at(self.work.as_raw_fd(), &name, false)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error.into()),
        }
        self.work.sync_all()?;
        Ok(())
    }

    pub(crate) fn work_exists(&self, name: &str) -> Result<bool, PathSandboxError> {
        match stat_at(self.work.as_raw_fd(), &c_name(name)?) {
            Ok(_) => Ok(true),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error.into()),
        }
    }

    pub(crate) fn fingerprint_work(
        &self,
        name: &str,
    ) -> Result<Option<PathFingerprint>, PathSandboxError> {
        let name = c_name(name)?;
        let stat = match stat_at(self.work.as_raw_fd(), &name) {
            Ok(stat) => stat,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        let mut budget = FingerprintBudget::default();
        fingerprint_entry(self.work.as_raw_fd(), &name, stat, 0, &mut budget).map(Some)
    }

    /// The permission bits of `path` when it is a directory; `None` when it is
    /// absent or is not one.
    ///
    /// A stat, deliberately — not a fingerprint. The caller needs a directory's
    /// mode to build the precondition for deleting it, and at that moment the
    /// directory still holds the children the same plan is about to remove, so
    /// its real fingerprint is not yet the one the delete will be checked
    /// against.
    pub(crate) fn directory_mode(&self, path: &str) -> Result<Option<u16>, PathSandboxError> {
        self.revalidate_root()?;
        let (parent, name) = match self.open_parent(path, false) {
            Ok(opened) => opened,
            // An ancestor is gone, so the path is too. Same answer as a missing
            // leaf: nothing here to delete.
            Err(PathSandboxError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(None)
            }
            Err(error) => return Err(error),
        };
        match stat_at(parent.as_raw_fd(), &name) {
            Ok(stat) if stat.st_mode & libc::S_IFMT == libc::S_IFDIR => {
                Ok(Some((stat.st_mode as u32 & 0o777) as u16))
            }
            Ok(_) => Ok(None),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    /// `chmod` an installed directory to `mode`.
    ///
    /// Opens the path with `O_DIRECTORY|O_NOFOLLOW` and chmods the DESCRIPTOR,
    /// not the name: a path-based chmod could be redirected between the check
    /// and the call, and this runs on a tree the peer's manifest named.
    pub(crate) fn set_directory_mode(&self, path: &str, mode: u32) -> Result<(), PathSandboxError> {
        self.revalidate_root()?;
        let (parent, name) = self.open_parent(path, false)?;
        let directory = open_directory_at(parent.as_raw_fd(), &name)?;
        if unsafe { libc::fchmod(directory.as_raw_fd(), (mode & 0o777) as libc::mode_t) } != 0 {
            return Err(PathSandboxError::Io(io::Error::last_os_error()));
        }
        directory.sync_all()?;
        Ok(())
    }

    pub(crate) fn target_identity(
        &self,
        path: &str,
    ) -> Result<Option<PathIdentity>, PathSandboxError> {
        self.revalidate_root()?;
        let (parent, name) = self.open_parent(path, false)?;
        match stat_at(parent.as_raw_fd(), &name) {
            Ok(stat) => Ok(Some(PathIdentity {
                device: stat.st_dev as u64,
                inode: stat.st_ino as u64,
            })),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    pub(crate) fn move_installed_to_trash(
        &self,
        path: &str,
        trash: &str,
        expected_digest: [u8; 32],
        expected_identity: PathIdentity,
        hook: &dyn ApplyCrashHook,
    ) -> Result<(), ApplyError> {
        let handle = self.inspect(path)?;
        let identity = self.target_identity(path)?;
        if handle.fingerprint.as_ref().map(PathFingerprint::digest) != Some(expected_digest)
            || identity != Some(expected_identity)
        {
            return Err(PathSandboxError::Blocked.into());
        }
        let trash = c_name(trash)?;
        hook.before_io(ApplyIoPoint::RollbackTrashRename)?;
        rename_exclusive_at(
            handle.parent.as_raw_fd(),
            &handle.name,
            self.work.as_raw_fd(),
            &trash,
        )?;
        hook.after_io(ApplyIoPoint::RollbackTrashRename)?;
        hook.before_io(ApplyIoPoint::RollbackTrashParentFsync)?;
        handle.parent.sync_all()?;
        hook.after_io(ApplyIoPoint::RollbackTrashParentFsync)?;
        hook.before_io(ApplyIoPoint::RollbackTrashWorkFsync)?;
        self.work.sync_all()?;
        hook.after_io(ApplyIoPoint::RollbackTrashWorkFsync)?;
        let moved_stat = stat_at(self.work.as_raw_fd(), &trash)?;
        let moved_identity = PathIdentity {
            device: moved_stat.st_dev as u64,
            inode: moved_stat.st_ino as u64,
        };
        let moved_digest = self
            .fingerprint_work(trash.to_str().map_err(|_| PathSandboxError::InvalidPath)?)?
            .map(|fingerprint| fingerprint.digest());
        if moved_identity != expected_identity || moved_digest != Some(expected_digest) {
            match rename_exclusive_at(
                self.work.as_raw_fd(),
                &trash,
                handle.parent.as_raw_fd(),
                &handle.name,
            ) {
                Ok(()) => {
                    handle.parent.sync_all()?;
                    self.work.sync_all()?;
                }
                Err(error) if is_exists_error(&error) => {}
                Err(error) => return Err(PathSandboxError::Io(error).into()),
            }
            return Err(PathSandboxError::Blocked.into());
        }
        Ok(())
    }

    pub(crate) fn restore_backup_exclusive(
        &self,
        backup: &str,
        path: &str,
        hook: &dyn ApplyCrashHook,
    ) -> Result<(), ApplyError> {
        self.revalidate_root()?;
        let (parent, name) = self.open_parent(path, false)?;
        hook.before_io(ApplyIoPoint::RollbackRestoreRename)?;
        rename_exclusive_at(
            self.work.as_raw_fd(),
            &c_name(backup)?,
            parent.as_raw_fd(),
            &name,
        )?;
        hook.after_io(ApplyIoPoint::RollbackRestoreRename)?;
        hook.before_io(ApplyIoPoint::RollbackRestoreFileFsync)?;
        sync_entry(parent.as_raw_fd(), &name)?;
        hook.after_io(ApplyIoPoint::RollbackRestoreFileFsync)?;
        hook.before_io(ApplyIoPoint::RollbackRestoreParentFsync)?;
        parent.sync_all()?;
        hook.after_io(ApplyIoPoint::RollbackRestoreParentFsync)?;
        hook.before_io(ApplyIoPoint::RollbackRestoreWorkFsync)?;
        self.work.sync_all()?;
        hook.after_io(ApplyIoPoint::RollbackRestoreWorkFsync)?;
        Ok(())
    }

    pub(crate) fn remove_rollback_trash(
        &self,
        name: &str,
        hook: &dyn ApplyCrashHook,
    ) -> Result<(), ApplyError> {
        let name = c_name(name)?;
        hook.before_io(ApplyIoPoint::RollbackTrashUnlink)?;
        match stat_at(self.work.as_raw_fd(), &name) {
            Ok(stat) if stat.st_mode & libc::S_IFMT == libc::S_IFDIR => {
                remove_tree_at(self.work.as_raw_fd(), &name)?
            }
            Ok(_) => unlink_at(self.work.as_raw_fd(), &name, false)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(PathSandboxError::Io(error).into()),
        }
        hook.after_io(ApplyIoPoint::RollbackTrashUnlink)?;
        hook.before_io(ApplyIoPoint::RollbackTrashUnlinkFsync)?;
        self.work.sync_all()?;
        hook.after_io(ApplyIoPoint::RollbackTrashUnlinkFsync)?;
        Ok(())
    }

    pub(crate) fn finalize_rollback_target(
        &self,
        path: &str,
        expected_absent: bool,
        original_digest: Option<[u8; 32]>,
        hook: &dyn ApplyCrashHook,
    ) -> Result<(), ApplyError> {
        self.revalidate_root()?;
        let current = self.fingerprint(path)?.map(|value| value.digest());
        if (expected_absent && current.is_some())
            || (!expected_absent && current != original_digest)
        {
            return Err(PathSandboxError::Blocked.into());
        }
        let (parent, name) = self.open_parent(path, false)?;
        match stat_at(parent.as_raw_fd(), &name) {
            Ok(_) if expected_absent => return Err(PathSandboxError::Blocked.into()),
            Ok(_) => {
                hook.before_io(ApplyIoPoint::RollbackRestoreFileFsync)?;
                sync_entry(parent.as_raw_fd(), &name)?;
                hook.after_io(ApplyIoPoint::RollbackRestoreFileFsync)?;
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound && expected_absent => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Err(PathSandboxError::Blocked.into());
            }
            Err(error) => return Err(PathSandboxError::Io(error).into()),
        }
        hook.before_io(ApplyIoPoint::RollbackRestoreParentFsync)?;
        parent.sync_all()?;
        hook.after_io(ApplyIoPoint::RollbackRestoreParentFsync)?;
        hook.before_io(ApplyIoPoint::RollbackRestoreWorkFsync)?;
        self.work.sync_all()?;
        hook.after_io(ApplyIoPoint::RollbackRestoreWorkFsync)?;
        Ok(())
    }

    fn revalidate_handle(&self, handle: &TargetHandle) -> Result<(), PathSandboxError> {
        self.revalidate_root()?;
        let components = validate_relative(&handle.path)?;
        let parent_path = components[..components.len() - 1].join("/");
        let reopened = self.open_relative_dir(&parent_path)?;
        let stat = fstat(reopened.as_raw_fd())?;
        let held = fstat(handle.parent.as_raw_fd())?;
        if stat.st_dev as u64 != handle.parent_dev
            || stat.st_ino as u64 != handle.parent_ino
            || held.st_dev as u64 != handle.parent_dev
            || held.st_ino as u64 != handle.parent_ino
        {
            return Err(PathSandboxError::ChangedDuringRead);
        }
        Ok(())
    }

    fn fingerprint_file(
        &self,
        parent: libc::c_int,
        name: &CString,
        before: libc::stat,
    ) -> Result<PathFingerprint, PathSandboxError> {
        let fd = unsafe {
            libc::openat(
                parent,
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            return Err(PathSandboxError::Io(io::Error::last_os_error()));
        }
        let mut file = unsafe { File::from_raw_fd(fd) };
        let opened = fstat(fd)?;
        if !same_identity(&before, &opened) || opened.st_mode & libc::S_IFMT != libc::S_IFREG {
            return Err(PathSandboxError::ChangedDuringRead);
        }
        let mut hasher = blake3::Hasher::new();
        let mut buffer = [0_u8; 64 * 1024];
        let mut length = 0_u64;
        loop {
            let read = file.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            length = length
                .checked_add(read as u64)
                .ok_or(PathSandboxError::ChangedDuringRead)?;
            hasher.update(&buffer[..read]);
        }
        let after = fstat(fd)?;
        if !same_identity(&opened, &after) || length != after.st_size as u64 {
            return Err(PathSandboxError::ChangedDuringRead);
        }
        Ok(PathFingerprint {
            kind: PathKind::File,
            content_hash: *hasher.finalize().as_bytes(),
            length,
            executable: after.st_mode & 0o111 != 0,
            symlink_target: None,
        })
    }

    fn open_parent(&self, path: &str, create: bool) -> Result<(File, CString), PathSandboxError> {
        let components = validate_relative(path)?;
        let mut directory = self.root.try_clone()?;
        for component in &components[..components.len() - 1] {
            let name = c_name(component)?;
            match open_directory_at(directory.as_raw_fd(), &name) {
                Ok(next) => directory = next,
                Err(PathSandboxError::Io(error))
                    if create && error.kind() == io::ErrorKind::NotFound =>
                {
                    if unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
                        return Err(PathSandboxError::Io(io::Error::last_os_error()));
                    }
                    directory.sync_all()?;
                    directory = open_directory_at(directory.as_raw_fd(), &name)?;
                }
                Err(error) => return Err(error),
            }
        }
        Ok((directory, c_name(components.last().unwrap())?))
    }

    fn open_relative_dir(&self, path: &str) -> Result<File, PathSandboxError> {
        let mut directory = self.root.try_clone()?;
        if path.is_empty() {
            return Ok(directory);
        }
        for component in validate_relative(path)? {
            directory = open_directory_at(directory.as_raw_fd(), &c_name(&component)?)?;
        }
        Ok(directory)
    }

    fn revalidate_root(&self) -> Result<(), PathSandboxError> {
        let stat = stat_at(self.root_parent.as_raw_fd(), &self.root_name)?;
        if stat.st_mode & libc::S_IFMT != libc::S_IFDIR
            || stat.st_dev as u64 != self.root_dev
            || stat.st_ino as u64 != self.root_ino
        {
            return Err(PathSandboxError::InvalidRoot);
        }
        Ok(())
    }
}

pub(crate) fn validate_relative(path: &str) -> Result<Vec<String>, PathSandboxError> {
    if path.is_empty() || path.as_bytes().contains(&0) || Path::new(path).is_absolute() {
        return Err(PathSandboxError::InvalidPath);
    }
    let mut result = Vec::new();
    for component in path.split('/') {
        if component.is_empty() || component == "." || component == ".." {
            return Err(PathSandboxError::InvalidPath);
        }
        result.push(component.to_owned());
    }
    if result.is_empty() {
        return Err(PathSandboxError::InvalidPath);
    }
    Ok(result)
}

fn validate_symlink_target(target: &str) -> Result<(), PathSandboxError> {
    if target.is_empty() || target.as_bytes().contains(&0) || Path::new(target).is_absolute() {
        return Err(PathSandboxError::InvalidPath);
    }
    for component in Path::new(target).components() {
        if !matches!(component, Component::Normal(_)) {
            return Err(PathSandboxError::InvalidPath);
        }
    }
    Ok(())
}

fn collision_key(name: &str) -> String {
    name.nfc().collect::<String>().case_fold().nfc().collect()
}

fn check_name_collisions(names: &[String]) -> Result<(), PathSandboxError> {
    let mut seen = BTreeMap::new();
    for name in names {
        let key = collision_key(name);
        if let Some(first) = seen.insert(key, name.clone()) {
            if first != *name {
                return Err(PathSandboxError::Collision {
                    first,
                    second: name.clone(),
                });
            }
        }
    }
    Ok(())
}

fn open_path_directory(path: &Path) -> Result<File, PathSandboxError> {
    let path =
        CString::new(path.as_os_str().as_bytes()).map_err(|_| PathSandboxError::InvalidRoot)?;
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(PathSandboxError::Io(io::Error::last_os_error()));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn open_directory_at(parent: libc::c_int, name: &CString) -> Result<File, PathSandboxError> {
    let fd = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(PathSandboxError::Io(io::Error::last_os_error()));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn c_name(value: &str) -> Result<CString, PathSandboxError> {
    c_name_bytes(value.as_bytes())
}
fn c_name_bytes(value: &[u8]) -> Result<CString, PathSandboxError> {
    if value.is_empty() || value.contains(&b'/') {
        return Err(PathSandboxError::InvalidPath);
    }
    CString::new(value).map_err(|_| PathSandboxError::InvalidPath)
}

fn stat_at(parent: libc::c_int, name: &CString) -> io::Result<libc::stat> {
    let mut stat = std::mem::MaybeUninit::uninit();
    if unsafe {
        libc::fstatat(
            parent,
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { stat.assume_init() })
}

fn fstat(fd: libc::c_int) -> io::Result<libc::stat> {
    let mut stat = std::mem::MaybeUninit::uninit();
    if unsafe { libc::fstat(fd, stat.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { stat.assume_init() })
}

fn same_identity(a: &libc::stat, b: &libc::stat) -> bool {
    a.st_dev == b.st_dev
        && a.st_ino == b.st_ino
        && a.st_mode == b.st_mode
        && a.st_size == b.st_size
        && a.st_mtime == b.st_mtime
        && a.st_mtime_nsec == b.st_mtime_nsec
}

#[derive(Default)]
struct FingerprintBudget {
    entries: u64,
    bytes: u64,
}

fn fingerprint_entry(
    parent: libc::c_int,
    name: &CString,
    before: libc::stat,
    depth: usize,
    budget: &mut FingerprintBudget,
) -> Result<PathFingerprint, PathSandboxError> {
    if depth > MAX_FINGERPRINT_DEPTH {
        return Err(PathSandboxError::FingerprintLimit);
    }
    budget.entries = budget
        .entries
        .checked_add(1)
        .ok_or(PathSandboxError::FingerprintLimit)?;
    if budget.entries > MAX_FINGERPRINT_ENTRIES {
        return Err(PathSandboxError::FingerprintLimit);
    }
    match before.st_mode & libc::S_IFMT {
        libc::S_IFREG => {
            let fd = unsafe {
                libc::openat(
                    parent,
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
                )
            };
            if fd < 0 {
                return Err(PathSandboxError::Io(io::Error::last_os_error()));
            }
            let mut file = unsafe { File::from_raw_fd(fd) };
            let opened = fstat(fd)?;
            if !same_identity(&before, &opened) || opened.st_mode & libc::S_IFMT != libc::S_IFREG {
                return Err(PathSandboxError::ChangedDuringRead);
            }
            let mut hasher = blake3::Hasher::new();
            let mut buffer = [0_u8; 64 * 1024];
            let mut length = 0_u64;
            loop {
                let read = file.read(&mut buffer)?;
                if read == 0 {
                    break;
                }
                length = length
                    .checked_add(read as u64)
                    .ok_or(PathSandboxError::FingerprintLimit)?;
                budget.bytes = budget
                    .bytes
                    .checked_add(read as u64)
                    .ok_or(PathSandboxError::FingerprintLimit)?;
                if budget.bytes > MAX_FINGERPRINT_BYTES {
                    return Err(PathSandboxError::FingerprintLimit);
                }
                hasher.update(&buffer[..read]);
            }
            let after = fstat(fd)?;
            if !same_identity(&opened, &after) || length != after.st_size as u64 {
                return Err(PathSandboxError::ChangedDuringRead);
            }
            Ok(PathFingerprint {
                kind: PathKind::File,
                content_hash: *hasher.finalize().as_bytes(),
                length,
                executable: after.st_mode & 0o111 != 0,
                symlink_target: None,
            })
        }
        libc::S_IFLNK => {
            let target = read_link_at(parent, name)?;
            let after = stat_at(parent, name)?;
            if !same_identity(&before, &after) {
                return Err(PathSandboxError::ChangedDuringRead);
            }
            budget.bytes = budget
                .bytes
                .checked_add(target.len() as u64)
                .ok_or(PathSandboxError::FingerprintLimit)?;
            if budget.bytes > MAX_FINGERPRINT_BYTES {
                return Err(PathSandboxError::FingerprintLimit);
            }
            Ok(PathFingerprint {
                kind: PathKind::Symlink,
                content_hash: *blake3::hash(target.as_bytes()).as_bytes(),
                length: target.len() as u64,
                executable: false,
                symlink_target: Some(target),
            })
        }
        libc::S_IFDIR => {
            let directory = open_directory_at(parent, name)?;
            let opened = fstat(directory.as_raw_fd())?;
            if !same_identity(&before, &opened) {
                return Err(PathSandboxError::ChangedDuringRead);
            }
            let mut names = entry_names(&directory)?;
            names.sort_by(|left, right| left.as_bytes().cmp(right.as_bytes()));
            check_name_collisions(&names)?;
            let start_entries = budget.entries;
            let mut hasher = blake3::Hasher::new();
            hasher.update(DIRECTORY_DOMAIN);
            hasher.update(&(opened.st_mode as u32 & 0o777).to_be_bytes());
            for child in names {
                budget.bytes = budget
                    .bytes
                    .checked_add(child.len() as u64)
                    .ok_or(PathSandboxError::FingerprintLimit)?;
                if budget.bytes > MAX_FINGERPRINT_BYTES {
                    return Err(PathSandboxError::FingerprintLimit);
                }
                let child_name = c_name(&child)?;
                let child_stat = stat_at(directory.as_raw_fd(), &child_name)?;
                let child_fingerprint = fingerprint_entry(
                    directory.as_raw_fd(),
                    &child_name,
                    child_stat,
                    depth + 1,
                    budget,
                )?;
                hasher.update(&(child.len() as u32).to_be_bytes());
                hasher.update(child.as_bytes());
                hasher.update(&child_fingerprint.digest());
            }
            let after = fstat(directory.as_raw_fd())?;
            if !same_identity(&opened, &after) {
                return Err(PathSandboxError::ChangedDuringRead);
            }
            Ok(PathFingerprint {
                kind: PathKind::Directory,
                content_hash: *hasher.finalize().as_bytes(),
                length: budget.entries - start_entries,
                executable: after.st_mode & 0o111 != 0,
                symlink_target: None,
            })
        }
        _ => Err(PathSandboxError::UnsupportedType),
    }
}

fn rename_at(
    from_dir: libc::c_int,
    from: &CString,
    to_dir: libc::c_int,
    to: &CString,
) -> io::Result<()> {
    if unsafe { libc::renameat(from_dir, from.as_ptr(), to_dir, to.as_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn rename_exclusive_at(
    from_dir: libc::c_int,
    from: &CString,
    to_dir: libc::c_int,
    to: &CString,
) -> io::Result<()> {
    #[cfg(target_os = "macos")]
    let result = unsafe {
        libc::renameatx_np(
            from_dir,
            from.as_ptr(),
            to_dir,
            to.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    #[cfg(target_os = "linux")]
    let result = unsafe {
        // Raw renameat2 syscall rather than the glibc wrapper. The wrapper
        // is a versioned symbol that only exists from glibc 2.28, so linking
        // it raises the whole binary's glibc floor to 2.28 and makes it
        // refuse to load on older hosts (RHEL/CentOS 7 ships glibc 2.17).
        // The syscall (Linux 3.15+) is identical, so no-replace atomicity is
        // unchanged wherever the kernel provides it; on an older kernel it
        // returns ENOSYS, which propagates as an ordinary error below rather
        // than aborting the process.
        libc::syscall(
            libc::SYS_renameat2,
            from_dir,
            from.as_ptr(),
            to_dir,
            to.as_ptr(),
            libc::RENAME_NOREPLACE,
        ) as libc::c_int
    };
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    compile_error!("atomic no-replace rename is required for apply");
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn is_exists_error(error: &io::Error) -> bool {
    error.raw_os_error() == Some(libc::EEXIST) || error.raw_os_error() == Some(libc::ENOTEMPTY)
}

fn unlink_at(parent: libc::c_int, name: &CString, directory: bool) -> io::Result<()> {
    if unsafe {
        libc::unlinkat(
            parent,
            name.as_ptr(),
            if directory { libc::AT_REMOVEDIR } else { 0 },
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn sync_entry(parent: libc::c_int, name: &CString) -> Result<(), PathSandboxError> {
    let stat = stat_at(parent, name)?;
    if stat.st_mode & libc::S_IFMT == libc::S_IFLNK {
        return Ok(());
    }
    let flags = libc::O_RDONLY
        | libc::O_NOFOLLOW
        | libc::O_CLOEXEC
        | if stat.st_mode & libc::S_IFMT == libc::S_IFDIR {
            libc::O_DIRECTORY
        } else {
            0
        };
    let fd = unsafe { libc::openat(parent, name.as_ptr(), flags) };
    if fd < 0 {
        return Err(PathSandboxError::Io(io::Error::last_os_error()));
    }
    let file = unsafe { File::from_raw_fd(fd) };
    file.sync_all()?;
    Ok(())
}

fn read_link_at(parent: libc::c_int, name: &CString) -> Result<String, PathSandboxError> {
    let mut buffer = vec![0_u8; 4097];
    let length =
        unsafe { libc::readlinkat(parent, name.as_ptr(), buffer.as_mut_ptr().cast(), 4096) };
    if length < 0 {
        return Err(PathSandboxError::Io(io::Error::last_os_error()));
    }
    if length == 4096 {
        return Err(PathSandboxError::InvalidPath);
    }
    buffer.truncate(length as usize);
    String::from_utf8(buffer).map_err(|_| PathSandboxError::InvalidPath)
}

fn entry_names(directory: &File) -> Result<Vec<String>, PathSandboxError> {
    let fd = unsafe { libc::fcntl(directory.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
    if fd < 0 {
        return Err(PathSandboxError::Io(io::Error::last_os_error()));
    }
    let stream = unsafe { libc::fdopendir(fd) };
    if stream.is_null() {
        unsafe { libc::close(fd) };
        return Err(PathSandboxError::Io(io::Error::last_os_error()));
    }
    let mut names = Vec::new();
    loop {
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            break;
        }
        let bytes = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if bytes == b"." || bytes == b".." {
            continue;
        }
        names.push(
            std::str::from_utf8(bytes)
                .map_err(|_| PathSandboxError::InvalidPath)?
                .to_owned(),
        );
    }
    unsafe { libc::closedir(stream) };
    Ok(names)
}

fn validate_existing_tree(directory: &File) -> Result<(), PathSandboxError> {
    let names = entry_names(directory)?;
    check_name_collisions(&names)?;
    for name in names {
        let name = c_name(&name)?;
        let stat = stat_at(directory.as_raw_fd(), &name)?;
        if stat.st_mode & libc::S_IFMT == libc::S_IFDIR {
            let child = open_directory_at(directory.as_raw_fd(), &name)?;
            validate_existing_tree(&child)?;
        } else if !matches!(stat.st_mode & libc::S_IFMT, libc::S_IFREG | libc::S_IFLNK) {
            return Err(PathSandboxError::UnsupportedType);
        }
    }
    Ok(())
}

fn remove_tree_at(parent: libc::c_int, name: &CString) -> Result<(), PathSandboxError> {
    let directory = open_directory_at(parent, name)?;
    for child_name in entry_names(&directory)? {
        let child_name = c_name(&child_name)?;
        let stat = stat_at(directory.as_raw_fd(), &child_name)?;
        if stat.st_mode & libc::S_IFMT == libc::S_IFDIR {
            remove_tree_at(directory.as_raw_fd(), &child_name)?;
        } else {
            unlink_at(directory.as_raw_fd(), &child_name, false)?;
        }
        directory.sync_all()?;
    }
    unlink_at(parent, name, true)?;
    Ok(())
}
