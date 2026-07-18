//! Manifest diff + wire codec for the mesh sync runner (Phase S1 of
//! `docs/design/mesh-project-sync-wiring-plan.md`).
//!
//! `reconcile.rs` decides head/frontier relations and moves oplog/manifest
//! pages; it does not emit a file-level plan. This module is the runner's own
//! diff: given the destination's and the source's scanned manifest entries, it
//! computes what the destination must fetch/overwrite and delete to converge.
//!
//! S1 proves the *diff* — the set of paths + content hashes that differ. It does
//! not resolve CAS object ids or move bytes; S2 turns `fetch` entries into CAS
//! transfers and a real `ApplyPlan`. The entry wire codec here is the minimal
//! encoding the two peers swap their manifests over the SyncOperation lane.

use std::collections::{HashMap, HashSet};

use super::{
    ApplyAction, ApplyPlan, ApplyPlanEntry, ApplyPrecondition, EntryKind, ManifestEntry, ObjectId,
    PathFingerprint, PathKind, ProjectId,
};

/// Upper bounds applied when decoding a peer's manifest (untrusted input).
const MAX_ENTRIES: usize = 4_000_000;
const MAX_PATH_BYTES: usize = 4096;

/// Target encoded size per manifest batch message. Kept well under the
/// `SyncOperation` lane's 8 MiB message cap so a large manifest is streamed as
/// many bounded messages rather than one oversized one the router would reject.
const MANIFEST_BATCH_BYTES: usize = 512 * 1024;

/// One entry the destination must transfer from the source to converge.
/// Mirrors the source `ManifestEntry`; carried separately so S2 can attach the
/// resolved CAS object id without mutating the manifest type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FetchEntry {
    pub relative_path: String,
    pub kind: EntryKind,
    pub executable: bool,
    pub length: u64,
    pub content_hash: [u8; 32],
    pub symlink_target: Option<String>,
}

/// The changes that make a local (destination) manifest converge to a remote
/// (source) manifest. Content bytes are unresolved (that is S2).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ManifestDiff {
    /// Paths present-or-changed on the source that the destination must pull.
    pub fetch: Vec<FetchEntry>,
    /// Paths present on the destination but gone from the source.
    pub delete: Vec<String>,
}

impl ManifestDiff {
    pub fn is_empty(&self) -> bool {
        self.fetch.is_empty() && self.delete.is_empty()
    }
}

/// Diff `local` (destination) against `remote` (source): what would make local
/// converge to remote. Path-keyed, so it is independent of the manifests'
/// iteration order; `fetch` follows `remote` order and `delete` follows `local`
/// order for deterministic output.
///
/// - path only in remote → fetch (add)
/// - path in both, entry differs → fetch (overwrite)
/// - path in both, entry equal → skip
/// - path only in local → delete
pub fn diff_manifests(local: &[ManifestEntry], remote: &[ManifestEntry]) -> ManifestDiff {
    let local_by_path: HashMap<&str, &ManifestEntry> = local
        .iter()
        .map(|entry| (entry.relative_path.as_str(), entry))
        .collect();
    let remote_paths: HashSet<&str> = remote
        .iter()
        .map(|entry| entry.relative_path.as_str())
        .collect();

    let mut diff = ManifestDiff::default();
    for entry in remote {
        match local_by_path.get(entry.relative_path.as_str()) {
            Some(local_entry) if *local_entry == entry => {}
            _ => diff.fetch.push(fetch_of(entry)),
        }
    }
    for entry in local {
        if !remote_paths.contains(entry.relative_path.as_str()) {
            diff.delete.push(entry.relative_path.clone());
        }
    }
    diff
}

fn fetch_of(entry: &ManifestEntry) -> FetchEntry {
    FetchEntry {
        relative_path: entry.relative_path.clone(),
        kind: entry.kind,
        executable: entry.executable,
        length: entry.length,
        content_hash: entry.content_hash,
        symlink_target: entry.symlink_target.clone(),
    }
}

/// One path that diverged on BOTH sides since the base — a conflict. Carries the
/// three manifest states (`None` = absent) so the resolver can three-way merge or
/// preserve both.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConflictPath {
    pub relative_path: String,
    pub base: Option<FetchEntry>,
    pub local: Option<FetchEntry>,
    pub remote: Option<FetchEntry>,
}

/// A bidirectional reconciliation from a three-way comparison of the last-synced
/// BASE manifest, the LOCAL tree, and the REMOTE tree. Where [`diff_manifests`]
/// is one-way (local converges to remote), this converges BOTH sides and flags
/// paths that changed divergently on both as conflicts — never last-writer-wins.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct BidiPlan {
    /// Remote-only changes the local tree pulls (local ← remote).
    pub fetch: Vec<FetchEntry>,
    /// Local-only changes the remote receives (remote ← local).
    pub push: Vec<FetchEntry>,
    /// Paths deleted locally that the remote must also delete.
    pub delete_remote: Vec<String>,
    /// Paths deleted remotely that the local must also delete.
    pub delete_local: Vec<String>,
    /// Paths changed on both sides since the base.
    pub conflicts: Vec<ConflictPath>,
}

impl BidiPlan {
    pub fn is_empty(&self) -> bool {
        self.fetch.is_empty()
            && self.push.is_empty()
            && self.delete_remote.is_empty()
            && self.delete_local.is_empty()
            && self.conflicts.is_empty()
    }
}

fn index_by_path(entries: &[ManifestEntry]) -> HashMap<&str, &ManifestEntry> {
    entries
        .iter()
        .map(|entry| (entry.relative_path.as_str(), entry))
        .collect()
}

/// Two optional manifest states are "equal" when both are absent or both present
/// with identical entries. A change is any inequality.
fn manifest_state_eq(a: Option<&ManifestEntry>, b: Option<&ManifestEntry>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(x), Some(y)) => x == y,
        _ => false,
    }
}

/// Reconcile `local` and `remote` against their last-synced `base`. Each path in
/// the union of the three is classified:
/// - `local` and `remote` already equal → converged (skip);
/// - only `remote` changed since base → fetch (present) or delete-local (gone);
/// - only `local` changed since base → push (present) or delete-remote (gone);
/// - both changed since base → conflict (carries base/local/remote states).
///
/// Output is path-sorted for deterministic results independent of scan order.
/// The base being empty makes every add on either side a candidate: an add on one
/// side alone is a push/fetch, an add of the SAME path on both is a conflict.
pub fn reconcile_bidirectional(
    base: &[ManifestEntry],
    local: &[ManifestEntry],
    remote: &[ManifestEntry],
) -> BidiPlan {
    let base_by = index_by_path(base);
    let local_by = index_by_path(local);
    let remote_by = index_by_path(remote);

    let mut paths: Vec<&str> = base_by
        .keys()
        .chain(local_by.keys())
        .chain(remote_by.keys())
        .copied()
        .collect();
    paths.sort_unstable();
    paths.dedup();

    let mut plan = BidiPlan::default();
    for path in paths {
        let base_entry = base_by.get(path).copied();
        let local_entry = local_by.get(path).copied();
        let remote_entry = remote_by.get(path).copied();

        if manifest_state_eq(local_entry, remote_entry) {
            continue; // already converged (equal, or both absent)
        }
        let local_changed = !manifest_state_eq(base_entry, local_entry);
        let remote_changed = !manifest_state_eq(base_entry, remote_entry);
        match (local_changed, remote_changed) {
            (true, true) => plan.conflicts.push(ConflictPath {
                relative_path: path.to_string(),
                base: base_entry.map(fetch_of),
                local: local_entry.map(fetch_of),
                remote: remote_entry.map(fetch_of),
            }),
            (false, true) => match remote_entry {
                Some(entry) => plan.fetch.push(fetch_of(entry)),
                None => plan.delete_local.push(path.to_string()),
            },
            (true, false) => match local_entry {
                Some(entry) => plan.push.push(fetch_of(entry)),
                None => plan.delete_remote.push(path.to_string()),
            },
            // local==base && remote==base ⇒ local==remote, excluded above.
            (false, false) => {}
        }
    }
    plan
}

/// The precondition [`PathFingerprint`] a locally-present manifest `entry` must
/// still match for an overwrite to be safe. A file's manifest hash is the plain
/// BLAKE3 of its bytes and a symlink's is the plain BLAKE3 of its target, both
/// exactly what `ApplyStore` recomputes on disk, so File and Symlink fingerprints
/// reconstruct faithfully. A directory's on-disk fingerprint folds in every
/// child, which the manifest entry does not carry, so it returns `None` — a path
/// currently held by a directory cannot yet be safely overwritten.
fn manifest_fingerprint(entry: &ManifestEntry) -> Option<PathFingerprint> {
    match entry.kind {
        EntryKind::File => Some(PathFingerprint {
            kind: PathKind::File,
            content_hash: entry.content_hash,
            length: entry.length,
            executable: entry.executable,
            symlink_target: None,
        }),
        EntryKind::Symlink => {
            let target = entry.symlink_target.clone()?;
            Some(PathFingerprint {
                kind: PathKind::Symlink,
                content_hash: *blake3::hash(target.as_bytes()).as_bytes(),
                length: target.len() as u64,
                executable: false,
                symlink_target: Some(target),
            })
        }
        EntryKind::Directory => None,
    }
}

/// Build an [`ApplyPlan`] from a diff's fetch list, the CAS object ids the fetch
/// resolved (path → object id), and the destination's own scanned manifest
/// `local`. File entries carry their transferred object id; directory and symlink
/// entries carry no bytes (a symlink's target is inline, a directory only its
/// mode). Directories are ordered first — a parent before each of its children —
/// so a file or symlink always has its parent directory to land in.
///
/// The precondition is taken from the destination's current state at each path:
/// absent → an add (`Absent`); present → an overwrite guarded by the current
/// [`PathFingerprint`] (`Present`), so a concurrently-changed file is refused
/// rather than clobbered. A path currently held by a directory is skipped (its
/// on-disk fingerprint is not reconstructible from the manifest — see
/// [`manifest_fingerprint`]). `target_manifest_root`/`frontier` remain
/// placeholders until oplog/visible-state tracking lands.
pub fn build_apply_plan(
    project: ProjectId,
    operation_id: [u8; 16],
    fetch: &[FetchEntry],
    object_ids: &HashMap<String, ObjectId>,
    local: &[ManifestEntry],
) -> ApplyPlan {
    let local_by_path: HashMap<&str, &ManifestEntry> = local
        .iter()
        .map(|entry| (entry.relative_path.as_str(), entry))
        .collect();
    // Directories are collected apart from files/symlinks so they can be applied
    // first: a leaf can only be installed once its parent directory exists.
    let mut directories = Vec::new();
    let mut leaves = Vec::new();
    for entry in fetch {
        let precondition = match local_by_path.get(entry.relative_path.as_str()) {
            None => ApplyPrecondition::Absent,
            Some(local_entry) => match manifest_fingerprint(local_entry) {
                Some(fingerprint) => ApplyPrecondition::Present(fingerprint),
                // Local path is a directory: defer (cannot reconstruct its fp).
                None => continue,
            },
        };
        let action = match entry.kind {
            EntryKind::Directory => ApplyAction::Directory {
                executable: entry.executable,
            },
            EntryKind::Symlink => {
                // A symlink carries its target inline; skip a malformed entry
                // that lost it rather than install a target-less symlink.
                let Some(target) = entry.symlink_target.clone() else {
                    continue;
                };
                ApplyAction::Symlink { target }
            }
            EntryKind::File => {
                // A file's bytes come from the fetch; without a resolved CAS
                // object there is nothing to install, so skip it.
                let Some(object_id) = object_ids.get(&entry.relative_path) else {
                    continue;
                };
                ApplyAction::File {
                    object_id: *object_id,
                    content_hash: entry.content_hash,
                    length: entry.length,
                    executable: entry.executable,
                }
            }
        };
        let plan_entry = ApplyPlanEntry {
            relative_path: entry.relative_path.clone(),
            action,
            precondition,
        };
        if matches!(plan_entry.action, ApplyAction::Directory { .. }) {
            directories.push(plan_entry);
        } else {
            leaves.push(plan_entry);
        }
    }
    // Sort directories by path so a parent (a shorter '/'-separated prefix)
    // always precedes its children; the leaves then land into them.
    directories.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
    let mut entries = directories;
    entries.extend(leaves);

    ApplyPlan {
        operation_id,
        project,
        target_manifest_root: [0; 32],
        frontier: Vec::new(),
        entries,
    }
}

/// A delete batch is refused when it would remove essentially the whole tree.
///
/// Deletes are the one direction that destroys work, and "the peer has nothing"
/// is exactly what a partial or empty remote manifest looks like — a real bug of
/// that shape (a re-scanned directory descriptor coming back empty) shipped in
/// this codebase and was harmless ONLY because deletes were not applied yet. The
/// guard keeps that class of failure recoverable: an ordinary cleanup passes, a
/// wipe stops the operation with a distinct error the caller can act on.
///
/// Deliberately loose. It is a catastrophe backstop, not a policy knob: blocking
/// a legitimate large deletion is its own kind of broken.
const DELETE_GUARD_MIN_ENTRIES: usize = 10;
const DELETE_GUARD_RATIO_NUMERATOR: usize = 9;
const DELETE_GUARD_RATIO_DENOMINATOR: usize = 10;

/// `Err` when deleting `deletes` of `present` tracked entries looks like a wipe.
pub fn check_delete_guard(deletes: usize, present: usize) -> Result<(), String> {
    if deletes >= DELETE_GUARD_MIN_ENTRIES
        && deletes * DELETE_GUARD_RATIO_DENOMINATOR >= present * DELETE_GUARD_RATIO_NUMERATOR
    {
        return Err("delete_guard_tripped".to_string());
    }
    Ok(())
}

/// An [`ApplyPlan`] that removes `paths` from the working tree.
///
/// Only files and symlinks. A directory's precondition cannot be derived from a
/// manifest entry, and removing one by its CURRENT state would carry off anything
/// created inside it since the scan — so an emptied directory is left in place
/// (it stays listed and simply re-appears as a no-op delete on later syncs).
///
/// Each precondition is the entry's state as the manifest recorded it, so a path
/// modified between the scan and the apply is refused rather than deleted.
pub fn build_delete_plan(
    project: ProjectId,
    operation_id: [u8; 16],
    paths: &[String],
    local: &[ManifestEntry],
) -> ApplyPlan {
    let local_by_path: HashMap<&str, &ManifestEntry> = local
        .iter()
        .map(|entry| (entry.relative_path.as_str(), entry))
        .collect();
    let mut entries: Vec<ApplyPlanEntry> = paths
        .iter()
        .filter_map(|path| {
            let entry = local_by_path.get(path.as_str())?;
            // Absent locally already: nothing to remove.
            let fingerprint = manifest_fingerprint(entry)?;
            Some(ApplyPlanEntry {
                relative_path: path.clone(),
                action: ApplyAction::Delete,
                precondition: ApplyPrecondition::Present(fingerprint),
            })
        })
        .collect();
    entries.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
    ApplyPlan {
        operation_id,
        project,
        target_manifest_root: [0; 32],
        frontier: Vec::new(),
        entries,
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum ManifestWireError {
    Truncated,
    TooLarge,
    BadKind(u8),
    BadUtf8,
}

fn kind_to_byte(kind: EntryKind) -> u8 {
    match kind {
        EntryKind::File => 1,
        EntryKind::Directory => 2,
        EntryKind::Symlink => 3,
    }
}

fn kind_from_byte(byte: u8) -> Result<EntryKind, ManifestWireError> {
    match byte {
        1 => Ok(EntryKind::File),
        2 => Ok(EntryKind::Directory),
        3 => Ok(EntryKind::Symlink),
        other => Err(ManifestWireError::BadKind(other)),
    }
}

/// Encode a manifest entry list for the SyncOperation lane:
/// `[count u32][ per entry: kind u8, exec u8, length u64, hash [32],
///   path_len u32, path, target_len u32, target ]`, all big-endian.
pub fn encode_entries(entries: &[ManifestEntry]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(entries.len() as u32).to_be_bytes());
    for entry in entries {
        out.push(kind_to_byte(entry.kind));
        out.push(u8::from(entry.executable));
        out.extend_from_slice(&entry.length.to_be_bytes());
        out.extend_from_slice(&entry.content_hash);
        let path = entry.relative_path.as_bytes();
        out.extend_from_slice(&(path.len() as u32).to_be_bytes());
        out.extend_from_slice(path);
        let target = entry.symlink_target.as_deref().unwrap_or("").as_bytes();
        out.extend_from_slice(&(target.len() as u32).to_be_bytes());
        out.extend_from_slice(target);
    }
    out
}

struct Reader<'a> {
    input: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], ManifestWireError> {
        let end = self
            .offset
            .checked_add(n)
            .ok_or(ManifestWireError::Truncated)?;
        let slice = self
            .input
            .get(self.offset..end)
            .ok_or(ManifestWireError::Truncated)?;
        self.offset = end;
        Ok(slice)
    }
    fn u32(&mut self) -> Result<u32, ManifestWireError> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64, ManifestWireError> {
        Ok(u64::from_be_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn u8(&mut self) -> Result<u8, ManifestWireError> {
        Ok(self.take(1)?[0])
    }
    fn string(&mut self, len: usize) -> Result<String, ManifestWireError> {
        if len > MAX_PATH_BYTES {
            return Err(ManifestWireError::TooLarge);
        }
        std::str::from_utf8(self.take(len)?)
            .map(str::to_owned)
            .map_err(|_| ManifestWireError::BadUtf8)
    }
}

/// Decode what [`encode_entries`] produced. Bounds every length against
/// `MAX_ENTRIES` / `MAX_PATH_BYTES` since the bytes come from a peer.
pub fn decode_entries(input: &[u8]) -> Result<Vec<ManifestEntry>, ManifestWireError> {
    let mut reader = Reader { input, offset: 0 };
    let count = reader.u32()? as usize;
    if count > MAX_ENTRIES {
        return Err(ManifestWireError::TooLarge);
    }
    let mut entries = Vec::with_capacity(count.min(1024));
    for _ in 0..count {
        let kind = kind_from_byte(reader.u8()?)?;
        let executable = reader.u8()? != 0;
        let length = reader.u64()?;
        let content_hash: [u8; 32] = reader.take(32)?.try_into().unwrap();
        let path_len = reader.u32()? as usize;
        let relative_path = reader.string(path_len)?;
        let target_len = reader.u32()? as usize;
        let symlink_target = if target_len == 0 {
            None
        } else {
            Some(reader.string(target_len)?)
        };
        entries.push(ManifestEntry {
            relative_path,
            kind,
            executable,
            length,
            content_hash,
            symlink_target,
        });
    }
    Ok(entries)
}

/// Encoded byte length one entry contributes to [`encode_entries`] (excludes
/// the list's leading count). Used to size batches by bytes rather than a fixed
/// entry count, so batches stay bounded regardless of path length.
fn entry_encoded_len(entry: &ManifestEntry) -> usize {
    1 + 1 + 8 + 32 + 4 + entry.relative_path.len() + 4 + entry.symlink_target.as_deref().map_or(0, str::len)
}

/// Split a manifest into batch messages for the `SyncOperation` lane, each
/// framed `[final: u8][encode_entries(chunk)]`. Batches are cut on a byte budget
/// ([`MANIFEST_BATCH_BYTES`]) so no single message approaches the lane cap; the
/// last batch (and only it) carries `final = 1`. An empty manifest yields one
/// final empty batch, so the receiver always sees a terminator.
pub fn encode_manifest_batches(entries: &[ManifestEntry]) -> Vec<Vec<u8>> {
    let mut groups: Vec<Vec<&ManifestEntry>> = vec![Vec::new()];
    let mut group_bytes = 0usize;
    for entry in entries {
        let len = entry_encoded_len(entry);
        let current = groups.last_mut().unwrap();
        if !current.is_empty() && group_bytes + len > MANIFEST_BATCH_BYTES {
            groups.push(Vec::new());
            group_bytes = 0;
        }
        groups.last_mut().unwrap().push(entry);
        group_bytes += len;
    }
    let last = groups.len() - 1;
    groups
        .into_iter()
        .enumerate()
        .map(|(index, group)| {
            let owned: Vec<ManifestEntry> = group.into_iter().cloned().collect();
            let mut message = Vec::with_capacity(1 + owned.len() * 96);
            message.push(u8::from(index == last));
            message.extend_from_slice(&encode_entries(&owned));
            message
        })
        .collect()
}

/// Decode one batch message from [`encode_manifest_batches`]:
/// `(is_final, entries)`.
pub fn decode_manifest_batch(
    payload: &[u8],
) -> Result<(bool, Vec<ManifestEntry>), ManifestWireError> {
    let (flag, rest) = payload.split_first().ok_or(ManifestWireError::Truncated)?;
    Ok((*flag != 0, decode_entries(rest)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(path: &str, hash: u8, exec: bool) -> ManifestEntry {
        ManifestEntry {
            relative_path: path.to_string(),
            kind: EntryKind::File,
            executable: exec,
            length: 10,
            content_hash: [hash; 32],
            symlink_target: None,
        }
    }

    fn symlink(path: &str, target: &str) -> ManifestEntry {
        ManifestEntry {
            relative_path: path.to_string(),
            kind: EntryKind::Symlink,
            executable: false,
            length: 0,
            content_hash: [0; 32],
            symlink_target: Some(target.to_string()),
        }
    }

    fn dir(path: &str) -> ManifestEntry {
        ManifestEntry {
            relative_path: path.to_string(),
            kind: EntryKind::Directory,
            executable: true, // directories are searchable
            length: 0,
            content_hash: [0; 32],
            symlink_target: None,
        }
    }

    fn paths(entries: &[FetchEntry]) -> Vec<&str> {
        entries.iter().map(|e| e.relative_path.as_str()).collect()
    }

    #[test]
    fn bidi_converged_is_empty() {
        let m = vec![file("a", 1, false), file("b", 2, false)];
        assert!(reconcile_bidirectional(&m, &m, &m).is_empty());
    }

    #[test]
    fn bidi_remote_only_change_fetches_local_only_change_pushes() {
        let base = vec![file("a", 1, false), file("b", 1, false)];
        // local changed b; remote changed a; base is the common ancestor.
        let local = vec![file("a", 1, false), file("b", 9, false)];
        let remote = vec![file("a", 9, false), file("b", 1, false)];
        let plan = reconcile_bidirectional(&base, &local, &remote);
        assert_eq!(paths(&plan.fetch), ["a"], "remote-only change → fetch");
        assert_eq!(paths(&plan.push), ["b"], "local-only change → push");
        assert!(plan.conflicts.is_empty());
    }

    #[test]
    fn bidi_add_on_one_side_only() {
        // base empty; local added a, remote added b → push a, fetch b (no conflict).
        let plan = reconcile_bidirectional(&[], &[file("a", 1, false)], &[file("b", 2, false)]);
        assert_eq!(paths(&plan.push), ["a"]);
        assert_eq!(paths(&plan.fetch), ["b"]);
        assert!(plan.conflicts.is_empty());
    }

    #[test]
    fn bidi_both_change_same_path_conflicts() {
        let base = vec![file("a", 1, false)];
        let local = vec![file("a", 2, false)];
        let remote = vec![file("a", 3, false)];
        let plan = reconcile_bidirectional(&base, &local, &remote);
        assert!(plan.fetch.is_empty() && plan.push.is_empty());
        assert_eq!(plan.conflicts.len(), 1);
        let c = &plan.conflicts[0];
        assert_eq!(c.relative_path, "a");
        assert_eq!(c.base.as_ref().unwrap().content_hash, [1; 32]);
        assert_eq!(c.local.as_ref().unwrap().content_hash, [2; 32]);
        assert_eq!(c.remote.as_ref().unwrap().content_hash, [3; 32]);
    }

    #[test]
    fn bidi_add_add_same_path_different_content_conflicts() {
        // no base; both added the same path with different content.
        let plan = reconcile_bidirectional(&[], &[file("a", 2, false)], &[file("a", 3, false)]);
        assert_eq!(plan.conflicts.len(), 1);
        assert!(plan.conflicts[0].base.is_none());
    }

    #[test]
    fn bidi_delete_propagates_both_directions() {
        let base = vec![file("a", 1, false), file("b", 1, false)];
        // local deleted a; remote deleted b (each the other still has).
        let local = vec![file("b", 1, false)];
        let remote = vec![file("a", 1, false)];
        let plan = reconcile_bidirectional(&base, &local, &remote);
        assert_eq!(plan.delete_remote, ["a"], "local deleted a → remote deletes a");
        assert_eq!(plan.delete_local, ["b"], "remote deleted b → local deletes b");
        assert!(plan.conflicts.is_empty() && plan.fetch.is_empty() && plan.push.is_empty());
    }

    #[test]
    fn delete_plan_covers_files_and_symlinks_and_skips_directories() {
        let local = vec![
            file("keep", 1, false),
            file("doomed", 2, false),
            ManifestEntry {
                relative_path: "adir".into(),
                kind: EntryKind::Directory,
                executable: true,
                length: 0,
                content_hash: [0; 32],
                symlink_target: None,
            },
        ];
        let paths = vec!["doomed".to_string(), "adir".to_string(), "never-existed".to_string()];
        let plan = build_delete_plan(ProjectId::from_bytes([7; 32]), [1; 16], &paths, &local);

        // The directory and the unknown path are skipped; only the file is planned.
        assert_eq!(plan.entries.len(), 1);
        assert_eq!(plan.entries[0].relative_path, "doomed");
        assert!(matches!(plan.entries[0].action, ApplyAction::Delete));
        // Preconditioned on the state the manifest recorded, so a file modified
        // between the scan and the apply is refused rather than deleted.
        assert!(matches!(
            plan.entries[0].precondition,
            ApplyPrecondition::Present(_)
        ));
    }

    #[test]
    fn the_delete_guard_allows_ordinary_cleanups_and_stops_a_wipe() {
        // Small batches always pass, whatever the ratio — deleting the only two
        // files in a two-file project is a normal thing to do.
        assert!(check_delete_guard(2, 2).is_ok());
        assert!(check_delete_guard(9, 9).is_ok());
        // A big but partial cleanup passes.
        assert!(check_delete_guard(50, 1000).is_ok());
        assert!(check_delete_guard(500, 1000).is_ok());
        // Wiping essentially everything does not. This is the shape a partial or
        // empty peer manifest takes, which is exactly what must not go through.
        assert!(check_delete_guard(1000, 1000).is_err());
        assert!(check_delete_guard(950, 1000).is_err());
        assert_eq!(
            check_delete_guard(1000, 1000).unwrap_err(),
            "delete_guard_tripped"
        );
    }

    #[test]
    fn bidi_delete_modify_conflicts() {
        let base = vec![file("a", 1, false)];
        // local deleted a; remote modified a → both changed → conflict.
        let plan = reconcile_bidirectional(&base, &[], &[file("a", 9, false)]);
        assert_eq!(plan.conflicts.len(), 1);
        let c = &plan.conflicts[0];
        assert!(c.local.is_none() && c.remote.is_some());
    }

    #[test]
    fn bidi_both_made_same_change_is_converged() {
        let base = vec![file("a", 1, false)];
        let same = vec![file("a", 5, false)];
        // both independently changed a to the SAME content → nothing to do.
        assert!(reconcile_bidirectional(&base, &same, &same).is_empty());
    }

    #[test]
    fn apply_plan_orders_directories_first_and_carries_symlinks() {
        // Remote holds a nested file, its two ancestor directories, and a
        // symlink; the local tree is empty, so every path is fetched. The dirs
        // are listed out of order to prove the plan re-orders them.
        let remote = vec![
            file("dir/deep/a.txt", 1, false),
            dir("dir/deep"),
            symlink("dir/link", "a.txt"),
            dir("dir"),
        ];
        let diff = diff_manifests(&[], &remote);
        // Only the file resolves to a CAS object; dirs/symlinks carry no bytes.
        let mut object_ids = HashMap::new();
        object_ids.insert("dir/deep/a.txt".to_string(), ObjectId([7; 32]));

        let plan = build_apply_plan(
            ProjectId::from_bytes([0x42; 32]),
            [1; 16],
            &diff.fetch,
            &object_ids,
            &[], // empty destination — every entry is an add
        );

        let paths: Vec<&str> = plan
            .entries
            .iter()
            .map(|e| e.relative_path.as_str())
            .collect();
        // Both directories come first, parent before child, then the leaves.
        assert_eq!(&paths[..2], &["dir", "dir/deep"], "dirs first, parent first");
        let first_leaf = plan
            .entries
            .iter()
            .position(|e| !matches!(e.action, ApplyAction::Directory { .. }))
            .unwrap();
        assert!(
            plan.entries[..first_leaf]
                .iter()
                .all(|e| matches!(e.action, ApplyAction::Directory { .. })),
            "no leaf may precede a directory"
        );

        // The symlink carries its inline target; the file its resolved object id.
        let link = plan
            .entries
            .iter()
            .find(|e| e.relative_path == "dir/link")
            .unwrap();
        assert_eq!(
            link.action,
            ApplyAction::Symlink {
                target: "a.txt".to_string()
            }
        );
        let f = plan
            .entries
            .iter()
            .find(|e| e.relative_path == "dir/deep/a.txt")
            .unwrap();
        assert_eq!(
            f.action,
            ApplyAction::File {
                object_id: ObjectId([7; 32]),
                content_hash: [1; 32],
                length: 10,
                executable: false,
            }
        );

        // Add-only sync: every entry expects an absent path, and all four are kept.
        assert_eq!(plan.entries.len(), 4);
        assert!(plan
            .entries
            .iter()
            .all(|e| e.precondition == ApplyPrecondition::Absent));
    }

    #[test]
    fn apply_plan_skips_a_symlink_that_lost_its_target() {
        // A symlink FetchEntry with no inline target is malformed; it must be
        // dropped, not emitted as a target-less symlink.
        let mut broken = fetch_of(&symlink("bad", "x"));
        broken.symlink_target = None;
        let plan = build_apply_plan(
            ProjectId::from_bytes([0x42; 32]),
            [1; 16],
            &[broken],
            &HashMap::new(),
            &[],
        );
        assert!(plan.entries.is_empty());
    }

    #[test]
    fn overwrite_carries_the_local_fingerprint_precondition() {
        // Local holds `f` (content 1) and a symlink `s -> old`; remote changed
        // both. Each overwrite must be guarded by the LOCAL fingerprint so a
        // concurrently-edited destination is refused, not clobbered.
        let local = vec![file("f", 1, false), symlink("s", "old")];
        let remote = vec![file("f", 9, false), symlink("s", "new")];
        let diff = diff_manifests(&local, &remote);
        assert_eq!(diff.fetch.len(), 2);

        let mut object_ids = HashMap::new();
        object_ids.insert("f".to_string(), ObjectId([7; 32]));
        let plan = build_apply_plan(
            ProjectId::from_bytes([0x42; 32]),
            [1; 16],
            &diff.fetch,
            &object_ids,
            &local,
        );

        let f = plan.entries.iter().find(|e| e.relative_path == "f").unwrap();
        assert_eq!(
            f.precondition,
            ApplyPrecondition::Present(PathFingerprint {
                kind: PathKind::File,
                content_hash: [1; 32],
                length: 10,
                executable: false,
                symlink_target: None,
            })
        );
        let s = plan.entries.iter().find(|e| e.relative_path == "s").unwrap();
        // The symlink precondition hashes the LOCAL (old) target, not the remote.
        assert_eq!(
            s.precondition,
            ApplyPrecondition::Present(PathFingerprint {
                kind: PathKind::Symlink,
                content_hash: *blake3::hash(b"old").as_bytes(),
                length: 3,
                executable: false,
                symlink_target: Some("old".to_string()),
            })
        );
    }

    #[test]
    fn overwrite_skips_a_path_currently_held_by_a_directory() {
        // Remote wants a file where the local tree still has a directory; a
        // directory's on-disk fingerprint is not reconstructible, so the entry
        // is deferred rather than emitted with an unverifiable precondition.
        let local = vec![dir("d")];
        let remote = vec![file("d", 1, false)];
        let diff = diff_manifests(&local, &remote);
        let mut object_ids = HashMap::new();
        object_ids.insert("d".to_string(), ObjectId([7; 32]));
        let plan = build_apply_plan(
            ProjectId::from_bytes([0x42; 32]),
            [1; 16],
            &diff.fetch,
            &object_ids,
            &local,
        );
        assert!(
            plan.entries.is_empty(),
            "a file-over-directory overwrite is deferred"
        );
    }

    #[test]
    fn identical_manifests_diff_to_nothing() {
        let m = vec![file("a", 1, false), file("b", 2, false)];
        assert!(diff_manifests(&m, &m).is_empty());
    }

    #[test]
    fn remote_only_path_is_fetched() {
        let local = vec![file("a", 1, false)];
        let remote = vec![file("a", 1, false), file("b", 2, false)];
        let diff = diff_manifests(&local, &remote);
        assert_eq!(diff.delete, Vec::<String>::new());
        assert_eq!(diff.fetch.len(), 1);
        assert_eq!(diff.fetch[0].relative_path, "b");
    }

    #[test]
    fn local_only_path_is_deleted() {
        let local = vec![file("a", 1, false), file("gone", 9, false)];
        let remote = vec![file("a", 1, false)];
        let diff = diff_manifests(&local, &remote);
        assert!(diff.fetch.is_empty());
        assert_eq!(diff.delete, vec!["gone".to_string()]);
    }

    #[test]
    fn changed_content_or_exec_bit_is_fetched() {
        let local = vec![file("a", 1, false), file("b", 2, false)];
        // a: content changed; b: exec bit changed.
        let remote = vec![file("a", 7, false), file("b", 2, true)];
        let diff = diff_manifests(&local, &remote);
        assert!(diff.delete.is_empty());
        let paths: Vec<_> = diff.fetch.iter().map(|e| e.relative_path.as_str()).collect();
        assert_eq!(paths, vec!["a", "b"]);
    }

    #[test]
    fn mixed_add_change_delete() {
        let local = vec![file("keep", 1, false), file("drop", 2, false), file("change", 3, false)];
        let remote = vec![file("keep", 1, false), file("change", 8, false), file("add", 4, false)];
        let diff = diff_manifests(&local, &remote);
        let fetch: Vec<_> = diff.fetch.iter().map(|e| e.relative_path.as_str()).collect();
        assert_eq!(fetch, vec!["change", "add"]);
        assert_eq!(diff.delete, vec!["drop".to_string()]);
    }

    #[test]
    fn wire_codec_round_trips() {
        let entries = vec![
            file("dir/a.txt", 1, false),
            file("dir/b.sh", 2, true),
            symlink("link", "dir/a.txt"),
        ];
        let decoded = decode_entries(&encode_entries(&entries)).unwrap();
        assert_eq!(decoded, entries);
    }

    #[test]
    fn decode_rejects_truncated_and_oversized() {
        assert_eq!(decode_entries(&[0, 0, 0]), Err(ManifestWireError::Truncated));
        // Claims 5 entries but carries none.
        assert_eq!(
            decode_entries(&[0, 0, 0, 5]),
            Err(ManifestWireError::Truncated)
        );
    }

    /// Reassemble a batched manifest by feeding batches to `decode_manifest_batch`
    /// until the final flag, mirroring the receiver loop.
    fn reassemble(batches: &[Vec<u8>]) -> Vec<ManifestEntry> {
        let mut out = Vec::new();
        let mut saw_final = false;
        for batch in batches {
            let (is_final, entries) = decode_manifest_batch(batch).unwrap();
            out.extend(entries);
            if is_final {
                saw_final = true;
                break;
            }
        }
        assert!(saw_final, "batch stream must end with a final batch");
        out
    }

    #[test]
    fn small_manifest_is_a_single_final_batch() {
        let entries = vec![file("a", 1, false), file("b", 2, true)];
        let batches = encode_manifest_batches(&entries);
        assert_eq!(batches.len(), 1);
        assert_eq!(batches[0][0], 1, "the only batch is final");
        assert_eq!(reassemble(&batches), entries);
    }

    #[test]
    fn empty_manifest_still_emits_one_final_batch() {
        let batches = encode_manifest_batches(&[]);
        assert_eq!(batches.len(), 1);
        assert_eq!(batches[0][0], 1);
        assert_eq!(reassemble(&batches), Vec::<ManifestEntry>::new());
    }

    #[test]
    fn large_manifest_spans_many_batches_and_round_trips() {
        // Long paths force several 512 KiB batches well before MAX_ENTRIES.
        let entries: Vec<ManifestEntry> = (0..40_000)
            .map(|i| file(&format!("deeply/nested/path/segment/file-{i:08}.dat"), (i % 251) as u8, i % 2 == 0))
            .collect();
        let batches = encode_manifest_batches(&entries);
        assert!(batches.len() > 1, "a large manifest must page into >1 batch");
        // Only the last batch is final.
        for (index, batch) in batches.iter().enumerate() {
            let expected = u8::from(index == batches.len() - 1);
            assert_eq!(batch[0], expected, "final flag wrong at batch {index}");
            assert!(batch.len() <= MANIFEST_BATCH_BYTES + 4096, "batch {index} exceeds budget");
        }
        assert_eq!(reassemble(&batches), entries);
    }
}
