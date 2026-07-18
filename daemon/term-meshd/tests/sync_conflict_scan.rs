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

/// A base entry with no recoverable content is now common, not exceptional: a
/// path both peers already had enters the base without ever passing through CAS.
/// With both sides present, falling back to `base = None` is honest (we have no
/// recorded base) and safe — no `merge_file` early return fires.
#[test]
fn a_missing_base_with_both_sides_present_is_classified_as_add_add() {
    let mut fixture = Fixture::new();
    // A base ENTRY with no staged object, as a converged path now produces.
    let base = entry("notes.txt", b"agreed\n", false);
    let remote = fixture.remote("notes.txt", b"theirs\n");
    let local = fixture.local("notes.txt", b"mine\n");

    let scan = fixture.scan(&[ConflictPath {
        relative_path: "notes.txt".into(),
        base: Some(base),
        local: Some(local),
        remote: Some(remote),
    }]);

    assert_eq!(scan.set.len(), 1, "still a usable, resolvable conflict");
    assert!(scan.unclassified.is_empty());
    let record = scan.set.iter().next().unwrap();
    assert_eq!(record.kind(), &ConflictKind::AddAddText);
    assert!(record.base().is_none(), "no base is recorded, and none is claimed");
    assert_eq!(record.local().unwrap().bytes(), b"mine\n");
    assert_eq!(record.remote().unwrap().bytes(), b"theirs\n");
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

// ── persistence (BD-4c) ─────────────────────────────────────────────────────

use sync::{decode_conflict_set, encode_conflict_set, ApplyStore, ConflictSet};

fn state_dir(base: &std::path::Path, name: &str) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let dir = base.join(name);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    dir
}

/// A conflict outlives the operation that found it, so every field a resolution
/// needs — all three sides' bytes included — must survive the round trip.
#[test]
fn a_conflict_set_round_trips_through_the_codec() {
    let mut fixture = Fixture::new();
    let base = fixture.base("notes.txt", b"start\n");
    let remote = fixture.remote("notes.txt", b"start\ntheirs\n");
    let local = fixture.local("notes.txt", b"start\nmine\n");
    let gone_base = fixture.base("gone.txt", b"was here\n");
    let gone_remote = fixture.remote("gone.txt", b"was here\nedited\n");

    let scan = fixture.scan(&[
        ConflictPath {
            relative_path: "notes.txt".into(),
            base: Some(base),
            local: Some(local),
            remote: Some(remote),
        },
        ConflictPath {
            relative_path: "gone.txt".into(),
            base: Some(gone_base),
            local: None,
            remote: Some(gone_remote),
        },
    ]);
    assert_eq!(scan.set.len(), 2);

    let restored = decode_conflict_set(&encode_conflict_set(&scan.set), fixture.domain).unwrap();
    assert_eq!(restored.len(), 2);
    for original in scan.set.iter() {
        // The id is recomputed on decode, so matching ids prove the rebuilt
        // record is byte-for-byte the same conflict, not merely similar.
        let same = restored
            .get(original.conflict_id())
            .expect("conflict id survived the round trip");
        assert_eq!(same.kind(), original.kind());
        assert_eq!(same.paths(), original.paths());
        assert_eq!(same.base().map(|c| c.bytes()), original.base().map(|c| c.bytes()));
        assert_eq!(same.local().map(|c| c.bytes()), original.local().map(|c| c.bytes()));
        assert_eq!(same.remote().map(|c| c.bytes()), original.remote().map(|c| c.bytes()));
        // The precondition a resolution is checked against must also survive, or
        // every restored conflict would be unresolvable.
        assert_eq!(same.precondition(), original.precondition());
    }
}

#[test]
fn an_empty_conflict_set_round_trips() {
    let fixture = Fixture::new();
    let empty = ConflictSet::new(fixture.domain).unwrap();
    let restored = decode_conflict_set(&encode_conflict_set(&empty), fixture.domain).unwrap();
    assert!(restored.is_empty());
}

/// The codec rebuilds through the validating constructor rather than trusting
/// the stored bytes, so tampering is rejected instead of loaded.
#[test]
fn a_tampered_or_foreign_encoding_is_rejected() {
    let mut fixture = Fixture::new();
    let base = fixture.base("notes.txt", b"start\n");
    let remote = fixture.remote("notes.txt", b"start\ntheirs\n");
    let local = fixture.local("notes.txt", b"start\nmine\n");
    let scan = fixture.scan(&[ConflictPath {
        relative_path: "notes.txt".into(),
        base: Some(base),
        local: Some(local),
        remote: Some(remote),
    }]);
    let encoded = encode_conflict_set(&scan.set);

    // Content bytes edited without updating their address: the constructor
    // re-derives the content root and refuses.
    let mut flipped = encoded.clone();
    let last = flipped.len() - 1;
    flipped[last] ^= 0xff;
    assert!(decode_conflict_set(&flipped, fixture.domain).is_err());

    // Truncated.
    assert!(decode_conflict_set(&encoded[..encoded.len() / 2], fixture.domain).is_err());

    // Trailing garbage — a decoder that stopped at the last record would accept
    // this and silently drop whatever followed.
    let mut extended = encoded.clone();
    extended.push(0);
    assert!(decode_conflict_set(&extended, fixture.domain).is_err());

    // Stored under a different project: adopting it would attach one project's
    // conflicts to another.
    let other = ObjectDomain {
        project_id: ProjectId::from_bytes([0x99; 32]),
        object_type: ObjectType::FILE,
        version: 1,
    };
    assert!(decode_conflict_set(&encoded, other).is_err());

    // Unknown codec version.
    let mut wrong_version = encoded.clone();
    wrong_version[0] = 99;
    assert!(decode_conflict_set(&wrong_version, fixture.domain).is_err());
}

/// Conflicts must survive the process that found them — resolution happens later.
#[test]
fn stored_conflicts_survive_a_store_reopen_and_are_replaced_wholesale() {
    let mut fixture = Fixture::new();
    let temporary = tempfile::tempdir().unwrap();
    let database = state_dir(temporary.path(), "apply-state").join("apply.db");
    let project = fixture.domain.project_id;

    let base = fixture.base("notes.txt", b"start\n");
    let remote = fixture.remote("notes.txt", b"start\ntheirs\n");
    let local = fixture.local("notes.txt", b"start\nmine\n");
    let scan = fixture.scan(&[ConflictPath {
        relative_path: "notes.txt".into(),
        base: Some(base),
        local: Some(local),
        remote: Some(remote),
    }]);

    let store = ApplyStore::open(&database).unwrap();
    assert!(
        store.load_conflicts(fixture.domain).unwrap().is_empty(),
        "a project with no stored conflicts loads an empty set, not an error"
    );
    store.save_conflicts(project, &scan.set).unwrap();
    drop(store);

    let reopened = ApplyStore::open(&database).unwrap();
    let loaded = reopened.load_conflicts(fixture.domain).unwrap();
    assert_eq!(loaded.len(), 1);
    let record = loaded.iter().next().unwrap();
    assert_eq!(record.paths(), ["notes.txt".to_string()]);
    assert_eq!(record.local().unwrap().bytes(), b"start\nmine\n");

    // A later sync replaces the set, so a conflict that is gone stays gone.
    reopened
        .save_conflicts(project, &ConflictSet::new(fixture.domain).unwrap())
        .unwrap();
    assert!(reopened.load_conflicts(fixture.domain).unwrap().is_empty());
}

// ── resolution (BD-4c) ──────────────────────────────────────────────────────

use sync::{
    reconcile_bidirectional, resolve_conflict, ConflictResolution, EntryKind as Kind, ManifestEntry,
};

/// A store + a scanned conflict, ready to resolve.
struct Resolvable {
    fixture: Fixture,
    store: std::sync::Mutex<ApplyStore>,
    conflict_id: [u8; 32],
    _temporary: tempfile::TempDir,
}

fn resolvable() -> Resolvable {
    let mut fixture = Fixture::new();
    let temporary = tempfile::tempdir().unwrap();
    let database = state_dir(temporary.path(), "apply-state").join("apply.db");

    let base = fixture.base("notes.txt", b"start\n");
    let remote = fixture.remote("notes.txt", b"start\ntheirs\n");
    let local = fixture.local("notes.txt", b"start\nmine\n");
    let scan = fixture.scan(&[ConflictPath {
        relative_path: "notes.txt".into(),
        base: Some(base.clone()),
        local: Some(local),
        remote: Some(remote),
    }]);
    let conflict_id = scan.set.iter().next().unwrap().conflict_id();

    let store = ApplyStore::open(&database).unwrap();
    // The base as a prior sync would have left it.
    store
        .save_base_manifest(
            fixture.domain.project_id,
            &[ManifestEntry {
                relative_path: "notes.txt".into(),
                kind: Kind::File,
                executable: false,
                length: base.length,
                content_hash: base.content_hash,
                symlink_target: None,
            }],
        )
        .unwrap();
    store
        .save_base_objects(fixture.domain.project_id, &fixture.base_objects)
        .unwrap();
    store.save_conflicts(fixture.domain.project_id, &scan.set).unwrap();

    Resolvable {
        fixture,
        store: std::sync::Mutex::new(store),
        conflict_id,
        _temporary: temporary,
    }
}

fn resolve(r: &Resolvable, resolution: ConflictResolution) -> sync::ResolutionOutcome {
    resolve_conflict(
        &r.store,
        &r.fixture.cas,
        r.fixture.domain,
        &r.fixture.root,
        r.conflict_id,
        resolution,
        &ProjectKey::new(KEY_BYTES),
        KEY_ID,
    )
    .unwrap()
}

/// The local tree and the stored set both reflect the decision.
#[test]
fn keeping_the_local_side_writes_it_and_clears_the_conflict() {
    let r = resolvable();
    let outcome = resolve(&r, ConflictResolution::KeepLocal);

    assert_eq!(outcome.paths, ["notes.txt".to_string()]);
    assert_eq!(outcome.remaining, 0);
    assert_eq!(
        std::fs::read(r.fixture.root.join("notes.txt")).unwrap(),
        b"start\nmine\n"
    );
    let store = r.store.lock().unwrap();
    assert!(store.load_conflicts(r.fixture.domain).unwrap().is_empty());
}

#[test]
fn keeping_the_remote_side_overwrites_the_local_file() {
    let r = resolvable();
    resolve(&r, ConflictResolution::KeepRemote);
    assert_eq!(
        std::fs::read(r.fixture.root.join("notes.txt")).unwrap(),
        b"start\ntheirs\n"
    );
}

#[test]
fn resolving_to_delete_removes_the_file() {
    let r = resolvable();
    let outcome = resolve(&r, ConflictResolution::Delete);
    assert!(!r.fixture.root.join("notes.txt").exists());
    assert_eq!(outcome.remaining, 0);
}

/// The point of the base rule. After resolving locally the peer still holds its
/// own version, so the next reconcile must PUSH the decision — not fetch the
/// peer's version back over it, and not raise the same conflict again.
#[test]
fn a_local_resolution_is_pushed_on_the_next_reconcile_not_undone() {
    let r = resolvable();
    resolve(&r, ConflictResolution::KeepLocal);

    let (base, _) = {
        let store = r.store.lock().unwrap();
        (
            store.load_base_manifest(r.fixture.domain.project_id).unwrap(),
            store.load_base_objects(r.fixture.domain.project_id).unwrap(),
        )
    };
    // The peer is unchanged; the local tree now holds the resolved content.
    let local = vec![manifest("notes.txt", b"start\nmine\n")];
    let remote = vec![manifest("notes.txt", b"start\ntheirs\n")];
    let plan = reconcile_bidirectional(&base, &local, &remote);

    assert_eq!(
        plan.push.iter().map(|e| e.relative_path.as_str()).collect::<Vec<_>>(),
        ["notes.txt"],
        "the resolution must propagate to the peer",
    );
    assert!(plan.fetch.is_empty(), "the peer's version must not come back");
    assert!(plan.conflicts.is_empty(), "the conflict must not be raised again");
}

/// Choosing the peer's side needs no transfer at all: both trees already agree.
#[test]
fn resolving_to_the_remote_side_converges_with_no_further_work() {
    let r = resolvable();
    resolve(&r, ConflictResolution::KeepRemote);

    let base = {
        let store = r.store.lock().unwrap();
        store.load_base_manifest(r.fixture.domain.project_id).unwrap()
    };
    let local = vec![manifest("notes.txt", b"start\ntheirs\n")];
    let remote = vec![manifest("notes.txt", b"start\ntheirs\n")];
    let plan = reconcile_bidirectional(&base, &local, &remote);
    assert!(plan.is_empty(), "already converged: {plan:?}");
}

/// Resolving twice must not double-apply: the conflict is gone the second time.
#[test]
fn resolving_an_unknown_or_already_resolved_conflict_is_rejected() {
    let r = resolvable();
    resolve(&r, ConflictResolution::KeepLocal);
    let again = resolve_conflict(
        &r.store,
        &r.fixture.cas,
        r.fixture.domain,
        &r.fixture.root,
        r.conflict_id,
        ConflictResolution::KeepRemote,
        &ProjectKey::new(KEY_BYTES),
        KEY_ID,
    );
    assert_eq!(again.unwrap_err(), "conflict_not_found");
    // The first decision stands.
    assert_eq!(
        std::fs::read(r.fixture.root.join("notes.txt")).unwrap(),
        b"start\nmine\n"
    );
}

fn manifest(path: &str, bytes: &[u8]) -> ManifestEntry {
    ManifestEntry {
        relative_path: path.to_string(),
        kind: Kind::File,
        executable: false,
        length: bytes.len() as u64,
        content_hash: *blake3::hash(bytes).as_bytes(),
        symlink_target: None,
    }
}
