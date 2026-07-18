use std::cmp::Ordering;
use std::fmt;

const MANIFEST_DOMAIN: &[u8] = b"term-mesh manifest v1\0";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum EntryKind {
    File = 1,
    Directory = 2,
    Symlink = 3,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestEntry {
    pub relative_path: String,
    pub kind: EntryKind,
    pub executable: bool,
    /// POSIX permission bits (`0o777`) for a FILE; `0` for directories and
    /// symlinks, whose modes this manifest does not track.
    ///
    /// setuid/setgid/sticky are deliberately excluded — a peer must not be able
    /// to push a setuid binary onto another machine. `executable` is kept as the
    /// classification input (`merge_file` reasons about it), and is always
    /// derivable from these bits; both the scanner and the wire decoder enforce
    /// that they agree, so the two can never drift apart.
    pub mode: u16,
    pub length: u64,
    pub content_hash: [u8; 32],
    pub symlink_target: Option<String>,
}

/// Permission bits to assume when only the executable bit is known.
///
/// Deliberately private (`0o700`/`0o600`) rather than the conventional
/// `0o755`/`0o644`: guessing WIDER than the source would hand out read access
/// the original file never granted. Callers that know the real mode pass it.
pub fn assumed_file_mode(executable: bool) -> u16 {
    if executable {
        0o700
    } else {
        0o600
    }
}

/// The `mode` a non-file entry carries: none. Directory and symlink permissions
/// are not tracked (see [`ManifestEntry::mode`]).
pub const NO_MODE: u16 = 0;

/// Whether `mode` agrees with `executable`. The two are stored separately —
/// `merge_file` classifies on `executable` — so every boundary that accepts them
/// from outside checks they describe the same file.
pub fn mode_matches_executable(kind: EntryKind, mode: u16, executable: bool) -> bool {
    match kind {
        EntryKind::File => mode & 0o777 == mode && (mode & 0o111 != 0) == executable,
        // Non-files carry no mode at all. Their executable bit is not checked:
        // it means nothing here (a directory's search bit is not something this
        // manifest installs), so it is left to the scanner to report.
        _ => mode == NO_MODE,
    }
}

pub(crate) fn decode_index_entry(input: &[u8]) -> Result<ManifestEntry, ManifestError> {
    if input.len() < 50 {
        return Err(ManifestError::InvalidEntry("truncated"));
    }
    let kind = match input[0] {
        1 => EntryKind::File,
        2 => EntryKind::Directory,
        3 => EntryKind::Symlink,
        _ => return Err(ManifestError::InvalidEntry("kind")),
    };
    let executable = match input[1] {
        0 => false,
        1 => true,
        _ => return Err(ManifestError::InvalidEntry("executable")),
    };
    let length = u64::from_be_bytes(input[2..10].try_into().unwrap());
    let mut content_hash = [0; 32];
    content_hash.copy_from_slice(&input[10..42]);
    let path_len = u32::from_be_bytes(input[42..46].try_into().unwrap()) as usize;
    let path_end = 46usize
        .checked_add(path_len)
        .ok_or(ManifestError::InvalidEntry("length"))?;
    if path_end + 4 > input.len() {
        return Err(ManifestError::InvalidEntry("path"));
    }
    let relative_path = std::str::from_utf8(&input[46..path_end])
        .map_err(|_| ManifestError::InvalidEntry("utf8"))?
        .to_owned();
    let target_len = u32::from_be_bytes(input[path_end..path_end + 4].try_into().unwrap()) as usize;
    let end = path_end + 4 + target_len;
    if end != input.len() {
        return Err(ManifestError::InvalidEntry("trailing"));
    }
    let target = std::str::from_utf8(&input[path_end + 4..end])
        .map_err(|_| ManifestError::InvalidEntry("utf8"))?;
    let symlink_target = if kind == EntryKind::Symlink {
        Some(target.to_owned())
    } else if target.is_empty() {
        None
    } else {
        return Err(ManifestError::InvalidEntry("target"));
    };
    // This index format predates mode tracking and belongs to the dormant
    // reconcile engine; assume the conservative mode rather than widen.
    let mode = if kind == EntryKind::File {
        assumed_file_mode(executable)
    } else {
        NO_MODE
    };
    let entry = ManifestEntry {
        relative_path,
        kind,
        executable,
        mode,
        length,
        content_hash,
        symlink_target,
    };
    validate_relative_path(&entry.relative_path)?;
    validate_entry_shape(&entry)?;
    Ok(entry)
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct ManifestRoot(pub [u8; 32]);

impl fmt::Debug for ManifestRoot {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "ManifestRoot(")?;
        for byte in self.0 {
            write!(formatter, "{byte:02x}")?;
        }
        write!(formatter, ")")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Manifest {
    pub root: ManifestRoot,
    pub entry_count: u64,
}

pub struct ManifestBuilder {
    hasher: blake3::Hasher,
    entry_count: u64,
    previous_path: Option<String>,
}

impl ManifestBuilder {
    pub fn new() -> Self {
        let mut hasher = blake3::Hasher::new();
        hasher.update(MANIFEST_DOMAIN);
        Self {
            hasher,
            entry_count: 0,
            previous_path: None,
        }
    }

    pub fn push(&mut self, entry: &ManifestEntry) -> Result<(), ManifestError> {
        validate_relative_path(&entry.relative_path)?;
        validate_entry_shape(entry)?;
        if let Some(previous) = &self.previous_path {
            match compare_paths(previous, &entry.relative_path) {
                Ordering::Equal => {
                    return Err(ManifestError::DuplicatePath(entry.relative_path.clone()));
                }
                Ordering::Greater => {
                    return Err(ManifestError::NonCanonicalOrder {
                        previous: previous.clone(),
                        current: entry.relative_path.clone(),
                    });
                }
                Ordering::Less => {}
            }
        }

        let path = entry.relative_path.as_bytes();
        self.hasher.update(&(path.len() as u32).to_be_bytes());
        self.hasher.update(path);
        self.hasher.update(&[entry.kind as u8]);
        self.hasher.update(&[u8::from(entry.executable)]);
        self.hasher.update(&entry.length.to_be_bytes());
        self.hasher.update(&entry.content_hash);
        match &entry.symlink_target {
            Some(target) => {
                self.hasher.update(&[1]);
                self.hasher.update(&(target.len() as u32).to_be_bytes());
                self.hasher.update(target.as_bytes());
            }
            None => {
                self.hasher.update(&[0]);
            }
        };
        self.entry_count += 1;
        self.previous_path = Some(entry.relative_path.clone());
        Ok(())
    }

    pub fn finish(self) -> Manifest {
        Manifest {
            root: ManifestRoot(*self.hasher.finalize().as_bytes()),
            entry_count: self.entry_count,
        }
    }
}

impl Default for ManifestBuilder {
    fn default() -> Self {
        Self::new()
    }
}

fn compare_paths(left: &str, right: &str) -> Ordering {
    left.split('/').cmp(right.split('/'))
}

fn validate_relative_path(path: &str) -> Result<(), ManifestError> {
    if path.is_empty() || path.starts_with('/') || path.contains('\0') {
        return Err(ManifestError::InvalidPath(path.to_string()));
    }
    if path
        .split('/')
        .any(|component| component.is_empty() || component == "." || component == "..")
    {
        return Err(ManifestError::InvalidPath(path.to_string()));
    }
    Ok(())
}

fn validate_entry_shape(entry: &ManifestEntry) -> Result<(), ManifestError> {
    let zero_hash = entry.content_hash == [0; 32];
    match entry.kind {
        EntryKind::File if entry.symlink_target.is_none() => Ok(()),
        EntryKind::Directory
            if !entry.executable
                && entry.length == 0
                && zero_hash
                && entry.symlink_target.is_none() =>
        {
            Ok(())
        }
        EntryKind::Symlink
            if !entry.executable
                && entry.length == 0
                && zero_hash
                && entry.symlink_target.is_some() =>
        {
            Ok(())
        }
        EntryKind::File => Err(ManifestError::InvalidEntry(
            "file entry must not have a symlink target",
        )),
        EntryKind::Directory => Err(ManifestError::InvalidEntry(
            "directory fields must use canonical zero values",
        )),
        EntryKind::Symlink => Err(ManifestError::InvalidEntry(
            "symlink fields must use canonical zero values and a target",
        )),
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum ManifestError {
    InvalidPath(String),
    InvalidEntry(&'static str),
    DuplicatePath(String),
    NonCanonicalOrder { previous: String, current: String },
}

impl fmt::Display for ManifestError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for ManifestError {}
