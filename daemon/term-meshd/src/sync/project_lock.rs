use super::ProjectId;
use std::ffi::CString;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::time::{Duration, Instant};

const PROJECT_LOCK_DIR: &str = ".term-mesh-project-locks";
const SPAWNED_CHILD_HOLD: Duration = Duration::from_millis(100);

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
    // A child this process is spawning holds a copy of every descriptor,
    // `O_CLOEXEC` ones included, until it execs, and with it the flock of a
    // lease the parent already released. Measured on macOS: 1 in 100 to 150
    // acquisitions of a free lease failed while other threads spawned
    // processes, and every one of them succeeded within 2ms.
    let deadline = Instant::now() + SPAWNED_CHILD_HOLD;
    loop {
        if unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Ok(ProjectLease { _file: file });
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EWOULDBLOCK)
            && error.raw_os_error() != Some(libc::EAGAIN)
        {
            return Err(ProjectLockError::Io(error));
        }
        if Instant::now() >= deadline {
            return Err(ProjectLockError::Busy);
        }
        std::thread::sleep(Duration::from_millis(1));
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    #[test]
    fn a_child_being_spawned_does_not_make_a_free_lease_busy() {
        let temporary = tempfile::tempdir().unwrap();
        let parent = File::open(temporary.path()).unwrap();
        let project = ProjectId::from_bytes([7; 32]);
        let stop = Arc::new(AtomicBool::new(false));
        let spawners: Vec<_> = (0..3)
            .map(|_| {
                let stop = stop.clone();
                std::thread::spawn(move || {
                    while !stop.load(Ordering::Relaxed) {
                        let _ = std::process::Command::new("/usr/bin/true").status();
                    }
                })
            })
            .collect();

        let busy = (0..3000)
            .filter(|_| {
                matches!(
                    acquire_project_file_lease_at(&parent, project),
                    Err(ProjectLockError::Busy)
                )
            })
            .count();

        stop.store(true, Ordering::Relaxed);
        for spawner in spawners {
            spawner.join().unwrap();
        }
        assert_eq!(busy, 0);
    }

    #[test]
    fn a_held_lease_is_still_busy() {
        let temporary = tempfile::tempdir().unwrap();
        let parent = File::open(temporary.path()).unwrap();
        let project = ProjectId::from_bytes([8; 32]);
        let _held = acquire_project_file_lease_at(&parent, project).unwrap();

        assert!(matches!(
            acquire_project_file_lease_at(&parent, project),
            Err(ProjectLockError::Busy)
        ));
    }
}
