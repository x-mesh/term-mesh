use super::ProjectId;
use std::ffi::CString;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;

const PROJECT_LOCK_DIR: &str = ".term-mesh-project-locks";

pub(crate) struct ProjectLease {
    _file: File,
}

#[derive(Debug)]
pub(crate) enum ProjectLockError {
    Io(io::Error),
    Invalid,
    Busy,
}

impl From<io::Error> for ProjectLockError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

pub(crate) fn acquire_project_file_lease(
    state_path: &Path,
    project: ProjectId,
) -> Result<ProjectLease, ProjectLockError> {
    let parent_path = state_path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let parent_name =
        CString::new(parent_path.as_os_str().as_bytes()).map_err(|_| ProjectLockError::Invalid)?;
    let parent_fd = unsafe {
        libc::open(
            parent_name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if parent_fd < 0 {
        return Err(ProjectLockError::Io(io::Error::last_os_error()));
    }
    let parent = unsafe { File::from_raw_fd(parent_fd) };
    acquire_project_file_lease_at(&parent, project)
}

pub(crate) fn acquire_project_file_lease_at(
    parent: &File,
    project: ProjectId,
) -> Result<ProjectLease, ProjectLockError> {
    let parent_fd = parent.as_raw_fd();
    let lock_dir_name = CString::new(PROJECT_LOCK_DIR).map_err(|_| ProjectLockError::Invalid)?;
    let created_dir = unsafe { libc::mkdirat(parent_fd, lock_dir_name.as_ptr(), 0o700) } == 0;
    if !created_dir {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EEXIST) {
            return Err(ProjectLockError::Io(error));
        }
    } else {
        parent.sync_all()?;
    }
    let lock_dir = open_directory_at(parent_fd, &lock_dir_name)?;
    let metadata = lock_dir.metadata()?;
    if !metadata.file_type().is_dir()
        || metadata.permissions().mode() & 0o777 != 0o700
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() < 2
    {
        return Err(ProjectLockError::Invalid);
    }
    let lock_name =
        CString::new(format!("{project}.lock")).map_err(|_| ProjectLockError::Invalid)?;
    let mut fd = unsafe {
        libc::openat(
            lock_dir.as_raw_fd(),
            lock_name.as_ptr(),
            libc::O_CREAT | libc::O_EXCL | libc::O_RDWR | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    let created_file = fd >= 0;
    if fd < 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EEXIST) {
            return Err(ProjectLockError::Io(error));
        }
        fd = unsafe {
            libc::openat(
                lock_dir.as_raw_fd(),
                lock_name.as_ptr(),
                libc::O_RDWR | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(ProjectLockError::Io(io::Error::last_os_error()));
        }
    }
    let file = unsafe { File::from_raw_fd(fd) };
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file()
        || metadata.permissions().mode() & 0o777 != 0o600
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() != 1
    {
        return Err(ProjectLockError::Invalid);
    }
    if created_file {
        file.sync_all()?;
        lock_dir.sync_all()?;
    }
    if unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        let error = io::Error::last_os_error();
        return Err(
            if error.raw_os_error() == Some(libc::EWOULDBLOCK)
                || error.raw_os_error() == Some(libc::EAGAIN)
            {
                ProjectLockError::Busy
            } else {
                ProjectLockError::Io(error)
            },
        );
    }
    Ok(ProjectLease { _file: file })
}

fn open_directory_at(parent_fd: libc::c_int, name: &CString) -> Result<File, ProjectLockError> {
    let fd = unsafe {
        libc::openat(
            parent_fd,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(ProjectLockError::Io(io::Error::last_os_error()));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}
