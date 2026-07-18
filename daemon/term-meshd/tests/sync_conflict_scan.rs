//! Classifying reconciled conflict paths (BD-4b).
//!
//! `reconcile_bidirectional` can only say "both sides changed this since the
//! base"; `scan_conflicts` reads the three sides' bytes — local from the working
//! tree, remote and base from CAS — and hands them to `merge_file`.
//!
//! The delete/modify case is the reason the base is mandatory: without it the
//! merge sees `(None, None, Some)`, takes its `local == base` early return, and
//! resolves to remote — resurrecting a file the user deleted.

#[path = "../src/sync/mod.rs"]
mod sync;

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use sync::{
    put_plaintext, scan_conflicts, CasError, CasLimits, CasStore, ConflictKind, ConflictPath,
    ConflictSide, EntryKind, FetchEntry, KeyId, ObjectDomain, ObjectId, ObjectType, ProjectId,
    ProjectKey, ProjectKeyMaterial, ProjectKeyProvider, UnclassifiedReason,
};

const KEY_BYTES: [u8; 32] = [0x5c; 32];
const KEY_ID: KeyId = KeyId([0x11; 16]);

struct FixedKeyProvider;

impl ProjectKeyProvider for FixedKeyProvider {
    fn current_project_key(&self, _: ProjectId) -> Result<ProjectKeyMaterial, CasError> {
        Ok(ProjectKeyMaterial { key_id: KEY_ID, key: ProjectKey::new(KEY_BYTES) })
    }
    fn project_key(&self, _: ProjectId, _: KeyId) -> Result<ProjectKey, CasError> {
        Ok(ProjectKey::new(KEY_BYTES))
    }
}

struct Fixture {
    _temporary: tempfile::TempDir,
    root: std::path::PathBuf,
    cas: CasStore,
    domain: ObjectDomain,
    remote_objects: HashMap<String, ObjectId>,
    base_objects: BTreeMap<String, ObjectId>,
}

impl Fixture {
    fn new() -> Self {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().join("tree");
        std::fs::create_dir_all(&root).unwrap();
        let project = ProjectId::from_bytes([0x42; 32]);
        let cas = CasStore::open(
            temporary.path().join("cas"),
            CasLimits::default(),
            Arc::new(FixedKeyProvider),
        )
        .unwrap();
        Self {
            _temporary: temporary,
            root,
            cas,
            domain: ObjectDomain { project_id: project, object_type: ObjectType::FILE, version: 1 },
            remote_objects: HashMap::new(),
            base_objects: BTreeMap::new(),
        }
    }

    /// Write the local side to the working tree, as the scan reads it.
    fn local(&self, path: &str, bytes: &[u8]) -> FetchEntry {
        std::fs::write(self.root.join(path), bytes).unwrap();
        entry(path, bytes, false)
    }

    /// Stage the peer's side in CAS, as the fetch phase would.
    fn remote(&mut self, path: &str, bytes: &[u8]) -> FetchEntry {
        let object_id = self.stage(bytes);
        self.remote_objects.insert(path.to_string(), object_id);
        entry(path, bytes, false)
    }

    /// Stage the agreed base in CAS and record its object, as a prior sync would.
    fn base(&mut self, path: &str, bytes: &[u8]) -> FetchEntry {
        let object_id = self.stage(bytes);
        self.base_objects.insert(path.to_string(), object_id);
        entry(path, bytes, false)
    }

    fn stage(&self, bytes: &[u8]) -> ObjectId {
        put_plaintext(
            &self.cas,
            self.domain,
            &ProjectKey::new(KEY_BYTES),
            KEY_ID,
            bytes,
        )
        .unwrap()
    }

    fn scan(&self, conflicts: &[ConflictPath]) -> sync::ConflictScan {
        scan_conflicts(
            conflicts,
            &self.cas,
            self.domain,
            &self.root,
            &self.remote_objects,
            &self.base_objects,
        )
        .unwrap()
    }
}

fn entry(path: &str, bytes: &[u8], executable: bool) -> FetchEntry {
    FetchEntry {
        relative_path: path.to_string(),
        kind: EntryKind::File,
        executable,
        length: bytes.len() as u64,
        content_hash: *blake3::hash(bytes).as_bytes(),
        symlink_target: None,
    }
}

#[test]
fn a_file_both_sides_edited_is_classified_as_a_text_conflict() {
    let mut fixture = Fixture::new();
    let base = fixture.base("notes.txt", b"shared start\n");
    let remote = fixture.remote("notes.txt", b"shared start\ntheir line\n");
    let local = fixture.local("notes.txt", b"shared start\nmy line\n");

    let scan = fixture.scan(&[ConflictPath {
        relative_path: "notes.txt".into(),
        base: Some(base),
        local: Some(local),
        remote: Some(remote),
    }]);

    assert_eq!(scan.set.len(), 1);
    assert!(scan.unclassified.is_empty());
    assert!(scan.converged.is_empty());
    let record = scan.set.iter().next().unwrap();
    assert_eq!(record.kind(), &ConflictKind::Text);
    assert_eq!(record.paths(), ["notes.txt".to_string()]);
    // All three sides survive into the record, so a resolution can offer any of
    // them (or a merge) without going back to the network.
    assert_eq!(record.base().unwrap().bytes(), b"shared start\n");
    assert_eq!(record.local().unwrap().bytes(), b"shared start\nmy line\n");
    assert_eq!(record.remote().unwrap().bytes(), b"shared start\ntheir line\n");
}

/// The case the base exists for. Deleting a file locally while the peer edits it
/// must be a conflict the user decides — never a silent restore.
#[test]
fn a_locally_deleted_file_the_peer_edited_is_a_delete_modify_conflict() {
    let mut fixture = Fixture::new();
    let base = fixture.base("gone.txt", b"original\n");
    let remote = fixture.remote("gone.txt", b"original\ntheir edit\n");
    // No `local` write: the file is deleted in the working tree.

    let scan = fixture.scan(&[ConflictPath {
        relative_path: "gone.txt".into(),
        base: Some(base),
        local: None,
        remote: Some(remote),
    }]);

    assert_eq!(scan.set.len(), 1);
    let record = scan.set.iter().next().unwrap();
    assert_eq!(
        record.kind(),
        &ConflictKind::DeleteModify { deleted: ConflictSide::Local }
    );
    assert!(record.local().is_none(), "the local deletion is preserved");
    // Nothing was written back to the tree.
    assert!(!fixture.root.join("gone.txt").exists());
}

/// If the base entry is known but its content is not recoverable, merging would
/// see `base = None` and mistake a delete/modify for a plain remote add. Report
/// it instead — an unresolved path is recoverable, a resurrected file is not.
#[test]
fn a_base_whose_content_is_missing_is_unclassified_rather_than_merged() {
    let mut fixture = Fixture::new();
    // A base ENTRY, but deliberately no staged object for it.
    let base = entry("gone.txt", b"original\n", false);
    let remote = fixture.remote("gone.txt", b"original\ntheir edit\n");

    let scan = fixture.scan(&[ConflictPath {
        relative_path: "gone.txt".into(),
        base: Some(base),
        local: None,
        remote: Some(remote),
    }]);

    assert!(scan.set.is_empty(), "not classified on partial information");
    assert_eq!(scan.unclassified.len(), 1);
    assert_eq!(
        scan.unclassified[0].reason,
        UnclassifiedReason::BaseContentUnavailable
    );
    assert!(
        !fixture.root.join("gone.txt").exists(),
        "the deleted file must not come back"
    );
}

/// With no base at all — a path neither peer had agreed on — both sides adding it
/// is a legitimate add/add, and `base = None` is the truth rather than a gap.
#[test]
fn a_path_with_no_base_that_both_peers_added_is_an_add_add_conflict() {
    let mut fixture = Fixture::new();
    let remote = fixture.remote("new.txt", b"their version\n");
    let local = fixture.local("new.txt", b"my version\n");

    let scan = fixture.scan(&[ConflictPath {
        relative_path: "new.txt".into(),
        base: None,
        local: Some(local),
        remote: Some(remote),
    }]);

    assert_eq!(scan.set.len(), 1);
    assert_eq!(
        scan.set.iter().next().unwrap().kind(),
        &ConflictKind::AddAddText
    );
}

#[test]
fn binary_content_is_classified_as_a_binary_conflict() {
    let mut fixture = Fixture::new();
    let base = fixture.base("blob.bin", &[0u8, 1, 2, 3]);
    let remote = fixture.remote("blob.bin", &[0u8, 1, 2, 9]);
    let local = fixture.local("blob.bin", &[0u8, 1, 2, 7]);

    let scan = fixture.scan(&[ConflictPath {
        relative_path: "blob.bin".into(),
        base: Some(base),
        local: Some(local),
        remote: Some(remote),
    }]);

    assert_eq!(scan.set.len(), 1);
    assert_eq!(
        scan.set.iter().next().unwrap().kind(),
        &ConflictKind::Binary
    );
}

/// `merge_file` compares file content, so a path that is a directory on one side
/// and a file on the other is out of its reach. Report it rather than guess.
#[test]
fn a_kind_level_conflict_is_reported_as_not_a_file() {
    let mut fixture = Fixture::new();
    let local = fixture.local("thing", b"a file here\n");
    let mut remote = fixture.remote("thing", b"ignored\n");
    remote.kind = EntryKind::Directory;

    let scan = fixture.scan(&[ConflictPath {
        relative_path: "thing".into(),
        base: None,
        local: Some(local),
        remote: Some(remote),
    }]);

    assert!(scan.set.is_empty());
    assert_eq!(scan.unclassified.len(), 1);
    assert_eq!(scan.unclassified[0].reason, UnclassifiedReason::NotAFile);
    assert_eq!(scan.unclassified[0].relative_path, "thing");
}

/// A path the reconcile flagged from manifest state can still turn out to hold
/// identical bytes on both sides. That is not a conflict.
#[test]
fn sides_that_agree_once_read_are_converged_not_conflicting() {
    let mut fixture = Fixture::new();
    let base = fixture.base("same.txt", b"before\n");
    let remote = fixture.remote("same.txt", b"after\n");
    let local = fixture.local("same.txt", b"after\n");

    let scan = fixture.scan(&[ConflictPath {
        relative_path: "same.txt".into(),
        base: Some(base),
        local: Some(local),
        remote: Some(remote),
    }]);

    assert!(scan.set.is_empty());
    assert_eq!(scan.converged, ["same.txt".to_string()]);
    assert_eq!(scan.outstanding(), 0);
}

/// Both counts feed the caller's "did this run converge?" answer: an
/// unclassified path is as unsynced as a classified one.
#[test]
fn outstanding_counts_classified_and_unclassified_together() {
    let mut fixture = Fixture::new();
    let base = fixture.base("a.txt", b"base a\n");
    let remote_a = fixture.remote("a.txt", b"their a\n");
    let local_a = fixture.local("a.txt", b"my a\n");
    let local_b = fixture.local("b", b"file here\n");
    let mut remote_b = fixture.remote("b", b"ignored\n");
    remote_b.kind = EntryKind::Directory;

    let scan = fixture.scan(&[
        ConflictPath {
            relative_path: "a.txt".into(),
            base: Some(base),
            local: Some(local_a),
            remote: Some(remote_a),
        },
        ConflictPath {
            relative_path: "b".into(),
            base: None,
            local: Some(local_b),
            remote: Some(remote_b),
        },
    ]);

    assert_eq!(scan.set.len(), 1);
    assert_eq!(scan.unclassified.len(), 1);
    assert_eq!(scan.outstanding(), 2);
}
