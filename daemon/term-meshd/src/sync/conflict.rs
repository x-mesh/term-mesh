use std::collections::BTreeMap;
use std::fmt;

use super::{ObjectDomain, ObjectId, ObjectType, ProjectId};

const CONFLICT_ID_DOMAIN: &[u8] = b"term-mesh conflict v1\0";
const CONFLICT_STATE_DOMAIN: &[u8] = b"term-mesh conflict state v1\0";
pub const MAX_CONFLICT_PATH_BYTES: usize = 4 * 1024;
pub const MAX_CONFLICT_CONTENT_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_CONFLICT_TOTAL_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_CONFLICT_COUNT: usize = 100_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictSide {
    Local,
    Remote,
}

impl ConflictSide {
    fn tag(self) -> u8 {
        match self {
            Self::Local => 1,
            Self::Remote => 2,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConflictPathOrigin {
    source_path: String,
    target_path: String,
    side: ConflictSide,
}

impl ConflictPathOrigin {
    pub(crate) fn new(source_path: String, target_path: String, side: ConflictSide) -> Self {
        Self {
            source_path,
            target_path,
            side,
        }
    }

    pub fn source_path(&self) -> &str {
        &self.source_path
    }

    pub fn target_path(&self) -> &str {
        &self.target_path
    }

    pub fn side(&self) -> ConflictSide {
        self.side
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConflictKind {
    Text,
    Binary,
    AddAddText,
    AddAddBinary,
    DeleteModify { deleted: ConflictSide },
    RenameCycle,
    ExecutableBit,
    CaseCollision,
    UnicodeNormalization,
    UnicodeCaseCollision,
    ExactPathCollision,
}

impl ConflictKind {
    fn tag(&self) -> u8 {
        match self {
            Self::Text => 1,
            Self::Binary => 2,
            Self::AddAddText => 3,
            Self::AddAddBinary => 4,
            Self::DeleteModify {
                deleted: ConflictSide::Local,
            } => 5,
            Self::DeleteModify {
                deleted: ConflictSide::Remote,
            } => 6,
            Self::RenameCycle => 7,
            Self::ExecutableBit => 8,
            Self::CaseCollision => 9,
            Self::UnicodeNormalization => 10,
            Self::UnicodeCaseCollision => 11,
            Self::ExactPathCollision => 12,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConflictContent {
    domain: ObjectDomain,
    content_root: ObjectId,
    bytes: Vec<u8>,
    executable: bool,
}

impl ConflictContent {
    pub fn new(
        domain: ObjectDomain,
        content_root: ObjectId,
        bytes: Vec<u8>,
        executable: bool,
    ) -> Result<Self, ConflictError> {
        validate_file_domain(domain)?;
        if bytes.len() > MAX_CONFLICT_CONTENT_BYTES {
            return Err(ConflictError::BudgetExceeded);
        }
        if ObjectId::for_plaintext(domain, &bytes) != content_root {
            return Err(ConflictError::ContentRootMismatch);
        }
        Ok(Self {
            domain,
            content_root,
            bytes,
            executable,
        })
    }

    pub fn domain(&self) -> ObjectDomain {
        self.domain
    }

    pub fn content_root(&self) -> ObjectId {
        self.content_root
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn executable(&self) -> bool {
        self.executable
    }

    pub fn is_binary(&self) -> bool {
        self.bytes.contains(&0) || std::str::from_utf8(&self.bytes).is_err()
    }

    pub(crate) fn validate(&self) -> Result<(), ConflictError> {
        validate_file_domain(self.domain)?;
        if self.bytes.len() > MAX_CONFLICT_CONTENT_BYTES {
            return Err(ConflictError::BudgetExceeded);
        }
        if ObjectId::for_plaintext(self.domain, &self.bytes) != self.content_root {
            return Err(ConflictError::ContentRootMismatch);
        }
        Ok(())
    }

    fn validate_for_domain(&self, expected_domain: ObjectDomain) -> Result<(), ConflictError> {
        self.validate()?;
        if self.domain != expected_domain {
            return Err(ConflictError::InvalidObjectDomain);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConflictRecord {
    domain: ObjectDomain,
    conflict_id: [u8; 32],
    kind: ConflictKind,
    paths: Vec<String>,
    path_origins: Vec<ConflictPathOrigin>,
    base: Option<ConflictContent>,
    local: Option<ConflictContent>,
    remote: Option<ConflictContent>,
}

impl ConflictRecord {
    pub fn new(
        domain: ObjectDomain,
        kind: ConflictKind,
        paths: Vec<String>,
        base: Option<ConflictContent>,
        local: Option<ConflictContent>,
        remote: Option<ConflictContent>,
    ) -> Result<Self, ConflictError> {
        Self::new_with_origins(domain, kind, paths, Vec::new(), base, local, remote)
    }

    pub(crate) fn new_path_conflict(
        domain: ObjectDomain,
        kind: ConflictKind,
        mut path_origins: Vec<ConflictPathOrigin>,
    ) -> Result<Self, ConflictError> {
        path_origins.sort_by(|left, right| {
            (
                left.source_path.as_str(),
                left.target_path.as_str(),
                left.side.tag(),
            )
                .cmp(&(
                    right.source_path.as_str(),
                    right.target_path.as_str(),
                    right.side.tag(),
                ))
        });
        let paths = path_origins
            .iter()
            .flat_map(|origin| [origin.source_path.clone(), origin.target_path.clone()])
            .collect();
        Self::new_with_origins(domain, kind, paths, path_origins, None, None, None)
    }

    fn new_with_origins(
        domain: ObjectDomain,
        kind: ConflictKind,
        mut paths: Vec<String>,
        path_origins: Vec<ConflictPathOrigin>,
        base: Option<ConflictContent>,
        local: Option<ConflictContent>,
        remote: Option<ConflictContent>,
    ) -> Result<Self, ConflictError> {
        validate_file_domain(domain)?;
        validate_paths(&paths)?;
        validate_path_origins(&path_origins)?;
        validate_contents(domain, &base, &local, &remote)?;
        validate_shape(&kind, &base, &local, &remote)?;
        paths.sort();
        paths.dedup();
        validate_path_shape(&kind, &paths, &path_origins)?;
        let conflict_id =
            conflict_digest(domain, &kind, &paths, &path_origins, &base, &local, &remote);
        Ok(Self {
            domain,
            conflict_id,
            kind,
            paths,
            path_origins,
            base,
            local,
            remote,
        })
    }

    pub fn domain(&self) -> ObjectDomain {
        self.domain
    }

    pub fn conflict_id(&self) -> [u8; 32] {
        self.conflict_id
    }

    pub fn kind(&self) -> &ConflictKind {
        &self.kind
    }

    pub fn paths(&self) -> &[String] {
        &self.paths
    }

    pub fn path_origins(&self) -> &[ConflictPathOrigin] {
        &self.path_origins
    }

    pub fn base(&self) -> Option<&ConflictContent> {
        self.base.as_ref()
    }

    pub fn local(&self) -> Option<&ConflictContent> {
        self.local.as_ref()
    }

    pub fn remote(&self) -> Option<&ConflictContent> {
        self.remote.as_ref()
    }

    pub fn precondition(&self) -> ResolutionPrecondition {
        ResolutionPrecondition {
            conflict_id: self.conflict_id,
            state_hash: state_digest(self),
        }
    }

    pub fn preserves_all_inputs(&self) -> bool {
        true
    }

    fn validate(&self) -> Result<(), ConflictError> {
        validate_file_domain(self.domain)?;
        validate_paths(&self.paths)?;
        validate_path_origins(&self.path_origins)?;
        validate_contents(self.domain, &self.base, &self.local, &self.remote)?;
        validate_shape(&self.kind, &self.base, &self.local, &self.remote)?;
        validate_path_shape(&self.kind, &self.paths, &self.path_origins)?;
        if conflict_digest(
            self.domain,
            &self.kind,
            &self.paths,
            &self.path_origins,
            &self.base,
            &self.local,
            &self.remote,
        ) != self.conflict_id
        {
            return Err(ConflictError::NonCanonicalConflict);
        }
        Ok(())
    }

    fn encoded_size(&self) -> Result<usize, ConflictError> {
        let mut size = 33usize;
        for path in &self.paths {
            size = size
                .checked_add(path.len())
                .ok_or(ConflictError::BudgetExceeded)?;
        }
        for origin in &self.path_origins {
            size = size
                .checked_add(origin.source_path.len())
                .and_then(|value| value.checked_add(origin.target_path.len()))
                .and_then(|value| value.checked_add(1))
                .ok_or(ConflictError::BudgetExceeded)?;
        }
        for content in [&self.base, &self.local, &self.remote]
            .into_iter()
            .flatten()
        {
            size = size
                .checked_add(content.bytes.len())
                .and_then(|value| value.checked_add(75))
                .ok_or(ConflictError::BudgetExceeded)?;
        }
        Ok(size)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResolutionPrecondition {
    conflict_id: [u8; 32],
    state_hash: [u8; 32],
}

impl ResolutionPrecondition {
    pub fn conflict_id(&self) -> [u8; 32] {
        self.conflict_id
    }

    pub fn state_hash(&self) -> [u8; 32] {
        self.state_hash
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConflictResolution {
    KeepBase,
    KeepLocal,
    KeepRemote,
    Delete,
    Content(ConflictContent),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedConflict {
    conflict_id: [u8; 32],
    paths: Vec<String>,
    content: Option<ConflictContent>,
}

impl ResolvedConflict {
    pub fn conflict_id(&self) -> [u8; 32] {
        self.conflict_id
    }

    pub fn paths(&self) -> &[String] {
        &self.paths
    }

    pub fn content(&self) -> Option<&ConflictContent> {
        self.content.as_ref()
    }
}

pub struct ConflictSet {
    expected_domain: ObjectDomain,
    unresolved: BTreeMap<[u8; 32], ConflictRecord>,
    revision: u64,
    encoded_bytes: usize,
}

impl ConflictSet {
    pub fn new(expected_domain: ObjectDomain) -> Result<Self, ConflictError> {
        validate_file_domain(expected_domain)?;
        Ok(Self {
            expected_domain,
            unresolved: BTreeMap::new(),
            revision: 0,
            encoded_bytes: 0,
        })
    }

    pub fn expected_domain(&self) -> ObjectDomain {
        self.expected_domain
    }

    pub fn insert(
        &mut self,
        conflict: ConflictRecord,
    ) -> Result<ResolutionPrecondition, ConflictError> {
        conflict.validate()?;
        if conflict.domain != self.expected_domain {
            return Err(ConflictError::InvalidObjectDomain);
        }
        let precondition = conflict.precondition();
        if let Some(existing) = self.unresolved.get(&conflict.conflict_id) {
            return if existing == &conflict {
                Ok(precondition)
            } else {
                Err(ConflictError::DuplicateConflictId)
            };
        }
        if self.unresolved.len() == MAX_CONFLICT_COUNT {
            return Err(ConflictError::BudgetExceeded);
        }
        let bytes = conflict.encoded_size()?;
        let next_bytes = self
            .encoded_bytes
            .checked_add(bytes)
            .ok_or(ConflictError::BudgetExceeded)?;
        if next_bytes > MAX_CONFLICT_TOTAL_BYTES {
            return Err(ConflictError::BudgetExceeded);
        }
        let next_revision = self
            .revision
            .checked_add(1)
            .ok_or(ConflictError::RevisionOverflow)?;
        self.unresolved.insert(conflict.conflict_id, conflict);
        self.encoded_bytes = next_bytes;
        self.revision = next_revision;
        Ok(precondition)
    }

    pub fn get(&self, conflict_id: [u8; 32]) -> Option<&ConflictRecord> {
        self.unresolved.get(&conflict_id)
    }

    /// The unresolved conflicts in conflict-id order. Stable across calls, so a
    /// listing a user acts on does not reshuffle between reading and resolving.
    pub fn iter(&self) -> impl Iterator<Item = &ConflictRecord> {
        self.unresolved.values()
    }

    pub fn len(&self) -> usize {
        self.unresolved.len()
    }

    pub fn is_empty(&self) -> bool {
        self.unresolved.is_empty()
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn resolve(
        &mut self,
        expected: ResolutionPrecondition,
        resolution: ConflictResolution,
    ) -> Result<ResolvedConflict, ConflictError> {
        let conflict = self
            .unresolved
            .get(&expected.conflict_id)
            .ok_or(ConflictError::StaleResolution)?;
        if conflict.precondition() != expected {
            return Err(ConflictError::StaleResolution);
        }
        let content = match resolution {
            ConflictResolution::KeepBase => conflict
                .base
                .clone()
                .ok_or(ConflictError::InvalidResolution)?,
            ConflictResolution::KeepLocal => conflict
                .local
                .clone()
                .ok_or(ConflictError::InvalidResolution)?,
            ConflictResolution::KeepRemote => conflict
                .remote
                .clone()
                .ok_or(ConflictError::InvalidResolution)?,
            ConflictResolution::Delete => {
                return self.remove_resolved(expected.conflict_id, None);
            }
            ConflictResolution::Content(content) => {
                content.validate_for_domain(self.expected_domain)?;
                content
            }
        };
        self.remove_resolved(expected.conflict_id, Some(content))
    }

    fn remove_resolved(
        &mut self,
        conflict_id: [u8; 32],
        content: Option<ConflictContent>,
    ) -> Result<ResolvedConflict, ConflictError> {
        let conflict = self
            .unresolved
            .get(&conflict_id)
            .ok_or(ConflictError::StaleResolution)?;
        let bytes = conflict.encoded_size()?;
        let next_revision = self
            .revision
            .checked_add(1)
            .ok_or(ConflictError::RevisionOverflow)?;
        let conflict = self
            .unresolved
            .remove(&conflict_id)
            .ok_or(ConflictError::StaleResolution)?;
        self.encoded_bytes = self.encoded_bytes.saturating_sub(bytes);
        self.revision = next_revision;
        Ok(ResolvedConflict {
            conflict_id,
            paths: conflict.paths,
            content,
        })
    }
}

pub(crate) fn validate_path(path: &str) -> Result<(), ConflictError> {
    if path.len() > MAX_CONFLICT_PATH_BYTES {
        return Err(ConflictError::BudgetExceeded);
    }
    if path.is_empty()
        || path.starts_with('/')
        || path.contains('\0')
        || path
            .split('/')
            .any(|component| component.is_empty() || component == "." || component == "..")
    {
        return Err(ConflictError::InvalidPath);
    }
    Ok(())
}

fn validate_paths(paths: &[String]) -> Result<(), ConflictError> {
    if paths.is_empty() {
        return Err(ConflictError::InvalidPath);
    }
    let mut total = 0usize;
    for path in paths {
        validate_path(path)?;
        total = total
            .checked_add(path.len())
            .ok_or(ConflictError::BudgetExceeded)?;
    }
    if total > MAX_CONFLICT_TOTAL_BYTES {
        return Err(ConflictError::BudgetExceeded);
    }
    Ok(())
}

fn validate_path_origins(origins: &[ConflictPathOrigin]) -> Result<(), ConflictError> {
    let mut total = 0usize;
    for origin in origins {
        validate_path(&origin.source_path)?;
        validate_path(&origin.target_path)?;
        total = total
            .checked_add(origin.source_path.len())
            .and_then(|value| value.checked_add(origin.target_path.len()))
            .ok_or(ConflictError::BudgetExceeded)?;
    }
    if total > MAX_CONFLICT_TOTAL_BYTES {
        return Err(ConflictError::BudgetExceeded);
    }
    Ok(())
}

fn validate_contents(
    expected_domain: ObjectDomain,
    base: &Option<ConflictContent>,
    local: &Option<ConflictContent>,
    remote: &Option<ConflictContent>,
) -> Result<(), ConflictError> {
    let mut total = 0usize;
    for content in [base, local, remote].into_iter().flatten() {
        content.validate_for_domain(expected_domain)?;
        total = total
            .checked_add(content.bytes.len())
            .ok_or(ConflictError::BudgetExceeded)?;
    }
    if total > MAX_CONFLICT_TOTAL_BYTES {
        return Err(ConflictError::BudgetExceeded);
    }
    Ok(())
}

fn validate_shape(
    kind: &ConflictKind,
    base: &Option<ConflictContent>,
    local: &Option<ConflictContent>,
    remote: &Option<ConflictContent>,
) -> Result<(), ConflictError> {
    let binary = |content: &Option<ConflictContent>| {
        content.as_ref().is_some_and(ConflictContent::is_binary)
    };
    let valid = match kind {
        ConflictKind::Text => {
            base.is_some()
                && local.is_some()
                && remote.is_some()
                && !binary(base)
                && !binary(local)
                && !binary(remote)
        }
        ConflictKind::Binary => {
            base.is_some()
                && local.is_some()
                && remote.is_some()
                && (binary(base) || binary(local) || binary(remote))
        }
        ConflictKind::AddAddText => {
            base.is_none()
                && local.is_some()
                && remote.is_some()
                && !binary(local)
                && !binary(remote)
        }
        ConflictKind::AddAddBinary => {
            base.is_none()
                && local.is_some()
                && remote.is_some()
                && (binary(local) || binary(remote))
        }
        ConflictKind::DeleteModify {
            deleted: ConflictSide::Local,
        } => base.is_some() && local.is_none() && remote.is_some() && remote != base,
        ConflictKind::DeleteModify {
            deleted: ConflictSide::Remote,
        } => base.is_some() && remote.is_none() && local.is_some() && local != base,
        ConflictKind::ExecutableBit => {
            matches!((base, local, remote), (Some(_), Some(local), Some(remote)) if local.executable != remote.executable)
        }
        ConflictKind::RenameCycle
        | ConflictKind::CaseCollision
        | ConflictKind::UnicodeNormalization
        | ConflictKind::UnicodeCaseCollision
        | ConflictKind::ExactPathCollision => base.is_none() && local.is_none() && remote.is_none(),
    };
    if valid {
        Ok(())
    } else {
        Err(ConflictError::InvalidConflictShape)
    }
}

fn validate_path_shape(
    kind: &ConflictKind,
    paths: &[String],
    origins: &[ConflictPathOrigin],
) -> Result<(), ConflictError> {
    match kind {
        ConflictKind::RenameCycle if paths.len() < 2 || !origins.is_empty() => {
            Err(ConflictError::InvalidConflictShape)
        }
        ConflictKind::CaseCollision
        | ConflictKind::UnicodeNormalization
        | ConflictKind::UnicodeCaseCollision
        | ConflictKind::ExactPathCollision
            if origins.len() < 2 =>
        {
            Err(ConflictError::InvalidConflictShape)
        }
        kind if !matches!(
            kind,
            ConflictKind::CaseCollision
                | ConflictKind::UnicodeNormalization
                | ConflictKind::UnicodeCaseCollision
                | ConflictKind::ExactPathCollision
        ) && !origins.is_empty() =>
        {
            Err(ConflictError::InvalidConflictShape)
        }
        _ => Ok(()),
    }
}

fn conflict_digest(
    domain: ObjectDomain,
    kind: &ConflictKind,
    paths: &[String],
    path_origins: &[ConflictPathOrigin],
    base: &Option<ConflictContent>,
    local: &Option<ConflictContent>,
    remote: &Option<ConflictContent>,
) -> [u8; 32] {
    let mut hasher = blake3::Hasher::new();
    hasher.update(CONFLICT_ID_DOMAIN);
    hasher.update(domain.project_id.as_bytes());
    hasher.update(&domain.object_type.get().to_be_bytes());
    hasher.update(&domain.version.to_be_bytes());
    hasher.update(&[kind.tag()]);
    for path in paths {
        hasher.update(&(path.len() as u64).to_be_bytes());
        hasher.update(path.as_bytes());
    }
    for origin in path_origins {
        hasher.update(&(origin.source_path.len() as u64).to_be_bytes());
        hasher.update(origin.source_path.as_bytes());
        hasher.update(&(origin.target_path.len() as u64).to_be_bytes());
        hasher.update(origin.target_path.as_bytes());
        hasher.update(&[origin.side.tag()]);
    }
    hash_content(&mut hasher, base);
    hash_content(&mut hasher, local);
    hash_content(&mut hasher, remote);
    *hasher.finalize().as_bytes()
}

fn validate_file_domain(domain: ObjectDomain) -> Result<(), ConflictError> {
    if domain.object_type != ObjectType::FILE {
        return Err(ConflictError::InvalidObjectDomain);
    }
    Ok(())
}

fn state_digest(conflict: &ConflictRecord) -> [u8; 32] {
    let mut hasher = blake3::Hasher::new();
    hasher.update(CONFLICT_STATE_DOMAIN);
    hasher.update(&conflict.conflict_id);
    hash_content(&mut hasher, &conflict.base);
    hash_content(&mut hasher, &conflict.local);
    hash_content(&mut hasher, &conflict.remote);
    *hasher.finalize().as_bytes()
}

fn hash_content(hasher: &mut blake3::Hasher, content: &Option<ConflictContent>) {
    match content {
        Some(content) => {
            hasher.update(&[1, u8::from(content.executable)]);
            hasher.update(content.domain.project_id.as_bytes());
            hasher.update(&content.domain.object_type.get().to_be_bytes());
            hasher.update(&content.domain.version.to_be_bytes());
            hasher.update(&content.content_root.0);
            hasher.update(&(content.bytes.len() as u64).to_be_bytes());
            hasher.update(&content.bytes);
        }
        None => {
            hasher.update(&[0]);
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConflictError {
    InvalidPath,
    BudgetExceeded,
    ContentRootMismatch,
    InvalidConflictShape,
    NonCanonicalConflict,
    DuplicateConflictId,
    RevisionOverflow,
    InvalidResolution,
    StaleResolution,
    InvalidObjectDomain,
}

impl fmt::Display for ConflictError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for ConflictError {}

// ── persistence codec ───────────────────────────────────────────────────────
//
// Unresolved conflicts must outlive the sync operation that found them — a user
// resolves them later, from a different process. The encoding carries the
// CONSTRUCTOR INPUTS rather than the built record: decoding rebuilds through
// `new_with_origins`, so a stored row runs the full validation again and its
// `conflict_id` is recomputed canonically. A corrupted or tampered row therefore
// cannot smuggle in a mismatched id, an impossible shape, or content whose bytes
// disagree with their address — it fails to decode instead.

const CONFLICT_CODEC_VERSION: u8 = 1;
/// Bound on a stored set, mirroring the in-memory `ConflictSet` limits so a
/// corrupt length prefix cannot drive a huge allocation before validation.
const MAX_ENCODED_CONFLICT_BYTES: usize = MAX_CONFLICT_TOTAL_BYTES + 1024 * 1024;

impl ConflictSide {
    fn from_tag(tag: u8) -> Option<Self> {
        match tag {
            1 => Some(Self::Local),
            2 => Some(Self::Remote),
            _ => None,
        }
    }
}

impl ConflictKind {
    fn from_tag(tag: u8) -> Option<Self> {
        Some(match tag {
            1 => Self::Text,
            2 => Self::Binary,
            3 => Self::AddAddText,
            4 => Self::AddAddBinary,
            5 => Self::DeleteModify { deleted: ConflictSide::Local },
            6 => Self::DeleteModify { deleted: ConflictSide::Remote },
            7 => Self::RenameCycle,
            8 => Self::ExecutableBit,
            9 => Self::CaseCollision,
            10 => Self::UnicodeNormalization,
            11 => Self::UnicodeCaseCollision,
            12 => Self::ExactPathCollision,
            _ => return None,
        })
    }
}

fn put_str(out: &mut Vec<u8>, value: &str) {
    out.extend_from_slice(&(value.len() as u32).to_be_bytes());
    out.extend_from_slice(value.as_bytes());
}

fn put_content(out: &mut Vec<u8>, content: Option<&ConflictContent>) {
    match content {
        None => out.push(0),
        Some(content) => {
            out.push(1);
            out.extend_from_slice(&content.content_root.0);
            out.push(u8::from(content.executable));
            out.extend_from_slice(&(content.bytes.len() as u32).to_be_bytes());
            out.extend_from_slice(&content.bytes);
        }
    }
}

/// Encode every unresolved conflict in `set` for storage.
pub fn encode_conflict_set(set: &ConflictSet) -> Vec<u8> {
    let mut out = vec![CONFLICT_CODEC_VERSION];
    let domain = set.expected_domain;
    out.extend_from_slice(domain.project_id.as_bytes());
    out.extend_from_slice(&domain.object_type.get().to_be_bytes());
    out.extend_from_slice(&domain.version.to_be_bytes());
    out.extend_from_slice(&(set.unresolved.len() as u32).to_be_bytes());
    for record in set.unresolved.values() {
        out.push(record.kind.tag());
        out.extend_from_slice(&(record.paths.len() as u32).to_be_bytes());
        for path in &record.paths {
            put_str(&mut out, path);
        }
        out.extend_from_slice(&(record.path_origins.len() as u32).to_be_bytes());
        for origin in &record.path_origins {
            put_str(&mut out, &origin.source_path);
            put_str(&mut out, &origin.target_path);
            out.push(origin.side.tag());
        }
        put_content(&mut out, record.base.as_ref());
        put_content(&mut out, record.local.as_ref());
        put_content(&mut out, record.remote.as_ref());
    }
    out
}

/// Rebuild a stored conflict set, re-validating every record.
///
/// `expected_domain` is the project the caller is loading for; a set stored under
/// a different domain is rejected rather than adopted, so a mixed-up row cannot
/// attach one project's conflicts to another.
pub fn decode_conflict_set(
    input: &[u8],
    expected_domain: ObjectDomain,
) -> Result<ConflictSet, ConflictError> {
    if input.len() > MAX_ENCODED_CONFLICT_BYTES {
        return Err(ConflictError::BudgetExceeded);
    }
    let mut reader = CodecReader { input, offset: 0 };
    if reader.u8()? != CONFLICT_CODEC_VERSION {
        return Err(ConflictError::NonCanonicalConflict);
    }
    let domain = ObjectDomain {
        project_id: ProjectId::from_bytes(reader.array::<32>()?),
        object_type: ObjectType::new(reader.u16()?)
            .map_err(|_| ConflictError::InvalidObjectDomain)?,
        version: reader.u16()?,
    };
    if domain != expected_domain {
        return Err(ConflictError::InvalidObjectDomain);
    }
    let mut set = ConflictSet::new(domain)?;
    let count = reader.u32()? as usize;
    if count > MAX_CONFLICT_COUNT {
        return Err(ConflictError::BudgetExceeded);
    }
    for _ in 0..count {
        let kind = ConflictKind::from_tag(reader.u8()?)
            .ok_or(ConflictError::InvalidConflictShape)?;
        let path_count = reader.u32()? as usize;
        if path_count > MAX_CONFLICT_COUNT {
            return Err(ConflictError::BudgetExceeded);
        }
        let mut paths = Vec::with_capacity(path_count.min(64));
        for _ in 0..path_count {
            paths.push(reader.string()?);
        }
        let origin_count = reader.u32()? as usize;
        if origin_count > MAX_CONFLICT_COUNT {
            return Err(ConflictError::BudgetExceeded);
        }
        let mut origins = Vec::with_capacity(origin_count.min(64));
        for _ in 0..origin_count {
            let source_path = reader.string()?;
            let target_path = reader.string()?;
            let side =
                ConflictSide::from_tag(reader.u8()?).ok_or(ConflictError::InvalidConflictShape)?;
            origins.push(ConflictPathOrigin { source_path, target_path, side });
        }
        let base = reader.content(domain)?;
        let local = reader.content(domain)?;
        let remote = reader.content(domain)?;
        // Rebuilt, not trusted: this re-runs every shape/content check and
        // recomputes the conflict id from the canonical digest.
        set.insert(ConflictRecord::new_with_origins(
            domain, kind, paths, origins, base, local, remote,
        )?)?;
    }
    if reader.offset != input.len() {
        return Err(ConflictError::NonCanonicalConflict);
    }
    Ok(set)
}

struct CodecReader<'a> {
    input: &'a [u8],
    offset: usize,
}

impl<'a> CodecReader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], ConflictError> {
        let end = self
            .offset
            .checked_add(n)
            .ok_or(ConflictError::BudgetExceeded)?;
        let slice = self
            .input
            .get(self.offset..end)
            .ok_or(ConflictError::NonCanonicalConflict)?;
        self.offset = end;
        Ok(slice)
    }
    fn u8(&mut self) -> Result<u8, ConflictError> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16, ConflictError> {
        Ok(u16::from_be_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> Result<u32, ConflictError> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn array<const N: usize>(&mut self) -> Result<[u8; N], ConflictError> {
        Ok(self.take(N)?.try_into().unwrap())
    }
    fn string(&mut self) -> Result<String, ConflictError> {
        let len = self.u32()? as usize;
        if len > MAX_CONFLICT_PATH_BYTES {
            return Err(ConflictError::BudgetExceeded);
        }
        String::from_utf8(self.take(len)?.to_vec()).map_err(|_| ConflictError::InvalidPath)
    }
    fn content(&mut self, domain: ObjectDomain) -> Result<Option<ConflictContent>, ConflictError> {
        if self.u8()? == 0 {
            return Ok(None);
        }
        let content_root = ObjectId(self.array::<32>()?);
        let executable = self.u8()? != 0;
        let len = self.u32()? as usize;
        if len > MAX_CONFLICT_CONTENT_BYTES {
            return Err(ConflictError::BudgetExceeded);
        }
        let bytes = self.take(len)?.to_vec();
        // `ConflictContent::new` re-derives the address, so bytes that do not
        // match their recorded `content_root` are rejected here.
        ConflictContent::new(domain, content_root, bytes, executable).map(Some)
    }
}
