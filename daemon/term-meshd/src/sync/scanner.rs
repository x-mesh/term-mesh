use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::fs::File;
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use unicode_casefold::UnicodeCaseFold;
use unicode_normalization::UnicodeNormalization;

use super::manifest::{EntryKind, Manifest, ManifestBuilder, ManifestEntry, ManifestError};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanReason {
    Initial,
    Restart,
    WatcherOverflow,
}

#[derive(Debug, Clone, Copy)]
pub struct ScanLimits {
    pub max_entries: u64,
    pub max_depth: usize,
    pub max_children_per_directory: usize,
    pub max_buffered_paths: usize,
    pub max_open_files: usize,
    pub max_symlink_bytes: usize,
    pub hash_buffer_bytes: usize,
}

impl Default for ScanLimits {
    fn default() -> Self {
        Self {
            max_entries: 1_000_000,
            max_depth: 128,
            max_children_per_directory: 100_000,
            max_buffered_paths: 200_000,
            max_open_files: 256,
            max_symlink_bytes: 64 * 1024,
            hash_buffer_bytes: 64 * 1024,
        }
    }
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ScanMetrics {
    pub entries: u64,
    pub peak_buffered_children: usize,
    pub peak_open_files: usize,
}

pub struct ManifestScanner {
    limits: ScanLimits,
    observer: Option<Box<dyn ScanObserver>>,
    cancellation: Option<Arc<AtomicBool>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanCheckpoint {
    DirectoryEnumerated,
    DirectoryCompleted,
    FileHashed,
}

pub trait ScanObserver {
    fn checkpoint(&self, checkpoint: ScanCheckpoint, relative_path: &str);
    fn entry(&self, _entry: &ManifestEntry) -> Result<(), ScanError> {
        Ok(())
    }
}

impl ManifestScanner {
    pub fn new(limits: ScanLimits) -> Result<Self, ScanError> {
        if limits.hash_buffer_bytes == 0
            || limits.max_open_files == 0
            || limits.max_symlink_bytes == 0
        {
            return Err(ScanError::InvalidLimits);
        }
        Ok(Self {
            limits,
            observer: None,
            cancellation: None,
        })
    }

    pub fn with_observer(
        limits: ScanLimits,
        observer: Box<dyn ScanObserver>,
    ) -> Result<Self, ScanError> {
        let mut scanner = Self::new(limits)?;
        scanner.observer = Some(observer);
        Ok(scanner)
    }

    /// Both an entry observer and a cancellation flag: the scan streams every
    /// entry to `observer` while polling `cancellation` so a long walk can be
    /// interrupted (e.g. a cancelled sync operation).
    pub fn with_observer_and_cancellation(
        limits: ScanLimits,
        observer: Box<dyn ScanObserver>,
        cancellation: Arc<AtomicBool>,
    ) -> Result<Self, ScanError> {
        let mut scanner = Self::new(limits)?;
        scanner.observer = Some(observer);
        scanner.cancellation = Some(cancellation);
        Ok(scanner)
    }

    pub fn with_cancellation(
        limits: ScanLimits,
        cancellation: Arc<AtomicBool>,
    ) -> Result<Self, ScanError> {
        let mut scanner = Self::new(limits)?;
        scanner.cancellation = Some(cancellation);
        Ok(scanner)
    }

    pub fn scan(
        &self,
        root: &Path,
        _reason: ScanReason,
    ) -> Result<(Manifest, ScanMetrics), ScanError> {
        self.check_cancelled()?;
        let root_fd = open_root(root)?;
        self.scan_owned_descriptor(root_fd)
    }

    pub fn scan_descriptor(
        &self,
        root: &File,
        _reason: ScanReason,
    ) -> Result<(Manifest, ScanMetrics), ScanError> {
        self.check_cancelled()?;
        let raw = unsafe { libc::fcntl(root.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        let root_fd = owned_fd(raw)?;
        self.scan_owned_descriptor(root_fd)
    }

    fn scan_owned_descriptor(
        &self,
        root_fd: OwnedFd,
    ) -> Result<(Manifest, ScanMetrics), ScanError> {
        let mut pipeline = ManifestPipeline::new(&self.limits, self.observer.as_deref());
        pipeline.observe_resources(0, 1)?;
        self.scan_directory(&root_fd, "", 0, 1, 0, &mut pipeline)?;
        Ok(pipeline.finish())
    }

    pub fn scan_synthetic(&self, count: u64) -> Result<(Manifest, ScanMetrics), ScanError> {
        let mut pipeline = ManifestPipeline::new(&self.limits, self.observer.as_deref());
        for index in 0..count {
            pipeline.push(ManifestEntry {
                relative_path: format!("synthetic/{index:016x}"),
                kind: EntryKind::File,
                executable: false,
                length: index,
                content_hash: *blake3::hash(&index.to_be_bytes()).as_bytes(),
                symlink_target: None,
            })?;
        }
        Ok(pipeline.finish())
    }

    fn scan_directory(
        &self,
        directory_fd: &OwnedFd,
        relative_parent: &str,
        depth: usize,
        open_files: usize,
        buffered_ancestors: usize,
        pipeline: &mut ManifestPipeline<'_>,
    ) -> Result<(), ScanError> {
        self.check_cancelled()?;
        if depth > self.limits.max_depth {
            return Err(ScanError::DepthLimit);
        }

        let directory_before = ensure_kind(directory_fd, libc::S_IFDIR)?;
        pipeline.observe_resources(buffered_ancestors, open_files + 1)?;
        // `openat(fd, ".")` rather than `dup(fd)`: a dup SHARES the original's
        // file offset, so `readdir` walking the stream to EOF leaves the caller's
        // descriptor at EOF too — and the next scan of that same descriptor
        // returns NOTHING. (A responder re-scanning its held project root per
        // connection would answer the second peer with an empty manifest, which
        // reads as "the peer deleted everything".) `openat` gives the stream its
        // own open file description starting at offset 0, and resolving "."
        // against an already-open directory fd keeps the traversal anchored to
        // this inode — no path is re-resolved, so the swap hardening still holds.
        let dot = c"."; // relative to `directory_fd`, never the process cwd
        let stream_fd = unsafe {
            libc::openat(
                directory_fd.as_raw_fd(),
                dot.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        };
        if stream_fd < 0 {
            return Err(ScanError::Io(std::io::Error::last_os_error()));
        }
        let stream = unsafe { libc::fdopendir(stream_fd) };
        if stream.is_null() {
            unsafe { libc::close(stream_fd) };
            return Err(ScanError::Io(std::io::Error::last_os_error()));
        }
        let stream = DirectoryStream(stream);
        let mut children = Vec::new();
        loop {
            self.check_cancelled()?;
            clear_errno();
            let entry = unsafe { libc::readdir(stream.0) };
            if entry.is_null() {
                if let Some(error) = current_errno() {
                    return Err(ScanError::Io(error));
                }
                break;
            }
            let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }
                .to_str()
                .map_err(|_| ScanError::NonUtf8Path)?
                .to_string();
            if name == "." || name == ".." || name == ".git" {
                continue;
            }
            if children.len() == self.limits.max_children_per_directory {
                return Err(ScanError::ChildrenLimit);
            }
            if pipeline.metrics.entries + children.len() as u64 == self.limits.max_entries {
                return Err(ScanError::EntryLimit);
            }
            children.push(name);
            pipeline.observe_resources(buffered_ancestors + children.len(), open_files + 1)?;
        }
        drop(stream);
        self.checkpoint(ScanCheckpoint::DirectoryEnumerated, relative_parent);
        let directory_after = ensure_kind(directory_fd, libc::S_IFDIR)?;
        if metadata_identity(&directory_before) != metadata_identity(&directory_after) {
            return Err(ScanError::RetryableDirectoryChanged(display_relative(
                relative_parent,
            )));
        }
        let buffered_here = buffered_ancestors + children.len();
        children.sort();
        validate_path_names(children.iter().map(String::as_str))?;

        for name in children {
            self.check_cancelled()?;
            let relative = if relative_parent.is_empty() {
                name.clone()
            } else {
                format!("{relative_parent}/{name}")
            };
            let metadata = stat_at(directory_fd, &name)?;
            let kind = metadata.st_mode & libc::S_IFMT;
            if kind == libc::S_IFLNK {
                let target = read_link_at(directory_fd, &name, self.limits.max_symlink_bytes)?;
                pipeline.push(ManifestEntry {
                    relative_path: relative,
                    kind: EntryKind::Symlink,
                    executable: false,
                    length: 0,
                    content_hash: [0; 32],
                    symlink_target: Some(target),
                })?;
            } else if kind == libc::S_IFDIR {
                pipeline.observe_resources(buffered_here, open_files + 1)?;
                let child_fd = open_at(
                    directory_fd,
                    &name,
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                )?;
                ensure_kind(&child_fd, libc::S_IFDIR)?;
                pipeline.push(ManifestEntry {
                    relative_path: relative.clone(),
                    kind: EntryKind::Directory,
                    executable: false,
                    length: 0,
                    content_hash: [0; 32],
                    symlink_target: None,
                })?;
                self.scan_directory(
                    &child_fd,
                    &relative,
                    depth + 1,
                    open_files + 1,
                    buffered_here,
                    pipeline,
                )?;
            } else if kind == libc::S_IFREG {
                pipeline.observe_resources(buffered_here, open_files + 1)?;
                let file_fd = open_at(
                    directory_fd,
                    &name,
                    libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                )?;
                let opened = ensure_kind(&file_fd, libc::S_IFREG)?;
                let executable = opened.st_mode & 0o111 != 0;
                let length = u64::try_from(opened.st_size).map_err(|_| ScanError::InvalidSize)?;
                let content_hash = hash_file(
                    file_fd,
                    self.limits.hash_buffer_bytes,
                    &opened,
                    &relative,
                    self.observer.as_deref(),
                    self.cancellation.as_deref(),
                )?;
                pipeline.push(ManifestEntry {
                    relative_path: relative,
                    kind: EntryKind::File,
                    executable,
                    length,
                    content_hash,
                    symlink_target: None,
                })?;
            }
        }
        self.checkpoint(ScanCheckpoint::DirectoryCompleted, relative_parent);
        let directory_final = ensure_kind(directory_fd, libc::S_IFDIR)?;
        if metadata_identity(&directory_before) != metadata_identity(&directory_final) {
            return Err(ScanError::RetryableDirectoryChanged(display_relative(
                relative_parent,
            )));
        }
        Ok(())
    }

    fn checkpoint(&self, checkpoint: ScanCheckpoint, relative_path: &str) {
        if let Some(observer) = self.observer.as_deref() {
            observer.checkpoint(checkpoint, relative_path);
        }
    }

    fn check_cancelled(&self) -> Result<(), ScanError> {
        if self
            .cancellation
            .as_deref()
            .is_some_and(|cancelled| cancelled.load(Ordering::Acquire))
        {
            return Err(ScanError::Cancelled);
        }
        Ok(())
    }
}

struct DirectoryStream(*mut libc::DIR);

impl Drop for DirectoryStream {
    fn drop(&mut self) {
        unsafe { libc::closedir(self.0) };
    }
}

#[cfg(target_os = "macos")]
fn clear_errno() {
    unsafe { *libc::__error() = 0 };
}

#[cfg(target_os = "macos")]
fn current_errno() -> Option<std::io::Error> {
    let errno = unsafe { *libc::__error() };
    (errno != 0).then(|| std::io::Error::from_raw_os_error(errno))
}

#[cfg(not(target_os = "macos"))]
fn clear_errno() {
    unsafe { *libc::__errno_location() = 0 };
}

#[cfg(not(target_os = "macos"))]
fn current_errno() -> Option<std::io::Error> {
    let errno = unsafe { *libc::__errno_location() };
    (errno != 0).then(|| std::io::Error::from_raw_os_error(errno))
}

struct ManifestPipeline<'a> {
    limits: &'a ScanLimits,
    builder: ManifestBuilder,
    metrics: ScanMetrics,
    observer: Option<&'a dyn ScanObserver>,
}

impl<'a> ManifestPipeline<'a> {
    fn new(limits: &'a ScanLimits, observer: Option<&'a dyn ScanObserver>) -> Self {
        Self {
            limits,
            builder: ManifestBuilder::new(),
            metrics: ScanMetrics::default(),
            observer,
        }
    }

    fn observe_resources(
        &mut self,
        buffered_children: usize,
        open_files: usize,
    ) -> Result<(), ScanError> {
        if buffered_children > self.limits.max_buffered_paths {
            return Err(ScanError::BufferedPathLimit);
        }
        if open_files > self.limits.max_open_files {
            return Err(ScanError::OpenFileLimit);
        }
        self.metrics.peak_buffered_children =
            self.metrics.peak_buffered_children.max(buffered_children);
        self.metrics.peak_open_files = self.metrics.peak_open_files.max(open_files);
        Ok(())
    }

    fn push(&mut self, entry: ManifestEntry) -> Result<(), ScanError> {
        if self.metrics.entries == self.limits.max_entries {
            return Err(ScanError::EntryLimit);
        }
        self.builder.push(&entry)?;
        if let Some(observer) = self.observer {
            observer.entry(&entry)?;
        }
        self.metrics.entries += 1;
        Ok(())
    }

    fn finish(self) -> (Manifest, ScanMetrics) {
        (self.builder.finish(), self.metrics)
    }
}

pub fn validate_path_names<'a>(names: impl IntoIterator<Item = &'a str>) -> Result<(), ScanError> {
    let mut canonical = HashMap::new();
    for original in names {
        let normalized: String = original.nfc().collect();
        let folded: String = normalized.case_fold().collect();
        let key: String = folded.nfc().collect();
        if let Some(first) = canonical.insert(key, original.to_string()) {
            return Err(ScanError::PathCollision {
                first,
                second: original.to_string(),
            });
        }
    }
    Ok(())
}

fn open_root(path: &Path) -> Result<OwnedFd, ScanError> {
    let path = CString::new(path.as_os_str().as_bytes()).map_err(|_| ScanError::InvalidPath)?;
    let raw = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    owned_fd(raw)
}

fn open_at(parent: &OwnedFd, name: &str, flags: libc::c_int) -> Result<OwnedFd, ScanError> {
    let name = CString::new(name).map_err(|_| ScanError::InvalidPath)?;
    let raw = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
    owned_fd(raw)
}

fn owned_fd(raw: libc::c_int) -> Result<OwnedFd, ScanError> {
    if raw < 0 {
        return Err(ScanError::Io(std::io::Error::last_os_error()));
    }
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

fn stat_at(parent: &OwnedFd, name: &str) -> Result<libc::stat, ScanError> {
    let name = CString::new(name).map_err(|_| ScanError::InvalidPath)?;
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    let result = unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if result != 0 {
        return Err(ScanError::Io(std::io::Error::last_os_error()));
    }
    Ok(unsafe { stat.assume_init() })
}

fn ensure_kind(fd: &OwnedFd, expected: libc::mode_t) -> Result<libc::stat, ScanError> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe { libc::fstat(fd.as_raw_fd(), stat.as_mut_ptr()) } != 0 {
        return Err(ScanError::Io(std::io::Error::last_os_error()));
    }
    let stat = unsafe { stat.assume_init() };
    if stat.st_mode & libc::S_IFMT != expected {
        return Err(ScanError::RaceDetected);
    }
    Ok(stat)
}

fn read_link_at(parent: &OwnedFd, name: &str, maximum: usize) -> Result<String, ScanError> {
    let name = CString::new(name).map_err(|_| ScanError::InvalidPath)?;
    let mut bytes = vec![0_u8; maximum];
    let read = unsafe {
        libc::readlinkat(
            parent.as_raw_fd(),
            name.as_ptr(),
            bytes.as_mut_ptr().cast(),
            bytes.len(),
        )
    };
    if read < 0 {
        return Err(ScanError::Io(std::io::Error::last_os_error()));
    }
    let read = read as usize;
    if read == maximum {
        return Err(ScanError::SymlinkTargetLimit);
    }
    bytes.truncate(read);
    String::from_utf8(bytes).map_err(|_| ScanError::NonUtf8Path)
}

fn hash_file(
    fd: OwnedFd,
    buffer_bytes: usize,
    before: &libc::stat,
    relative_path: &str,
    observer: Option<&dyn ScanObserver>,
    cancellation: Option<&AtomicBool>,
) -> Result<[u8; 32], ScanError> {
    let mut file = File::from(fd);
    let mut buffer = vec![0; buffer_bytes];
    let mut hasher = blake3::Hasher::new();
    let mut total_read = 0_u64;
    loop {
        if cancellation.is_some_and(|cancelled| cancelled.load(Ordering::Acquire)) {
            return Err(ScanError::Cancelled);
        }
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        total_read = total_read
            .checked_add(read as u64)
            .ok_or(ScanError::InvalidSize)?;
        hasher.update(&buffer[..read]);
    }
    if let Some(observer) = observer {
        observer.checkpoint(ScanCheckpoint::FileHashed, relative_path);
    }
    let after = fstat(file.as_raw_fd())?;
    let post_size = u64::try_from(after.st_size).map_err(|_| ScanError::InvalidSize)?;
    if metadata_identity(before) != metadata_identity(&after) || total_read != post_size {
        return Err(ScanError::RetryableFileChanged(relative_path.to_string()));
    }
    Ok(*hasher.finalize().as_bytes())
}

fn fstat(raw_fd: libc::c_int) -> Result<libc::stat, ScanError> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe { libc::fstat(raw_fd, stat.as_mut_ptr()) } != 0 {
        return Err(ScanError::Io(std::io::Error::last_os_error()));
    }
    Ok(unsafe { stat.assume_init() })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct MetadataIdentity {
    device: u64,
    inode: u64,
    size: i64,
    kind: libc::mode_t,
    modified_seconds: i64,
    modified_nanos: i64,
    changed_seconds: i64,
    changed_nanos: i64,
}

fn metadata_identity(stat: &libc::stat) -> MetadataIdentity {
    let (modified_seconds, modified_nanos, changed_seconds, changed_nanos) = stat_times(stat);
    MetadataIdentity {
        device: stat.st_dev as u64,
        inode: stat.st_ino as u64,
        size: stat.st_size,
        kind: stat.st_mode & libc::S_IFMT,
        modified_seconds,
        modified_nanos,
        changed_seconds,
        changed_nanos,
    }
}

fn stat_times(stat: &libc::stat) -> (i64, i64, i64, i64) {
    (
        stat.st_mtime as i64,
        stat.st_mtime_nsec as i64,
        stat.st_ctime as i64,
        stat.st_ctime_nsec as i64,
    )
}

fn display_relative(relative_path: &str) -> String {
    if relative_path.is_empty() {
        ".".to_string()
    } else {
        relative_path.to_string()
    }
}

#[derive(Debug)]
pub enum ScanError {
    Io(std::io::Error),
    Manifest(ManifestError),
    InvalidLimits,
    InvalidPath,
    NonUtf8Path,
    EntryLimit,
    DepthLimit,
    ChildrenLimit,
    BufferedPathLimit,
    OpenFileLimit,
    SymlinkTargetLimit,
    InvalidSize,
    RaceDetected,
    RetryableFileChanged(String),
    RetryableDirectoryChanged(String),
    PathCollision { first: String, second: String },
    Cancelled,
}

impl From<std::io::Error> for ScanError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<ManifestError> for ScanError {
    fn from(error: ManifestError) -> Self {
        Self::Manifest(error)
    }
}

impl std::fmt::Display for ScanError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for ScanError {}
