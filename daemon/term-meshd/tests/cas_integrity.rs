#[path = "../src/sync/mod.rs"]
mod sync;

use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::os::unix::fs::symlink;
use std::sync::{Arc, RwLock};

use sync::{
    encrypt_chunk, encrypt_chunk_for_key, CasError, CasLimits, CasStore, EncryptedChunk, KeyId,
    ObjectDomain, ObjectId, ObjectType, ProjectId, ProjectKey, ProjectKeyMaterial,
    ProjectKeyProvider, StagingObject, CHUNK_SIZE,
};

const KEY: [u8; 32] = [0x42; 32];
const NEW_KEY: [u8; 32] = [0x43; 32];

struct FixedKeyProvider;

impl ProjectKeyProvider for FixedKeyProvider {
    fn current_project_key(&self, _project_id: ProjectId) -> Result<ProjectKeyMaterial, CasError> {
        Ok(ProjectKeyMaterial {
            key_id: KeyId([1; 16]),
            key: ProjectKey::new(KEY),
        })
    }

    fn project_key(&self, _project_id: ProjectId, key_id: KeyId) -> Result<ProjectKey, CasError> {
        if key_id != KeyId([1; 16]) {
            return Err(CasError::KeyUnavailable(key_id));
        }
        Ok(ProjectKey::new(KEY))
    }
}

struct RotatingKeyProvider {
    current: RwLock<KeyId>,
    keys: RwLock<HashMap<KeyId, [u8; 32]>>,
}

impl RotatingKeyProvider {
    fn new() -> Self {
        Self {
            current: RwLock::new(KeyId([1; 16])),
            keys: RwLock::new(HashMap::from([
                (KeyId([1; 16]), KEY),
                (KeyId([2; 16]), NEW_KEY),
            ])),
        }
    }
}

impl ProjectKeyProvider for RotatingKeyProvider {
    fn current_project_key(&self, _: ProjectId) -> Result<ProjectKeyMaterial, CasError> {
        let key_id = *self.current.read().unwrap();
        let key = self
            .keys
            .read()
            .unwrap()
            .get(&key_id)
            .copied()
            .ok_or(CasError::KeyUnavailable(key_id))?;
        Ok(ProjectKeyMaterial {
            key_id,
            key: ProjectKey::new(key),
        })
    }
    fn project_key(&self, _: ProjectId, key_id: KeyId) -> Result<ProjectKey, CasError> {
        self.keys
            .read()
            .unwrap()
            .get(&key_id)
            .copied()
            .map(ProjectKey::new)
            .ok_or(CasError::KeyUnavailable(key_id))
    }
}

fn domain(project: u8, object_type: ObjectType, version: u16) -> ObjectDomain {
    ObjectDomain {
        project_id: ProjectId::from_bytes([project; 32]),
        object_type,
        version,
    }
}

fn store(root: &std::path::Path) -> CasStore {
    CasStore::open(root, CasLimits::default(), Arc::new(FixedKeyProvider)).unwrap()
}

#[test]
fn root_v2_marker_is_atomic_and_unmarked_or_v1_storage_requires_explicit_reset() {
    let empty = tempfile::tempdir().unwrap();
    let _store = store(empty.path());
    assert_eq!(
        fs::read(empty.path().join(".term-mesh-cas-format")).unwrap(),
        b"term-mesh-cas-v2\n"
    );

    let unmarked = tempfile::tempdir().unwrap();
    fs::create_dir(unmarked.path().join("live")).unwrap();
    assert!(matches!(
        CasStore::open(
            unmarked.path(),
            CasLimits::default(),
            Arc::new(FixedKeyProvider)
        ),
        Err(CasError::IncompatibleFormatNeedsMigration)
    ));

    let legacy = tempfile::tempdir().unwrap();
    fs::write(
        legacy.path().join(".term-mesh-cas-format"),
        b"term-mesh-cas-v2\n",
    )
    .unwrap();
    fs::create_dir(legacy.path().join("live")).unwrap();
    fs::create_dir(legacy.path().join("staging")).unwrap();
    let mut v1 = vec![0; 104];
    v1[..8].copy_from_slice(b"TMCAS\0\x01\0");
    fs::write(legacy.path().join("live/legacy.cas"), v1).unwrap();
    assert!(matches!(
        CasStore::open(
            legacy.path(),
            CasLimits::default(),
            Arc::new(FixedKeyProvider)
        ),
        Err(CasError::IncompatibleFormatNeedsMigration)
    ));

    fs::write(legacy.path().join("live/legacy.cas"), b"TMCAS\0\x02\0").unwrap();
    assert!(matches!(
        CasStore::open(
            legacy.path(),
            CasLimits::default(),
            Arc::new(FixedKeyProvider)
        ),
        Err(CasError::IncompatibleFormatNeedsMigration)
    ));
}

#[test]
fn root_format_creation_sweeps_only_strict_regular_crash_temp() {
    let recovered = tempfile::tempdir().unwrap();
    let stale = recovered
        .path()
        .join(format!("format.tmp.{}", "a".repeat(32)));
    fs::write(&stale, b"partial").unwrap();
    let _cas = store(recovered.path());
    assert!(!stale.exists());
    assert!(recovered.path().join(".term-mesh-cas-format").is_file());

    let near_miss = tempfile::tempdir().unwrap();
    let preserved = near_miss.path().join("format.tmp.NOT-STRICT");
    fs::write(&preserved, b"keep").unwrap();
    assert!(matches!(
        CasStore::open(
            near_miss.path(),
            CasLimits::default(),
            Arc::new(FixedKeyProvider)
        ),
        Err(CasError::IncompatibleFormatNeedsMigration)
    ));
    assert!(preserved.is_file());
}

#[test]
fn retirement_fence_survives_restart_and_blocks_concurrent_old_key_stages() {
    let temp = tempfile::tempdir().unwrap();
    let cas = store(temp.path());
    cas.test_install_retirement_fence(KeyId([1; 16])).unwrap();
    drop(cas);

    let cas = Arc::new(store(temp.path()));
    let handles = (0..8).map(|index| {
        let cas = cas.clone();
        std::thread::spawn(move || {
            let domain = domain(120 + index as u8, ObjectType::FILE, 1);
            let id = ObjectId::for_plaintext(domain, b"x");
            matches!(cas.begin_stage(domain, id, 1), Err(CasError::RetiredKeyFence(key)) if key == KeyId([1; 16]))
        })
    }).collect::<Vec<_>>();
    assert!(handles.into_iter().all(|handle| handle.join().unwrap()));
    cas.test_complete_retirement_fence(KeyId([1; 16])).unwrap();
    let domain = domain(119, ObjectType::FILE, 1);
    let id = ObjectId::for_plaintext(domain, b"x");
    assert!(cas.begin_stage(domain, id, 1).is_ok());
}

#[test]
fn retirement_fence_serializes_finish_promotion_and_staging_cleanup() {
    let temp = tempfile::tempdir().unwrap();
    for iteration in 0..100 {
        let root = temp.path().join(iteration.to_string());
        let cas = store(&root);
        let domain = domain(118, ObjectType::FILE, 1);
        let id = ObjectId::for_plaintext(domain, b"x");
        let mut stage = cas.begin_stage(domain, id, 1).unwrap();
        write_chunk(&mut stage, domain, id, 1, 0, b"x").unwrap();

        cas.test_install_retirement_fence(KeyId([1; 16])).unwrap();
        assert!(matches!(
            stage.finish(),
            Err(CasError::RetiredKeyFence(key)) if key == KeyId([1; 16])
        ));
        assert_eq!(
            cas.test_retirement_counts(KeyId([1; 16])).unwrap(),
            (0, 1, 0)
        );
    }
}

fn write_chunk(
    stage: &mut StagingObject,
    domain: ObjectDomain,
    id: ObjectId,
    total_len: u64,
    index: u32,
    plaintext: &[u8],
) -> Result<(), CasError> {
    let envelope = encrypt_chunk(
        &ProjectKey::new(KEY),
        domain,
        id,
        total_len,
        index,
        plaintext,
    )?;
    stage.write_encrypted_chunk(index, &envelope)
}

#[test]
fn reopened_resume_requires_exact_checkpoint_and_preserves_verified_chunks() {
    let temp = tempfile::tempdir().unwrap();
    let domain = domain(73, ObjectType::FILE, 1);
    let plaintext = b"checkpoint replay survives reopen";
    let id = ObjectId::for_plaintext(domain, plaintext);
    let cas = store(temp.path());
    let mut stage = cas.begin_stage(domain, id, plaintext.len() as u64).unwrap();
    let older = stage.checkpoint();
    let stage_id = stage.stage_id();
    write_chunk(&mut stage, domain, id, plaintext.len() as u64, 0, plaintext).unwrap();
    let exact = stage.checkpoint();
    assert_ne!(older.generation, exact.generation);
    drop(stage);
    drop(cas);

    let reopened = store(temp.path());
    assert!(matches!(
        reopened.resume_stage(stage_id, older),
        Err(CasError::StaleResumeMetadata)
    ));
    let resumed = reopened.resume_stage(stage_id, exact).unwrap();
    assert_eq!(resumed.verified_ranges(), vec![(0, 1)]);
    assert_eq!(resumed.checkpoint(), exact);
    drop(resumed);

    let repeated = reopened.resume_stage(stage_id, exact).unwrap();
    assert_eq!(repeated.verified_ranges(), vec![(0, 1)]);
    assert_eq!(repeated.checkpoint(), exact);
}

fn ingest(cas: &CasStore, domain: ObjectDomain, plaintext: &[u8]) -> ObjectId {
    let id = ObjectId::for_plaintext(domain, plaintext);
    let mut stage = cas.begin_stage(domain, id, plaintext.len() as u64).unwrap();
    let chunks = if plaintext.is_empty() {
        1
    } else {
        plaintext.len().div_ceil(CHUNK_SIZE)
    };
    for index in 0..chunks {
        let start = index * CHUNK_SIZE;
        let end = (start + CHUNK_SIZE).min(plaintext.len());
        write_chunk(
            &mut stage,
            domain,
            id,
            plaintext.len() as u64,
            index as u32,
            &plaintext[start..end],
        )
        .unwrap();
    }
    stage.finish().unwrap();
    id
}

#[test]
fn reopened_live_object_reads_exact_bounded_encrypted_chunks() {
    let temp = tempfile::tempdir().unwrap();
    let object_domain = domain(30, ObjectType::FILE, 1);
    let mut plaintext = vec![0x55; CHUNK_SIZE + 17];
    plaintext[CHUNK_SIZE] = 0x77;
    let id = ingest(&store(temp.path()), object_domain, &plaintext);
    let reopened = store(temp.path());
    let live = reopened.get_live(object_domain, id).unwrap().unwrap();
    let (first_len, first) = live.read_encrypted_chunk(0).unwrap();
    let (last_len, last) = live.read_encrypted_chunk(1).unwrap();
    assert_eq!(first_len as usize, CHUNK_SIZE);
    assert_eq!(last_len, 17);
    assert_eq!(first.ciphertext().len(), CHUNK_SIZE + 16);
    assert_eq!(last.ciphertext().len(), 17 + 16);
    assert!(matches!(
        live.read_encrypted_chunk(2),
        Err(CasError::ChunkOutOfRange(2))
    ));
}

#[test]
fn rotation_writes_current_key_and_reads_old_key_until_retired() {
    let temporary = tempfile::tempdir().unwrap();
    let provider = Arc::new(RotatingKeyProvider::new());
    let cas = CasStore::open(temporary.path(), CasLimits::default(), provider.clone()).unwrap();
    let object_domain = domain(31, ObjectType::FILE, 1);
    let old_id = ingest(&cas, object_domain, b"old generation");
    assert_eq!(
        cas.get_live(object_domain, old_id).unwrap().unwrap().key_id,
        KeyId([1; 16])
    );

    *provider.current.write().unwrap() = KeyId([2; 16]);
    let plaintext = b"new generation";
    let new_id = ObjectId::for_plaintext(object_domain, plaintext);
    let mut stage = cas
        .begin_stage(object_domain, new_id, plaintext.len() as u64)
        .unwrap();
    let envelope = encrypt_chunk_for_key(
        &ProjectKey::new(NEW_KEY),
        KeyId([2; 16]),
        object_domain,
        new_id,
        plaintext.len() as u64,
        0,
        plaintext,
    )
    .unwrap();
    stage.write_encrypted_chunk(0, &envelope).unwrap();
    assert_eq!(stage.finish().unwrap().key_id, KeyId([2; 16]));
    assert!(cas.get_live(object_domain, old_id).unwrap().is_some());
    assert!(cas.get_live(object_domain, new_id).unwrap().is_some());

    provider.keys.write().unwrap().remove(&KeyId([1; 16]));
    assert!(matches!(
        cas.get_live(object_domain, old_id),
        Err(CasError::KeyUnavailable(key_id)) if key_id == KeyId([1; 16])
    ));
    assert!(cas.get_live(object_domain, new_id).unwrap().is_some());
}

#[test]
fn key_id_is_authenticated_even_when_two_ids_alias_the_same_raw_key() {
    let temporary = tempfile::tempdir().unwrap();
    let provider = Arc::new(RotatingKeyProvider::new());
    provider.keys.write().unwrap().insert(KeyId([2; 16]), KEY);
    let cas = CasStore::open(temporary.path(), CasLimits::default(), provider).unwrap();
    let object_domain = domain(32, ObjectType::FILE, 1);
    let object_id = ingest(&cas, object_domain, b"key id substitution");
    let live = temporary
        .path()
        .join("live")
        .join(format!("{object_id}.cas"));
    let mut file = OpenOptions::new().write(true).open(live).unwrap();
    file.seek(SeekFrom::Start(76)).unwrap();
    file.write_all(&[2; 16]).unwrap();
    file.sync_all().unwrap();
    assert!(matches!(
        cas.get_live(object_domain, object_id),
        Err(CasError::CorruptLiveObject)
    ));
}

#[test]
fn object_identity_is_deterministic_and_domain_separated() {
    let bytes = b"domain-separated content";
    let first = ObjectId::for_plaintext(domain(1, ObjectType::FILE, 1), bytes);
    assert_eq!(
        first,
        ObjectId::for_plaintext(domain(1, ObjectType::FILE, 1), bytes)
    );
    assert_eq!(
        first.to_string(),
        "f60b23f867295c7f151a7026fe0b3512c8cc0d4ddd6fb445c73e4f42b8ee0661"
    );
    assert_ne!(
        first,
        ObjectId::for_plaintext(domain(2, ObjectType::FILE, 1), bytes)
    );
    assert_ne!(
        first,
        ObjectId::for_plaintext(domain(1, ObjectType::MANIFEST, 1), bytes)
    );
    assert_ne!(
        first,
        ObjectId::for_plaintext(domain(1, ObjectType::FILE, 2), bytes)
    );
}

#[test]
fn exact_zero_four_mib_and_four_mib_plus_one_vectors_promote() {
    for (project, plaintext) in [
        (10, Vec::new()),
        (11, vec![0x11; CHUNK_SIZE]),
        (12, vec![0x22; CHUNK_SIZE + 1]),
    ] {
        let temp = tempfile::tempdir().unwrap();
        let cas = store(temp.path());
        let domain = domain(project, ObjectType::FILE, 1);
        let id = ingest(&cas, domain, &plaintext);
        assert!(cas.get_live(domain, id).unwrap().is_some());
    }
}

#[test]
fn nonce_is_internal_and_corrupt_or_substituted_envelopes_fail_closed() {
    let temp = tempfile::tempdir().unwrap();
    let cas = store(temp.path());
    let source = domain(20, ObjectType::FILE, 1);
    let target = domain(21, ObjectType::FILE, 1);
    let plaintext = b"authenticated bytes";
    let id = ObjectId::for_plaintext(source, plaintext);
    let first = encrypt_chunk(
        &ProjectKey::new(KEY),
        source,
        id,
        plaintext.len() as u64,
        0,
        plaintext,
    )
    .unwrap();
    let second = encrypt_chunk(
        &ProjectKey::new(KEY),
        source,
        id,
        plaintext.len() as u64,
        0,
        plaintext,
    )
    .unwrap();
    assert_ne!(first.nonce(), second.nonce());

    let mut stage = cas.begin_stage(source, id, plaintext.len() as u64).unwrap();
    let truncated = EncryptedChunk::from_parts(
        *first.nonce(),
        first.ciphertext()[..first.ciphertext().len() - 1].to_vec(),
    );
    assert!(matches!(
        stage.write_encrypted_chunk(0, &truncated),
        Err(CasError::WrongChunkLength { .. })
    ));
    let mut flipped = first.ciphertext().to_vec();
    flipped[0] ^= 1;
    assert!(matches!(
        stage.write_encrypted_chunk(0, &EncryptedChunk::from_parts(*first.nonce(), flipped)),
        Err(CasError::Crypto(_))
    ));
    assert!(matches!(
        stage.write_encrypted_chunk(1, &first),
        Err(CasError::ChunkOutOfRange(1))
    ));
    let mut substituted = cas.begin_stage(target, id, plaintext.len() as u64).unwrap();
    assert!(matches!(
        substituted.write_encrypted_chunk(0, &first),
        Err(CasError::Crypto(_))
    ));
    assert!(cas.get_live(source, id).unwrap().is_none());
}

#[test]
fn resumable_ranges_reverify_chunks_and_reject_valid_old_bitmap() {
    let temp = tempfile::tempdir().unwrap();
    let cas = store(temp.path());
    let domain = domain(30, ObjectType::FILE, 1);
    let plaintext = vec![0x33; CHUNK_SIZE + 1];
    let id = ObjectId::for_plaintext(domain, &plaintext);
    let mut stage = cas.begin_stage(domain, id, plaintext.len() as u64).unwrap();
    let stage_id = stage.stage_id();
    let stage_dir = temp.path().join("staging").join(stage_id.to_string());
    let old_metadata = fs::read(stage_dir.join("metadata.json")).unwrap();
    write_chunk(
        &mut stage,
        domain,
        id,
        plaintext.len() as u64,
        0,
        &plaintext[..CHUNK_SIZE],
    )
    .unwrap();
    let checkpoint = stage.checkpoint();
    drop(stage);

    let resumed = cas.resume_stage(stage_id, checkpoint).unwrap();
    assert_eq!(resumed.verified_ranges(), vec![(0, 1)]);
    drop(resumed);
    fs::write(stage_dir.join("metadata.json"), old_metadata).unwrap();
    assert!(matches!(
        cas.resume_stage(stage_id, checkpoint),
        Err(CasError::StaleResumeMetadata)
    ));
    assert!(cas.get_live(domain, id).unwrap().is_none());
}

#[test]
fn existing_chunk_is_never_deleted_and_mismatch_is_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let cas = store(temp.path());
    let domain = domain(40, ObjectType::FILE, 1);
    let expected = b"expected plaintext";
    let mut different = expected.to_vec();
    different[0] ^= 1;
    let id = ObjectId::for_plaintext(domain, expected);
    let mut stage = cas.begin_stage(domain, id, expected.len() as u64).unwrap();
    write_chunk(&mut stage, domain, id, expected.len() as u64, 0, expected).unwrap();
    let checkpoint = stage.checkpoint();
    let stage_id = stage.stage_id();
    drop(stage);
    let chunk_path = temp
        .path()
        .join("staging")
        .join(stage_id.to_string())
        .join("chunks/0.chunk");
    let original = fs::read(&chunk_path).unwrap();

    let bad = encrypt_chunk(
        &ProjectKey::new(KEY),
        domain,
        id,
        expected.len() as u64,
        0,
        &different,
    )
    .unwrap();
    let mut resumed = cas.resume_stage(stage_id, checkpoint).unwrap();
    assert!(matches!(
        resumed.write_encrypted_chunk(0, &bad),
        Err(CasError::ChunkConflict(0))
    ));
    assert_eq!(fs::read(chunk_path).unwrap(), original);
}

#[test]
fn actual_disk_chunk_truncation_and_giant_chunk_are_rejected_before_allocation() {
    let temp = tempfile::tempdir().unwrap();
    let cas = store(temp.path());
    let domain = domain(50, ObjectType::FILE, 1);
    let plaintext = b"durable chunk";
    let id = ObjectId::for_plaintext(domain, plaintext);
    let mut stage = cas.begin_stage(domain, id, plaintext.len() as u64).unwrap();
    write_chunk(&mut stage, domain, id, plaintext.len() as u64, 0, plaintext).unwrap();
    let checkpoint = stage.checkpoint();
    let stage_id = stage.stage_id();
    drop(stage);
    let chunk = temp
        .path()
        .join("staging")
        .join(stage_id.to_string())
        .join("chunks/0.chunk");
    OpenOptions::new()
        .write(true)
        .open(&chunk)
        .unwrap()
        .set_len(3)
        .unwrap();
    assert!(matches!(
        cas.resume_stage(stage_id, checkpoint),
        Err(CasError::TruncatedCiphertext(0))
    ));
    OpenOptions::new()
        .write(true)
        .open(&chunk)
        .unwrap()
        .set_len(64 * 1024 * 1024)
        .unwrap();
    assert!(matches!(
        cas.resume_stage(stage_id, checkpoint),
        Err(CasError::TruncatedCiphertext(0))
    ));
    assert!(cas.get_live(domain, id).unwrap().is_none());
}

#[test]
fn giant_metadata_is_rejected_before_read_allocation() {
    let temp = tempfile::tempdir().unwrap();
    let cas = store(temp.path());
    let domain = domain(51, ObjectType::FILE, 1);
    let id = ObjectId::for_plaintext(domain, b"metadata bound");
    let stage = cas.begin_stage(domain, id, 14).unwrap();
    let checkpoint = stage.checkpoint();
    let stage_id = stage.stage_id();
    drop(stage);
    let metadata = temp
        .path()
        .join("staging")
        .join(stage_id.to_string())
        .join("metadata.json");
    OpenOptions::new()
        .write(true)
        .open(metadata)
        .unwrap()
        .set_len(64 * 1024 * 1024)
        .unwrap();
    assert!(matches!(
        cas.resume_stage(stage_id, checkpoint),
        Err(CasError::ReadLimitExceeded { .. })
    ));
}

#[test]
fn no_replace_and_storage_limit_preserve_existing_live_object() {
    let temp = tempfile::tempdir().unwrap();
    let domain = domain(60, ObjectType::FILE, 1);
    let plaintext = b"already durable";
    let cas = store(temp.path());
    let id = ingest(&cas, domain, plaintext);
    let live_path = temp.path().join("live").join(format!("{id}.cas"));
    let original = fs::read(&live_path).unwrap();
    ingest(&cas, domain, plaintext);
    assert_eq!(fs::read(&live_path).unwrap(), original);

    let limited = CasStore::open(
        temp.path(),
        CasLimits {
            max_object_bytes: 1024,
            max_staged_ciphertext_bytes: 1,
        },
        Arc::new(FixedKeyProvider),
    )
    .unwrap();
    let mut failed = limited
        .begin_stage(domain, id, plaintext.len() as u64)
        .unwrap();
    assert!(matches!(
        write_chunk(
            &mut failed,
            domain,
            id,
            plaintext.len() as u64,
            0,
            plaintext
        ),
        Err(CasError::StagingLimitExceeded)
    ));
    assert_eq!(fs::read(&live_path).unwrap(), original);
    assert!(limited.get_live(domain, id).unwrap().is_some());
}

#[test]
fn symlink_root_and_live_entry_are_rejected_without_escape() {
    let temp = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let linked_root = temp.path().join("linked-cas");
    symlink(outside.path(), &linked_root).unwrap();
    assert!(CasStore::open(
        &linked_root,
        CasLimits::default(),
        Arc::new(FixedKeyProvider)
    )
    .is_err());

    let root = temp.path().join("real-cas");
    let cas = store(&root);
    let domain = domain(70, ObjectType::FILE, 1);
    let id = ObjectId::for_plaintext(domain, b"outside");
    let outside_file = outside.path().join("secret");
    fs::write(&outside_file, b"do not read").unwrap();
    symlink(&outside_file, root.join("live").join(format!("{id}.cas"))).unwrap();
    assert!(cas.get_live(domain, id).is_err());
}

#[test]
fn chunk_count_overflow_and_live_bitflip_fail_closed() {
    let temp = tempfile::tempdir().unwrap();
    let overflow = (u32::MAX as u64 + 1) * CHUNK_SIZE as u64;
    assert!(matches!(
        CasStore::open(
            temp.path().join("overflow"),
            CasLimits {
                max_object_bytes: overflow,
                max_staged_ciphertext_bytes: overflow,
            },
            Arc::new(FixedKeyProvider),
        ),
        Err(CasError::ChunkCountOverflow)
    ));

    let cas = store(temp.path());
    let domain = domain(80, ObjectType::FILE, 1);
    let plaintext = b"detect live corruption";
    let id = ingest(&cas, domain, plaintext);
    let live = temp.path().join("live").join(format!("{id}.cas"));
    let mut file = OpenOptions::new().write(true).open(live).unwrap();
    file.seek(SeekFrom::End(-1)).unwrap();
    file.write_all(&[0]).unwrap();
    file.sync_all().unwrap();
    assert!(matches!(
        cas.get_live(domain, id),
        Err(CasError::CorruptLiveObject)
    ));
}

#[test]
fn object_build_error_leaves_no_temp_files() {
    let temp = tempfile::tempdir().unwrap();
    let cas = store(temp.path());
    let domain = domain(90, ObjectType::FILE, 1);
    let plaintext = b"identity mismatch";
    let wrong_id = ObjectId([0x99; 32]);
    let mut stage = cas
        .begin_stage(domain, wrong_id, plaintext.len() as u64)
        .unwrap();
    let stage_dir = temp
        .path()
        .join("staging")
        .join(stage.stage_id().to_string());
    write_chunk(
        &mut stage,
        domain,
        wrong_id,
        plaintext.len() as u64,
        0,
        plaintext,
    )
    .unwrap();
    assert!(matches!(
        stage.finish(),
        Err(CasError::ObjectIdentityMismatch { .. })
    ));
    for entry in fs::read_dir(&stage_dir).unwrap() {
        let entry = entry.unwrap();
        assert!(!entry.file_name().to_string_lossy().contains(".tmp."));
    }
    for entry in fs::read_dir(stage_dir.join("chunks")).unwrap() {
        let entry = entry.unwrap();
        assert!(!entry.file_name().to_string_lossy().contains(".tmp."));
    }
}

#[test]
fn reopen_sweeps_only_strict_regular_crash_temp_files() {
    let temp = tempfile::tempdir().unwrap();
    let cas = store(temp.path());
    let domain = domain(91, ObjectType::FILE, 1);
    let id = ObjectId::for_plaintext(domain, b"x");
    let stage = cas.begin_stage(domain, id, 1).unwrap();
    let checkpoint = stage.checkpoint();
    let stage_id = stage.stage_id();
    let stage_dir = temp.path().join("staging").join(stage_id.to_string());
    let chunks = stage_dir.join("chunks");
    drop(stage);
    drop(cas);

    let stage_temp = stage_dir.join(format!("object.tmp.{}", "a".repeat(32)));
    let chunk_temp = chunks.join(format!("0.tmp.{}", "b".repeat(32)));
    let symlink_temp = stage_dir.join(format!("metadata.tmp.{}", "c".repeat(32)));
    let directory_temp = chunks.join(format!("1.tmp.{}", "d".repeat(32)));
    let near_miss = stage_dir.join("object.tmp.NOT-STRICT");
    fs::write(&stage_temp, b"stale").unwrap();
    fs::write(&chunk_temp, b"stale").unwrap();
    symlink(temp.path().join("outside"), &symlink_temp).unwrap();
    fs::create_dir(&directory_temp).unwrap();
    fs::write(&near_miss, b"keep").unwrap();

    let cas = store(temp.path());
    assert!(!stage_temp.exists());
    assert!(!chunk_temp.exists());
    assert!(fs::symlink_metadata(&symlink_temp)
        .unwrap()
        .file_type()
        .is_symlink());
    assert!(directory_temp.is_dir());
    assert!(near_miss.is_file());
    assert!(cas.resume_stage(stage_id, checkpoint).is_ok());
}
