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
    /// The base manifest says this path had a base, but its content is no longer
    /// readable from CAS. Merging on `base = None` would misclassify — see the
    /// module note on the delete/modify early return.
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
            Some(entry) => match base_objects.get(&path) {
                None => {
                    scan.unclassified.push(Unclassified {
                        relative_path: path,
                        reason: UnclassifiedReason::BaseContentUnavailable,
                    });
                    continue;
                }
                Some(object_id) => match read_plaintext(cas, domain, *object_id) {
                    // The base entry exists but its object was collected or is
                    // damaged: report rather than merge on a fabricated `None`.
                    Err(_) => {
                        scan.unclassified.push(Unclassified {
                            relative_path: path,
                            reason: UnclassifiedReason::BaseContentUnavailable,
                        });
                        continue;
                    }
                    Ok(bytes) => Some(content(domain, bytes, entry.executable)?),
                },
            },
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
