use std::collections::HashSet;
use std::ffi::{CStr, CString, OsStr};
use std::fmt;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use super::crypto::{CryptoError, ProjectKey, NONCE_BYTES, TAG_BYTES};
use super::ProjectId;

pub const CHUNK_SIZE: usize = 4 * 1024 * 1024;
const OBJECT_DOMAIN: &[u8] = b"term-mesh cas object v1\0";
const CHUNK_AAD_DOMAIN: &[u8] = b"term-mesh cas chunk v2\0";
const BITMAP_MAC_DOMAIN: &[u8] = b"term-mesh cas resume v1\0";
const CONTAINER_MAGIC: &[u8; 8] = b"TMCAS\0\x02\0";
const CONTAINER_HEADER_BYTES: u64 = 104;
const MAX_METADATA_BYTES: u64 = 16 * 1024 * 1024;
const ROOT_FORMAT_MARKER: &str = ".term-mesh-cas-format";
const ROOT_FORMAT_V2: &[u8] = b"term-mesh-cas-v2\n";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ObjectType(u16);

impl ObjectType {
    pub const FILE: Self = Self(1);
    pub const MANIFEST: Self = Self(2);
    pub const CONFLICT: Self = Self(3);

    pub fn new(value: u16) -> Result<Self, CasError> {
        if value == 0 {
            return Err(CasError::InvalidObjectType);
        }
        Ok(Self(value))
    }

    pub fn get(self) -> u16 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ObjectDomain {
    pub project_id: ProjectId,
    pub object_type: ObjectType,
    pub version: u16,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct ObjectId(pub [u8; 32]);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct KeyId(pub [u8; 16]);

pub struct ProjectKeyMaterial {
    pub key_id: KeyId,
    pub key: ProjectKey,
}

impl ObjectId {
    pub fn for_plaintext(domain: ObjectDomain, plaintext: &[u8]) -> Self {
        let mut hasher = ObjectIdHasher::new(domain, plaintext.len() as u64);
        hasher
            .update(plaintext)
            .expect("slice length matches declaration");
        hasher.finish().expect("slice length matches declaration")
    }
}

pub struct ObjectIdHasher {
    hasher: blake3::Hasher,
    expected: u64,
    written: u64,
}
impl ObjectIdHasher {
    pub fn new(domain: ObjectDomain, plaintext_len: u64) -> Self {
        Self {
            hasher: object_hasher(domain, plaintext_len),
            expected: plaintext_len,
            written: 0,
        }
    }
    pub fn update(&mut self, bytes: &[u8]) -> Result<(), CasError> {
        self.written =
            self.written
                .checked_add(bytes.len() as u64)
                .ok_or(CasError::ObjectTooLarge {
                    length: u64::MAX,
                    limit: self.expected,
                })?;
        if self.written > self.expected {
            return Err(CasError::ObjectTooLarge {
                length: self.written,
                limit: self.expected,
            });
        }
        self.hasher.update(bytes);
        Ok(())
    }
    pub fn finish(self) -> Result<ObjectId, CasError> {
        if self.written != self.expected {
            return Err(CasError::UnexpectedFileLength);
        }
        Ok(ObjectId(*self.hasher.finalize().as_bytes()))
    }
}

impl fmt::Debug for ObjectId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "ObjectId({})", hex::encode(self.0))
    }
}

impl fmt::Display for ObjectId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", hex::encode(self.0))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct StageId([u8; 16]);

impl StageId {
    pub fn random() -> Result<Self, CasError> {
        Ok(Self(random_bytes()?))
    }

    pub fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(bytes)
    }
    pub fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }

    fn directory_name(self) -> String {
        hex::encode(self.0)
    }
}

impl fmt::Display for StageId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.directory_name())
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct ResumeToken([u8; 32]);

impl ResumeToken {
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }
    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl fmt::Debug for ResumeToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ResumeToken(REDACTED)")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResumeCheckpoint {
    pub token: ResumeToken,
    pub generation: u64,
}

#[derive(Debug)]
pub struct EncryptedChunk {
    nonce: [u8; NONCE_BYTES],
    ciphertext: Vec<u8>,
}

impl EncryptedChunk {
    pub fn from_parts(nonce: [u8; NONCE_BYTES], ciphertext: Vec<u8>) -> Self {
        Self { nonce, ciphertext }
    }

    pub fn nonce(&self) -> &[u8; NONCE_BYTES] {
        &self.nonce
    }

    pub fn ciphertext(&self) -> &[u8] {
        &self.ciphertext
    }
}

pub fn encrypt_chunk(
    key: &ProjectKey,
    domain: ObjectDomain,
    object_id: ObjectId,
    plaintext_len: u64,
    index: u32,
    plaintext: &[u8],
) -> Result<EncryptedChunk, CasError> {
    encrypt_chunk_for_key(
        key,
        KeyId([1; 16]),
        domain,
        object_id,
        plaintext_len,
        index,
        plaintext,
    )
}

pub fn encrypt_chunk_for_key(
    key: &ProjectKey,
    key_id: KeyId,
    domain: ObjectDomain,
    object_id: ObjectId,
    plaintext_len: u64,
    index: u32,
    plaintext: &[u8],
) -> Result<EncryptedChunk, CasError> {
    let nonce = random_bytes()?;
    encrypt_chunk_with_nonce(
        key,
        key_id,
        domain,
        object_id,
        plaintext_len,
        index,
        plaintext,
        nonce,
    )
}

fn encrypt_chunk_with_nonce(
    key: &ProjectKey,
    key_id: KeyId,
    domain: ObjectDomain,
    object_id: ObjectId,
    plaintext_len: u64,
    index: u32,
    plaintext: &[u8],
    nonce: [u8; NONCE_BYTES],
) -> Result<EncryptedChunk, CasError> {
    let expected = expected_chunk_len_for(plaintext_len, index)?;
    if plaintext.len() != expected {
        return Err(CasError::WrongChunkLength {
            index,
            expected,
            actual: plaintext.len(),
        });
    }
    Ok(EncryptedChunk {
        nonce,
        ciphertext: key.encrypt(
            &nonce,
            plaintext,
            &chunk_aad_fields(domain, key_id, object_id, plaintext_len, index)?,
        )?,
    })
}

pub trait ProjectKeyProvider: Send + Sync {
    fn current_project_key(&self, project_id: ProjectId) -> Result<ProjectKeyMaterial, CasError>;
    fn project_key(&self, project_id: ProjectId, key_id: KeyId) -> Result<ProjectKey, CasError>;
}

#[derive(Debug, Clone)]
pub struct CasLimits {
    pub max_object_bytes: u64,
    pub max_staged_ciphertext_bytes: u64,
}

impl Default for CasLimits {
    fn default() -> Self {
        Self {
            max_object_bytes: 50 * 1024 * 1024 * 1024,
            max_staged_ciphertext_bytes: 51 * 1024 * 1024 * 1024,
        }
    }
}

pub struct CasStore {
    root_path: PathBuf,
    root: Directory,
    live: Directory,
    staging: Directory,
    limits: CasLimits,
    keys: Arc<dyn ProjectKeyProvider>,
    retirement_fences: Arc<Mutex<HashSet<KeyId>>>,
}

impl CasStore {
    pub fn open(
        root: impl Into<PathBuf>,
        limits: CasLimits,
        keys: Arc<dyn ProjectKeyProvider>,
    ) -> Result<Self, CasError> {
        validate_chunk_count(limits.max_object_bytes)?;
        let root_path = root.into();
        let root = open_or_create_root(&root_path)?;
        sweep_format_temps(&root)?;
        enforce_root_format(&root)?;
        root.mkdir("live")?;
        root.mkdir("staging")?;
        root.sync()?;
        let live = root.open_directory("live")?;
        let staging = root.open_directory("staging")?;
        enforce_live_v2(&live)?;
        live.sync()?;
        staging.sync()?;
        sweep_staging_tree(&staging)?;
        let retirement_fences = load_retirement_fences(&root)?;
        Ok(Self {
            root_path,
            root,
            live,
            staging,
            limits,
            keys,
            retirement_fences: Arc::new(Mutex::new(retirement_fences)),
        })
    }

    pub fn root_path(&self) -> &Path {
        &self.root_path
    }

    pub fn begin_stage(
        &self,
        domain: ObjectDomain,
        expected_id: ObjectId,
        plaintext_len: u64,
    ) -> Result<StagingObject, CasError> {
        validate_object_length(plaintext_len, &self.limits)?;
        let material = self.keys.current_project_key(domain.project_id)?;
        // Serialize key selection through durable metadata creation with
        // retirement-fence installation. A rejected stage must not leave an
        // unsealed directory that retirement evidence can mistake for an
        // in-flight object.
        let fences = self
            .retirement_fences
            .lock()
            .map_err(|_| CasError::Poisoned)?;
        if fences.contains(&material.key_id) {
            return Err(CasError::RetiredKeyFence(material.key_id));
        }
        let stage_id = StageId::random()?;
        let stage_name = stage_id.directory_name();
        self.staging.mkdir_exclusive(&stage_name)?;
        self.staging.sync()?;
        let stage = self.staging.open_directory(&stage_name)?;
        stage.mkdir_exclusive("chunks")?;
        stage.sync()?;
        let chunks = stage.open_directory("chunks")?;
        chunks.sync()?;

        let token = ResumeToken(random_bytes()?);
        let mut metadata =
            StageMetadata::new(domain, expected_id, plaintext_len, token, material.key_id)?;
        metadata.seal(&material.key);
        write_metadata(&stage, &metadata, &self.limits)?;
        drop(fences);
        Ok(StagingObject {
            root: self.root.try_clone()?,
            live: self.live.try_clone()?,
            staging: self.staging.try_clone()?,
            stage,
            chunks,
            stage_id,
            limits: self.limits.clone(),
            key: material.key,
            metadata,
            retirement_fences: self.retirement_fences.clone(),
        })
    }

    pub fn resume_stage(
        &self,
        stage_id: StageId,
        // The caller must persist this checkpoint outside staging (t2/t5 ownership).
        expected: ResumeCheckpoint,
    ) -> Result<StagingObject, CasError> {
        let stage_name = stage_id.directory_name();
        let stage = self.staging.open_directory(&stage_name)?;
        let chunks = stage.open_directory("chunks")?;
        stage.sweep_temp_files()?;
        chunks.sweep_temp_files()?;
        let metadata = read_metadata(&stage, &self.limits)?;
        validate_object_length(metadata.plaintext_len, &self.limits)?;
        let key = self
            .keys
            .project_key(metadata.domain()?.project_id, metadata.key_id)?;
        metadata.verify(&key)?;
        if metadata.resume_token != expected.token.0 || metadata.generation != expected.generation {
            return Err(CasError::StaleResumeMetadata);
        }
        verify_marked_chunks(&chunks, &metadata, &key)?;
        Ok(StagingObject {
            root: self.root.try_clone()?,
            live: self.live.try_clone()?,
            staging: self.staging.try_clone()?,
            stage,
            chunks,
            stage_id,
            limits: self.limits.clone(),
            key,
            metadata,
            retirement_fences: self.retirement_fences.clone(),
        })
    }

    pub(super) fn acquire_retirement_fence(
        &self,
        key_id: KeyId,
    ) -> Result<CasRetirementLease<'_>, CasError> {
        let mut fences = self
            .retirement_fences
            .lock()
            .map_err(|_| CasError::Poisoned)?;
        let name = retirement_fence_name(key_id);
        if fences.insert(key_id) {
            match self.root.create_new(&name) {
                Ok(file) => {
                    file.sync_all()?;
                    self.root.sync()?;
                }
                Err(CasError::Io(error)) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => {
                    fences.remove(&key_id);
                    return Err(error);
                }
            }
        }
        drop(fences);
        let counts = self.retirement_counts(key_id)?;
        Ok(CasRetirementLease {
            store: self,
            key_id,
            counts,
        })
    }

    pub(super) fn complete_retirement_fence_idempotent(
        &self,
        key_id: KeyId,
    ) -> Result<(), CasError> {
        let mut fences = self
            .retirement_fences
            .lock()
            .map_err(|_| CasError::Poisoned)?;
        match self.root.unlink_file(&retirement_fence_name(key_id)) {
            Ok(()) => self.root.sync()?,
            Err(CasError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        fences.remove(&key_id);
        Ok(())
    }

    fn retirement_counts(&self, key_id: KeyId) -> Result<CasRetirementCounts, CasError> {
        let mut live = 0_u64;
        for name in self.live.entry_names()? {
            if !name.ends_with(".cas") || !self.live.is_regular_entry(&name)? {
                continue;
            }
            let mut file = self.live.open_regular(&name, libc::O_RDONLY)?;
            if read_container_key_id(&mut file)? == key_id {
                live += 1;
            }
        }
        let mut inflight = 0_u64;
        for name in self.staging.entry_names()? {
            if !is_lower_hex(&name, 32) {
                continue;
            }
            let stage = self.staging.open_directory(&name)?;
            let metadata = read_metadata(&stage, &self.limits)?;
            if metadata.key_id == key_id {
                inflight += 1;
            }
        }
        Ok(CasRetirementCounts {
            old_key_objects: live,
            inflight,
            reachable: live,
        })
    }

    #[cfg(test)]
    pub fn test_install_retirement_fence(&self, key_id: KeyId) -> Result<(), CasError> {
        drop(self.acquire_retirement_fence(key_id)?);
        Ok(())
    }

    #[cfg(test)]
    pub fn test_complete_retirement_fence(&self, key_id: KeyId) -> Result<(), CasError> {
        self.acquire_retirement_fence(key_id)?.complete()
    }

    #[cfg(test)]
    pub fn test_retirement_counts(&self, key_id: KeyId) -> Result<(u64, u64, u64), CasError> {
        let counts = self.retirement_counts(key_id)?;
        Ok((counts.old_key_objects, counts.inflight, counts.reachable))
    }

    pub fn get_live(
        &self,
        domain: ObjectDomain,
        object_id: ObjectId,
    ) -> Result<Option<LiveObject>, CasError> {
        let name = live_name(object_id);
        let file = match self.live.open_regular(&name, libc::O_RDONLY) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(CasError::Io(error)),
        };
        let (file, key_id) = verify_container(file, domain, object_id, &*self.keys, &self.limits)?;
        Ok(Some(LiveObject {
            file,
            object_id,
            key_id,
        }))
    }

    /// Copies a live object as plaintext without exposing project keys or CAS AAD details.
    /// The container is authenticated again while copying and its inode metadata must remain
    /// stable for the entire operation.
    pub fn copy_verified_plaintext<W: Write>(
        &self,
        domain: ObjectDomain,
        object_id: ObjectId,
        writer: &mut W,
    ) -> Result<u64, CasError> {
        let live = self
            .get_live(domain, object_id)?
            .ok_or(CasError::IncompleteObject)?;
        let mut file = live.try_clone_file()?;
        let before = file.metadata()?;
        let key = self.keys.project_key(domain.project_id, live.key_id)?;
        let mut header = [0; CONTAINER_HEADER_BYTES as usize];
        file.read_exact(&mut header)
            .map_err(|_| CasError::CorruptLiveObject)?;
        if &header[..8] != CONTAINER_MAGIC
            || &header[8..40] != domain.project_id.as_bytes()
            || u16::from_be_bytes(header[40..42].try_into().unwrap()) != domain.object_type.get()
            || u16::from_be_bytes(header[42..44].try_into().unwrap()) != domain.version
            || header[44..76] != object_id.0
            || header[76..92] != live.key_id.0
        {
            return Err(CasError::CorruptLiveObject);
        }
        let plaintext_len = u64::from_be_bytes(header[92..100].try_into().unwrap());
        validate_object_length(plaintext_len, &self.limits)?;
        let chunks = u32::from_be_bytes(header[100..104].try_into().unwrap());
        if chunks != validate_chunk_count(plaintext_len)? {
            return Err(CasError::CorruptLiveObject);
        }
        let metadata = StageMetadata::new(
            domain,
            object_id,
            plaintext_len,
            ResumeToken([0; 32]),
            live.key_id,
        )?;
        let mut identity = ObjectIdHasher::new(domain, plaintext_len);
        for index in 0..chunks {
            let mut nonce = [0; NONCE_BYTES];
            let mut encoded_length = [0; 4];
            file.read_exact(&mut nonce)
                .map_err(|_| CasError::CorruptLiveObject)?;
            file.read_exact(&mut encoded_length)
                .map_err(|_| CasError::CorruptLiveObject)?;
            let ciphertext_len = u32::from_be_bytes(encoded_length) as usize;
            if ciphertext_len != expected_chunk_len(&metadata, index)? + TAG_BYTES {
                return Err(CasError::CorruptLiveObject);
            }
            let mut ciphertext = vec![0; ciphertext_len];
            file.read_exact(&mut ciphertext)
                .map_err(|_| CasError::CorruptLiveObject)?;
            let plaintext = key
                .decrypt(&nonce, &ciphertext, &chunk_aad(&metadata, index)?)
                .map_err(|_| CasError::CorruptLiveObject)?;
            identity.update(&plaintext)?;
            writer.write_all(&plaintext)?;
        }
        if identity.finish()? != object_id {
            return Err(CasError::CorruptLiveObject);
        }
        let after = file.metadata()?;
        if before.dev() != after.dev()
            || before.ino() != after.ino()
            || before.len() != after.len()
            || before.modified().ok() != after.modified().ok()
        {
            return Err(CasError::CorruptLiveObject);
        }
        Ok(plaintext_len)
    }
}

pub struct StagingObject {
    root: Directory,
    live: Directory,
    staging: Directory,
    stage: Directory,
    chunks: Directory,
    stage_id: StageId,
    limits: CasLimits,
    key: ProjectKey,
    metadata: StageMetadata,
    retirement_fences: Arc<Mutex<HashSet<KeyId>>>,
}

impl StagingObject {
    pub fn stage_id(&self) -> StageId {
        self.stage_id
    }

    pub fn checkpoint(&self) -> ResumeCheckpoint {
        ResumeCheckpoint {
            token: ResumeToken(self.metadata.resume_token),
            generation: self.metadata.generation,
        }
    }

    pub fn verified_ranges(&self) -> Vec<(u32, u32)> {
        bitmap_ranges(&self.metadata.verified)
    }
    pub fn object_id(&self) -> ObjectId {
        self.metadata.object_id()
    }
    pub fn domain(&self) -> Result<ObjectDomain, CasError> {
        self.metadata.domain()
    }
    pub fn plaintext_len(&self) -> u64 {
        self.metadata.plaintext_len
    }
    pub fn key_id(&self) -> KeyId {
        self.metadata.key_id
    }
    pub fn chunk_count(&self) -> Result<u32, CasError> {
        self.metadata.chunk_count()
    }

    pub fn write_encrypted_chunk(
        &mut self,
        index: u32,
        envelope: &EncryptedChunk,
    ) -> Result<(), CasError> {
        if self
            .retirement_fences
            .lock()
            .map_err(|_| CasError::Poisoned)?
            .contains(&self.metadata.key_id)
        {
            return Err(CasError::RetiredKeyFence(self.metadata.key_id));
        }
        let expected_len = expected_chunk_len(&self.metadata, index)?;
        if envelope.ciphertext.len() != expected_len + TAG_BYTES {
            return Err(CasError::WrongChunkLength {
                index,
                expected: expected_len + TAG_BYTES,
                actual: envelope.ciphertext.len(),
            });
        }
        let already_verified_bytes = self
            .metadata
            .verified
            .iter()
            .enumerate()
            .filter(|(_, verified)| **verified)
            .try_fold(0_u64, |total, (chunk, _)| {
                let plaintext = expected_chunk_len(&self.metadata, chunk as u32)? as u64;
                total
                    .checked_add(plaintext + TAG_BYTES as u64 + NONCE_BYTES as u64)
                    .ok_or(CasError::StagingLimitExceeded)
            })?;
        let projected = already_verified_bytes
            .checked_add(envelope.ciphertext.len() as u64 + NONCE_BYTES as u64)
            .ok_or(CasError::StagingLimitExceeded)?;
        if !self.metadata.verified[index as usize]
            && projected > self.limits.max_staged_ciphertext_bytes
        {
            return Err(CasError::StagingLimitExceeded);
        }

        let aad = chunk_aad(&self.metadata, index)?;
        let plaintext = self
            .key
            .decrypt(&envelope.nonce, &envelope.ciphertext, &aad)?;
        if plaintext.len() != expected_len {
            return Err(CasError::WrongChunkLength {
                index,
                expected: expected_len,
                actual: plaintext.len(),
            });
        }

        let mut temporary = TempFile::create(&self.chunks, &format!("{index}.tmp"))?;
        let final_name = format!("{index}.chunk");
        temporary.file_mut().write_all(&envelope.nonce)?;
        temporary.file_mut().write_all(&envelope.ciphertext)?;
        temporary.file_mut().sync_all()?;
        match temporary.link_to(&self.chunks, &final_name) {
            Ok(()) => self.chunks.sync()?,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                let existing = read_chunk(&self.chunks, &self.metadata, index)?;
                let existing_plaintext =
                    self.key
                        .decrypt(&existing.nonce, &existing.ciphertext, &aad)?;
                if existing_plaintext != plaintext {
                    return Err(CasError::ChunkConflict(index));
                }
            }
            Err(error) => return Err(CasError::Io(error)),
        }
        temporary.remove()?;

        self.metadata.verified[index as usize] = true;
        self.metadata.generation = self
            .metadata
            .generation
            .checked_add(1)
            .ok_or(CasError::GenerationExhausted)?;
        self.metadata.seal(&self.key);
        write_metadata(&self.stage, &self.metadata, &self.limits)?;
        Ok(())
    }

    pub fn finish(self) -> Result<LiveObject, CasError> {
        // Promotion and staging cleanup form one retirement-visible state
        // transition. Holding the same mutex as fence installation prevents a
        // scan from observing the object in neither staging nor live storage.
        let retirement_fences = self.retirement_fences.clone();
        let fences = retirement_fences.lock().map_err(|_| CasError::Poisoned)?;
        if fences.contains(&self.metadata.key_id) {
            return Err(CasError::RetiredKeyFence(self.metadata.key_id));
        }
        if self.metadata.verified.iter().any(|verified| !verified) {
            return Err(CasError::IncompleteObject);
        }
        let mut temporary = TempFile::create(&self.stage, "object.tmp")?;
        write_container_header(temporary.file_mut(), &self.metadata)?;
        let domain = self.metadata.domain()?;
        let mut hasher = object_hasher(domain, self.metadata.plaintext_len);
        for index in 0..self.metadata.chunk_count()? {
            let envelope = read_chunk(&self.chunks, &self.metadata, index)?;
            let plaintext = self.key.decrypt(
                &envelope.nonce,
                &envelope.ciphertext,
                &chunk_aad(&self.metadata, index)?,
            )?;
            if plaintext.len() != expected_chunk_len(&self.metadata, index)? {
                return Err(CasError::WrongChunkLength {
                    index,
                    expected: expected_chunk_len(&self.metadata, index)?,
                    actual: plaintext.len(),
                });
            }
            hasher.update(&plaintext);
            temporary.file_mut().write_all(&envelope.nonce)?;
            temporary
                .file_mut()
                .write_all(&(envelope.ciphertext.len() as u32).to_be_bytes())?;
            temporary.file_mut().write_all(&envelope.ciphertext)?;
        }
        let actual = ObjectId(*hasher.finalize().as_bytes());
        let expected = self.metadata.object_id();
        if actual != expected {
            return Err(CasError::ObjectIdentityMismatch { expected, actual });
        }
        temporary.file_mut().sync_all()?;

        let destination = live_name(expected);
        match temporary.link_to(&self.live, &destination) {
            Ok(()) => self.live.sync()?,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                let existing = self.live.open_regular(&destination, libc::O_RDONLY)?;
                verify_container_with_key(
                    existing,
                    domain,
                    expected,
                    self.metadata.key_id,
                    &self.key,
                    &self.limits,
                )?;
            }
            Err(error) => return Err(CasError::Io(error)),
        }
        temporary.remove()?;
        self.cleanup_staging();
        let file = self.live.open_regular(&destination, libc::O_RDONLY)?;
        let (file, key_id) = verify_container_with_key(
            file,
            domain,
            expected,
            self.metadata.key_id,
            &self.key,
            &self.limits,
        )?;
        drop(fences);
        Ok(LiveObject {
            file,
            object_id: expected,
            key_id,
        })
    }

    fn cleanup_staging(&self) {
        if let Ok(count) = self.metadata.chunk_count() {
            for index in 0..count {
                let _ = self.chunks.unlink_file(&format!("{index}.chunk"));
            }
        }
        let _ = self.chunks.sync();
        let _ = self.stage.unlink_file("metadata.json");
        let _ = self.stage.unlink_directory("chunks");
        let _ = self.stage.sync();
        let _ = self
            .staging
            .unlink_directory(&self.stage_id.directory_name());
        let _ = self.staging.sync();
        let _ = self.root.sync();
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) struct CasRetirementCounts {
    pub old_key_objects: u64,
    pub inflight: u64,
    pub reachable: u64,
}

pub(super) struct CasRetirementLease<'a> {
    store: &'a CasStore,
    key_id: KeyId,
    counts: CasRetirementCounts,
}

impl CasRetirementLease<'_> {
    pub fn counts(&self) -> CasRetirementCounts {
        self.counts
    }
    pub fn revalidate(&self) -> Result<(), CasError> {
        if self.store.retirement_counts(self.key_id)? != self.counts {
            return Err(CasError::RetirementFenceChanged);
        }
        Ok(())
    }
    pub fn complete(self) -> Result<(), CasError> {
        self.store.complete_retirement_fence_idempotent(self.key_id)
    }
}

pub struct LiveObject {
    file: File,
    pub object_id: ObjectId,
    pub key_id: KeyId,
}

impl LiveObject {
    pub fn try_clone_file(&self) -> Result<File, CasError> {
        Ok(self.file.try_clone()?)
    }

    pub fn read_encrypted_chunk(&self, index: u32) -> Result<(u32, EncryptedChunk), CasError> {
        let mut file = self.file.try_clone()?;
        file.seek(SeekFrom::Start(0))?;
        let mut header = [0; CONTAINER_HEADER_BYTES as usize];
        file.read_exact(&mut header)
            .map_err(|_| CasError::CorruptLiveObject)?;
        if &header[..8] != CONTAINER_MAGIC
            || header[44..76] != self.object_id.0
            || header[76..92] != self.key_id.0
        {
            return Err(CasError::CorruptLiveObject);
        }
        let plaintext_len = u64::from_be_bytes(header[92..100].try_into().unwrap());
        let chunk_count = u32::from_be_bytes(header[100..104].try_into().unwrap());
        if index >= chunk_count || chunk_count != validate_chunk_count(plaintext_len)? {
            return Err(CasError::ChunkOutOfRange(index));
        }
        let stride = (NONCE_BYTES + 4 + CHUNK_SIZE + TAG_BYTES) as u64;
        let offset = CONTAINER_HEADER_BYTES
            .checked_add(
                (index as u64)
                    .checked_mul(stride)
                    .ok_or(CasError::SizeOverflow)?,
            )
            .ok_or(CasError::SizeOverflow)?;
        file.seek(SeekFrom::Start(offset))?;
        let mut nonce = [0; NONCE_BYTES];
        file.read_exact(&mut nonce)
            .map_err(|_| CasError::CorruptLiveObject)?;
        let mut encoded_length = [0; 4];
        file.read_exact(&mut encoded_length)
            .map_err(|_| CasError::CorruptLiveObject)?;
        let ciphertext_len = u32::from_be_bytes(encoded_length) as usize;
        let expected_plaintext = expected_chunk_len_for(plaintext_len, index)?;
        if ciphertext_len != expected_plaintext + TAG_BYTES
            || ciphertext_len > CHUNK_SIZE + TAG_BYTES
        {
            return Err(CasError::CorruptLiveObject);
        }
        let mut ciphertext = vec![0; ciphertext_len];
        file.read_exact(&mut ciphertext)
            .map_err(|_| CasError::CorruptLiveObject)?;
        Ok((
            expected_plaintext as u32,
            EncryptedChunk { nonce, ciphertext },
        ))
    }
}

impl fmt::Debug for LiveObject {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("LiveObject")
            .field("object_id", &self.object_id)
            .finish_non_exhaustive()
    }
}

#[derive(Serialize, Deserialize)]
struct StageMetadata {
    project_id: [u8; 32],
    object_type: u16,
    version: u16,
    object_id: [u8; 32],
    key_id: KeyId,
    plaintext_len: u64,
    verified: Vec<bool>,
    resume_token: [u8; 32],
    generation: u64,
    mac: [u8; 32],
}

impl StageMetadata {
    fn new(
        domain: ObjectDomain,
        object_id: ObjectId,
        plaintext_len: u64,
        resume_token: ResumeToken,
        key_id: KeyId,
    ) -> Result<Self, CasError> {
        let chunk_count = validate_chunk_count(plaintext_len)?;
        Ok(Self {
            project_id: *domain.project_id.as_bytes(),
            object_type: domain.object_type.get(),
            version: domain.version,
            object_id: object_id.0,
            key_id,
            plaintext_len,
            verified: vec![false; chunk_count as usize],
            resume_token: resume_token.0,
            generation: 0,
            mac: [0; 32],
        })
    }

    fn domain(&self) -> Result<ObjectDomain, CasError> {
        Ok(ObjectDomain {
            project_id: ProjectId::from_bytes(self.project_id),
            object_type: ObjectType::new(self.object_type)?,
            version: self.version,
        })
    }

    fn object_id(&self) -> ObjectId {
        ObjectId(self.object_id)
    }

    fn chunk_count(&self) -> Result<u32, CasError> {
        validate_chunk_count(self.plaintext_len)
    }

    fn seal(&mut self, key: &ProjectKey) {
        self.mac = key.keyed_hash(&metadata_mac_input(self));
    }

    fn verify(&self, key: &ProjectKey) -> Result<(), CasError> {
        if self.verified.len() != self.chunk_count()? as usize
            || key.keyed_hash(&metadata_mac_input(self)) != self.mac
        {
            return Err(CasError::CorruptResumeMetadata);
        }
        Ok(())
    }
}

fn object_hasher(domain: ObjectDomain, plaintext_len: u64) -> blake3::Hasher {
    let mut hasher = blake3::Hasher::new();
    hasher.update(OBJECT_DOMAIN);
    hasher.update(domain.project_id.as_bytes());
    hasher.update(&domain.object_type.get().to_be_bytes());
    hasher.update(&domain.version.to_be_bytes());
    hasher.update(&plaintext_len.to_be_bytes());
    hasher
}

fn chunk_aad(metadata: &StageMetadata, index: u32) -> Result<Vec<u8>, CasError> {
    chunk_aad_fields(
        metadata.domain()?,
        metadata.key_id,
        metadata.object_id(),
        metadata.plaintext_len,
        index,
    )
}

fn chunk_aad_fields(
    domain: ObjectDomain,
    key_id: KeyId,
    object_id: ObjectId,
    plaintext_len: u64,
    index: u32,
) -> Result<Vec<u8>, CasError> {
    let expected_len = expected_chunk_len_for(plaintext_len, index)? as u32;
    let mut aad = Vec::with_capacity(110);
    aad.extend_from_slice(CHUNK_AAD_DOMAIN);
    aad.extend_from_slice(domain.project_id.as_bytes());
    aad.extend_from_slice(&key_id.0);
    aad.extend_from_slice(&domain.object_type.get().to_be_bytes());
    aad.extend_from_slice(&domain.version.to_be_bytes());
    aad.extend_from_slice(&object_id.0);
    aad.extend_from_slice(&plaintext_len.to_be_bytes());
    aad.extend_from_slice(&index.to_be_bytes());
    aad.extend_from_slice(&expected_len.to_be_bytes());
    Ok(aad)
}

fn metadata_mac_input(metadata: &StageMetadata) -> Vec<u8> {
    let mut input = Vec::with_capacity(136 + metadata.verified.len());
    input.extend_from_slice(BITMAP_MAC_DOMAIN);
    input.extend_from_slice(&metadata.project_id);
    input.extend_from_slice(&metadata.object_type.to_be_bytes());
    input.extend_from_slice(&metadata.version.to_be_bytes());
    input.extend_from_slice(&metadata.object_id);
    input.extend_from_slice(&metadata.key_id.0);
    input.extend_from_slice(&metadata.plaintext_len.to_be_bytes());
    input.extend_from_slice(&metadata.resume_token);
    input.extend_from_slice(&metadata.generation.to_be_bytes());
    input.extend(metadata.verified.iter().map(|value| u8::from(*value)));
    input
}

fn expected_chunk_len(metadata: &StageMetadata, index: u32) -> Result<usize, CasError> {
    expected_chunk_len_for(metadata.plaintext_len, index)
}

fn expected_chunk_len_for(length: u64, index: u32) -> Result<usize, CasError> {
    if index >= validate_chunk_count(length)? {
        return Err(CasError::ChunkOutOfRange(index));
    }
    let start = index as u64 * CHUNK_SIZE as u64;
    Ok((length - start).min(CHUNK_SIZE as u64) as usize)
}

fn validate_chunk_count(length: u64) -> Result<u32, CasError> {
    let chunks = if length == 0 {
        1
    } else {
        length.div_ceil(CHUNK_SIZE as u64)
    };
    u32::try_from(chunks).map_err(|_| CasError::ChunkCountOverflow)
}

fn validate_object_length(length: u64, limits: &CasLimits) -> Result<(), CasError> {
    validate_chunk_count(length)?;
    if length > limits.max_object_bytes {
        return Err(CasError::ObjectTooLarge {
            length,
            limit: limits.max_object_bytes,
        });
    }
    Ok(())
}

fn bitmap_ranges(bitmap: &[bool]) -> Vec<(u32, u32)> {
    let mut ranges = Vec::new();
    let mut start = None;
    for (index, verified) in bitmap.iter().copied().chain([false]).enumerate() {
        match (start, verified) {
            (None, true) => start = Some(index as u32),
            (Some(first), false) => {
                ranges.push((first, index as u32));
                start = None;
            }
            _ => {}
        }
    }
    ranges
}

fn metadata_size_limit(limits: &CasLimits) -> Result<u64, CasError> {
    let chunks = validate_chunk_count(limits.max_object_bytes)? as u64;
    let calculated = 1024_u64
        .checked_add(chunks.checked_mul(6).ok_or(CasError::SizeOverflow)?)
        .ok_or(CasError::SizeOverflow)?;
    Ok(calculated.min(MAX_METADATA_BYTES))
}

fn write_metadata(
    stage: &Directory,
    metadata: &StageMetadata,
    limits: &CasLimits,
) -> Result<(), CasError> {
    let bytes = serde_json::to_vec(metadata).map_err(CasError::Metadata)?;
    let limit = metadata_size_limit(limits)?;
    if bytes.len() as u64 > limit {
        return Err(CasError::CorruptResumeMetadata);
    }
    let mut temporary = TempFile::create(stage, "metadata.tmp")?;
    temporary.file_mut().write_all(&bytes)?;
    temporary.file_mut().sync_all()?;
    temporary.rename_to(stage, "metadata.json")?;
    stage.sync()?;
    Ok(())
}

fn read_metadata(stage: &Directory, limits: &CasLimits) -> Result<StageMetadata, CasError> {
    let file = stage.open_regular("metadata.json", libc::O_RDONLY)?;
    let bytes = read_bounded(file, metadata_size_limit(limits)?)?;
    serde_json::from_slice(&bytes).map_err(CasError::Metadata)
}

fn verify_marked_chunks(
    chunks: &Directory,
    metadata: &StageMetadata,
    key: &ProjectKey,
) -> Result<(), CasError> {
    for (index, verified) in metadata.verified.iter().copied().enumerate() {
        if verified {
            let envelope = read_chunk(chunks, metadata, index as u32)?;
            let plaintext = key.decrypt(
                &envelope.nonce,
                &envelope.ciphertext,
                &chunk_aad(metadata, index as u32)?,
            )?;
            if plaintext.len() != expected_chunk_len(metadata, index as u32)? {
                return Err(CasError::CorruptResumeMetadata);
            }
        }
    }
    Ok(())
}

fn read_chunk(
    chunks: &Directory,
    metadata: &StageMetadata,
    index: u32,
) -> Result<EncryptedChunk, CasError> {
    let expected = expected_chunk_len(metadata, index)? + NONCE_BYTES + TAG_BYTES;
    let file = chunks.open_regular(&format!("{index}.chunk"), libc::O_RDONLY)?;
    let bytes =
        read_exact_size(file, expected as u64).map_err(|_| CasError::TruncatedCiphertext(index))?;
    let mut nonce = [0; NONCE_BYTES];
    nonce.copy_from_slice(&bytes[..NONCE_BYTES]);
    Ok(EncryptedChunk {
        nonce,
        ciphertext: bytes[NONCE_BYTES..].to_vec(),
    })
}

fn write_container_header(file: &mut File, metadata: &StageMetadata) -> Result<(), CasError> {
    file.write_all(CONTAINER_MAGIC)?;
    file.write_all(&metadata.project_id)?;
    file.write_all(&metadata.object_type.to_be_bytes())?;
    file.write_all(&metadata.version.to_be_bytes())?;
    file.write_all(&metadata.object_id)?;
    file.write_all(&metadata.key_id.0)?;
    file.write_all(&metadata.plaintext_len.to_be_bytes())?;
    file.write_all(&metadata.chunk_count()?.to_be_bytes())?;
    Ok(())
}

fn verify_container(
    mut file: File,
    domain: ObjectDomain,
    object_id: ObjectId,
    keys: &dyn ProjectKeyProvider,
    limits: &CasLimits,
) -> Result<(File, KeyId), CasError> {
    let key_id = read_container_key_id(&mut file)?;
    file.seek(SeekFrom::Start(0))?;
    let key = keys.project_key(domain.project_id, key_id)?;
    verify_container_with_key(file, domain, object_id, key_id, &key, limits)
}

fn read_container_key_id(file: &mut File) -> Result<KeyId, CasError> {
    let mut prefix = [0; 92];
    file.read_exact(&mut prefix)
        .map_err(|_| CasError::CorruptLiveObject)?;
    if &prefix[..8] != CONTAINER_MAGIC {
        return Err(CasError::CorruptLiveObject);
    }
    Ok(KeyId(prefix[76..92].try_into().unwrap()))
}

fn verify_container_with_key(
    mut file: File,
    domain: ObjectDomain,
    object_id: ObjectId,
    expected_key_id: KeyId,
    key: &ProjectKey,
    limits: &CasLimits,
) -> Result<(File, KeyId), CasError> {
    let length = regular_file_len(&file)?;
    if length > maximum_container_size(limits.max_object_bytes)? {
        return Err(CasError::CorruptLiveObject);
    }
    let mut header = [0; CONTAINER_HEADER_BYTES as usize];
    file.read_exact(&mut header)
        .map_err(|_| CasError::CorruptLiveObject)?;
    if &header[..8] != CONTAINER_MAGIC
        || &header[8..40] != domain.project_id.as_bytes()
        || u16::from_be_bytes(header[40..42].try_into().unwrap()) != domain.object_type.get()
        || u16::from_be_bytes(header[42..44].try_into().unwrap()) != domain.version
        || header[44..76] != object_id.0
        || header[76..92] != expected_key_id.0
    {
        return Err(CasError::CorruptLiveObject);
    }
    let plaintext_len = u64::from_be_bytes(header[92..100].try_into().unwrap());
    validate_object_length(plaintext_len, limits).map_err(|_| CasError::CorruptLiveObject)?;
    let chunks = u32::from_be_bytes(header[100..104].try_into().unwrap());
    if chunks != validate_chunk_count(plaintext_len)?
        || length != exact_container_size(plaintext_len, chunks)?
    {
        return Err(CasError::CorruptLiveObject);
    }
    let metadata = StageMetadata::new(
        domain,
        object_id,
        plaintext_len,
        ResumeToken([0; 32]),
        expected_key_id,
    )?;
    let mut hasher = object_hasher(domain, plaintext_len);
    for index in 0..chunks {
        let mut nonce = [0; NONCE_BYTES];
        file.read_exact(&mut nonce)
            .map_err(|_| CasError::CorruptLiveObject)?;
        let mut encoded_length = [0; 4];
        file.read_exact(&mut encoded_length)
            .map_err(|_| CasError::CorruptLiveObject)?;
        let ciphertext_len = u32::from_be_bytes(encoded_length) as usize;
        if ciphertext_len != expected_chunk_len(&metadata, index)? + TAG_BYTES {
            return Err(CasError::CorruptLiveObject);
        }
        let mut ciphertext = vec![0; ciphertext_len];
        file.read_exact(&mut ciphertext)
            .map_err(|_| CasError::CorruptLiveObject)?;
        let plaintext = key
            .decrypt(&nonce, &ciphertext, &chunk_aad(&metadata, index)?)
            .map_err(|_| CasError::CorruptLiveObject)?;
        hasher.update(&plaintext);
    }
    if ObjectId(*hasher.finalize().as_bytes()) != object_id {
        return Err(CasError::CorruptLiveObject);
    }
    file.seek(SeekFrom::Start(0))?;
    Ok((file, expected_key_id))
}

fn exact_container_size(plaintext_len: u64, chunks: u32) -> Result<u64, CasError> {
    CONTAINER_HEADER_BYTES
        .checked_add(plaintext_len)
        .and_then(|size| {
            size.checked_add(chunks as u64 * (NONCE_BYTES as u64 + TAG_BYTES as u64 + 4))
        })
        .ok_or(CasError::SizeOverflow)
}

fn maximum_container_size(max_plaintext_len: u64) -> Result<u64, CasError> {
    exact_container_size(max_plaintext_len, validate_chunk_count(max_plaintext_len)?)
}

fn read_bounded(mut file: File, limit: u64) -> Result<Vec<u8>, CasError> {
    let length = regular_file_len(&file)?;
    if length > limit {
        return Err(CasError::ReadLimitExceeded { length, limit });
    }
    let mut bytes = Vec::with_capacity(length as usize);
    Read::by_ref(&mut file)
        .take(limit + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 != length {
        return Err(CasError::UnexpectedFileLength);
    }
    Ok(bytes)
}

fn read_exact_size(mut file: File, expected: u64) -> Result<Vec<u8>, CasError> {
    let length = regular_file_len(&file)?;
    if length != expected {
        return Err(CasError::UnexpectedFileLength);
    }
    let mut bytes = vec![0; expected as usize];
    file.read_exact(&mut bytes)?;
    let mut trailing = [0; 1];
    if file.read(&mut trailing)? != 0 {
        return Err(CasError::UnexpectedFileLength);
    }
    Ok(bytes)
}

fn regular_file_len(file: &File) -> Result<u64, CasError> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe { libc::fstat(file.as_raw_fd(), stat.as_mut_ptr()) } != 0 {
        return Err(CasError::Io(io::Error::last_os_error()));
    }
    let stat = unsafe { stat.assume_init() };
    if stat.st_mode & libc::S_IFMT != libc::S_IFREG {
        return Err(CasError::NotRegularFile);
    }
    u64::try_from(stat.st_size).map_err(|_| CasError::UnexpectedFileLength)
}

fn live_name(object_id: ObjectId) -> String {
    format!("{object_id}.cas")
}

fn random_bytes<const N: usize>() -> Result<[u8; N], CasError> {
    let mut bytes = [0; N];
    getrandom::getrandom(&mut bytes).map_err(CasError::Random)?;
    Ok(bytes)
}

fn unique_name(prefix: &str) -> Result<String, CasError> {
    Ok(format!("{prefix}.{}", hex::encode(random_bytes::<16>()?)))
}

struct TempFile {
    directory: Directory,
    name: String,
    file: File,
    armed: bool,
}

impl TempFile {
    fn create(directory: &Directory, prefix: &str) -> Result<Self, CasError> {
        let directory = directory.try_clone()?;
        let name = unique_name(prefix)?;
        let file = directory.create_new(&name)?;
        Ok(Self {
            directory,
            name,
            file,
            armed: true,
        })
    }

    fn file_mut(&mut self) -> &mut File {
        &mut self.file
    }

    fn link_to(&self, destination_dir: &Directory, destination: &str) -> io::Result<()> {
        self.directory
            .link(&self.name, destination_dir, destination)
    }

    fn rename_to(mut self, destination_dir: &Directory, destination: &str) -> Result<(), CasError> {
        self.directory
            .rename(&self.name, destination_dir, destination)?;
        self.armed = false;
        Ok(())
    }

    fn remove(mut self) -> Result<(), CasError> {
        self.directory.unlink_file(&self.name)?;
        self.directory.sync()?;
        self.armed = false;
        Ok(())
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        if self.armed {
            let _ = self.directory.unlink_file(&self.name);
            let _ = self.directory.sync();
        }
    }
}

struct Directory {
    fd: OwnedFd,
}

impl Directory {
    fn try_clone(&self) -> Result<Self, CasError> {
        let fd = unsafe { libc::fcntl(self.fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        if fd < 0 {
            return Err(CasError::Io(io::Error::last_os_error()));
        }
        Ok(Self {
            fd: unsafe { OwnedFd::from_raw_fd(fd) },
        })
    }

    fn open_directory(&self, name: &str) -> Result<Self, CasError> {
        let fd = self.open_fd(
            name,
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0,
        )?;
        Ok(Self { fd })
    }

    fn open_regular(&self, name: &str, flags: libc::c_int) -> io::Result<File> {
        let fd = self.open_fd_io(
            name,
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
            0,
        )?;
        let file = unsafe { File::from_raw_fd(fd.into_raw_fd()) };
        regular_file_len(&file).map_err(cas_error_to_io)?;
        Ok(file)
    }

    fn create_new(&self, name: &str) -> Result<File, CasError> {
        let fd = self.open_fd(
            name,
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )?;
        Ok(unsafe { File::from_raw_fd(fd.into_raw_fd()) })
    }

    fn entry_names(&self) -> Result<Vec<String>, CasError> {
        let duplicate = self
            .open_fd(".", libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC, 0)?
            .into_raw_fd();
        let stream = unsafe { libc::fdopendir(duplicate) };
        if stream.is_null() {
            unsafe { libc::close(duplicate) };
            return Err(CasError::Io(io::Error::last_os_error()));
        }
        let stream = DirectoryStream(stream);
        let mut names = Vec::new();
        loop {
            let entry = unsafe { libc::readdir(stream.0) };
            if entry.is_null() {
                break;
            }
            let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
            if name == b"." || name == b".." {
                continue;
            }
            if let Ok(name) = std::str::from_utf8(name) {
                names.push(name.to_string());
            }
        }
        Ok(names)
    }

    fn is_regular_entry(&self, name: &str) -> Result<bool, CasError> {
        let name = c_name(name)?;
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe {
            libc::fstatat(
                self.fd.as_raw_fd(),
                name.as_ptr(),
                stat.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::NotFound {
                return Ok(false);
            }
            return Err(CasError::Io(error));
        }
        let stat = unsafe { stat.assume_init() };
        Ok(stat.st_mode & libc::S_IFMT == libc::S_IFREG)
    }

    fn sweep_temp_files(&self) -> Result<usize, CasError> {
        let mut removed = 0;
        for name in self.entry_names()? {
            if is_strict_temp_name(&name) && self.is_regular_entry(&name)? {
                match self.unlink_file(&name) {
                    Ok(()) => removed += 1,
                    Err(CasError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {}
                    Err(error) => return Err(error),
                }
            }
        }
        if removed != 0 {
            self.sync()?;
        }
        Ok(removed)
    }

    fn mkdir(&self, name: &str) -> Result<(), CasError> {
        match self.mkdir_exclusive(name) {
            Ok(()) => Ok(()),
            Err(CasError::Io(error)) if error.kind() == io::ErrorKind::AlreadyExists => {
                self.open_directory(name).map(|_| ())
            }
            Err(error) => Err(error),
        }
    }

    fn mkdir_exclusive(&self, name: &str) -> Result<(), CasError> {
        let name = c_name(name)?;
        if unsafe { libc::mkdirat(self.fd.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
            return Err(CasError::Io(io::Error::last_os_error()));
        }
        self.sync()?;
        Ok(())
    }

    fn link(&self, source: &str, destination_dir: &Self, destination: &str) -> io::Result<()> {
        let source = c_name_io(source)?;
        let destination = c_name_io(destination)?;
        if unsafe {
            libc::linkat(
                self.fd.as_raw_fd(),
                source.as_ptr(),
                destination_dir.fd.as_raw_fd(),
                destination.as_ptr(),
                0,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    fn rename(
        &self,
        source: &str,
        destination_dir: &Self,
        destination: &str,
    ) -> Result<(), CasError> {
        let source = c_name(source)?;
        let destination = c_name(destination)?;
        if unsafe {
            libc::renameat(
                self.fd.as_raw_fd(),
                source.as_ptr(),
                destination_dir.fd.as_raw_fd(),
                destination.as_ptr(),
            )
        } != 0
        {
            return Err(CasError::Io(io::Error::last_os_error()));
        }
        Ok(())
    }

    fn unlink_file(&self, name: &str) -> Result<(), CasError> {
        self.unlink(name, 0)
    }

    fn unlink_directory(&self, name: &str) -> Result<(), CasError> {
        self.unlink(name, libc::AT_REMOVEDIR)
    }

    fn unlink(&self, name: &str, flags: libc::c_int) -> Result<(), CasError> {
        let name = c_name(name)?;
        if unsafe { libc::unlinkat(self.fd.as_raw_fd(), name.as_ptr(), flags) } != 0 {
            return Err(CasError::Io(io::Error::last_os_error()));
        }
        Ok(())
    }

    fn sync(&self) -> Result<(), CasError> {
        let file = unsafe { File::from_raw_fd(self.try_clone()?.fd.into_raw_fd()) };
        file.sync_all()?;
        Ok(())
    }

    fn open_fd(
        &self,
        name: &str,
        flags: libc::c_int,
        mode: libc::mode_t,
    ) -> Result<OwnedFd, CasError> {
        self.open_fd_io(name, flags, mode).map_err(CasError::Io)
    }

    fn open_fd_io(
        &self,
        name: &str,
        flags: libc::c_int,
        mode: libc::mode_t,
    ) -> io::Result<OwnedFd> {
        let name = c_name_io(name)?;
        let fd = unsafe {
            libc::openat(
                self.fd.as_raw_fd(),
                name.as_ptr(),
                flags,
                mode as libc::c_uint,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }
}

struct DirectoryStream(*mut libc::DIR);

impl Drop for DirectoryStream {
    fn drop(&mut self) {
        unsafe { libc::closedir(self.0) };
    }
}

fn is_lower_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn is_strict_temp_name(name: &str) -> bool {
    let Some((prefix, suffix)) = name.rsplit_once(".tmp.") else {
        return false;
    };
    is_lower_hex(suffix, 32)
        && (prefix == "metadata"
            || prefix == "object"
            || (!prefix.is_empty() && prefix.bytes().all(|byte| byte.is_ascii_digit())))
}

fn is_format_temp_name(name: &str) -> bool {
    name.strip_prefix("format.tmp.")
        .is_some_and(|suffix| is_lower_hex(suffix, 32))
}

fn sweep_format_temps(root: &Directory) -> Result<(), CasError> {
    let mut removed = false;
    for name in root.entry_names()? {
        if is_format_temp_name(&name) && root.is_regular_entry(&name)? {
            match root.unlink_file(&name) {
                Ok(()) => removed = true,
                Err(CasError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
    }
    if removed {
        root.sync()?;
    }
    Ok(())
}

fn retirement_fence_name(key_id: KeyId) -> String {
    format!(".retire-{}.fence", hex::encode(key_id.0))
}

fn load_retirement_fences(root: &Directory) -> Result<HashSet<KeyId>, CasError> {
    let mut result = HashSet::new();
    for name in root.entry_names()? {
        let Some(hex_id) = name
            .strip_prefix(".retire-")
            .and_then(|value| value.strip_suffix(".fence"))
        else {
            continue;
        };
        if !is_lower_hex(hex_id, 32) || !root.is_regular_entry(&name)? {
            continue;
        }
        let decoded = hex::decode(hex_id).map_err(|_| CasError::InvalidName)?;
        result.insert(KeyId(
            decoded.try_into().map_err(|_| CasError::InvalidName)?,
        ));
    }
    Ok(result)
}

fn sweep_staging_tree(staging: &Directory) -> Result<(), CasError> {
    staging.sweep_temp_files()?;
    for name in staging.entry_names()? {
        if !is_lower_hex(&name, 32) {
            continue;
        }
        let stage = match staging.open_directory(&name) {
            Ok(stage) => stage,
            Err(CasError::Io(error))
                if matches!(
                    error.raw_os_error(),
                    Some(libc::ELOOP) | Some(libc::ENOTDIR)
                ) =>
            {
                continue;
            }
            Err(error) => return Err(error),
        };
        stage.sweep_temp_files()?;
        match stage.open_directory("chunks") {
            Ok(chunks) => {
                chunks.sweep_temp_files()?;
            }
            Err(CasError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

trait IntoRawFdLocal {
    fn into_raw_fd(self) -> libc::c_int;
}

impl IntoRawFdLocal for OwnedFd {
    fn into_raw_fd(self) -> libc::c_int {
        use std::os::fd::IntoRawFd;
        IntoRawFd::into_raw_fd(self)
    }
}

fn open_or_create_root(path: &Path) -> Result<Directory, CasError> {
    let parent_path = path.parent().ok_or(CasError::InvalidRootPath)?;
    let name = path
        .file_name()
        .ok_or(CasError::InvalidRootPath)
        .and_then(c_os_name)?;
    let parent = open_directory_path(parent_path)?;
    match parent.mkdir_exclusive(&name) {
        Ok(()) => parent.sync()?,
        Err(CasError::Io(error)) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    let root = parent.open_directory(&name)?;
    root.sync()?;
    Ok(root)
}

/// Pre-release reset contract: an unmarked/non-v2 non-empty root must be
/// removed or migrated by an explicit operator action. We never infer a key_id
/// for v1 ciphertext and never reset storage while opening it.
fn enforce_root_format(root: &Directory) -> Result<(), CasError> {
    let entries = root.entry_names()?;
    if entries.is_empty() {
        let mut marker = TempFile::create(root, "format.tmp")?;
        marker.file_mut().write_all(ROOT_FORMAT_V2)?;
        marker.file_mut().sync_all()?;
        marker.rename_to(root, ROOT_FORMAT_MARKER)?;
        root.sync()?;
        return Ok(());
    }
    if !entries.iter().any(|name| name == ROOT_FORMAT_MARKER) {
        return Err(CasError::IncompatibleFormatNeedsMigration);
    }
    let marker = root
        .open_regular(ROOT_FORMAT_MARKER, libc::O_RDONLY)
        .map_err(|_| CasError::IncompatibleFormatNeedsMigration)?;
    let bytes = read_exact_size(marker, ROOT_FORMAT_V2.len() as u64)
        .map_err(|_| CasError::IncompatibleFormatNeedsMigration)?;
    if bytes != ROOT_FORMAT_V2 {
        return Err(CasError::IncompatibleFormatNeedsMigration);
    }
    Ok(())
}

fn enforce_live_v2(live: &Directory) -> Result<(), CasError> {
    for name in live.entry_names()? {
        if !name.ends_with(".cas") || !live.is_regular_entry(&name)? {
            continue;
        }
        let mut file = live.open_regular(&name, libc::O_RDONLY)?;
        if regular_file_len(&file)? < CONTAINER_HEADER_BYTES {
            return Err(CasError::IncompatibleFormatNeedsMigration);
        }
        let mut magic = [0; 8];
        file.read_exact(&mut magic)
            .map_err(|_| CasError::IncompatibleFormatNeedsMigration)?;
        if &magic != CONTAINER_MAGIC {
            return Err(CasError::IncompatibleFormatNeedsMigration);
        }
    }
    Ok(())
}

fn open_directory_path(path: &Path) -> Result<Directory, CasError> {
    let bytes = path.as_os_str().as_bytes();
    let c_path = CString::new(bytes).map_err(|_| CasError::InvalidRootPath)?;
    let fd = unsafe {
        libc::open(
            c_path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(CasError::Io(io::Error::last_os_error()));
    }
    Ok(Directory {
        fd: unsafe { OwnedFd::from_raw_fd(fd) },
    })
}

fn c_os_name(name: &OsStr) -> Result<String, CasError> {
    let bytes = name.as_bytes();
    if bytes.is_empty() || bytes.contains(&b'/') || bytes.contains(&0) {
        return Err(CasError::InvalidName);
    }
    String::from_utf8(bytes.to_vec()).map_err(|_| CasError::InvalidName)
}

fn c_name(name: &str) -> Result<CString, CasError> {
    c_name_io(name).map_err(CasError::Io)
}

fn c_name_io(name: &str) -> io::Result<CString> {
    if name.is_empty() || name.as_bytes().contains(&b'/') {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid name"));
    }
    CString::new(name).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in name"))
}

fn cas_error_to_io(error: CasError) -> io::Error {
    match error {
        CasError::Io(error) => error,
        other => io::Error::new(io::ErrorKind::InvalidData, other),
    }
}

#[derive(Debug)]
pub enum CasError {
    Io(io::Error),
    Random(getrandom::Error),
    Metadata(serde_json::Error),
    Crypto(CryptoError),
    InvalidObjectType,
    InvalidRootPath,
    InvalidName,
    NotRegularFile,
    ObjectTooLarge {
        length: u64,
        limit: u64,
    },
    StagingLimitExceeded,
    ReadLimitExceeded {
        length: u64,
        limit: u64,
    },
    SizeOverflow,
    ChunkCountOverflow,
    GenerationExhausted,
    ChunkOutOfRange(u32),
    ChunkConflict(u32),
    WrongChunkLength {
        index: u32,
        expected: usize,
        actual: usize,
    },
    TruncatedCiphertext(u32),
    UnexpectedFileLength,
    CorruptResumeMetadata,
    StaleResumeMetadata,
    IncompleteObject,
    ObjectIdentityMismatch {
        expected: ObjectId,
        actual: ObjectId,
    },
    CorruptLiveObject,
    KeyUnavailable(KeyId),
    RetiredKeyFence(KeyId),
    RetirementFenceChanged,
    Poisoned,
    IncompatibleFormatNeedsMigration,
}

impl fmt::Display for CasError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for CasError {}

impl From<io::Error> for CasError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<CryptoError> for CasError {
    fn from(error: CryptoError) -> Self {
        Self::Crypto(error)
    }
}
