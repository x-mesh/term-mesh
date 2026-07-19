use std::fs::File;
use std::ops::{Deref, DerefMut};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::sync::Arc;

use rusqlite::{Connection, OpenFlags};

use super::sqlite_openat_vfs::OpenAtVfs;

pub(crate) struct SecureSqlite {
    connection: Option<Connection>,
    _vfs: Arc<OpenAtVfs>,
    directory: File,
    database_name: String,
}

impl SecureSqlite {
    pub(crate) fn open(path: &Path) -> Result<Self, SecureSqliteError> {
        let parent = path.parent().ok_or(SecureSqliteError::Security)?;
        if !parent.exists() {
            let mut builder = std::fs::DirBuilder::new();
            builder.mode(0o700).recursive(true).create(parent)?;
        }
        let directory = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(parent)
            .map_err(|_| SecureSqliteError::Security)?;
        let metadata = directory
            .metadata()
            .map_err(|_| SecureSqliteError::Security)?;
        if !metadata.is_dir()
            || metadata.mode() & 0o777 != 0o700
            || metadata.uid() != unsafe { libc::geteuid() }
        {
            return Err(SecureSqliteError::Security);
        }
        let database_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .filter(|name| !name.is_empty() && !name.contains('/'))
            .ok_or(SecureSqliteError::Security)?
            .to_owned();
        validate_files(&directory, &database_name)?;
        let vfs = OpenAtVfs::register(&directory, &database_name)
            .map_err(|_| SecureSqliteError::Security)?;
        let connection = Connection::open_with_flags_and_vfs(
            &database_name,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_NOFOLLOW
                | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
            vfs.name(),
        )?;
        let value = Self {
            connection: Some(connection),
            _vfs: vfs,
            directory,
            database_name,
        };
        value.validate_files()?;
        Ok(value)
    }

    pub(crate) fn validate_files(&self) -> Result<(), SecureSqliteError> {
        validate_files(&self.directory, &self.database_name)
    }
}

impl Deref for SecureSqlite {
    type Target = Connection;

    fn deref(&self) -> &Self::Target {
        self.connection.as_ref().expect("secure SQLite connection")
    }
}

impl DerefMut for SecureSqlite {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.connection.as_mut().expect("secure SQLite connection")
    }
}

impl Drop for SecureSqlite {
    fn drop(&mut self) {
        drop(self.connection.take());
    }
}

fn validate_files(directory: &File, database: &str) -> Result<(), SecureSqliteError> {
    let directory_device = directory
        .metadata()
        .map_err(|_| SecureSqliteError::Security)?
        .dev();
    for suffix in ["", "-wal", "-shm"] {
        let name = std::ffi::CString::new(format!("{database}{suffix}"))
            .map_err(|_| SecureSqliteError::Security)?;
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        let result = unsafe {
            libc::fstatat(
                directory.as_raw_fd(),
                name.as_ptr(),
                stat.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        };
        if result != 0 {
            if std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) {
                continue;
            }
            return Err(SecureSqliteError::Security);
        }
        let stat = unsafe { stat.assume_init() };
        if stat.st_mode & libc::S_IFMT != libc::S_IFREG
            || stat.st_mode & 0o777 != 0o600
            || stat.st_uid != unsafe { libc::geteuid() }
            || stat.st_nlink != 1
            || stat.st_dev as u64 != directory_device
        {
            return Err(SecureSqliteError::Security);
        }
    }
    Ok(())
}

#[derive(Debug)]
pub(crate) enum SecureSqliteError {
    Security,
    Io(std::io::Error),
    Sql(rusqlite::Error),
}

impl From<std::io::Error> for SecureSqliteError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<rusqlite::Error> for SecureSqliteError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sql(error)
    }
}
