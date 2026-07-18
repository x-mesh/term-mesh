//! Turning reconciled conflict PATHS into classified conflict RECORDS (BD-4b).
//!
//! [`reconcile_bidirectional`](super::reconcile_bidirectional) works on manifest
//! metadata, so all it can say is "both sides changed this path since the base".
//! [`merge_file`] classifies the conflict — text vs binary, add/add vs
//! delete/modify, an executable-bit flip — but it needs the three sides' actual
//! BYTES. This module reads them:
//!
//! - **local** from the working tree,
//! - **remote** from CAS, staged by the fetch phase (requested but deliberately
//!   left out of the apply plan, so pulling a conflicting file never overwrites
//!   the local edit),
//! - **base** from CAS via the base object map ([`ApplyStore::load_base_objects`]).
//!
//! The base is not optional. Without it a path deleted locally and modified
//! remotely reaches `merge_file` as `(None, None, Some)`, matches its
//! `local == base` early return, and RESOLVES TO REMOTE — silently resurrecting
//! the deleted file. So a path whose base content cannot be read is reported as
//! unclassified rather than merged on partial information.
//!
//! Nothing here writes to the working tree. A conflicting path is left untouched
//! on both peers until it is resolved.

use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use super::{
    merge_file, CasStore, ConflictContent, ConflictPath, ConflictSet, EntryKind, FetchEntry,
    MergeOutcome, ObjectDomain, ObjectId, ThreeWayFile,
};

/// Why a conflicting path could not be classified. Each variant leaves the path
/// untouched on both sides; they differ in what is needed to make progress.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnclassifiedReason {
    /// A directory or symlink is involved. `merge_file` compares file content, so
    /// kind-level conflicts (a path that is a directory here and a file there)
    /// need their own classification.
    NotAFile,
    /// The base manifest says this path had a base, its content is not
    /// recoverable, AND one side is absent. Fabricating `base = None` there hits
    /// `merge_file`'s `local == base` early return and resurrects a deletion —
    /// see the module note. (With both sides present the same fabrication is
    /// harmless, so that case is classified as an add/add instead.)
    BaseContentUnavailable,
    /// The peer's side of the conflict was never staged, so there is nothing to
    /// compare against (a fetch that skipped the path, e.g. it vanished between
    /// the manifest exchange and the request).
    RemoteContentUnavailable,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unclassified {
    pub relative_path: String,
    pub reason: UnclassifiedReason,
}

/// The result of reading and classifying every conflicting path.
pub struct ConflictScan {
    /// Conflicts `merge_file` classified, keyed by conflict id.
    pub set: ConflictSet,
    /// Paths that turned out to agree once their content was read. The reconcile
    /// compares manifest state, which can differ while the bytes do not.
    pub converged: Vec<String>,
    /// Paths left for a human or a later phase.
    pub unclassified: Vec<Unclassified>,
}

impl ConflictScan {
    /// Every path the scan saw — classified or not. This is what a caller should
    /// report as "conflicts", since an unclassified path is still unsynced.
    pub fn outstanding(&self) -> usize {
        self.set.len() + self.unclassified.len()
    }
}

/// Read the three sides of each conflicting path and classify it.
///
/// `remote_objects` is the fetch phase's staged-object map and `base_objects` the
/// stored base object map; `root` is the local working tree.
pub fn scan_conflicts(
    conflicts: &[ConflictPath],
    cas: &CasStore,
    domain: ObjectDomain,
    root: &Path,
    remote_objects: &HashMap<String, ObjectId>,
    base_objects: &BTreeMap<String, ObjectId>,
) -> Result<ConflictScan, String> {
    let mut scan = ConflictScan {
        set: ConflictSet::new(domain).map_err(|_| "conflict_domain_invalid".to_string())?,
        converged: Vec::new(),
        unclassified: Vec::new(),
    };
    for conflict in conflicts {
        let path = conflict.relative_path.clone();
        if let Some(reason) = unclassifiable(conflict) {
            scan.unclassified.push(Unclassified {
                relative_path: path,
                reason,
            });
            continue;
        }
        let local = match conflict.local.as_ref() {
            None => None,
            Some(entry) => Some(local_content(root, domain, entry)?),
        };
        let remote = match conflict.remote.as_ref() {
            None => None,
            Some(entry) => match remote_objects.get(&path) {
                None => {
                    scan.unclassified.push(Unclassified {
                        relative_path: path,
                        reason: UnclassifiedReason::RemoteContentUnavailable,
                    });
                    continue;
                }
                Some(object_id) => Some(cas_content(cas, domain, *object_id, entry.executable)?),
            },
        };
        let base = match conflict.base.as_ref() {
            None => None,
            Some(entry) => {
                // A base entry has no CAS object when the path was never
                // transferred (both peers already had it) — or when its object was
                // collected. Either way the base BYTES are gone.
                let recovered = base_objects
                    .get(&path)
                    .and_then(|object_id| read_plaintext(cas, domain, *object_id).ok());
                match recovered {
                    Some(bytes) => Some(content(domain, bytes, entry.executable)?),
                    // Falling back to `base = None` is only safe with both sides
                    // present: then no early return fires and the conflict reads
                    // as an add/add, which is honest — we have no recorded base.
                    // With a side missing it would resurrect a deletion, so stop.
                    None if conflict.local.is_none() || conflict.remote.is_none() => {
                        scan.unclassified.push(Unclassified {
                            relative_path: path,
                            reason: UnclassifiedReason::BaseContentUnavailable,
                        });
                        continue;
                    }
                    None => None,
                }
            }
        };

        let input = ThreeWayFile::new(domain, path.clone(), base, local, remote)
            .map_err(|_| "conflict_input_invalid".to_string())?;
        match merge_file(input).map_err(|_| "conflict_merge_failed".to_string())? {
            MergeOutcome::Conflict(record) => {
                scan.set
                    .insert(record)
                    .map_err(|_| "conflict_insert_failed".to_string())?;
            }
            MergeOutcome::Resolved(_) => scan.converged.push(path),
        }
    }
    Ok(scan)
}

/// A conflict `merge_file` cannot take, decided from metadata alone.
fn unclassifiable(conflict: &ConflictPath) -> Option<UnclassifiedReason> {
    let sides = [
        conflict.base.as_ref(),
        conflict.local.as_ref(),
        conflict.remote.as_ref(),
    ];
    sides
        .into_iter()
        .flatten()
        .any(|entry| entry.kind != EntryKind::File)
        .then_some(UnclassifiedReason::NotAFile)
}

fn local_content(
    root: &Path,
    domain: ObjectDomain,
    entry: &FetchEntry,
) -> Result<ConflictContent, String> {
    let bytes = std::fs::read(root.join(&entry.relative_path))
        .map_err(|_| "conflict_read_failed".to_string())?;
    content(domain, bytes, entry.executable)
}

fn cas_content(
    cas: &CasStore,
    domain: ObjectDomain,
    object_id: ObjectId,
    executable: bool,
) -> Result<ConflictContent, String> {
    let bytes = read_plaintext(cas, domain, object_id)?;
    content(domain, bytes, executable)
}

fn read_plaintext(
    cas: &CasStore,
    domain: ObjectDomain,
    object_id: ObjectId,
) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    cas.copy_verified_plaintext(domain, object_id, &mut bytes)
        .map_err(|_| "conflict_cas_read_failed".to_string())?;
    Ok(bytes)
}

/// `ConflictContent::new` re-derives the content address and rejects a mismatch,
/// so the id is computed here rather than carried in from the manifest — the
/// manifest's `content_hash` is not an `ObjectId`.
fn content(
    domain: ObjectDomain,
    bytes: Vec<u8>,
    executable: bool,
) -> Result<ConflictContent, String> {
    let object_id = ObjectId::for_plaintext(domain, &bytes);
    ConflictContent::new(domain, object_id, bytes, executable)
        .map_err(|_| "conflict_content_invalid".to_string())
}

// ── resolution (BD-4c) ──────────────────────────────────────────────────────

use std::sync::Mutex;

use super::{
    put_plaintext, ApplyAction, ApplyPlan, ApplyPlanEntry, ApplyPrecondition, ApplyStore,
    ConflictResolution, KeyId, ManifestEntry, ProjectKey,
};

/// What a resolution changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolutionOutcome {
    /// Paths written (or deleted) in the working tree.
    pub paths: Vec<String>,
    /// Conflicts still unresolved for this project.
    pub remaining: usize,
}

/// Apply a decision to one conflict: write the chosen content to the working
/// tree, drop the conflict from the stored set, and re-anchor the base so the
/// decision actually propagates.
///
/// **The base rule is the subtle part.** After resolving, the peer still holds
/// its own version, so what the base says next decides who wins:
///
/// - base ← the resolved content: the peer's version now reads as a remote
///   change and the next sync FETCHES it, silently undoing the resolution;
/// - base ← unchanged: both sides still differ from it, so the same conflict is
///   raised again, forever;
/// - base ← the REMOTE side's content (what the peer currently has): only the
///   local tree differs from the base, so the next sync PUSHES the decision to
///   the peer. Choosing "keep remote" then leaves both sides equal to the base
///   and converges with no transfer at all.
///
/// The third is the only one that makes a resolution stick, so that is what this
/// does. If the peer has moved on since the conflict was recorded, the next
/// reconcile sees a genuine new divergence and raises a fresh conflict — which is
/// correct, not a regression.
#[allow(clippy::too_many_arguments)]
pub fn resolve_conflict(
    apply_store: &Mutex<ApplyStore>,
    cas: &CasStore,
    domain: ObjectDomain,
    root: &Path,
    conflict_id: [u8; 32],
    resolution: ConflictResolution,
    key: &ProjectKey,
    key_id: KeyId,
) -> Result<ResolutionOutcome, String> {
    let project = domain.project_id;
    let store = apply_store
        .lock()
        .map_err(|_| "conflict_store_failed".to_string())?;
    let mut set = store
        .load_conflicts(domain)
        .map_err(|_| "conflict_store_failed".to_string())?;
    let record = set
        .get(conflict_id)
        .ok_or_else(|| "conflict_not_found".to_string())?;
    // The peer's side as it stood when the conflict was recorded — captured
    // before `resolve` consumes the record, because it becomes the new base.
    let remote_side = record.remote().cloned();
    let precondition = record.precondition();
    let resolved = set
        .resolve(precondition, resolution)
        .map_err(|_| "conflict_resolution_rejected".to_string())?;

    let mut entries = Vec::with_capacity(resolved.paths().len());
    for path in resolved.paths() {
        let current = ApplyStore::fingerprint_path(root, project, path)
            .map_err(|_| "conflict_apply_failed".to_string())?;
        let precondition = match current {
            Some(fingerprint) => ApplyPrecondition::Present(fingerprint),
            None => ApplyPrecondition::Absent,
        };
        let action = match resolved.content() {
            None => {
                // Deleting a path that is already gone is a no-op, not an error:
                // the user's decision is already reflected on disk.
                if precondition == ApplyPrecondition::Absent {
                    continue;
                }
                ApplyAction::Delete
            }
            Some(content) => ApplyAction::File {
                object_id: put_plaintext(cas, domain, key, key_id, content.bytes())?,
                content_hash: *blake3::hash(content.bytes()).as_bytes(),
                length: content.bytes().len() as u64,
                executable: content.executable(),
            },
        };
        entries.push(ApplyPlanEntry {
            relative_path: path.clone(),
            action,
            precondition,
        });
    }

    if !entries.is_empty() {
        let mut operation_id = [0u8; 16];
        getrandom::getrandom(&mut operation_id)
            .map_err(|_| "conflict_apply_failed".to_string())?;
        store
            .apply(
                root,
                cas,
                domain,
                &ApplyPlan {
                    operation_id,
                    project,
                    target_manifest_root: [0; 32],
                    frontier: Vec::new(),
                    entries,
                },
            )
            .map_err(|_| "conflict_apply_failed".to_string())?;
    }

    rebase_onto_remote(&store, cas, domain, resolved.paths(), remote_side.as_ref())?;
    store
        .save_conflicts(project, &set)
        .map_err(|_| "conflict_store_failed".to_string())?;
    Ok(ResolutionOutcome {
        paths: resolved.paths().to_vec(),
        remaining: set.len(),
    })
}

/// Re-anchor the base for `paths` to the peer's side (see [`resolve_conflict`]).
/// A remote side that was absent removes the path from the base entirely, so the
/// local decision reads as an add or a delete rather than a modification.
fn rebase_onto_remote(
    store: &ApplyStore,
    cas: &CasStore,
    domain: ObjectDomain,
    paths: &[String],
    remote: Option<&ConflictContent>,
) -> Result<(), String> {
    let project = domain.project_id;
    let mut base = store
        .load_base_manifest(project)
        .map_err(|_| "conflict_store_failed".to_string())?;
    let mut objects = store
        .load_base_objects(project)
        .map_err(|_| "conflict_store_failed".to_string())?;
    for path in paths {
        base.retain(|entry| &entry.relative_path != path);
        objects.remove(path);
        let Some(content) = remote else { continue };
        base.push(ManifestEntry {
            relative_path: path.clone(),
            kind: EntryKind::File,
            executable: content.executable(),
            length: content.bytes().len() as u64,
            content_hash: *blake3::hash(content.bytes()).as_bytes(),
            symlink_target: None,
        });
        // The base must be READABLE later, so the peer's bytes go into CAS under
        // this daemon's current key rather than relying on the staged copy the
        // sync happened to leave behind.
        let material = cas
            .current_project_key(project)
            .map_err(|_| "conflict_apply_failed".to_string())?;
        let object_id = put_plaintext(
            cas,
            domain,
            &material.key,
            material.key_id,
            content.bytes(),
        )?;
        objects.insert(path.clone(), object_id);
    }
    base.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
    store
        .save_base_manifest(project, &base)
        .map_err(|_| "conflict_store_failed".to_string())?;
    store
        .save_base_objects(project, &objects)
        .map_err(|_| "conflict_store_failed".to_string())?;
    Ok(())
}

/// A conflict rendered for listing over the socket. Content bytes are summarized
/// rather than inlined — a listing must stay small even when a conflict holds
/// megabytes on three sides.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ConflictSummary {
    pub conflict_id: String,
    pub kind: String,
    pub paths: Vec<String>,
    pub base_bytes: Option<u64>,
    pub local_bytes: Option<u64>,
    pub remote_bytes: Option<u64>,
}

pub fn summarize_conflicts(set: &ConflictSet) -> Vec<ConflictSummary> {
    set.iter()
        .map(|record| ConflictSummary {
            conflict_id: hex::encode(record.conflict_id()),
            kind: format!("{:?}", record.kind()),
            paths: record.paths().to_vec(),
            base_bytes: record.base().map(|c| c.bytes().len() as u64),
            local_bytes: record.local().map(|c| c.bytes().len() as u64),
            remote_bytes: record.remote().map(|c| c.bytes().len() as u64),
        })
        .collect()
}
