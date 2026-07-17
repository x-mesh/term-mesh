use std::collections::BTreeMap;
use std::fmt;

use super::{ObjectDomain, ObjectId, ObjectType};

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
