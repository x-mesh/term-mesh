#[path = "../src/sync/mod.rs"]
mod sync;

use std::fs;
use std::io::Write;
use std::os::unix::fs::symlink;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use sync::{
    EntryKind, ManifestBuilder, ManifestEntry, ManifestError, ManifestScanner, ScanCheckpoint,
    ScanError, ScanLimits, ScanObserver, ScanReason,
};

#[test]
fn initial_restart_and_overflow_scans_have_identical_roots() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("project");
    fs::create_dir_all(root.join("src")).unwrap();
    fs::write(root.join("src/main.rs"), b"fn main() {}\n").unwrap();
    fs::write(root.join("README.md"), b"mesh\n").unwrap();
    fs::create_dir(root.join(".git")).unwrap();
    fs::write(root.join(".git/config"), b"secret").unwrap();
    let outside = temp.path().join("outside");
    fs::create_dir(&outside).unwrap();
    fs::write(outside.join("secret"), b"must not be traversed").unwrap();
    symlink(&outside, root.join("outside-link")).unwrap();

    let scanner = ManifestScanner::new(ScanLimits::default()).unwrap();
    let initial = scanner.scan(&root, ScanReason::Initial).unwrap().0;
    let restart = scanner.scan(&root, ScanReason::Restart).unwrap().0;
    let overflow = scanner.scan(&root, ScanReason::WatcherOverflow).unwrap().0;
    assert_eq!(initial, restart);
    assert_eq!(restart, overflow);
    assert_eq!(initial.entry_count, 4);
}

#[test]
fn invalid_paths_are_rejected_by_canonical_manifest_builder() {
    for path in ["/absolute", "a/../b", "a\0b"] {
        let mut builder = ManifestBuilder::new();
        let error = builder
            .push(&ManifestEntry {
                relative_path: path.to_string(),
                kind: EntryKind::File,
                executable: false,
                length: 0,
                content_hash: [0; 32],
                symlink_target: None,
            })
            .unwrap_err();
        assert!(matches!(error, ManifestError::InvalidPath(_)));
    }
}

#[test]
fn case_and_unicode_normalization_collisions_are_typed_errors() {
    let case = sync::validate_path_names(["Readme", "README"]).unwrap_err();
    assert!(matches!(case, ScanError::PathCollision { .. }));

    let unicode = sync::validate_path_names(["caf\u{e9}", "cafe\u{301}"]).unwrap_err();
    assert!(matches!(unicode, ScanError::PathCollision { .. }));
}

#[test]
fn one_million_entry_stream_stays_within_configured_buffers() {
    let limits = ScanLimits {
        max_entries: 1_000_000,
        max_depth: 128,
        max_children_per_directory: 1024,
        max_buffered_paths: 1024,
        max_open_files: 32,
        max_symlink_bytes: 4096,
        hash_buffer_bytes: 64 * 1024,
    };
    let scanner = ManifestScanner::new(limits).unwrap();
    let (manifest, metrics) = scanner.scan_synthetic(1_000_000).unwrap();
    assert_eq!(manifest.entry_count, 1_000_000);
    assert_eq!(metrics.entries, 1_000_000);
    assert_eq!(metrics.peak_buffered_children, 0);
    assert_eq!(metrics.peak_open_files, 0);
}

#[test]
fn full_case_folding_detects_non_ascii_collision() {
    let error = sync::validate_path_names(["Straße", "STRASSE"]).unwrap_err();
    assert!(matches!(error, ScanError::PathCollision { .. }));
}

#[test]
fn canonical_builder_rejects_duplicate_order_and_nonzero_structural_fields() {
    let file = |path: &str| ManifestEntry {
        relative_path: path.to_string(),
        kind: EntryKind::File,
        executable: false,
        length: 0,
        content_hash: [1; 32],
        symlink_target: None,
    };
    let mut duplicate = ManifestBuilder::new();
    duplicate.push(&file("a")).unwrap();
    assert!(matches!(
        duplicate.push(&file("a")),
        Err(ManifestError::DuplicatePath(_))
    ));

    let mut order = ManifestBuilder::new();
    order.push(&file("b")).unwrap();
    assert!(matches!(
        order.push(&file("a")),
        Err(ManifestError::NonCanonicalOrder { .. })
    ));

    let mut structural = ManifestBuilder::new();
    assert!(matches!(
        structural.push(&ManifestEntry {
            relative_path: "dir".to_string(),
            kind: EntryKind::Directory,
            executable: true,
            length: 1,
            content_hash: [1; 32],
            symlink_target: None,
        }),
        Err(ManifestError::InvalidEntry(_))
    ));
}

#[test]
fn root_symlink_is_not_followed() {
    let temp = tempfile::tempdir().unwrap();
    let target = temp.path().join("target");
    let alias = temp.path().join("alias");
    fs::create_dir(&target).unwrap();
    symlink(&target, &alias).unwrap();
    let scanner = ManifestScanner::new(ScanLimits::default()).unwrap();
    assert!(scanner.scan(&alias, ScanReason::Initial).is_err());
}

#[test]
fn real_scanner_limits_are_exact_at_the_boundary() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("project");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("a"), b"a").unwrap();
    fs::write(root.join("b"), b"b").unwrap();

    let mut exact = ScanLimits::default();
    exact.max_entries = 2;
    exact.max_children_per_directory = 2;
    exact.max_buffered_paths = 2;
    exact.max_open_files = 2;
    exact.hash_buffer_bytes = 1;
    let (_, metrics) = ManifestScanner::new(exact)
        .unwrap()
        .scan(&root, ScanReason::Initial)
        .unwrap();
    assert_eq!(metrics.entries, 2);
    assert_eq!(metrics.peak_buffered_children, 2);
    assert_eq!(metrics.peak_open_files, 2);

    let mut below = exact;
    below.max_entries = 1;
    assert!(matches!(
        ManifestScanner::new(below)
            .unwrap()
            .scan(&root, ScanReason::Initial),
        Err(ScanError::EntryLimit)
    ));
    below = exact;
    below.max_children_per_directory = 1;
    assert!(matches!(
        ManifestScanner::new(below)
            .unwrap()
            .scan(&root, ScanReason::Initial),
        Err(ScanError::ChildrenLimit)
    ));
    below = exact;
    below.max_open_files = 1;
    assert!(matches!(
        ManifestScanner::new(below)
            .unwrap()
            .scan(&root, ScanReason::Initial),
        Err(ScanError::OpenFileLimit)
    ));

    let nested = temp.path().join("nested");
    fs::create_dir_all(nested.join("dir")).unwrap();
    fs::write(nested.join("dir/file"), b"x").unwrap();
    below = ScanLimits::default();
    below.max_buffered_paths = 1;
    assert!(matches!(
        ManifestScanner::new(below)
            .unwrap()
            .scan(&nested, ScanReason::Initial),
        Err(ScanError::BufferedPathLimit)
    ));

    below = exact;
    below.hash_buffer_bytes = 0;
    assert!(matches!(
        ManifestScanner::new(below),
        Err(ScanError::InvalidLimits)
    ));
}

enum Mutation {
    File(std::path::PathBuf),
    Directory(std::path::PathBuf),
    DirectoryCompleted(std::path::PathBuf),
}

struct MutationObserver {
    mutation: Mutation,
    fired: AtomicBool,
}

impl ScanObserver for MutationObserver {
    fn checkpoint(&self, checkpoint: ScanCheckpoint, relative_path: &str) {
        if self.fired.swap(true, Ordering::SeqCst) {
            return;
        }
        match (&self.mutation, checkpoint, relative_path) {
            (Mutation::File(path), ScanCheckpoint::FileHashed, "data") => {
                let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
                file.write_all(b"changed").unwrap();
                file.sync_all().unwrap();
            }
            (Mutation::Directory(path), ScanCheckpoint::DirectoryEnumerated, "") => {
                fs::write(path.join("added-during-scan"), b"new").unwrap();
            }
            (Mutation::DirectoryCompleted(path), ScanCheckpoint::DirectoryCompleted, "") => {
                fs::write(path.join("added-after-child-processing"), b"new").unwrap();
            }
            _ => self.fired.store(false, Ordering::SeqCst),
        }
    }
}

#[test]
fn concurrent_file_change_returns_explicit_retryable_error() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("project");
    fs::create_dir(&root).unwrap();
    let file = root.join("data");
    fs::write(&file, b"before").unwrap();
    let scanner = ManifestScanner::with_observer(
        ScanLimits::default(),
        Box::new(MutationObserver {
            mutation: Mutation::File(file),
            fired: AtomicBool::new(false),
        }),
    )
    .unwrap();
    assert!(matches!(
        scanner.scan(&root, ScanReason::Initial),
        Err(ScanError::RetryableFileChanged(path)) if path == "data"
    ));
}

#[test]
fn concurrent_directory_change_returns_explicit_retryable_error() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("project");
    fs::create_dir(&root).unwrap();
    let scanner = ManifestScanner::with_observer(
        ScanLimits::default(),
        Box::new(MutationObserver {
            mutation: Mutation::Directory(root.clone()),
            fired: AtomicBool::new(false),
        }),
    )
    .unwrap();
    assert!(matches!(
        scanner.scan(&root, ScanReason::Initial),
        Err(ScanError::RetryableDirectoryChanged(path)) if path == "."
    ));
}

#[test]
fn parent_change_after_child_processing_is_detected_by_final_fstat() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("project");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("existing"), b"content").unwrap();
    let scanner = ManifestScanner::with_observer(
        ScanLimits::default(),
        Box::new(MutationObserver {
            mutation: Mutation::DirectoryCompleted(root.clone()),
            fired: AtomicBool::new(false),
        }),
    )
    .unwrap();
    assert!(matches!(
        scanner.scan(&root, ScanReason::Initial),
        Err(ScanError::RetryableDirectoryChanged(path)) if path == "."
    ));
}

#[test]
fn cancellation_is_observed_before_directory_walk() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("project");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("large"), vec![0u8; 1024 * 1024]).unwrap();
    let cancelled = Arc::new(AtomicBool::new(true));
    let scanner = ManifestScanner::with_cancellation(ScanLimits::default(), cancelled).unwrap();

    assert!(matches!(
        scanner.scan(&root, ScanReason::Initial),
        Err(ScanError::Cancelled)
    ));
}
