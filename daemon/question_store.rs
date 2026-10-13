use sha2::{Digest, Sha256};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

pub const RECORD_TTL: Duration = Duration::from_secs(24 * 60 * 60);
static WRITE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn private_base() -> Result<PathBuf, String> {
    #[cfg(test)]
    {
        return Ok(
            env::temp_dir().join(format!("term-mesh-question-tests-{}", unsafe {
                libc::geteuid()
            })),
        );
    }
    #[cfg(not(test))]
    {
        // Hooks and the daemon do not always inherit the same runtime environment.
        let home = env::var_os("HOME").ok_or_else(|| "HOME is not set".to_string())?;
        #[cfg(target_os = "macos")]
        return Ok(PathBuf::from(home).join("Library/Application Support/term-mesh"));
        #[cfg(not(target_os = "macos"))]
        Ok(PathBuf::from(home).join(".local/share/term-mesh"))
    }
}

pub(crate) fn root_for_socket(socket: &str) -> Result<PathBuf, String> {
    let mut hash = Sha256::new();
    hash.update(socket.as_bytes());
    Ok(private_base()?
        .join("questions-v1")
        .join(format!("{:x}", hash.finalize())))
}

pub(crate) fn verify_private_directory(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(format!(
            "question store component is not a directory: {}",
            path.display()
        ));
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        return Err(format!(
            "question store component has another owner: {}",
            path.display()
        ));
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(format!(
            "question store component is not private: {}",
            path.display()
        ));
    }
    Ok(())
}

pub fn prepare_root(root: &Path) -> Result<(), String> {
    let base = private_base()?;
    if !root.starts_with(&base) {
        return Err("question store root is outside the private base".into());
    }
    if !base.exists() {
        fs::create_dir_all(&base).map_err(|error| error.to_string())?;
    }
    fs::set_permissions(&base, fs::Permissions::from_mode(0o700))
        .map_err(|error| error.to_string())?;
    verify_private_directory(&base)?;
    let mut current = base;
    let components: Vec<_> = root
        .strip_prefix(&current)
        .map_err(|error| error.to_string())?
        .components()
        .map(|component| component.as_os_str().to_os_string())
        .collect();
    for component in components {
        current.push(component);
        if !current.exists() {
            if let Err(error) = fs::create_dir(&current) {
                if error.kind() != std::io::ErrorKind::AlreadyExists {
                    return Err(error.to_string());
                }
            }
        }
        fs::set_permissions(&current, fs::Permissions::from_mode(0o700))
            .map_err(|error| error.to_string())?;
        verify_private_directory(&current)?;
    }
    Ok(())
}

#[cfg(test)]
pub fn prepare_test_root(root: &Path) -> Result<(), String> {
    fs::create_dir_all(root).map_err(|error| error.to_string())?;
    fs::set_permissions(root, fs::Permissions::from_mode(0o700))
        .map_err(|error| error.to_string())?;
    verify_private_directory(root)
}

pub fn prepare_surface(root: &Path, surface: &str, session: &str) -> Result<PathBuf, String> {
    prepare_root(root)?;
    let surface_dir = root.join(surface);
    let session_dir = surface_dir.join(session);
    for path in [&surface_dir, &session_dir] {
        if !path.exists() {
            if let Err(error) = fs::create_dir(path) {
                if error.kind() != std::io::ErrorKind::AlreadyExists {
                    return Err(error.to_string());
                }
            }
        }
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .map_err(|error| error.to_string())?;
        verify_private_directory(path)?;
    }
    Ok(session_dir)
}

pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "invalid question record path".to_string())?;
    verify_private_directory(parent)?;
    let sequence = WRITE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temporary = path.with_extension(format!("{}.{}.tmp", std::process::id(), sequence));
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|error| error.to_string())?;
    file.write_all(bytes).map_err(|error| error.to_string())?;
    file.sync_all().map_err(|error| error.to_string())?;
    fs::rename(&temporary, path).map_err(|error| error.to_string())?;
    File::open(parent)
        .and_then(|file| file.sync_all())
        .map_err(|error| error.to_string())
}

pub fn cleanup<F>(root: &Path, is_terminal: F) -> Result<(), String>
where
    F: Fn(&Path) -> bool,
{
    #[cfg(not(test))]
    if !root.exists() {
        return Ok(());
    }
    #[cfg(test)]
    {
        if root.starts_with(private_base()?) {
            prepare_root(root)?;
        } else {
            verify_private_directory(root)?;
        }
    }
    let now = SystemTime::now();
    for surface in fs::read_dir(root)
        .map_err(|error| error.to_string())?
        .flatten()
    {
        if verify_private_directory(&surface.path()).is_err() {
            continue;
        }
        let Ok(sessions) = fs::read_dir(surface.path()) else {
            continue;
        };
        for session in sessions.flatten() {
            if verify_private_directory(&session.path()).is_err() {
                continue;
            }
            let Ok(files) = fs::read_dir(session.path()) else {
                continue;
            };
            for file in files.flatten() {
                let path = file.path();
                let Ok(metadata) = fs::symlink_metadata(&path) else {
                    continue;
                };
                if !metadata.file_type().is_file() {
                    continue;
                }
                let old = metadata
                    .modified()
                    .ok()
                    .and_then(|time| now.duration_since(time).ok())
                    .is_some_and(|age| age > RECORD_TTL);
                let temporary = path.extension().is_some_and(|extension| extension == "tmp");
                if (temporary && old) || (!temporary && (old || is_terminal(&path))) {
                    let _ = fs::remove_file(path);
                }
            }
        }
    }
    Ok(())
}
