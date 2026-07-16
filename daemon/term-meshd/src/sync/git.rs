use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use flate2::read::ZlibDecoder;
use flate2::write::ZlibEncoder;
use flate2::{Compression, Decompress, FlushDecompress, Status};
use git2::{ObjectType, Oid, Reference};
use memmap2::MmapOptions;
use serde::{Deserialize, Serialize};
use sha1::{Digest, Sha1};

const JOURNAL_VERSION: u16 = 1;
const MAX_PACK_BYTES: u64 = 64 * 1024 * 1024 * 1024;
const MAX_GRAPH_OBJECTS: usize = 10_000_000;
const MAX_GRAPH_BYTES: u64 = 100 * 1024 * 1024 * 1024;
const MAX_DELTA_DEPTH: usize = 64;
const MAX_PACK_OBJECTS: usize = 1_000_000;
const MAX_OBJECT_BYTES: u64 = 128 * 1024 * 1024;
const MAX_IN_MEMORY_BYTES: u64 = 512 * 1024 * 1024;
const MAX_PACKED_REFS_BYTES: u64 = 64 * 1024 * 1024;
const MAX_REFERENCES_PER_OBJECT: usize = 1_000_000;
const MAX_OBJECT_DIRECTORY_ENTRIES: usize = MAX_PACK_OBJECTS + 2;
const MAX_STATE_DIRECTORY_ENTRIES: usize = 100_000;
const MAX_ORPHAN_PACK_COUNT: usize = 16;
const MAX_ORPHAN_PACK_BYTES: u64 = 1024 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitAdvertisement {
    pub original_ref: String,
    pub tip: Oid,
    pub expected_mesh_tip: Option<Oid>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitPhase {
    Prepared,
    Quarantined,
    Promoting,
    Imported,
    Orphan,
    PromoteWrite,
    PackedRefLock,
    LooseRefLock,
    RefRename,
    RefCas,
    RefUpdated,
    Completed,
}

pub trait GitCrashHook {
    fn after_phase(&self, _phase: GitPhase) -> Result<(), GitError> {
        Ok(())
    }
}

pub struct NoGitCrash;
impl GitCrashHook for NoGitCrash {}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct GitJournal {
    version: u16,
    operation_id: String,
    project_binding: String,
    repository_identity: String,
    state_identity: String,
    peer_id: String,
    original_ref: String,
    destination_ref: String,
    tip: String,
    expected_mesh_tip: Option<String>,
    quarantine_id: String,
    pack_checksum: Option<String>,
    target_pack_identity: Option<String>,
    target_tip_existed_before: bool,
    pack_bytes: Option<u64>,
    newly_created: bool,
    orphan: bool,
    phase: GitPhase,
}

pub struct GitReplicationPlane {
    repository_path: PathIdentity,
    storage: GitStorage,
    state: SecureState,
    peer_id: [u8; 32],
}

impl GitReplicationPlane {
    pub fn open(
        repository_path: &Path,
        state_root: &Path,
        peer_id: [u8; 32],
    ) -> Result<Self, GitError> {
        let repository_path_identity = PathIdentity::open(repository_path)?;
        let storage = GitStorage::open(&repository_path_identity.directory)?;
        let state = SecureState::open(state_root)?;
        Ok(Self {
            repository_path: repository_path_identity,
            storage,
            state,
            peer_id,
        })
    }

    pub fn destination_ref(&self, original_ref: &str) -> Result<String, GitError> {
        if !Reference::is_valid_name(original_ref) {
            return Err(GitError::RefRejected);
        }
        let suffix = original_ref
            .strip_prefix("refs/heads/")
            .map(|suffix| format!("heads/{suffix}"))
            .or_else(|| {
                original_ref
                    .strip_prefix("refs/tags/")
                    .map(|suffix| format!("tags/{suffix}"))
            })
            .ok_or(GitError::RefRejected)?;
        if suffix.is_empty() {
            return Err(GitError::RefRejected);
        }
        let peer = hex::encode(self.peer_id);
        let destination = format!("refs/mesh/{peer}/{suffix}");
        sync_protocol::validate_mesh_ref(&peer, &destination).map_err(|_| GitError::RefRejected)?;
        Ok(destination)
    }

    pub fn replicate(
        &self,
        operation_id: [u8; 16],
        advertisement: &GitAdvertisement,
        pack: impl Read,
    ) -> Result<String, GitError> {
        self.replicate_with_hook(operation_id, advertisement, pack, &NoGitCrash)
    }

    pub fn replicate_with_hook(
        &self,
        operation_id: [u8; 16],
        advertisement: &GitAdvertisement,
        pack: impl Read,
        crash: &dyn GitCrashHook,
    ) -> Result<String, GitError> {
        self.revalidate_boundaries()?;
        let target_objects = self.storage.load_objects()?;
        let destination = self.destination_ref(&advertisement.original_ref)?;
        let operation = hex::encode(operation_id);
        validate_hex_component(&operation, 32)?;
        let journal_name = format!("{operation}.json");
        let repository_identity = self.repository_path.identity_string();
        let state_identity = self.state.identity_string();
        let project_binding = project_binding(&repository_identity, &state_identity);
        let mut journal = GitJournal {
            version: JOURNAL_VERSION,
            operation_id: operation.clone(),
            project_binding,
            repository_identity,
            state_identity,
            peer_id: hex::encode(self.peer_id),
            original_ref: advertisement.original_ref.clone(),
            destination_ref: destination.clone(),
            tip: advertisement.tip.to_string(),
            expected_mesh_tip: advertisement.expected_mesh_tip.map(|oid| oid.to_string()),
            quarantine_id: operation.clone(),
            pack_checksum: None,
            target_pack_identity: None,
            target_tip_existed_before: target_objects.contains_key(&advertisement.tip),
            pack_bytes: None,
            newly_created: false,
            orphan: false,
            phase: GitPhase::Prepared,
        };
        let existing = self.state.read_journal(&journal_name)?;
        if let Some(existing) = &existing {
            validate_journal(&journal_name, existing, &journal)?;
        }
        let current = self.current_tip(&destination)?;
        if current == Some(advertisement.tip) {
            self.revalidate_boundaries()?;
            verify_object_map_graph(&target_objects, advertisement.tip)?;
            if existing.is_none() {
                self.state.write_journal(&journal_name, &journal)?;
            }
            self.storage.write_mesh_ref(
                &destination,
                Some(advertisement.tip),
                advertisement.tip,
                &operation,
                crash,
                &self.state,
            )?;
            if let Some(existing) = existing {
                journal = existing;
            }
            journal.phase = GitPhase::Completed;
            journal.orphan = false;
            self.state.write_journal(&journal_name, &journal)?;
            self.state.remove_quarantine(&operation)?;
            return Ok(destination);
        }
        require_expected_tip(current, advertisement.expected_mesh_tip)?;
        if let Some(existing) = existing {
            journal = existing;
            let resumable = matches!(journal.phase, GitPhase::Imported)
                || (matches!(journal.phase, GitPhase::Promoting)
                    && target_objects.contains_key(&advertisement.tip)
                    && verify_object_map_graph(&target_objects, advertisement.tip).is_ok());
            if resumable {
                verify_object_map_graph(&target_objects, advertisement.tip)?;
                if let Err(error) = self.update_ref(&destination, advertisement, &operation, crash)
                {
                    journal.phase = GitPhase::Orphan;
                    journal.orphan = journal.newly_created;
                    self.state.write_journal(&journal_name, &journal)?;
                    return Err(error);
                }
                crash.after_phase(GitPhase::RefCas)?;
                journal.phase = GitPhase::RefUpdated;
                journal.orphan = false;
                self.state.write_journal(&journal_name, &journal)?;
                crash.after_phase(GitPhase::RefUpdated)?;
                journal.phase = GitPhase::Completed;
                self.state.write_journal(&journal_name, &journal)?;
                return Ok(destination);
            }
        } else {
            self.state.write_journal(&journal_name, &journal)?;
            crash.after_phase(GitPhase::Prepared)?;
        }

        self.state.reset_quarantine(&operation)?;
        let mut cleanup = QuarantineCleanup::new(&self.state, operation.clone());
        let mut pack_file = self.state.create_pack_spool(&operation)?;
        copy_bounded(pack, &mut pack_file, MAX_PACK_BYTES)?;
        pack_file.sync_all()?;
        let pack_len = pack_file.metadata()?.len();
        // The file is private, immutable after sync, and held open for the full mapping lifetime.
        let pack_bytes = unsafe { MmapOptions::new().map(&pack_file)? };
        let parsed = ParsedPack::parse(&pack_bytes, &target_objects)?;
        let reachable = parsed.verify_graph(advertisement.tip, &target_objects)?;
        let pack_checksum = parsed.checksum.clone();
        journal.phase = GitPhase::Quarantined;
        journal.pack_checksum = Some(pack_checksum.clone());
        journal.target_pack_identity = Some(format!("pack-{pack_checksum}"));
        journal.pack_bytes = Some(pack_len);
        self.state.write_journal(&journal_name, &journal)?;
        crash.after_phase(GitPhase::Quarantined)?;

        self.revalidate_boundaries()?;
        if !journal.target_tip_existed_before {
            journal.newly_created = true;
            self.state.ensure_orphan_budget(
                &journal_name,
                &pack_checksum,
                journal.pack_bytes.ok_or(GitError::CorruptJournal)?,
                &journal,
            )?;
        }
        journal.phase = GitPhase::Promoting;
        self.state.write_journal(&journal_name, &journal)?;
        crash.after_phase(GitPhase::Promoting)?;
        self.storage.revalidate()?;
        crash.after_phase(GitPhase::PromoteWrite)?;
        for (oid, object) in &parsed.objects {
            if !reachable.contains(oid) || target_objects.contains_key(oid) {
                continue;
            }
            self.storage
                .write_loose_object(*oid, object.kind, &object.data)?;
        }
        journal.phase = GitPhase::Imported;
        self.state.write_journal(&journal_name, &journal)?;
        crash.after_phase(GitPhase::Imported)?;

        if let Err(error) = self.update_ref(&destination, advertisement, &operation, crash) {
            journal.phase = GitPhase::Orphan;
            journal.orphan = journal.newly_created;
            self.state.write_journal(&journal_name, &journal)?;
            return Err(error);
        }
        crash.after_phase(GitPhase::RefCas)?;
        journal.phase = GitPhase::RefUpdated;
        journal.orphan = false;
        self.state.write_journal(&journal_name, &journal)?;
        crash.after_phase(GitPhase::RefUpdated)?;

        journal.phase = GitPhase::Completed;
        self.state.write_journal(&journal_name, &journal)?;
        crash.after_phase(GitPhase::Completed)?;
        self.state.remove_quarantine(&operation)?;
        cleanup.disarm();
        Ok(destination)
    }

    fn revalidate_boundaries(&self) -> Result<(), GitError> {
        self.state.revalidate()?;
        self.repository_path.revalidate()?;
        self.storage.revalidate()?;
        Ok(())
    }

    fn current_tip(&self, name: &str) -> Result<Option<Oid>, GitError> {
        self.revalidate_boundaries()?;
        self.storage.current_mesh_ref(name)
    }

    fn update_ref(
        &self,
        destination: &str,
        advertisement: &GitAdvertisement,
        operation: &str,
        crash: &dyn GitCrashHook,
    ) -> Result<(), GitError> {
        self.revalidate_boundaries()?;
        let current = self.current_tip(destination)?;
        if current == Some(advertisement.tip) {
            return self.storage.write_mesh_ref(
                destination,
                current,
                advertisement.tip,
                operation,
                crash,
                &self.state,
            );
        }
        match (current, advertisement.expected_mesh_tip) {
            (None, None) => {}
            (Some(current), Some(expected)) if current == expected => {}
            _ => return Err(GitError::StaleRef),
        }
        self.storage.write_mesh_ref(
            destination,
            current,
            advertisement.tip,
            operation,
            crash,
            &self.state,
        )
    }
}

fn verify_object_map_graph(objects: &HashMap<Oid, MemoryObject>, tip: Oid) -> Result<(), GitError> {
    ParsedPack {
        checksum: String::new(),
        objects: HashMap::new(),
    }
    .verify_graph(tip, objects)
    .map(|_| ())
}

#[derive(Clone)]
struct MemoryObject {
    kind: ObjectType,
    data: Arc<[u8]>,
}

enum PackBase {
    Object(ObjectType),
    Offset(u64),
    Reference(Oid),
}

struct PackEntry {
    offset: u64,
    base: PackBase,
    data: Arc<[u8]>,
}

#[derive(Clone)]
struct ResolvedObject {
    object: MemoryObject,
    depth: usize,
}

struct ParsedPack {
    checksum: String,
    objects: HashMap<Oid, MemoryObject>,
}

impl ParsedPack {
    fn parse(bytes: &[u8], target: &HashMap<Oid, MemoryObject>) -> Result<Self, GitError> {
        if bytes.len() < 32 || &bytes[..4] != b"PACK" {
            return Err(GitError::CorruptPack);
        }
        let version = u32::from_be_bytes(bytes[4..8].try_into().unwrap());
        if !matches!(version, 2 | 3) {
            return Err(GitError::CorruptPack);
        }
        let count = u32::from_be_bytes(bytes[8..12].try_into().unwrap()) as usize;
        let trailer_at = bytes.len() - 20;
        let encoded_bytes = trailer_at.checked_sub(12).ok_or(GitError::CorruptPack)?;
        if count > MAX_PACK_OBJECTS || count > encoded_bytes {
            return Err(GitError::GraphLimit);
        }
        let digest = Sha1::digest(&bytes[..trailer_at]);
        if digest.as_slice() != &bytes[trailer_at..] {
            return Err(GitError::CorruptPack);
        }
        let mut cursor = 12usize;
        let mut entries = Vec::new();
        let mut declared_inflated_bytes = 0u64;
        entries
            .try_reserve(count)
            .map_err(|_| GitError::GraphLimit)?;
        for _ in 0..count {
            let offset = cursor as u64;
            let (kind, size) = parse_pack_header(bytes, &mut cursor, trailer_at)?;
            charge_declared_inflated(&mut declared_inflated_bytes, size)?;
            let base = match kind {
                1 => PackBase::Object(ObjectType::Commit),
                2 => PackBase::Object(ObjectType::Tree),
                3 => PackBase::Object(ObjectType::Blob),
                4 => PackBase::Object(ObjectType::Tag),
                6 => PackBase::Offset(parse_ofs_base(bytes, &mut cursor, trailer_at, offset)?),
                7 => {
                    if cursor.checked_add(20).is_none_or(|end| end > trailer_at) {
                        return Err(GitError::CorruptPack);
                    }
                    let oid = Oid::from_bytes(&bytes[cursor..cursor + 20])?;
                    cursor += 20;
                    PackBase::Reference(oid)
                }
                _ => return Err(GitError::CorruptPack),
            };
            let (data, consumed) = inflate_exact(&bytes[cursor..trailer_at], size)?;
            cursor = cursor.checked_add(consumed).ok_or(GitError::CorruptPack)?;
            entries.push(PackEntry {
                offset,
                base,
                data: Arc::from(data),
            });
        }
        if cursor != trailer_at {
            return Err(GitError::CorruptPack);
        }

        let mut by_offset = HashMap::new();
        let mut objects = HashMap::new();
        let mut depths = HashMap::new();
        let mut pending = Vec::new();
        by_offset
            .try_reserve(count)
            .map_err(|_| GitError::GraphLimit)?;
        objects
            .try_reserve(count)
            .map_err(|_| GitError::GraphLimit)?;
        depths
            .try_reserve(count)
            .map_err(|_| GitError::GraphLimit)?;
        pending
            .try_reserve(count)
            .map_err(|_| GitError::GraphLimit)?;
        let mut total_bytes = 0u64;
        for entry in entries {
            match resolve_entry(&entry, &by_offset, &objects, &depths, target)? {
                Some(resolved) => {
                    install_resolved(
                        entry.offset,
                        resolved,
                        &mut by_offset,
                        &mut objects,
                        &mut depths,
                        &mut total_bytes,
                    )?;
                }
                None => pending.push(entry),
            }
        }
        while !pending.is_empty() {
            let mut next = Vec::new();
            next.try_reserve(pending.len())
                .map_err(|_| GitError::GraphLimit)?;
            let mut progress = false;
            for entry in pending {
                match resolve_entry(&entry, &by_offset, &objects, &depths, target)? {
                    Some(resolved) => {
                        install_resolved(
                            entry.offset,
                            resolved,
                            &mut by_offset,
                            &mut objects,
                            &mut depths,
                            &mut total_bytes,
                        )?;
                        progress = true;
                    }
                    None => next.push(entry),
                }
            }
            if !progress {
                return Err(GitError::CorruptGraph);
            }
            pending = next;
        }
        Ok(Self {
            checksum: hex::encode(&bytes[trailer_at..]),
            objects,
        })
    }

    fn object(
        &self,
        oid: Oid,
        target: &HashMap<Oid, MemoryObject>,
    ) -> Result<MemoryObject, GitError> {
        if let Some(object) = self.objects.get(&oid) {
            return Ok(object.clone());
        }
        target
            .get(&oid)
            .cloned()
            .ok_or(GitError::MissingObject(oid))
    }

    fn verify_graph(
        &self,
        tip: Oid,
        target: &HashMap<Oid, MemoryObject>,
    ) -> Result<HashSet<Oid>, GitError> {
        let mut pending = vec![(tip, None)];
        let mut seen = HashSet::new();
        let mut bytes = 0u64;
        while let Some((oid, expected)) = pending.pop() {
            seen.try_reserve(1).map_err(|_| GitError::GraphLimit)?;
            if !seen.insert(oid) {
                let object = self.object(oid, target)?;
                if expected.is_some_and(|kind| object.kind != kind) {
                    return Err(GitError::CorruptGraph);
                }
                continue;
            }
            if seen.len() > MAX_GRAPH_OBJECTS {
                return Err(GitError::GraphLimit);
            }
            let object = self.object(oid, target)?;
            if expected.is_some_and(|kind| object.kind != kind) {
                return Err(GitError::CorruptGraph);
            }
            bytes = bytes
                .checked_add(object.data.len() as u64)
                .ok_or(GitError::GraphLimit)?;
            if bytes > MAX_GRAPH_BYTES {
                return Err(GitError::GraphLimit);
            }
            let references = object_references(&object)?;
            pending
                .try_reserve(references.len())
                .map_err(|_| GitError::GraphLimit)?;
            pending.extend(
                references
                    .into_iter()
                    .map(|edge| (edge.oid, Some(edge.expected))),
            );
        }
        if self.objects.keys().any(|oid| !seen.contains(oid)) {
            return Err(GitError::CorruptGraph);
        }
        Ok(seen)
    }
}

fn charge_declared_inflated(total: &mut u64, size: usize) -> Result<(), GitError> {
    *total = total.checked_add(size as u64).ok_or(GitError::GraphLimit)?;
    if *total > MAX_IN_MEMORY_BYTES {
        return Err(GitError::GraphLimit);
    }
    Ok(())
}

fn parse_pack_header(
    bytes: &[u8],
    cursor: &mut usize,
    limit: usize,
) -> Result<(u8, usize), GitError> {
    let first = *bytes.get(*cursor).ok_or(GitError::CorruptPack)?;
    *cursor += 1;
    let kind = (first >> 4) & 7;
    let mut size = (first & 0x0f) as u64;
    let mut shift = 4u32;
    let mut byte = first;
    let mut groups = 0usize;
    while byte & 0x80 != 0 {
        if *cursor >= limit || shift >= 64 {
            return Err(GitError::CorruptPack);
        }
        byte = bytes[*cursor];
        *cursor += 1;
        groups += 1;
        let raw = (byte & 0x7f) as u64;
        if raw > (u64::MAX >> shift) {
            return Err(GitError::CorruptPack);
        }
        let part = raw << shift;
        size = size.checked_add(part).ok_or(GitError::CorruptPack)?;
        shift += 7;
    }
    if groups > 0 && byte & 0x7f == 0 {
        return Err(GitError::CorruptPack);
    }
    if size > MAX_OBJECT_BYTES || size > usize::MAX as u64 {
        return Err(GitError::GraphLimit);
    }
    Ok((kind, size as usize))
}

fn parse_ofs_base(
    bytes: &[u8],
    cursor: &mut usize,
    limit: usize,
    offset: u64,
) -> Result<u64, GitError> {
    let mut byte = *bytes.get(*cursor).ok_or(GitError::CorruptPack)?;
    *cursor += 1;
    let mut distance = (byte & 0x7f) as u64;
    while byte & 0x80 != 0 {
        if *cursor >= limit {
            return Err(GitError::CorruptPack);
        }
        byte = bytes[*cursor];
        *cursor += 1;
        let incremented = distance.checked_add(1).ok_or(GitError::CorruptPack)?;
        if incremented > (u64::MAX >> 7) {
            return Err(GitError::CorruptPack);
        }
        distance = (incremented << 7)
            .checked_add((byte & 0x7f) as u64)
            .ok_or(GitError::CorruptPack)?;
    }
    offset.checked_sub(distance).ok_or(GitError::CorruptPack)
}

fn inflate_exact(input: &[u8], expected: usize) -> Result<(Vec<u8>, usize), GitError> {
    let mut output = Vec::new();
    output
        .try_reserve(expected.checked_add(1).ok_or(GitError::GraphLimit)?)
        .map_err(|_| GitError::GraphLimit)?;
    let mut decoder = Decompress::new(true);
    let status = decoder
        .decompress_vec(input, &mut output, FlushDecompress::Finish)
        .map_err(|_| GitError::CorruptPack)?;
    if status != Status::StreamEnd || output.len() != expected {
        return Err(GitError::CorruptPack);
    }
    Ok((output, decoder.total_in() as usize))
}

fn resolve_entry(
    entry: &PackEntry,
    by_offset: &HashMap<u64, ResolvedObject>,
    objects: &HashMap<Oid, MemoryObject>,
    depths: &HashMap<Oid, usize>,
    target: &HashMap<Oid, MemoryObject>,
) -> Result<Option<ResolvedObject>, GitError> {
    match &entry.base {
        PackBase::Object(kind) => Ok(Some(ResolvedObject {
            object: MemoryObject {
                kind: *kind,
                data: entry.data.clone(),
            },
            depth: 0,
        })),
        PackBase::Offset(offset) => {
            let base = by_offset.get(offset).ok_or(GitError::CorruptPack)?;
            resolve_delta(base, &entry.data).map(Some)
        }
        PackBase::Reference(oid) => {
            if let Some(object) = objects.get(oid) {
                return resolve_delta(
                    &ResolvedObject {
                        object: object.clone(),
                        depth: *depths.get(oid).ok_or(GitError::CorruptGraph)?,
                    },
                    &entry.data,
                )
                .map(Some);
            }
            match target.get(oid) {
                Some(object) => {
                    let base = ResolvedObject {
                        object: object.clone(),
                        depth: 0,
                    };
                    if Oid::hash_object(base.object.kind, &base.object.data)? != *oid {
                        return Err(GitError::CorruptGraph);
                    }
                    resolve_delta(&base, &entry.data).map(Some)
                }
                None => Ok(None),
            }
        }
    }
}

fn resolve_delta(base: &ResolvedObject, delta: &[u8]) -> Result<ResolvedObject, GitError> {
    let depth = base.depth.checked_add(1).ok_or(GitError::GraphLimit)?;
    if depth > MAX_DELTA_DEPTH {
        return Err(GitError::GraphLimit);
    }
    let data = apply_delta(&base.object.data, delta)?;
    Ok(ResolvedObject {
        object: MemoryObject {
            kind: base.object.kind,
            data: Arc::from(data),
        },
        depth,
    })
}

fn install_resolved(
    offset: u64,
    resolved: ResolvedObject,
    by_offset: &mut HashMap<u64, ResolvedObject>,
    objects: &mut HashMap<Oid, MemoryObject>,
    depths: &mut HashMap<Oid, usize>,
    total_bytes: &mut u64,
) -> Result<(), GitError> {
    *total_bytes = total_bytes
        .checked_add(resolved.object.data.len() as u64)
        .ok_or(GitError::GraphLimit)?;
    if *total_bytes > MAX_IN_MEMORY_BYTES {
        return Err(GitError::GraphLimit);
    }
    let oid = Oid::hash_object(resolved.object.kind, &resolved.object.data)?;
    if let Some(existing) = objects.get(&oid) {
        if existing.kind != resolved.object.kind || existing.data != resolved.object.data {
            return Err(GitError::CorruptGraph);
        }
    } else {
        objects.try_reserve(1).map_err(|_| GitError::GraphLimit)?;
        objects.insert(oid, resolved.object.clone());
    }
    depths.insert(oid, resolved.depth);
    by_offset.insert(offset, resolved);
    Ok(())
}

fn apply_delta(base: &[u8], delta: &[u8]) -> Result<Vec<u8>, GitError> {
    let mut cursor = 0usize;
    let base_size = delta_varint(delta, &mut cursor)?;
    let result_size = delta_varint(delta, &mut cursor)?;
    if base_size != base.len() as u64 || result_size > MAX_OBJECT_BYTES {
        return Err(GitError::CorruptPack);
    }
    let mut output = Vec::new();
    output
        .try_reserve(result_size as usize)
        .map_err(|_| GitError::GraphLimit)?;
    while cursor < delta.len() {
        let opcode = delta[cursor];
        cursor += 1;
        if opcode & 0x80 != 0 {
            let mut offset = 0usize;
            let mut size = 0usize;
            for bit in 0..4 {
                if opcode & (1 << bit) != 0 {
                    offset |= (next_delta_byte(delta, &mut cursor)? as usize) << (bit * 8);
                }
            }
            for bit in 0..3 {
                if opcode & (1 << (bit + 4)) != 0 {
                    size |= (next_delta_byte(delta, &mut cursor)? as usize) << (bit * 8);
                }
            }
            if size == 0 {
                size = 0x10000;
            }
            let end = offset.checked_add(size).ok_or(GitError::CorruptPack)?;
            let source = base.get(offset..end).ok_or(GitError::CorruptPack)?;
            output.extend_from_slice(source);
        } else if opcode != 0 {
            let size = opcode as usize;
            let end = cursor.checked_add(size).ok_or(GitError::CorruptPack)?;
            output.extend_from_slice(delta.get(cursor..end).ok_or(GitError::CorruptPack)?);
            cursor = end;
        } else {
            return Err(GitError::CorruptPack);
        }
        if output.len() as u64 > result_size {
            return Err(GitError::CorruptPack);
        }
    }
    if output.len() as u64 != result_size {
        return Err(GitError::CorruptPack);
    }
    Ok(output)
}

fn delta_varint(bytes: &[u8], cursor: &mut usize) -> Result<u64, GitError> {
    let mut value = 0u64;
    let mut shift = 0u32;
    let mut groups = 0usize;
    loop {
        let byte = next_delta_byte(bytes, cursor)?;
        groups += 1;
        let raw = (byte & 0x7f) as u64;
        if raw > (u64::MAX >> shift) {
            return Err(GitError::CorruptPack);
        }
        let part = raw << shift;
        value = value.checked_add(part).ok_or(GitError::CorruptPack)?;
        if byte & 0x80 == 0 {
            if groups > 1 && byte & 0x7f == 0 {
                return Err(GitError::CorruptPack);
            }
            return Ok(value);
        }
        shift = shift.checked_add(7).ok_or(GitError::CorruptPack)?;
        if shift >= 64 {
            return Err(GitError::CorruptPack);
        }
    }
}

fn next_delta_byte(bytes: &[u8], cursor: &mut usize) -> Result<u8, GitError> {
    let byte = *bytes.get(*cursor).ok_or(GitError::CorruptPack)?;
    *cursor += 1;
    Ok(byte)
}

#[derive(Clone, Copy)]
struct ObjectEdge {
    oid: Oid,
    expected: ObjectType,
}

fn push_edge(edges: &mut Vec<ObjectEdge>, edge: ObjectEdge) -> Result<(), GitError> {
    if edges.len() >= MAX_REFERENCES_PER_OBJECT {
        return Err(GitError::GraphLimit);
    }
    edges.try_reserve(1).map_err(|_| GitError::GraphLimit)?;
    edges.push(edge);
    Ok(())
}

fn object_references(object: &MemoryObject) -> Result<Vec<ObjectEdge>, GitError> {
    match object.kind {
        ObjectType::Blob => Ok(Vec::new()),
        ObjectType::Commit => parse_commit_references(&object.data),
        ObjectType::Tree => parse_tree_references(&object.data),
        ObjectType::Tag => parse_tag_reference(&object.data).map(|edge| vec![edge]),
        _ => Err(GitError::CorruptGraph),
    }
}

fn parse_commit_references(data: &[u8]) -> Result<Vec<ObjectEdge>, GitError> {
    let header_end = data
        .windows(2)
        .position(|window| window == b"\n\n")
        .unwrap_or(data.len());
    let header = std::str::from_utf8(&data[..header_end]).map_err(|_| GitError::CorruptGraph)?;
    let mut result = Vec::new();
    let mut tree_count = 0usize;
    for line in header.lines() {
        if let Some(value) = line.strip_prefix("tree ") {
            tree_count += 1;
            push_edge(
                &mut result,
                ObjectEdge {
                    oid: Oid::from_str(value).map_err(|_| GitError::CorruptGraph)?,
                    expected: ObjectType::Tree,
                },
            )?;
        } else if let Some(value) = line.strip_prefix("parent ") {
            push_edge(
                &mut result,
                ObjectEdge {
                    oid: Oid::from_str(value).map_err(|_| GitError::CorruptGraph)?,
                    expected: ObjectType::Commit,
                },
            )?;
        }
    }
    if tree_count != 1 {
        return Err(GitError::CorruptGraph);
    }
    Ok(result)
}

fn parse_tree_references(data: &[u8]) -> Result<Vec<ObjectEdge>, GitError> {
    let mut cursor = 0usize;
    let mut result = Vec::new();
    while cursor < data.len() {
        let space = data[cursor..]
            .iter()
            .position(|byte| *byte == b' ')
            .ok_or(GitError::CorruptGraph)?
            + cursor;
        if space == cursor || !data[cursor..space].iter().all(u8::is_ascii_digit) {
            return Err(GitError::CorruptGraph);
        }
        let expected = match &data[cursor..space] {
            b"40000" | b"040000" => ObjectType::Tree,
            b"160000" => ObjectType::Commit,
            b"100644" | b"100755" | b"120000" => ObjectType::Blob,
            _ => return Err(GitError::CorruptGraph),
        };
        cursor = space + 1;
        let nul = data[cursor..]
            .iter()
            .position(|byte| *byte == 0)
            .ok_or(GitError::CorruptGraph)?
            + cursor;
        if nul == cursor {
            return Err(GitError::CorruptGraph);
        }
        cursor = nul + 1;
        let end = cursor.checked_add(20).ok_or(GitError::CorruptGraph)?;
        push_edge(
            &mut result,
            ObjectEdge {
                oid: Oid::from_bytes(data.get(cursor..end).ok_or(GitError::CorruptGraph)?)?,
                expected,
            },
        )?;
        cursor = end;
    }
    Ok(result)
}

fn parse_tag_reference(data: &[u8]) -> Result<ObjectEdge, GitError> {
    let header = std::str::from_utf8(data).map_err(|_| GitError::CorruptGraph)?;
    let value = header
        .lines()
        .find_map(|line| line.strip_prefix("object "))
        .ok_or(GitError::CorruptGraph)?;
    let declared = header
        .lines()
        .find_map(|line| line.strip_prefix("type "))
        .ok_or(GitError::CorruptGraph)?;
    let expected = match declared {
        "blob" => ObjectType::Blob,
        "tree" => ObjectType::Tree,
        "commit" => ObjectType::Commit,
        "tag" => ObjectType::Tag,
        _ => return Err(GitError::CorruptGraph),
    };
    Ok(ObjectEdge {
        oid: Oid::from_str(value).map_err(|_| GitError::CorruptGraph)?,
        expected,
    })
}

fn copy_bounded(mut input: impl Read, output: &mut impl Write, limit: u64) -> Result<(), GitError> {
    let mut buffer = [0u8; 64 * 1024];
    let mut total = 0u64;
    loop {
        let read = input.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        total = total.checked_add(read as u64).ok_or(GitError::PackLimit)?;
        if total > limit {
            return Err(GitError::PackLimit);
        }
        output.write_all(&buffer[..read])?;
    }
    Ok(())
}

fn validate_journal(
    filename: &str,
    existing: &GitJournal,
    expected: &GitJournal,
) -> Result<(), GitError> {
    validate_journal_structure(filename, existing)?;
    if existing.version != JOURNAL_VERSION
        || existing.operation_id != expected.operation_id
        || existing.project_binding != expected.project_binding
        || existing.repository_identity != expected.repository_identity
        || existing.state_identity != expected.state_identity
        || existing.peer_id != expected.peer_id
        || existing.original_ref != expected.original_ref
        || existing.destination_ref != expected.destination_ref
        || existing.tip != expected.tip
        || existing.expected_mesh_tip != expected.expected_mesh_tip
    {
        return Err(GitError::JournalCollision);
    }
    Ok(())
}

fn validate_journal_structure(filename: &str, journal: &GitJournal) -> Result<(), GitError> {
    let operation = filename
        .strip_suffix(".json")
        .ok_or(GitError::CorruptJournal)?;
    validate_journal_hex(operation, 32)?;
    let original_suffix = journal
        .original_ref
        .strip_prefix("refs/heads/")
        .map(|suffix| format!("heads/{suffix}"))
        .or_else(|| {
            journal
                .original_ref
                .strip_prefix("refs/tags/")
                .map(|suffix| format!("tags/{suffix}"))
        });
    if journal.version != JOURNAL_VERSION
        || journal.operation_id != operation
        || journal.quarantine_id != operation
        || validate_journal_hex(&journal.project_binding, 64).is_err()
        || validate_journal_hex(&journal.peer_id, 64).is_err()
        || !valid_identity(&journal.repository_identity)
        || !valid_identity(&journal.state_identity)
        || project_binding(&journal.repository_identity, &journal.state_identity)
            != journal.project_binding
        || !Reference::is_valid_name(&journal.original_ref)
        || original_suffix.as_deref().is_none_or(str::is_empty)
        || Oid::from_str(&journal.tip).map(|oid| oid.to_string()) != Ok(journal.tip.clone())
        || journal.expected_mesh_tip.as_ref().is_some_and(|value| {
            Oid::from_str(value).map(|oid| oid.to_string()) != Ok(value.clone())
        })
        || !Reference::is_valid_name(&journal.destination_ref)
    {
        return Err(GitError::CorruptJournal);
    }
    let expected_destination = format!(
        "refs/mesh/{}/{}",
        journal.peer_id,
        original_suffix.ok_or(GitError::CorruptJournal)?
    );
    if journal.destination_ref != expected_destination
        || sync_protocol::validate_mesh_ref(&journal.peer_id, &journal.destination_ref).is_err()
    {
        return Err(GitError::CorruptJournal);
    }
    let has_pack = journal.pack_checksum.is_some()
        && journal.pack_bytes.is_some()
        && journal.target_pack_identity.is_some();
    let no_pack = journal.pack_checksum.is_none()
        && journal.pack_bytes.is_none()
        && journal.target_pack_identity.is_none();
    if !has_pack && !no_pack {
        return Err(GitError::CorruptJournal);
    }
    if let Some(checksum) = &journal.pack_checksum {
        validate_journal_hex(checksum, 40)?;
        if journal.target_pack_identity.as_deref() != Some(&format!("pack-{checksum}")) {
            return Err(GitError::CorruptJournal);
        }
    }
    if journal
        .pack_bytes
        .is_some_and(|bytes| bytes == 0 || bytes > MAX_PACK_BYTES)
        || journal.target_tip_existed_before && journal.newly_created
        || journal.orphan != (journal.phase == GitPhase::Orphan)
        || journal.orphan && !journal.newly_created
    {
        return Err(GitError::CorruptJournal);
    }
    let fields_valid = match journal.phase {
        GitPhase::Prepared => !has_pack && !journal.newly_created && !journal.orphan,
        GitPhase::Quarantined => has_pack && !journal.newly_created && !journal.orphan,
        GitPhase::Promoting | GitPhase::Imported => has_pack && !journal.orphan,
        GitPhase::Orphan => has_pack && journal.newly_created && journal.orphan,
        GitPhase::RefUpdated | GitPhase::Completed => {
            !journal.orphan && (!journal.newly_created || has_pack)
        }
        GitPhase::PromoteWrite
        | GitPhase::PackedRefLock
        | GitPhase::LooseRefLock
        | GitPhase::RefRename
        | GitPhase::RefCas => false,
    };
    if !fields_valid {
        return Err(GitError::CorruptJournal);
    }
    Ok(())
}

fn validate_journal_hex(value: &str, length: usize) -> Result<(), GitError> {
    validate_hex_component(value, length).map_err(|_| GitError::CorruptJournal)
}

fn valid_identity(value: &str) -> bool {
    let Some((device, inode)) = value.split_once(':') else {
        return false;
    };
    !device.is_empty()
        && !inode.is_empty()
        && !device.starts_with('+')
        && !inode.starts_with('+')
        && device.parse::<u64>().is_ok()
        && inode.parse::<u64>().is_ok_and(|inode| inode != 0)
}

fn project_binding(repository_identity: &str, state_identity: &str) -> String {
    let mut hasher = blake3::Hasher::new();
    hasher.update(b"term-mesh git project binding v1\0");
    hasher.update(repository_identity.as_bytes());
    hasher.update(state_identity.as_bytes());
    hasher.finalize().to_hex().to_string()
}

fn require_expected_tip(current: Option<Oid>, expected: Option<Oid>) -> Result<(), GitError> {
    match (current, expected) {
        (None, None) => Ok(()),
        (Some(current), Some(expected)) if current == expected => Ok(()),
        _ => Err(GitError::StaleRef),
    }
}

#[derive(Clone, Copy)]
struct FileIdentity {
    device: u64,
    inode: u64,
}

struct PathIdentity {
    path: PathBuf,
    parent: File,
    name: CString,
    directory: File,
    identity: FileIdentity,
}

impl PathIdentity {
    fn open(path: &Path) -> Result<Self, GitError> {
        let parent_path = path.parent().ok_or(GitError::InvalidState)?;
        let name = path.file_name().ok_or(GitError::InvalidState)?;
        let parent = open_path_directory(parent_path)?;
        let name = CString::new(name.as_bytes()).map_err(|_| GitError::InvalidState)?;
        let directory = open_directory_at(parent.as_raw_fd(), &name)?;
        let metadata = directory.metadata()?;
        Ok(Self {
            path: path.to_owned(),
            parent,
            name,
            directory,
            identity: FileIdentity {
                device: metadata.dev(),
                inode: metadata.ino(),
            },
        })
    }

    fn revalidate(&self) -> Result<(), GitError> {
        let stat = stat_at(self.parent.as_raw_fd(), &self.name)?;
        if stat.st_mode & libc::S_IFMT != libc::S_IFDIR
            || stat.st_dev as u64 != self.identity.device
            || stat.st_ino as u64 != self.identity.inode
        {
            return Err(GitError::StateReplaced);
        }
        let reopened = open_directory_at(self.parent.as_raw_fd(), &self.name)?;
        let metadata = reopened.metadata()?;
        if metadata.dev() != self.identity.device || metadata.ino() != self.identity.inode {
            return Err(GitError::StateReplaced);
        }
        Ok(())
    }

    fn identity_string(&self) -> String {
        format!("{}:{}", self.identity.device, self.identity.inode)
    }
}

struct GitStorage {
    root: File,
    common: File,
    common_identity: FileIdentity,
    objects: File,
    objects_identity: FileIdentity,
    device: u64,
}

struct LooseTemp<'a> {
    directory: &'a File,
    name: CString,
    active: bool,
}

impl LooseTemp<'_> {
    fn disarm(&mut self) {
        self.active = false;
    }

    fn cleanup(&mut self) -> Result<(), GitError> {
        if !self.active {
            return Ok(());
        }
        if unsafe { libc::unlinkat(self.directory.as_raw_fd(), self.name.as_ptr(), 0) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
        self.directory.sync_all()?;
        self.active = false;
        Ok(())
    }
}

impl Drop for LooseTemp<'_> {
    fn drop(&mut self) {
        if self.active {
            unsafe {
                libc::unlinkat(self.directory.as_raw_fd(), self.name.as_ptr(), 0);
            }
            let _ = self.directory.sync_all();
        }
    }
}

impl GitStorage {
    fn open(root: &File) -> Result<Self, GitError> {
        let common = resolve_common_directory(root)?;
        let common_metadata = common.metadata()?;
        let device = common_metadata.dev();
        validate_git_directory(&common, device)?;
        let objects = open_directory_at(common.as_raw_fd(), &c_name("objects")?)?;
        validate_git_directory(&objects, device)?;
        let metadata = objects.metadata()?;
        Ok(Self {
            root: root.try_clone()?,
            common,
            common_identity: FileIdentity {
                device: common_metadata.dev(),
                inode: common_metadata.ino(),
            },
            objects,
            objects_identity: FileIdentity {
                device: metadata.dev(),
                inode: metadata.ino(),
            },
            device,
        })
        .and_then(|storage| {
            storage.sweep_loose_temps()?;
            Ok(storage)
        })
    }

    fn revalidate(&self) -> Result<(), GitError> {
        let current = resolve_common_directory(&self.root)?;
        let metadata = current.metadata()?;
        if metadata.dev() != self.common_identity.device
            || metadata.ino() != self.common_identity.inode
        {
            return Err(GitError::StateReplaced);
        }
        validate_child_identity(&self.common, "objects", self.objects_identity)
    }

    fn sweep_loose_temps(&self) -> Result<(), GitError> {
        for_each_directory_name(&self.objects, 258, |prefix| {
            if prefix == "info" || prefix == "pack" {
                return Ok(());
            }
            validate_hex_component(&prefix, 2)?;
            let directory = open_directory_at(self.objects.as_raw_fd(), &c_name(&prefix)?)?;
            validate_git_directory(&directory, self.device)?;
            let mut changed = false;
            for_each_directory_name(&directory, MAX_OBJECT_DIRECTORY_ENTRIES, |name| {
                let Some(suffix) = name.strip_prefix(".tmp-") else {
                    return Ok(());
                };
                validate_hex_component(suffix, 32)?;
                let name = c_name(&name)?;
                let stat = stat_at(directory.as_raw_fd(), &name)?;
                if stat.st_mode & libc::S_IFMT != libc::S_IFREG
                    || stat.st_dev as u64 != self.device
                    || stat.st_uid != unsafe { libc::geteuid() }
                    || stat.st_nlink != 1
                    || stat.st_mode & 0o022 != 0
                {
                    return Err(GitError::InvalidState);
                }
                if unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0) } != 0 {
                    return Err(io::Error::last_os_error().into());
                }
                changed = true;
                Ok(())
            })?;
            if changed {
                directory.sync_all()?;
            }
            Ok(())
        })
    }

    fn load_objects(&self) -> Result<HashMap<Oid, MemoryObject>, GitError> {
        self.revalidate()?;
        let mut objects = HashMap::new();
        let mut total_bytes = 0u64;
        for prefix in directory_names_bounded(&self.objects, 258)? {
            if prefix == "info" || prefix == "pack" {
                continue;
            }
            if validate_hex_component(&prefix, 2).is_err() {
                return Err(GitError::InvalidState);
            }
            let directory = open_directory_at(self.objects.as_raw_fd(), &c_name(&prefix)?)?;
            validate_git_directory(&directory, self.device)?;
            for suffix in directory_names_bounded(&directory, MAX_OBJECT_DIRECTORY_ENTRIES)? {
                validate_hex_component(&suffix, 38)?;
                if objects.len() >= MAX_PACK_OBJECTS {
                    return Err(GitError::GraphLimit);
                }
                let oid = Oid::from_str(&format!("{prefix}{suffix}"))
                    .map_err(|_| GitError::CorruptGraph)?;
                let object = read_loose_object(&directory, &c_name(&suffix)?, oid, self.device)?;
                total_bytes = total_bytes
                    .checked_add(object.data.len() as u64)
                    .ok_or(GitError::GraphLimit)?;
                if total_bytes > MAX_IN_MEMORY_BYTES {
                    return Err(GitError::GraphLimit);
                }
                insert_object(&mut objects, oid, object)?;
            }
        }

        let pack_directory = match open_directory_at(self.objects.as_raw_fd(), &c_name("pack")?) {
            Ok(directory) => directory,
            Err(GitError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(objects);
            }
            Err(error) => return Err(error),
        };
        validate_git_directory(&pack_directory, self.device)?;
        let mut pack_names =
            directory_names_bounded(&pack_directory, MAX_OBJECT_DIRECTORY_ENTRIES)?;
        pack_names.sort();
        for name in pack_names {
            if !name.ends_with(".pack") {
                continue;
            }
            let file = open_git_file_at(&pack_directory, &c_name(&name)?, self.device)?;
            if file.metadata()?.len() > MAX_PACK_BYTES {
                return Err(GitError::PackLimit);
            }
            let bytes = unsafe { MmapOptions::new().map(&file)? };
            let parsed = ParsedPack::parse(&bytes, &objects)?;
            for (oid, object) in parsed.objects {
                if objects.len() >= MAX_PACK_OBJECTS && !objects.contains_key(&oid) {
                    return Err(GitError::GraphLimit);
                }
                total_bytes = total_bytes
                    .checked_add(object.data.len() as u64)
                    .ok_or(GitError::GraphLimit)?;
                if total_bytes > MAX_IN_MEMORY_BYTES {
                    return Err(GitError::GraphLimit);
                }
                insert_object(&mut objects, oid, object)?;
            }
        }
        Ok(objects)
    }

    fn write_loose_object(&self, oid: Oid, kind: ObjectType, data: &[u8]) -> Result<(), GitError> {
        if Oid::hash_object(kind, data)? != oid {
            return Err(GitError::CorruptGraph);
        }
        let object_kind = kind;
        let kind_name = match kind {
            ObjectType::Blob => "blob",
            ObjectType::Tree => "tree",
            ObjectType::Commit => "commit",
            ObjectType::Tag => "tag",
            _ => return Err(GitError::CorruptGraph),
        };
        let expected_oid = oid;
        let oid_text = oid.to_string();
        let directory_name = c_name(&oid_text[..2])?;
        let directory = ensure_git_directory(&self.objects, &directory_name, self.device)?;
        let destination = c_name(&oid_text[2..])?;
        match stat_at(directory.as_raw_fd(), &destination) {
            Ok(_) => {
                let existing =
                    read_loose_object(&directory, &destination, expected_oid, self.device)?;
                return if existing.kind == object_kind && existing.data.as_ref() == data {
                    Ok(())
                } else {
                    Err(GitError::StateReplaced)
                };
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }

        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
        write!(encoder, "{kind_name} {}\0", data.len())?;
        encoder.write_all(data)?;
        let compressed = encoder.finish()?;
        let mut random = [0u8; 16];
        getrandom::getrandom(&mut random).map_err(|_| GitError::Random)?;
        let temporary = c_name(&format!(".tmp-{}", hex::encode(random)))?;
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                temporary.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o444,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error().into());
        }
        let mut temporary_guard = LooseTemp {
            directory: &directory,
            name: temporary.clone(),
            active: true,
        };
        let mut file = unsafe { File::from_raw_fd(fd) };
        let link_result = (|| {
            file.write_all(&compressed)?;
            file.sync_all()?;
            let linked = unsafe {
                libc::linkat(
                    directory.as_raw_fd(),
                    temporary.as_ptr(),
                    directory.as_raw_fd(),
                    destination.as_ptr(),
                    0,
                )
            };
            Ok::<_, GitError>((linked != 0).then(io::Error::last_os_error))
        })();
        drop(file);
        let cleanup_result = temporary_guard.cleanup();
        let link_error = link_result?;
        cleanup_result?;
        if let Some(error) = link_error {
            if error.kind() == io::ErrorKind::AlreadyExists {
                let existing =
                    read_loose_object(&directory, &destination, expected_oid, self.device)?;
                if existing.kind == object_kind && existing.data.as_ref() == data {
                    return Ok(());
                }
                return Err(GitError::StateReplaced);
            }
            return Err(error.into());
        }
        Ok(())
    }

    fn write_mesh_ref(
        &self,
        destination: &str,
        expected: Option<Oid>,
        tip: Oid,
        operation: &str,
        crash: &dyn GitCrashHook,
        state: &SecureState,
    ) -> Result<(), GitError> {
        self.revalidate()?;
        validate_hex_component(operation, 32)?;
        let (parent, leaf) = self
            .ref_parent(destination, true)?
            .ok_or(GitError::RefRejected)?;
        let packed_lock = c_name("packed-refs.lock")?;
        let lock = c_name(&format!(
            "{}.lock",
            leaf.to_str().map_err(|_| GitError::RefRejected)?
        ))?;
        let mut packed_lock_file = acquire_ref_lock(
            &self.common,
            &packed_lock,
            operation,
            &parent,
            &lock,
            self.device,
            state,
            destination,
        )?;
        let mut packed_guard = LooseTemp {
            directory: &self.common,
            name: packed_lock.clone(),
            active: true,
        };
        let created_ms = unix_time_ms()?;
        writeln!(
            packed_lock_file,
            "term-mesh-ref-lock-v1 {operation} {} {created_ms} {tip} {destination}",
            unsafe { libc::getpid() },
        )?;
        packed_lock_file.sync_all()?;
        self.common.sync_all()?;
        if let Err(error) = crash.after_phase(GitPhase::PackedRefLock) {
            drop(packed_lock_file);
            packed_guard.cleanup()?;
            return Err(error);
        }
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                lock.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            drop(packed_lock_file);
            packed_guard.cleanup()?;
            return Err(GitError::RefLocked);
        }
        let mut leaf_guard = LooseTemp {
            directory: &parent,
            name: lock.clone(),
            active: true,
        };
        let mut lock_file = unsafe { File::from_raw_fd(fd) };
        let result = (|| {
            let effective = match read_loose_ref(&parent, &leaf)? {
                Some(loose) => Some(loose),
                None => self.read_packed_ref(destination)?,
            };
            if effective != expected {
                return Err(GitError::StaleRef);
            }
            writeln!(lock_file, "{tip}")?;
            lock_file.sync_all()?;
            crash.after_phase(GitPhase::LooseRefLock)?;
            if unsafe {
                libc::renameat(
                    parent.as_raw_fd(),
                    lock.as_ptr(),
                    parent.as_raw_fd(),
                    leaf.as_ptr(),
                )
            } != 0
            {
                return Err(io::Error::last_os_error().into());
            }
            leaf_guard.disarm();
            parent.sync_all()?;
            crash.after_phase(GitPhase::RefRename)?;
            Ok(())
        })();
        if result.is_err() {
            leaf_guard.cleanup()?;
        }
        drop(packed_lock_file);
        packed_guard.cleanup()?;
        result
    }

    fn current_mesh_ref(&self, destination: &str) -> Result<Option<Oid>, GitError> {
        self.revalidate()?;
        if let Some((parent, leaf)) = self.ref_parent(destination, false)? {
            if let Some(oid) = read_loose_ref(&parent, &leaf)? {
                return Ok(Some(oid));
            }
        }
        self.read_packed_ref(destination)
    }

    fn ref_parent(
        &self,
        destination: &str,
        create: bool,
    ) -> Result<Option<(File, CString)>, GitError> {
        let components = destination
            .strip_prefix("refs/")
            .ok_or(GitError::RefRejected)?
            .split('/')
            .collect::<Vec<_>>();
        if components.len() < 4 || !Reference::is_valid_name(destination) {
            return Err(GitError::RefRejected);
        }
        let mut parent = match if create {
            ensure_git_directory(&self.common, &c_name("refs")?, self.device)
        } else {
            open_directory_at(self.common.as_raw_fd(), &c_name("refs")?)
        } {
            Ok(parent) => parent,
            Err(GitError::Io(error)) if !create && error.kind() == io::ErrorKind::NotFound => {
                return Ok(None);
            }
            Err(error) => return Err(error),
        };
        for component in &components[..components.len() - 1] {
            parent = match if create {
                ensure_git_directory(&parent, &c_name(component)?, self.device)
            } else {
                open_directory_at(parent.as_raw_fd(), &c_name(component)?)
            } {
                Ok(parent) => parent,
                Err(GitError::Io(error)) if !create && error.kind() == io::ErrorKind::NotFound => {
                    return Ok(None);
                }
                Err(error) => return Err(error),
            };
            validate_git_directory(&parent, self.device)?;
        }
        Ok(Some((
            parent,
            c_name(components.last().ok_or(GitError::RefRejected)?)?,
        )))
    }

    fn read_packed_ref(&self, destination: &str) -> Result<Option<Oid>, GitError> {
        let name = c_name("packed-refs")?;
        let mut file = match open_git_file_at(&self.common, &name, self.device) {
            Ok(file) => file,
            Err(GitError::Io(error)) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let before = file.metadata()?;
        if before.len() > MAX_PACKED_REFS_BYTES {
            return Err(GitError::GraphLimit);
        }
        let mut bytes = Vec::new();
        bytes
            .try_reserve(before.len() as usize)
            .map_err(|_| GitError::GraphLimit)?;
        file.read_to_end(&mut bytes)?;
        let after = file.metadata()?;
        if before.dev() != after.dev()
            || before.ino() != after.ino()
            || before.len() != after.len()
            || bytes.len() as u64 != before.len()
        {
            return Err(GitError::StateReplaced);
        }
        parse_packed_ref(&bytes, destination)
    }
}

fn open_git_file_at(parent: &File, name: &CString, device: u64) -> Result<File, GitError> {
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error().into());
    }
    let file = unsafe { File::from_raw_fd(fd) };
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.dev() != device
        || metadata.permissions().mode() & 0o022 != 0
    {
        return Err(GitError::InvalidState);
    }
    Ok(file)
}

fn read_loose_object(
    parent: &File,
    name: &CString,
    expected_oid: Oid,
    device: u64,
) -> Result<MemoryObject, GitError> {
    let file = open_git_file_at(parent, name, device)?;
    let mut decoder = ZlibDecoder::new(file);
    let mut decoded = Vec::new();
    decoded
        .try_reserve(4096)
        .map_err(|_| GitError::GraphLimit)?;
    std::io::Read::by_ref(&mut decoder)
        .take(MAX_OBJECT_BYTES + 129)
        .read_to_end(&mut decoded)?;
    if decoded.len() as u64 > MAX_OBJECT_BYTES + 128 {
        return Err(GitError::GraphLimit);
    }
    let nul = decoded
        .iter()
        .take(128)
        .position(|byte| *byte == 0)
        .ok_or(GitError::CorruptGraph)?;
    let header = std::str::from_utf8(&decoded[..nul]).map_err(|_| GitError::CorruptGraph)?;
    let (kind, size) = header.split_once(' ').ok_or(GitError::CorruptGraph)?;
    let kind = match kind {
        "blob" => ObjectType::Blob,
        "tree" => ObjectType::Tree,
        "commit" => ObjectType::Commit,
        "tag" => ObjectType::Tag,
        _ => return Err(GitError::CorruptGraph),
    };
    let size = size.parse::<u64>().map_err(|_| GitError::CorruptGraph)?;
    let data = decoded.get(nul + 1..).ok_or(GitError::CorruptGraph)?;
    if size != data.len() as u64 || size > MAX_OBJECT_BYTES {
        return Err(GitError::CorruptGraph);
    }
    if Oid::hash_object(kind, data)? != expected_oid {
        return Err(GitError::CorruptGraph);
    }
    Ok(MemoryObject {
        kind,
        data: Arc::from(data),
    })
}

fn insert_object(
    objects: &mut HashMap<Oid, MemoryObject>,
    oid: Oid,
    object: MemoryObject,
) -> Result<(), GitError> {
    if let Some(existing) = objects.get(&oid) {
        if existing.kind != object.kind || existing.data != object.data {
            return Err(GitError::CorruptGraph);
        }
    } else {
        objects.try_reserve(1).map_err(|_| GitError::GraphLimit)?;
        objects.insert(oid, object);
    }
    Ok(())
}

fn parse_packed_ref(bytes: &[u8], destination: &str) -> Result<Option<Oid>, GitError> {
    let text = std::str::from_utf8(bytes).map_err(|_| GitError::CorruptJournal)?;
    let mut names = HashSet::new();
    let mut result = None;
    let mut prior_entry = false;
    for line in text.lines() {
        if line.is_empty() || line.starts_with('#') {
            prior_entry = false;
            continue;
        }
        if let Some(peeled) = line.strip_prefix('^') {
            if !prior_entry || peeled.len() != 40 || Oid::from_str(peeled).is_err() {
                return Err(GitError::CorruptJournal);
            }
            prior_entry = false;
            continue;
        }
        let (oid, name) = line.split_once(' ').ok_or(GitError::CorruptJournal)?;
        names.try_reserve(1).map_err(|_| GitError::GraphLimit)?;
        if oid.len() != 40
            || name.is_empty()
            || name.contains(' ')
            || !Reference::is_valid_name(name)
            || !names.insert(name)
        {
            return Err(GitError::CorruptJournal);
        }
        let oid = Oid::from_str(oid).map_err(|_| GitError::CorruptJournal)?;
        if name == destination {
            result = Some(oid);
        }
        prior_entry = true;
    }
    Ok(result)
}

fn acquire_ref_lock(
    common: &File,
    packed_lock: &CString,
    operation: &str,
    leaf_parent: &File,
    leaf_lock: &CString,
    device: u64,
    state: &SecureState,
    destination: &str,
) -> Result<File, GitError> {
    for attempt in 0..2 {
        let fd = unsafe {
            libc::openat(
                common.as_raw_fd(),
                packed_lock.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd >= 0 {
            return Ok(unsafe { File::from_raw_fd(fd) });
        }
        let error = io::Error::last_os_error();
        if attempt != 0 || error.kind() != io::ErrorKind::AlreadyExists {
            return Err(GitError::RefLocked);
        }
        recover_stale_ref_locks(
            common,
            packed_lock,
            operation,
            leaf_parent,
            leaf_lock,
            device,
            state,
            destination,
        )?;
    }
    Err(GitError::RefLocked)
}

fn recover_stale_ref_locks(
    common: &File,
    packed_lock: &CString,
    _operation: &str,
    leaf_parent: &File,
    leaf_lock: &CString,
    device: u64,
    state: &SecureState,
    destination: &str,
) -> Result<(), GitError> {
    let mut file = open_owned_lock_at(common, packed_lock, device)?;
    if file.metadata()?.len() > 256 {
        return Err(GitError::RefLocked);
    }
    let mut value = String::new();
    file.read_to_string(&mut value)?;
    let fields = value
        .trim_end_matches(['\r', '\n'])
        .split(' ')
        .collect::<Vec<_>>();
    if fields.len() != 6 || fields[0] != "term-mesh-ref-lock-v1" {
        return Err(GitError::RefLocked);
    }
    let pid = fields[2].parse::<i32>().map_err(|_| GitError::RefLocked)?;
    let created_ms = fields[3].parse::<u64>().map_err(|_| GitError::RefLocked)?;
    let tip = Oid::from_str(fields[4]).map_err(|_| GitError::RefLocked)?;
    if fields[5] != destination || !state.authorizes_ref_lock(fields[1], destination, tip)? {
        return Err(GitError::RefLocked);
    }
    let now = unix_time_ms()?;
    let _age = now.checked_sub(created_ms).ok_or(GitError::RefLocked)?;
    if process_is_alive(pid) {
        return Err(GitError::RefLocked);
    }

    match stat_at(leaf_parent.as_raw_fd(), leaf_lock) {
        Ok(_) => {
            let leaf = open_owned_lock_at(leaf_parent, leaf_lock, device)?;
            drop(leaf);
            if unsafe { libc::unlinkat(leaf_parent.as_raw_fd(), leaf_lock.as_ptr(), 0) } != 0 {
                return Err(io::Error::last_os_error().into());
            }
            leaf_parent.sync_all()?;
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    drop(file);
    if unsafe { libc::unlinkat(common.as_raw_fd(), packed_lock.as_ptr(), 0) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    common.sync_all()?;
    Ok(())
}

fn open_owned_lock_at(parent: &File, name: &CString, device: u64) -> Result<File, GitError> {
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(GitError::RefLocked);
    }
    let file = unsafe { File::from_raw_fd(fd) };
    let metadata = file.metadata().map_err(|_| GitError::RefLocked)?;
    if !metadata.file_type().is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.dev() != device
        || metadata.nlink() != 1
        || metadata.permissions().mode() & 0o777 != 0o600
    {
        return Err(GitError::RefLocked);
    }
    Ok(file)
}

fn process_is_alive(pid: i32) -> bool {
    if pid <= 0 {
        return true;
    }
    if unsafe { libc::kill(pid, 0) } == 0 {
        return true;
    }
    io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

fn unix_time_ms() -> Result<u64, GitError> {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| GitError::InvalidState)?
        .as_millis();
    u64::try_from(millis).map_err(|_| GitError::InvalidState)
}

fn read_loose_ref(parent: &File, name: &CString) -> Result<Option<Oid>, GitError> {
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        let error = io::Error::last_os_error();
        return if error.kind() == io::ErrorKind::NotFound {
            Ok(None)
        } else {
            Err(error.into())
        };
    }
    let mut file = unsafe { File::from_raw_fd(fd) };
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file() || metadata.len() > 128 {
        return Err(GitError::SymbolicRef);
    }
    let mut value = String::new();
    file.read_to_string(&mut value)?;
    let value = value.trim_end_matches(['\r', '\n']);
    if value.starts_with("ref:") {
        return Err(GitError::SymbolicRef);
    }
    Oid::from_str(value)
        .map(Some)
        .map_err(|_| GitError::CorruptJournal)
}

fn resolve_common_directory(root: &File) -> Result<File, GitError> {
    let dot_git = c_name(".git")?;
    let git_dir = match stat_at(root.as_raw_fd(), &dot_git) {
        Ok(stat) if stat.st_mode & libc::S_IFMT == libc::S_IFDIR => {
            open_directory_at(root.as_raw_fd(), &dot_git)?
        }
        Ok(stat) if stat.st_mode & libc::S_IFMT == libc::S_IFREG => {
            let marker = read_git_marker(root, &dot_git, stat.st_dev as u64)?;
            let target = marker
                .strip_prefix("gitdir: ")
                .ok_or(GitError::InvalidState)?;
            resolve_directory_value(root, target)?
        }
        Ok(_) => return Err(GitError::InvalidState),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let objects = open_directory_at(root.as_raw_fd(), &c_name("objects")?)?;
            validate_git_directory(&objects, root.metadata()?.dev())?;
            return root.try_clone().map_err(Into::into);
        }
        Err(error) => return Err(error.into()),
    };
    validate_git_directory(&git_dir, git_dir.metadata()?.dev())?;
    let commondir = c_name("commondir")?;
    match stat_at(git_dir.as_raw_fd(), &commondir) {
        Ok(stat) if stat.st_mode & libc::S_IFMT == libc::S_IFREG => {
            let value = read_git_marker(&git_dir, &commondir, stat.st_dev as u64)?;
            resolve_directory_value(&git_dir, &value)
        }
        Ok(_) => Err(GitError::InvalidState),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(git_dir),
        Err(error) => Err(error.into()),
    }
}

fn read_git_marker(parent: &File, name: &CString, device: u64) -> Result<String, GitError> {
    let mut file = open_git_file_at(parent, name, device)?;
    if file.metadata()?.len() > 4096 {
        return Err(GitError::InvalidState);
    }
    let mut bytes = Vec::new();
    bytes.try_reserve(4096).map_err(|_| GitError::GraphLimit)?;
    file.read_to_end(&mut bytes)?;
    let value = std::str::from_utf8(&bytes)
        .map_err(|_| GitError::InvalidState)?
        .trim_end_matches(['\r', '\n']);
    if value.is_empty() || value.contains('\0') {
        return Err(GitError::InvalidState);
    }
    Ok(value.to_owned())
}

fn resolve_directory_value(base: &File, value: &str) -> Result<File, GitError> {
    use std::path::Component;

    let path = Path::new(value);
    let mut current = if path.is_absolute() {
        File::open("/")?
    } else {
        base.try_clone()?
    };
    for component in path.components() {
        let value = match component {
            Component::RootDir | Component::CurDir => continue,
            Component::ParentDir => "..",
            Component::Normal(value) => value.to_str().ok_or(GitError::InvalidState)?,
            Component::Prefix(_) => return Err(GitError::InvalidState),
        };
        current = open_directory_at(current.as_raw_fd(), &c_name(value)?)?;
    }
    Ok(current)
}

struct SecureState {
    anchor: PathIdentity,
    root: File,
    journals: File,
    journals_identity: FileIdentity,
    quarantine: File,
    quarantine_identity: FileIdentity,
    device: u64,
}

#[derive(Clone, Copy)]
struct QuarantineIdentity {
    operation: FileIdentity,
    repository: FileIdentity,
}

impl SecureState {
    fn open(path: &Path) -> Result<Self, GitError> {
        let anchor = PathIdentity::open(path)?;
        let root = anchor.directory.try_clone()?;
        validate_owned_directory(&root, None)?;
        if unsafe { libc::flock(root.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(GitError::StateBusy);
        }
        let device = root.metadata()?.dev();
        let journals = ensure_owned_directory(&root, "git-journals", device)?;
        let quarantine = ensure_owned_directory(&root, "git-quarantine", device)?;
        let journals_metadata = journals.metadata()?;
        let quarantine_metadata = quarantine.metadata()?;
        let state = Self {
            anchor,
            root,
            journals,
            journals_identity: FileIdentity {
                device: journals_metadata.dev(),
                inode: journals_metadata.ino(),
            },
            quarantine,
            quarantine_identity: FileIdentity {
                device: quarantine_metadata.dev(),
                inode: quarantine_metadata.ino(),
            },
            device,
        };
        state.sweep_journal_temps()?;
        state.sweep_quarantines()?;
        Ok(state)
    }

    fn identity_string(&self) -> String {
        self.anchor.identity_string()
    }

    fn revalidate(&self) -> Result<(), GitError> {
        self.anchor.revalidate()?;
        validate_child_identity(&self.root, "git-journals", self.journals_identity)?;
        validate_child_identity(&self.root, "git-quarantine", self.quarantine_identity)?;
        Ok(())
    }

    fn reset_quarantine(&self, operation: &str) -> Result<(), GitError> {
        self.revalidate()?;
        validate_hex_component(operation, 32)?;
        let name = c_name(operation)?;
        match stat_at(self.quarantine.as_raw_fd(), &name) {
            Ok(_) => remove_tree_at(self.quarantine.as_raw_fd(), &name, self.device)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        mkdir_owned(&self.quarantine, &name, self.device)?;
        Ok(())
    }

    fn create_pack_spool(&self, operation: &str) -> Result<File, GitError> {
        self.revalidate()?;
        let operation_dir = open_directory_at(self.quarantine.as_raw_fd(), &c_name(operation)?)?;
        validate_owned_directory(&operation_dir, Some(self.device))?;
        let name = c_name("input.pack")?;
        // `openat` binds creation to the held operation dirfd; pathname swaps cannot redirect it.
        let fd = unsafe {
            libc::openat(
                operation_dir.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error().into());
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }

    fn prepare_quarantine_repo(
        &self,
        operation: &str,
    ) -> Result<(PathBuf, QuarantineIdentity), GitError> {
        self.revalidate()?;
        let operation_name = c_name(operation)?;
        let operation_dir = open_directory_at(self.quarantine.as_raw_fd(), &operation_name)?;
        validate_owned_directory(&operation_dir, Some(self.device))?;
        let operation_meta = operation_dir.metadata()?;
        let repository_name = c_name("repo.git")?;
        let repository_dir = mkdir_owned(&operation_dir, &repository_name, self.device)?;
        let repository_meta = repository_dir.metadata()?;
        let identity = QuarantineIdentity {
            operation: FileIdentity {
                device: operation_meta.dev(),
                inode: operation_meta.ino(),
            },
            repository: FileIdentity {
                device: repository_meta.dev(),
                inode: repository_meta.ino(),
            },
        };
        Ok((
            self.anchor
                .path
                .join("git-quarantine")
                .join(operation)
                .join("repo.git"),
            identity,
        ))
    }

    fn revalidate_quarantine(
        &self,
        operation: &str,
        identity: QuarantineIdentity,
    ) -> Result<(), GitError> {
        self.revalidate()?;
        validate_child_identity(&self.quarantine, operation, identity.operation)?;
        let operation_dir = open_directory_at(self.quarantine.as_raw_fd(), &c_name(operation)?)?;
        validate_child_identity(&operation_dir, "repo.git", identity.repository)?;
        Ok(())
    }

    fn remove_quarantine(&self, operation: &str) -> Result<(), GitError> {
        validate_hex_component(operation, 32)?;
        let name = c_name(operation)?;
        match stat_at(self.quarantine.as_raw_fd(), &name) {
            Ok(_) => remove_tree_at(self.quarantine.as_raw_fd(), &name, self.device),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        }
    }

    fn sweep_quarantines(&self) -> Result<(), GitError> {
        for_each_directory_name(&self.quarantine, MAX_STATE_DIRECTORY_ENTRIES, |name| {
            validate_hex_component(name, 32)?;
            remove_tree_at(self.quarantine.as_raw_fd(), &c_name(name)?, self.device)
        })
    }

    fn sweep_journal_temps(&self) -> Result<(), GitError> {
        for_each_directory_name(&self.journals, MAX_STATE_DIRECTORY_ENTRIES, |name| {
            if let Some(suffix) = name.strip_prefix(".tmp-") {
                validate_hex_component(suffix, 32)?;
                let name = c_name(name)?;
                let stat = stat_at(self.journals.as_raw_fd(), &name)?;
                if stat.st_mode & libc::S_IFMT != libc::S_IFREG
                    || stat.st_uid != unsafe { libc::geteuid() }
                    || stat.st_nlink != 1
                {
                    return Err(GitError::InvalidState);
                }
                if unsafe { libc::unlinkat(self.journals.as_raw_fd(), name.as_ptr(), 0) } != 0 {
                    return Err(io::Error::last_os_error().into());
                }
                self.journals.sync_all()?;
            } else {
                let operation = name.strip_suffix(".json").ok_or(GitError::InvalidState)?;
                validate_hex_component(operation, 32)?;
            }
            Ok(())
        })
    }

    fn ensure_orphan_budget(
        &self,
        current_journal: &str,
        incoming_checksum: &str,
        incoming_bytes: u64,
        expected: &GitJournal,
    ) -> Result<(), GitError> {
        let mut charged = HashSet::new();
        let mut identities = HashMap::new();
        let mut bytes = 0u64;
        for name in directory_names_bounded(&self.journals, MAX_STATE_DIRECTORY_ENTRIES)? {
            if name == current_journal || !name.ends_with(".json") {
                continue;
            }
            let journal = self.read_journal(&name)?.ok_or(GitError::CorruptJournal)?;
            validate_journal_structure(&name, &journal)?;
            if journal.project_binding != expected.project_binding
                || journal.repository_identity != expected.repository_identity
                || journal.state_identity != expected.state_identity
            {
                return Err(GitError::JournalCollision);
            }
            if !journal.newly_created
                || !matches!(
                    journal.phase,
                    GitPhase::Promoting | GitPhase::Imported | GitPhase::Orphan
                )
            {
                continue;
            }
            let checksum = journal
                .pack_checksum
                .clone()
                .ok_or(GitError::CorruptJournal)?;
            let identity = (
                journal.pack_bytes.ok_or(GitError::CorruptJournal)?,
                journal.newly_created,
            );
            if identities
                .insert(checksum.clone(), identity)
                .is_some_and(|prior| prior != identity)
            {
                return Err(GitError::CorruptJournal);
            }
            if charged.insert(checksum) {
                bytes = bytes
                    .checked_add(identity.0)
                    .ok_or(GitError::OrphanBudgetExceeded)?;
            }
        }
        if charged.contains(incoming_checksum) {
            return Ok(());
        }
        if charged.len() >= MAX_ORPHAN_PACK_COUNT
            || bytes
                .checked_add(incoming_bytes)
                .is_none_or(|total| total > MAX_ORPHAN_PACK_BYTES)
        {
            return Err(GitError::OrphanBudgetExceeded);
        }
        Ok(())
    }

    fn read_journal(&self, name: &str) -> Result<Option<GitJournal>, GitError> {
        let name = c_name(name)?;
        let fd = unsafe {
            libc::openat(
                self.journals.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::NotFound {
                Ok(None)
            } else {
                Err(error.into())
            };
        }
        let mut file = unsafe { File::from_raw_fd(fd) };
        validate_owned_file(&file)?;
        if file.metadata()?.len() > 4096 {
            return Err(GitError::CorruptJournal);
        }
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)?;
        let journal: GitJournal =
            serde_json::from_slice(&bytes).map_err(|_| GitError::CorruptJournal)?;
        let name = name.to_str().map_err(|_| GitError::CorruptJournal)?;
        validate_journal_structure(name, &journal)?;
        Ok(Some(journal))
    }

    fn authorizes_ref_lock(
        &self,
        operation: &str,
        destination: &str,
        tip: Oid,
    ) -> Result<bool, GitError> {
        validate_hex_component(operation, 32)?;
        let Some(journal) = self.read_journal(&format!("{operation}.json"))? else {
            return Ok(false);
        };
        Ok(journal.destination_ref == destination
            && journal.tip == tip.to_string()
            && matches!(
                journal.phase,
                GitPhase::Prepared
                    | GitPhase::Imported
                    | GitPhase::RefUpdated
                    | GitPhase::Completed
            ))
    }

    fn write_journal(&self, name: &str, journal: &GitJournal) -> Result<(), GitError> {
        let destination = c_name(name)?;
        let bytes = serde_json::to_vec(journal).map_err(|_| GitError::CorruptJournal)?;
        if bytes.len() > 4096 {
            return Err(GitError::CorruptJournal);
        }
        let mut random = [0u8; 16];
        getrandom::getrandom(&mut random).map_err(|_| GitError::Random)?;
        let temporary = c_name(&format!(".tmp-{}", hex::encode(random)))?;
        let fd = unsafe {
            libc::openat(
                self.journals.as_raw_fd(),
                temporary.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error().into());
        }
        let mut file = unsafe { File::from_raw_fd(fd) };
        validate_owned_file(&file)?;
        let result = (|| {
            file.write_all(&bytes)?;
            file.sync_all()?;
            if unsafe {
                libc::renameat(
                    self.journals.as_raw_fd(),
                    temporary.as_ptr(),
                    self.journals.as_raw_fd(),
                    destination.as_ptr(),
                )
            } != 0
            {
                return Err(GitError::Io(io::Error::last_os_error()));
            }
            self.journals.sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            unsafe {
                libc::unlinkat(self.journals.as_raw_fd(), temporary.as_ptr(), 0);
            }
        }
        result
    }
}

struct QuarantineCleanup<'a> {
    state: &'a SecureState,
    operation: String,
    armed: bool,
}

impl<'a> QuarantineCleanup<'a> {
    fn new(state: &'a SecureState, operation: String) -> Self {
        Self {
            state,
            operation,
            armed: true,
        }
    }
    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for QuarantineCleanup<'_> {
    fn drop(&mut self) {
        if self.armed {
            let _ = self.state.remove_quarantine(&self.operation);
        }
    }
}

fn open_path_directory(path: &Path) -> Result<File, GitError> {
    let path = CString::new(path.as_os_str().as_bytes()).map_err(|_| GitError::InvalidState)?;
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error().into());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn ensure_owned_directory(parent: &File, name: &str, device: u64) -> Result<File, GitError> {
    let name = c_name(name)?;
    if unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EEXIST) {
            return Err(error.into());
        }
    } else {
        parent.sync_all()?;
    }
    let directory = open_directory_at(parent.as_raw_fd(), &name)?;
    validate_owned_directory(&directory, Some(device))?;
    Ok(directory)
}

fn mkdir_owned(parent: &File, name: &CString, device: u64) -> Result<File, GitError> {
    if unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    parent.sync_all()?;
    let directory = open_directory_at(parent.as_raw_fd(), name)?;
    validate_owned_directory(&directory, Some(device))?;
    Ok(directory)
}

fn ensure_git_directory(parent: &File, name: &CString, device: u64) -> Result<File, GitError> {
    let directory = match open_directory_at(parent.as_raw_fd(), name) {
        Ok(directory) => directory,
        Err(GitError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {
            if unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o755) } != 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::AlreadyExists {
                    return Err(error.into());
                }
            }
            parent.sync_all()?;
            open_directory_at(parent.as_raw_fd(), name)?
        }
        Err(error) => return Err(error),
    };
    validate_git_directory(&directory, device)?;
    Ok(directory)
}

fn open_directory_at(parent: RawFd, name: &CString) -> Result<File, GitError> {
    let fd = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error().into());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn validate_owned_directory(file: &File, device: Option<u64>) -> Result<(), GitError> {
    let metadata = file.metadata()?;
    if !metadata.file_type().is_dir()
        || metadata.permissions().mode() & 0o777 != 0o700
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() < 2
        || device.is_some_and(|expected| metadata.dev() != expected)
    {
        return Err(GitError::InvalidState);
    }
    Ok(())
}

fn validate_git_directory(file: &File, device: u64) -> Result<(), GitError> {
    let metadata = file.metadata()?;
    if !metadata.file_type().is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.dev() != device
        || metadata.permissions().mode() & 0o022 != 0
    {
        return Err(GitError::InvalidState);
    }
    Ok(())
}

fn validate_owned_file(file: &File) -> Result<(), GitError> {
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file()
        || metadata.permissions().mode() & 0o777 != 0o600
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() != 1
    {
        return Err(GitError::InvalidState);
    }
    Ok(())
}

fn validate_child_identity(
    parent: &File,
    name: &str,
    identity: FileIdentity,
) -> Result<(), GitError> {
    let name = c_name(name)?;
    let stat = stat_at(parent.as_raw_fd(), &name)?;
    if stat.st_mode & libc::S_IFMT != libc::S_IFDIR
        || stat.st_dev as u64 != identity.device
        || stat.st_ino as u64 != identity.inode
    {
        return Err(GitError::StateReplaced);
    }
    let reopened = open_directory_at(parent.as_raw_fd(), &name)?;
    let metadata = reopened.metadata()?;
    if metadata.dev() != identity.device || metadata.ino() != identity.inode {
        return Err(GitError::StateReplaced);
    }
    Ok(())
}

fn c_name(value: &str) -> Result<CString, GitError> {
    if value.is_empty() || value.as_bytes().contains(&b'/') {
        return Err(GitError::InvalidState);
    }
    CString::new(value).map_err(|_| GitError::InvalidState)
}

fn validate_hex_component(value: &str, length: usize) -> Result<(), GitError> {
    if value.len() != length
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(GitError::InvalidState);
    }
    Ok(())
}

fn stat_at(parent: RawFd, name: &CString) -> io::Result<libc::stat> {
    let mut stat = std::mem::MaybeUninit::uninit();
    if unsafe {
        libc::fstatat(
            parent,
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { stat.assume_init() })
}

fn directory_names(directory: &File) -> Result<Vec<String>, GitError> {
    directory_names_bounded(directory, usize::MAX)
}

fn directory_names_bounded(directory: &File, limit: usize) -> Result<Vec<String>, GitError> {
    let current = c_name(".")?;
    let duplicate = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            current.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if duplicate < 0 {
        return Err(io::Error::last_os_error().into());
    }
    let stream = unsafe { libc::fdopendir(duplicate) };
    if stream.is_null() {
        unsafe { libc::close(duplicate) };
        return Err(io::Error::last_os_error().into());
    }
    let mut names = Vec::new();
    loop {
        unsafe { *libc::__error() = 0 };
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            let error = io::Error::last_os_error();
            unsafe { libc::closedir(stream) };
            return if error.raw_os_error() == Some(0) {
                Ok(names)
            } else {
                Err(error.into())
            };
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        let bytes = name.to_bytes();
        if bytes == b"." || bytes == b".." {
            continue;
        }
        if names.len() >= limit {
            unsafe { libc::closedir(stream) };
            return Err(GitError::GraphLimit);
        }
        if names.try_reserve(1).is_err() {
            unsafe { libc::closedir(stream) };
            return Err(GitError::GraphLimit);
        }
        let value = match std::str::from_utf8(bytes) {
            Ok(value) => value,
            Err(_) => {
                unsafe { libc::closedir(stream) };
                return Err(GitError::InvalidState);
            }
        };
        let mut owned = String::new();
        if owned.try_reserve(value.len()).is_err() {
            unsafe { libc::closedir(stream) };
            return Err(GitError::GraphLimit);
        }
        owned.push_str(value);
        names.push(owned);
    }
}

fn for_each_directory_name(
    directory: &File,
    limit: usize,
    mut visit: impl FnMut(&str) -> Result<(), GitError>,
) -> Result<(), GitError> {
    let current = c_name(".")?;
    let duplicate = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            current.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if duplicate < 0 {
        return Err(io::Error::last_os_error().into());
    }
    let stream = unsafe { libc::fdopendir(duplicate) };
    if stream.is_null() {
        unsafe { libc::close(duplicate) };
        return Err(io::Error::last_os_error().into());
    }
    let mut count = 0usize;
    loop {
        unsafe { *libc::__error() = 0 };
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            let error = io::Error::last_os_error();
            unsafe { libc::closedir(stream) };
            return if error.raw_os_error() == Some(0) {
                Ok(())
            } else {
                Err(error.into())
            };
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        let bytes = name.to_bytes();
        if bytes == b"." || bytes == b".." {
            continue;
        }
        count = count.checked_add(1).ok_or(GitError::GraphLimit)?;
        if count > limit {
            unsafe { libc::closedir(stream) };
            return Err(GitError::GraphLimit);
        }
        let value = match std::str::from_utf8(bytes) {
            Ok(value) => value,
            Err(_) => {
                unsafe { libc::closedir(stream) };
                return Err(GitError::InvalidState);
            }
        };
        if let Err(error) = visit(value) {
            unsafe { libc::closedir(stream) };
            return Err(error);
        }
    }
}

fn remove_tree_at(parent: RawFd, name: &CString, device: u64) -> Result<(), GitError> {
    let stat = stat_at(parent, name)?;
    if stat.st_mode & libc::S_IFMT != libc::S_IFDIR || stat.st_dev as u64 != device {
        return Err(GitError::InvalidState);
    }
    let directory = open_directory_at(parent, name)?;
    for child in directory_names_bounded(&directory, MAX_STATE_DIRECTORY_ENTRIES)? {
        let child = c_name(&child)?;
        let child_stat = stat_at(directory.as_raw_fd(), &child)?;
        if child_stat.st_dev as u64 != device {
            return Err(GitError::InvalidState);
        }
        if child_stat.st_mode & libc::S_IFMT == libc::S_IFDIR {
            remove_tree_at(directory.as_raw_fd(), &child, device)?;
        } else if unsafe { libc::unlinkat(directory.as_raw_fd(), child.as_ptr(), 0) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
    }
    directory.sync_all()?;
    drop(directory);
    if unsafe { libc::unlinkat(parent, name.as_ptr(), libc::AT_REMOVEDIR) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    Ok(())
}

#[derive(Debug)]
pub enum GitError {
    Io(io::Error),
    Git(git2::Error),
    RefRejected,
    SymbolicRef,
    StaleRef,
    CorruptPack,
    CorruptGraph,
    MissingObject(Oid),
    PackLimit,
    GraphLimit,
    CorruptJournal,
    JournalCollision,
    InvalidState,
    StateReplaced,
    StateBusy,
    RefLocked,
    OrphanBudgetExceeded,
    Random,
    Crash,
}

impl From<io::Error> for GitError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}
impl From<git2::Error> for GitError {
    fn from(error: git2::Error) -> Self {
        Self::Git(error)
    }
}
impl std::fmt::Display for GitError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{self:?}")
    }
}
impl std::error::Error for GitError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn object(kind: ObjectType, data: impl AsRef<[u8]>) -> (Oid, MemoryObject) {
        let data: Arc<[u8]> = Arc::from(data.as_ref());
        let oid = Oid::hash_object(kind, &data).unwrap();
        (oid, MemoryObject { kind, data })
    }

    #[test]
    fn adversarial_object_count_header_is_rejected_before_allocation() {
        let mut bytes = Vec::from(&b"PACK\0\0\0\x02\xff\xff\xff\xff"[..]);
        let digest = Sha1::digest(&bytes);
        bytes.extend_from_slice(&digest);
        assert!(matches!(
            ParsedPack::parse(&bytes, &HashMap::new()),
            Err(GitError::GraphLimit)
        ));
    }

    #[test]
    fn declared_inflated_aggregate_is_charged_before_inflate() {
        let mut total = MAX_IN_MEMORY_BYTES - MAX_OBJECT_BYTES;
        charge_declared_inflated(&mut total, MAX_OBJECT_BYTES as usize).unwrap();
        assert!(matches!(
            charge_declared_inflated(&mut total, 1),
            Err(GitError::GraphLimit)
        ));
    }

    #[test]
    fn pack_and_delta_varints_reject_overflow_and_noncanonical_forms() {
        let mut cursor = 0;
        assert!(matches!(
            parse_pack_header(&[0x90, 0], &mut cursor, 2),
            Err(GitError::CorruptPack)
        ));
        let mut overflowing = vec![0x90];
        overflowing.extend(std::iter::repeat_n(0xff, 9));
        overflowing.push(0x7f);
        let mut cursor = 0;
        assert!(matches!(
            parse_pack_header(&overflowing, &mut cursor, overflowing.len()),
            Err(GitError::CorruptPack)
        ));

        let mut cursor = 0;
        assert!(matches!(
            delta_varint(&[0x80, 0], &mut cursor),
            Err(GitError::CorruptPack)
        ));
        let mut cursor = 0;
        assert!(matches!(
            delta_varint(&[0xff; 10], &mut cursor),
            Err(GitError::CorruptPack)
        ));
    }

    #[test]
    fn graph_rejects_wrong_declared_type_and_unreachable_extras() {
        let (blob_oid, blob) = object(ObjectType::Blob, b"payload");
        let commit_data =
            format!("tree {blob_oid}\nauthor a <a@b> 0 +0000\ncommitter a <a@b> 0 +0000\n\nmsg\n");
        let (commit_oid, commit) = object(ObjectType::Commit, commit_data);
        let wrong_type = ParsedPack {
            checksum: String::new(),
            objects: HashMap::from([(commit_oid, commit), (blob_oid, blob.clone())]),
        };
        assert!(matches!(
            wrong_type.verify_graph(commit_oid, &HashMap::new()),
            Err(GitError::CorruptGraph)
        ));

        let (extra_oid, extra) = object(ObjectType::Blob, b"unreachable");
        let unreachable = ParsedPack {
            checksum: String::new(),
            objects: HashMap::from([(blob_oid, blob), (extra_oid, extra)]),
        };
        assert!(matches!(
            unreachable.verify_graph(blob_oid, &HashMap::new()),
            Err(GitError::CorruptGraph)
        ));
    }
}
