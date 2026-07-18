use std::fmt;
use std::fs::File;
use std::os::fd::FromRawFd;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, OptionalExtension};

use super::schema;
use super::secure_sqlite::{SecureSqlite, SecureSqliteError};

pub const PROJECT_ID_BYTES: usize = 32;
pub const MANIFEST_ID_BYTES: usize = 32;

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct ProjectId([u8; PROJECT_ID_BYTES]);

impl ProjectId {
    pub fn from_bytes(bytes: [u8; PROJECT_ID_BYTES]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; PROJECT_ID_BYTES] {
        &self.0
    }
}

impl fmt::Debug for ProjectId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "ProjectId({self})")
    }
}

impl fmt::Display for ProjectId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        for byte in self.0 {
            write!(formatter, "{byte:02x}")?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectRecord {
    pub project_id: ProjectId,
    pub root_path: PathBuf,
    pub active_manifest: Option<[u8; MANIFEST_ID_BYTES]>,
    pub roster_epoch: u64,
}

#[derive(Debug, Clone)]
pub struct HeldProjectRoot {
    project_id: ProjectId,
    canonical_path: PathBuf,
    descriptor: Arc<File>,
    device: u64,
    inode: u64,
}

impl HeldProjectRoot {
    pub fn project_id(&self) -> ProjectId {
        self.project_id
    }

    pub fn canonical_path(&self) -> &Path {
        &self.canonical_path
    }

    pub fn descriptor(&self) -> &File {
        &self.descriptor
    }

    pub fn revalidate(&self) -> Result<(), RegistryError> {
        use std::os::unix::fs::MetadataExt;
        let metadata = std::fs::symlink_metadata(&self.canonical_path)?;
        if metadata.file_type().is_symlink()
            || !metadata.is_dir()
            || metadata.dev() != self.device
            || metadata.ino() != self.inode
        {
            return Err(RegistryError::RootIdentityChanged(
                self.canonical_path.clone(),
            ));
        }
        let held = self.descriptor.metadata()?;
        if held.dev() != self.device || held.ino() != self.inode {
            return Err(RegistryError::RootIdentityChanged(
                self.canonical_path.clone(),
            ));
        }
        Ok(())
    }
}

pub struct ProjectRegistry {
    path: PathBuf,
    connection: Mutex<SecureSqlite>,
}

impl ProjectRegistry {
    pub fn open(path: impl Into<PathBuf>) -> Result<Self, RegistryError> {
        let path = path.into();
        let existed = path.exists();
        let connection = SecureSqlite::open(&path).map_err(|error| match error {
            SecureSqliteError::Sql(error) if existed => RegistryError::Quarantined {
                path: path.clone(),
                reason: error.to_string(),
            },
            other => map_secure_error(other),
        })?;
        if existed {
            schema::configure(&connection).map_err(|error| RegistryError::Quarantined {
                path: path.clone(),
                reason: error.to_string(),
            })?;
            schema::validate(&connection).map_err(|reason| RegistryError::Quarantined {
                path: path.clone(),
                reason,
            })?;
        } else {
            schema::initialize(&connection)?;
            schema::validate(&connection).map_err(|reason| RegistryError::Quarantined {
                path: path.clone(),
                reason,
            })?;
        }
        connection.validate_files().map_err(map_secure_error)?;
        Ok(Self {
            path,
            connection: Mutex::new(connection),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn add(&self, root: &Path) -> Result<ProjectRecord, RegistryError> {
        self.add_with_id(root, random_project_id()?)
    }

    /// Register `root` under an explicit `project_id`. Cross-machine sync needs
    /// both daemons to hold the SAME project id (the trust store, DEK, and
    /// `SyncHello` are all keyed by it), so the responder registers its tree under
    /// the id the initiator assigned. [`add`](Self::add) picks a random id; this
    /// pins a chosen one.
    pub fn add_with_id(
        &self,
        root: &Path,
        project_id: ProjectId,
    ) -> Result<ProjectRecord, RegistryError> {
        let root = canonical_root(root)?;
        let root_text = path_text(&root)?;
        let created_at_ms = now_ms()?;
        self.connection()?.execute(
            "INSERT INTO sync_projects
             (project_id, root_path, active_manifest, roster_epoch, created_at_ms)
             VALUES (?1, ?2, NULL, 0, ?3)",
            params![project_id.as_bytes().as_slice(), root_text, created_at_ms],
        )?;
        Ok(ProjectRecord {
            project_id,
            root_path: root,
            active_manifest: None,
            roster_epoch: 0,
        })
    }

    pub fn get(&self, project_id: ProjectId) -> Result<Option<ProjectRecord>, RegistryError> {
        self.connection()?
            .query_row(
                "SELECT project_id, root_path, active_manifest, roster_epoch
                 FROM sync_projects WHERE project_id = ?1",
                params![project_id.as_bytes().as_slice()],
                decode_record,
            )
            .optional()
            .map_err(RegistryError::from)
    }

    pub fn list(&self) -> Result<Vec<ProjectRecord>, RegistryError> {
        let connection = self.connection()?;
        let mut statement = connection.prepare(
            "SELECT project_id, root_path, active_manifest, roster_epoch
             FROM sync_projects ORDER BY root_path, project_id",
        )?;
        let records = statement
            .query_map([], decode_record)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(RegistryError::from)?;
        Ok(records)
    }

    pub fn resolve_root(&self, project_id: ProjectId) -> Result<HeldProjectRoot, RegistryError> {
        let record = self
            .get(project_id)?
            .ok_or(RegistryError::ProjectNotFound(project_id))?;
        let path = record.root_path.clone();
        let path_bytes = std::os::unix::ffi::OsStrExt::as_bytes(path.as_os_str());
        let path = std::ffi::CString::new(path_bytes).map_err(|_| RegistryError::InvalidRoot)?;
        let fd = unsafe {
            libc::open(
                path.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            )
        };
        if fd < 0 {
            return Err(RegistryError::Io(std::io::Error::last_os_error()));
        }
        let descriptor = unsafe { File::from_raw_fd(fd) };
        use std::os::unix::fs::MetadataExt;
        let metadata = descriptor.metadata()?;
        if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } {
            return Err(RegistryError::InvalidRoot);
        }
        let held = HeldProjectRoot {
            project_id,
            canonical_path: record.root_path,
            descriptor: Arc::new(descriptor),
            device: metadata.dev(),
            inode: metadata.ino(),
        };
        held.revalidate()?;
        Ok(held)
    }

    pub fn relocate(&self, project_id: ProjectId, new_root: &Path) -> Result<(), RegistryError> {
        let root = canonical_root(new_root)?;
        let changed = self.connection()?.execute(
            "UPDATE sync_projects SET root_path = ?1 WHERE project_id = ?2",
            params![path_text(&root)?, project_id.as_bytes().as_slice()],
        )?;
        if changed == 0 {
            return Err(RegistryError::ProjectNotFound(project_id));
        }
        Ok(())
    }

    pub fn update_sync_state(
        &self,
        project_id: ProjectId,
        active_manifest: [u8; MANIFEST_ID_BYTES],
        roster_epoch: u64,
    ) -> Result<(), RegistryError> {
        let roster_epoch =
            i64::try_from(roster_epoch).map_err(|_| RegistryError::EpochOutOfRange)?;
        let mut connection = self.connection()?;
        let transaction = connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE sync_projects SET active_manifest = ?1 WHERE project_id = ?2",
            params![active_manifest.as_slice(), project_id.as_bytes().as_slice()],
        )?;
        if changed == 0 {
            return Err(RegistryError::ProjectNotFound(project_id));
        }

        let committed_epoch: i64 = transaction.query_row(
            "SELECT roster_epoch FROM sync_projects WHERE project_id = ?1",
            params![project_id.as_bytes().as_slice()],
            |row| row.get(0),
        )?;
        if roster_epoch < committed_epoch {
            return Err(RegistryError::EpochRegression {
                committed: committed_epoch as u64,
                proposed: roster_epoch as u64,
            });
        }
        transaction.execute(
            "UPDATE sync_projects SET roster_epoch = ?1 WHERE project_id = ?2",
            params![roster_epoch, project_id.as_bytes().as_slice()],
        )?;
        transaction.commit()?;
        Ok(())
    }

    fn connection(&self) -> Result<MutexGuard<'_, SecureSqlite>, RegistryError> {
        self.connection.lock().map_err(|_| RegistryError::Poisoned)
    }
}

fn decode_record(row: &rusqlite::Row<'_>) -> rusqlite::Result<ProjectRecord> {
    let project_id: Vec<u8> = row.get(0)?;
    let root_path: String = row.get(1)?;
    let active_manifest: Option<Vec<u8>> = row.get(2)?;
    let roster_epoch: i64 = row.get(3)?;
    Ok(ProjectRecord {
        project_id: ProjectId(project_id.try_into().map_err(|value: Vec<u8>| {
            rusqlite::Error::FromSqlConversionFailure(
                value.len(),
                rusqlite::types::Type::Blob,
                "project_id must be 32 bytes".into(),
            )
        })?),
        root_path: PathBuf::from(root_path),
        active_manifest: active_manifest
            .map(|value| {
                value.try_into().map_err(|value: Vec<u8>| {
                    rusqlite::Error::FromSqlConversionFailure(
                        value.len(),
                        rusqlite::types::Type::Blob,
                        "active_manifest must be 32 bytes".into(),
                    )
                })
            })
            .transpose()?,
        roster_epoch: u64::try_from(roster_epoch).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                0,
                rusqlite::types::Type::Integer,
                Box::new(error),
            )
        })?,
    })
}

fn canonical_root(root: &Path) -> Result<PathBuf, RegistryError> {
    let canonical = std::fs::canonicalize(root)?;
    if !canonical.is_dir() {
        return Err(RegistryError::RootNotDirectory(canonical));
    }
    Ok(canonical)
}

fn path_text(path: &Path) -> Result<&str, RegistryError> {
    path.to_str()
        .ok_or_else(|| RegistryError::NonUtf8Path(path.to_path_buf()))
}

fn random_project_id() -> Result<ProjectId, RegistryError> {
    let mut bytes = [0; PROJECT_ID_BYTES];
    getrandom::getrandom(&mut bytes).map_err(RegistryError::Random)?;
    Ok(ProjectId(bytes))
}

fn now_ms() -> Result<i64, RegistryError> {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(RegistryError::Clock)?
        .as_millis();
    i64::try_from(millis).map_err(|_| RegistryError::ClockOutOfRange)
}

fn map_secure_error(error: SecureSqliteError) -> RegistryError {
    match error {
        SecureSqliteError::Security => RegistryError::Security,
        SecureSqliteError::Io(error) => RegistryError::Io(error),
        SecureSqliteError::Sql(error) => RegistryError::Database(error),
    }
}

#[derive(Debug)]
pub enum RegistryError {
    Quarantined { path: PathBuf, reason: String },
    ProjectNotFound(ProjectId),
    EpochRegression { committed: u64, proposed: u64 },
    EpochOutOfRange,
    RootNotDirectory(PathBuf),
    NonUtf8Path(PathBuf),
    Database(rusqlite::Error),
    Io(std::io::Error),
    Random(getrandom::Error),
    Clock(std::time::SystemTimeError),
    ClockOutOfRange,
    Poisoned,
    InvalidRoot,
    RootIdentityChanged(PathBuf),
    Security,
}

impl fmt::Display for RegistryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Quarantined { path, reason } => {
                write!(
                    formatter,
                    "registry {} is quarantined: {reason}",
                    path.display()
                )
            }
            Self::ProjectNotFound(id) => write!(formatter, "project {id} was not found"),
            Self::EpochRegression {
                committed,
                proposed,
            } => write!(
                formatter,
                "roster epoch regression: committed {committed}, proposed {proposed}"
            ),
            Self::EpochOutOfRange => write!(formatter, "roster epoch exceeds SQLite integer range"),
            Self::RootNotDirectory(path) => {
                write!(
                    formatter,
                    "project root is not a directory: {}",
                    path.display()
                )
            }
            Self::NonUtf8Path(path) => {
                write!(formatter, "project root is not UTF-8: {}", path.display())
            }
            Self::Database(error) => write!(formatter, "registry database error: {error}"),
            Self::Io(error) => write!(formatter, "registry I/O error: {error}"),
            Self::Random(error) => write!(formatter, "project id random source failed: {error}"),
            Self::Clock(error) => write!(formatter, "system clock error: {error}"),
            Self::ClockOutOfRange => write!(formatter, "system clock is outside SQLite range"),
            Self::Poisoned => write!(formatter, "registry connection lock is poisoned"),
            Self::InvalidRoot => write!(formatter, "registered project root is invalid"),
            Self::RootIdentityChanged(_) => write!(formatter, "registered project root changed"),
            Self::Security => write!(formatter, "registry database security validation failed"),
        }
    }
}

impl std::error::Error for RegistryError {}

pub fn default_registry_db_path() -> PathBuf {
    if let Some(path) = std::env::var_os("TERMMESH_SYNC_REGISTRY_DB") {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("term-mesh")
        .join("sync")
        .join("sync_projects.db")
}

impl From<rusqlite::Error> for RegistryError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Database(error)
    }
}

impl From<std::io::Error> for RegistryError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}
