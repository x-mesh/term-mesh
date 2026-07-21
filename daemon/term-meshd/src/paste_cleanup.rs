use std::fs;
use std::io;
use std::path::Path;
use std::time::{Duration, SystemTime};

pub const PASTE_DIRECTORY: &str = "/tmp/term-mesh-paste";
pub const PASTE_TTL: Duration = Duration::from_secs(24 * 60 * 60);

/// Remove expired artifacts created by `RemotePasteTransfer`.
///
/// This deliberately examines only direct entries in the dedicated directory.
/// Symlinks, directories, and files outside the managed filename shape are never
/// removed. A per-entry read failure is non-fatal so one raced or unreadable
/// entry cannot prevent later expired artifacts from being reclaimed.
pub fn sweep_paste_artifacts(directory: &Path, ttl: Duration) -> io::Result<usize> {
    sweep_paste_artifacts_at(directory, ttl, SystemTime::now())
}

fn sweep_paste_artifacts_at(directory: &Path, ttl: Duration, now: SystemTime) -> io::Result<usize> {
    match fs::symlink_metadata(directory) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "paste cleanup directory is not a directory",
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error),
    }

    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) => return Err(error),
    };

    let mut removed = 0;
    for entry in entries {
        let Ok(entry) = entry else { continue };
        let path = entry.path();
        if !is_managed_paste_artifact(&path) {
            continue;
        }

        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if !metadata.file_type().is_file() {
            continue;
        }

        let Ok(modified) = metadata.modified() else {
            continue;
        };
        let Ok(age) = now.duration_since(modified) else {
            continue;
        };
        if age < ttl {
            continue;
        }

        match fs::remove_file(&path) {
            Ok(()) => removed += 1,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                tracing::warn!(path = %path.display(), "failed to remove expired paste artifact: {error}")
            }
        }
    }
    Ok(removed)
}

fn is_managed_paste_artifact(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    let Some((timestamp, rest)) = name.split_once('-') else {
        return false;
    };
    timestamp.len() == 13 && timestamp.bytes().all(|byte| byte.is_ascii_digit()) && !rest.is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;

    fn sweep_at(directory: &Path, ttl: Duration) -> io::Result<usize> {
        sweep_paste_artifacts_at(directory, ttl, SystemTime::now())
    }

    #[test]
    fn removes_expired_managed_regular_files_only() {
        let temp = tempfile::tempdir().unwrap();
        let expired = temp.path().join("1700000000000-clipboard-image.png");
        let file_drop = temp.path().join("1700000000001-report.pdf");
        let unrelated = temp.path().join("notes.png");
        File::create(&expired).unwrap();
        File::create(&file_drop).unwrap();
        File::create(&unrelated).unwrap();
        let modified = fs::metadata(&file_drop).unwrap().modified().unwrap();

        assert_eq!(
            sweep_paste_artifacts_at(
                temp.path(),
                Duration::from_secs(60),
                modified + Duration::from_secs(60),
            )
            .unwrap(),
            2
        );
        assert!(!expired.exists());
        assert!(!file_drop.exists());
        assert!(unrelated.exists());
    }

    #[test]
    fn retains_fresh_managed_regular_files() {
        let temp = tempfile::tempdir().unwrap();
        let fresh = temp.path().join("1700000000000-clipboard-image.png");
        File::create(&fresh).unwrap();
        let modified = fs::metadata(&fresh).unwrap().modified().unwrap();

        assert_eq!(
            sweep_paste_artifacts_at(
                temp.path(),
                Duration::from_secs(60),
                modified + Duration::from_secs(1),
            )
            .unwrap(),
            0
        );
        assert!(fresh.exists());
    }

    #[test]
    fn missing_directory_is_empty() {
        let temp = tempfile::tempdir().unwrap();
        assert_eq!(
            sweep_at(&temp.path().join("missing"), Duration::ZERO).unwrap(),
            0
        );
    }

    #[cfg(unix)]
    #[test]
    fn preserves_symlinks_and_directories_with_managed_names() {
        use std::os::unix::fs::symlink;

        let temp = tempfile::tempdir().unwrap();
        let target = temp.path().join("target");
        File::create(&target).unwrap();
        let link = temp.path().join("1700000000000-clipboard-link.png");
        let directory = temp.path().join("1700000000000-clipboard-directory.png");
        symlink(&target, &link).unwrap();
        fs::create_dir(&directory).unwrap();

        assert_eq!(sweep_at(temp.path(), Duration::ZERO).unwrap(), 0);
        assert!(link.exists());
        assert!(directory.exists());
    }

    #[cfg(unix)]
    #[test]
    fn rejects_a_symlinked_cleanup_directory() {
        use std::os::unix::fs::symlink;

        let temp = tempfile::tempdir().unwrap();
        let target = temp.path().join("target");
        fs::create_dir(&target).unwrap();
        let link = temp.path().join("paste-directory-link");
        symlink(&target, &link).unwrap();

        let error = sweep_at(&link, Duration::ZERO).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }
}
