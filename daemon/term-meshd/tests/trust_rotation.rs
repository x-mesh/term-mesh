#[path = "../src/sync/mod.rs"]
mod sync;

use std::sync::atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering};
use std::sync::Arc;

use ed25519_dalek::{Signer, SigningKey};
use sync_protocol::{
    CanonicalRecord, ControlFields, DeviceGrantPayload, DeviceRevokePayload, RecordKind,
    RotationPayload, SignedRotationAck,
};
use zeroize::Zeroizing;

use sync::{
    unwrap_project_key, wrap_project_key, AckCounts, AckEvidence, CasError, CasLimits,
    CasMigrationCounts, CasMigrationEvidence, CasStore, ControlPublishEvidence, KeyId,
    KeyPersistEvidence, ProjectId, ProjectKey, ProjectKeyMaterial, ProjectKeyProvider,
    PublishReceipt, RandomSource, RotationCoordinator, RotationError, RotationOrchestrator,
    RotationPlan, TrustError, TrustStore,
};

struct Keys;
impl ProjectKeyProvider for Keys {
    fn current_project_key(&self, _: ProjectId) -> Result<ProjectKeyMaterial, CasError> {
        Ok(ProjectKeyMaterial {
            key_id: KeyId([3; 16]),
            key: ProjectKey::new([6; 32]),
        })
    }
    fn project_key(&self, _: ProjectId, key_id: KeyId) -> Result<ProjectKey, CasError> {
        if key_id == KeyId([2; 16]) || key_id == KeyId([3; 16]) {
            Ok(ProjectKey::new([6; 32]))
        } else {
            Err(CasError::KeyUnavailable(key_id))
        }
    }
}

struct CounterRandom(AtomicU8);
impl CounterRandom {
    fn new() -> Self {
        Self(AtomicU8::new(1))
    }
}
impl RandomSource for CounterRandom {
    fn fill(&self, output: &mut [u8]) -> Result<(), sync::KeychainError> {
        output.fill(self.0.fetch_add(1, Ordering::Relaxed));
        Ok(())
    }
}

fn signed_control(
    signing: &SigningKey,
    kind: RecordKind,
    fields: &ControlFields,
    payload: Vec<u8>,
) -> CanonicalRecord {
    let mut record = CanonicalRecord {
        kind,
        project_id: fields.project_id,
        device_id: fields.device_id,
        roster_epoch: fields.roster_epoch,
        sequence: fields.roster_epoch,
        payload,
        signature: [0; 64],
    };
    record.signature = signing.sign(&record.signing_preimage().unwrap()).to_bytes();
    record
}

fn fields(project: [u8; 32], epoch: u64, nonce: u8) -> ControlFields {
    ControlFields {
        project_id: project,
        device_id: [2; 32],
        roster_epoch: epoch,
        nonce: [nonce; 32],
        signing_public_key: [3; 32],
        agreement_public_key: [4; 32],
        key_id: [epoch as u8; 16],
    }
}

#[test]
fn recovery_records_reject_forgery_replay_stale_epoch_and_revoke() {
    let temporary = tempfile::tempdir().unwrap();
    let path = temporary.path().join("key-state.sqlite3");
    let project = [1; 32];
    let recovery = SigningKey::from_bytes(&[9; 32]);
    let store = TrustStore::open_with_keys(
        &path,
        ProjectId::from_bytes(project),
        recovery.verifying_key().to_bytes(),
        Arc::new(Keys),
    )
    .unwrap();

    let grant_fields = fields(project, 1, 10);
    let grant_payload = DeviceGrantPayload {
        fields: grant_fields.clone(),
        ephemeral_public_key: [5; 32],
        wrap_nonce: [6; 24],
        wrapped_dek: [7; 48],
        tls_certificate_hash: [8; 32],
    };
    let grant = signed_control(
        &recovery,
        RecordKind::DeviceGrant,
        &grant_fields,
        grant_payload.encode(),
    );
    store.apply_control_record(&grant).unwrap();
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection.execute(
        "INSERT INTO trust_dek_wraps(device_id,key_id,ephemeral_public,wrap_nonce,wrapped_dek) VALUES(?1,?2,?3,?4,?5)",
        rusqlite::params![[2_u8;32].as_slice(), [0xfe_u8;16].as_slice(), [8_u8;32].as_slice(), [9_u8;24].as_slice(), [10_u8;48].as_slice()],
    ).unwrap();
    assert!(matches!(
        store.apply_control_record(&grant),
        Err(TrustError::ReplayedNonce)
    ));

    let stale_fields = fields(project, 3, 11);
    let stale = signed_control(
        &recovery,
        RecordKind::DeviceRevoke,
        &stale_fields,
        DeviceRevokePayload {
            fields: stale_fields.clone(),
        }
        .encode(),
    );
    assert!(matches!(
        store.apply_control_record(&stale),
        Err(TrustError::StaleEpoch)
    ));

    let revoke_fields = fields(project, 2, 12);
    let mut forged = signed_control(
        &recovery,
        RecordKind::DeviceRevoke,
        &revoke_fields,
        DeviceRevokePayload {
            fields: revoke_fields.clone(),
        }
        .encode(),
    );
    forged.signature[0] ^= 1;
    assert!(matches!(
        store.apply_control_record(&forged),
        Err(TrustError::ForgedSignature)
    ));
    let revoke = signed_control(
        &recovery,
        RecordKind::DeviceRevoke,
        &revoke_fields,
        DeviceRevokePayload {
            fields: revoke_fields.clone(),
        }
        .encode(),
    );
    store.apply_control_record(&revoke).unwrap();
    let remaining: i64 = connection
        .query_row(
            "SELECT count(*) FROM trust_dek_wraps WHERE device_id=?1",
            [[2_u8; 32].as_slice()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(remaining, 0);
    assert_eq!(store.epoch().unwrap(), 2);

    let rotation_fields = fields(project, 3, 13);
    let rotation = signed_control(
        &recovery,
        RecordKind::Rotation,
        &rotation_fields,
        RotationPayload {
            fields: rotation_fields.clone(),
            dek_commitment: ProjectKey::new([6; 32])
                .rotation_commitment(&project, &rotation_fields.key_id),
        }
        .encode(),
    );
    store.apply_control_record(&rotation).unwrap();
    assert_eq!(store.epoch().unwrap(), 3);
}

#[test]
fn revoke_succeeds_when_device_has_zero_wraps() {
    let temporary = tempfile::tempdir().unwrap();
    let path = temporary.path().join("key-state.sqlite3");
    let project = [21; 32];
    let recovery = SigningKey::from_bytes(&[22; 32]);
    let store = TrustStore::open_with_keys(
        &path,
        ProjectId::from_bytes(project),
        recovery.verifying_key().to_bytes(),
        Arc::new(Keys),
    )
    .unwrap();
    let grant_fields = fields(project, 1, 31);
    let grant = signed_control(
        &recovery,
        RecordKind::DeviceGrant,
        &grant_fields,
        DeviceGrantPayload {
            fields: grant_fields.clone(),
            ephemeral_public_key: [5; 32],
            wrap_nonce: [6; 24],
            wrapped_dek: [7; 48],
            tls_certificate_hash: [8; 32],
        }
        .encode(),
    );
    store.apply_control_record(&grant).unwrap();
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute(
            "DELETE FROM trust_dek_wraps WHERE device_id=?1",
            [[2_u8; 32].as_slice()],
        )
        .unwrap();
    let revoke_fields = fields(project, 2, 32);
    let revoke = signed_control(
        &recovery,
        RecordKind::DeviceRevoke,
        &revoke_fields,
        DeviceRevokePayload {
            fields: revoke_fields.clone(),
        }
        .encode(),
    );
    store.apply_control_record(&revoke).unwrap();
    assert_eq!(store.epoch().unwrap(), 2);
}

#[test]
fn dek_wrap_binds_device_epoch_and_rotation_journal_resumes_every_phase() {
    let random = CounterRandom::new();
    let project = ProjectId::from_bytes([1; 32]);
    let receiver_secret = [2; 32];
    let receiver_public =
        x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from(receiver_secret))
            .to_bytes();
    let wrapped = wrap_project_key(
        &random,
        project,
        [3; 32],
        4,
        KeyId([5; 16]),
        &ProjectKey::new([6; 32]),
        receiver_public,
    )
    .unwrap();
    let unwrapped = unwrap_project_key(
        project,
        [3; 32],
        4,
        &wrapped,
        Zeroizing::new(receiver_secret),
    )
    .unwrap();
    assert_eq!(unwrapped.expose_for_wrapping(), &[6; 32]);
    assert!(unwrap_project_key(
        project,
        [7; 32],
        4,
        &wrapped,
        Zeroizing::new(receiver_secret)
    )
    .is_err());
    assert!(matches!(
        wrap_project_key(
            &random,
            project,
            [3; 32],
            4,
            KeyId([5; 16]),
            &ProjectKey::new([6; 32]),
            [0; 32]
        ),
        Err(RotationError::NonContributoryKey)
    ));
    for ephemeral_public in [[0; 32], {
        let mut low = [0; 32];
        low[0] = 1;
        low
    }] {
        let malicious = sync::WrappedProjectKey {
            key_id: KeyId([5; 16]),
            ephemeral_public,
            nonce: [0; 24],
            ciphertext: [0; 48],
        };
        assert!(matches!(
            unwrap_project_key(
                project,
                [3; 32],
                4,
                &malicious,
                Zeroizing::new(receiver_secret)
            ),
            Err(RotationError::NonContributoryKey)
        ));
    }
    assert!(matches!(
        wrap_project_key(
            &random,
            project,
            [3; 32],
            4,
            KeyId([5; 16]),
            &ProjectKey::new([6; 32]),
            {
                let mut low = [0; 32];
                low[0] = 1;
                low
            }
        ),
        Err(RotationError::NonContributoryKey)
    ));

    let temporary = tempfile::tempdir().unwrap();
    let path = temporary.path().join("key-state.sqlite3");
    let recovery = SigningKey::from_bytes(&[8; 32]);
    let rotation_id = [9; 32];
    let rotation_fields = ControlFields {
        project_id: [1; 32],
        device_id: [3; 32],
        roster_epoch: 1,
        nonce: [4; 32],
        signing_public_key: [5; 32],
        agreement_public_key: [6; 32],
        key_id: [2; 16],
    };
    let control = signed_control(
        &recovery,
        RecordKind::Rotation,
        &rotation_fields,
        RotationPayload {
            fields: rotation_fields.clone(),
            dek_commitment: ProjectKey::new([6; 32]).rotation_commitment(&[1; 32], &[2; 16]),
        }
        .encode(),
    );
    let evidence = Evidence::default();
    for boundary in 0..5 {
        let store = TrustStore::open_with_keys(
            &path,
            project,
            recovery.verifying_key().to_bytes(),
            Arc::new(Keys),
        )
        .unwrap();
        let orchestrator = RotationOrchestrator {
            trust: &store,
            keys: &evidence,
            publisher: &evidence,
            acknowledgements: &evidence,
            cas: &evidence,
        };
        let completed = orchestrator
            .reconcile(&RotationPlan {
                rotation_id,
                from_key_id: KeyId([0; 16]),
                to_key_id: KeyId([2; 16]),
                control_record: &control,
            })
            .unwrap();
        assert!(!completed);
        if boundary == 0 {
            assert!(matches!(
                orchestrator.reconcile(&RotationPlan {
                    rotation_id,
                    from_key_id: KeyId([0xee; 16]),
                    to_key_id: KeyId([2; 16]),
                    control_record: &control
                }),
                Err(RotationError::JournalConflict)
            ));
            let connection = rusqlite::Connection::open(&path).unwrap();
            connection
                .execute(
                    "UPDATE trust_rotation_journal SET control_hash=?2 WHERE rotation_id=?1",
                    rusqlite::params![rotation_id.as_slice(), [0xaa_u8; 32].as_slice()],
                )
                .unwrap();
            assert!(matches!(
                orchestrator.reconcile(&RotationPlan {
                    rotation_id,
                    from_key_id: KeyId([0; 16]),
                    to_key_id: KeyId([2; 16]),
                    control_record: &control,
                }),
                Err(RotationError::JournalConflict)
            ));
            assert_eq!(evidence.publish.load(Ordering::SeqCst), 0);
            connection
                .execute(
                    "UPDATE trust_rotation_journal SET control_hash=?2 WHERE rotation_id=?1",
                    rusqlite::params![
                        rotation_id.as_slice(),
                        control.domain_hash().unwrap().as_slice()
                    ],
                )
                .unwrap();
        }
        assert_eq!(evidence.persist.load(Ordering::SeqCst), 1);
        assert_eq!(
            evidence.publish.load(Ordering::SeqCst),
            usize::from(boundary >= 1)
        );
        assert_eq!(
            evidence.acks.load(Ordering::SeqCst),
            usize::from(boundary >= 3)
        );
        assert_eq!(
            evidence.cas.load(Ordering::SeqCst),
            usize::from(boundary >= 4)
        );
        assert_eq!(evidence.delete.load(Ordering::SeqCst), 0);
    }
    evidence.fail_delete.store(true, Ordering::SeqCst);
    {
        let store = TrustStore::open_with_keys(
            &path,
            project,
            recovery.verifying_key().to_bytes(),
            Arc::new(Keys),
        )
        .unwrap();
        let orchestrator = RotationOrchestrator {
            trust: &store,
            keys: &evidence,
            publisher: &evidence,
            acknowledgements: &evidence,
            cas: &evidence,
        };
        assert!(matches!(
            orchestrator.reconcile(&RotationPlan {
                rotation_id,
                from_key_id: KeyId([0; 16]),
                to_key_id: KeyId([2; 16]),
                control_record: &control
            }),
            Err(RotationError::Evidence(_))
        ));
    }
    {
        let store = TrustStore::open_with_keys(
            &path,
            project,
            recovery.verifying_key().to_bytes(),
            Arc::new(Keys),
        )
        .unwrap();
        let orchestrator = RotationOrchestrator {
            trust: &store,
            keys: &evidence,
            publisher: &evidence,
            acknowledgements: &evidence,
            cas: &evidence,
        };
        assert!(orchestrator
            .reconcile(&RotationPlan {
                rotation_id,
                from_key_id: KeyId([0; 16]),
                to_key_id: KeyId([2; 16]),
                control_record: &control
            })
            .unwrap());
    }
    assert_eq!(evidence.persist.load(Ordering::SeqCst), 1);
    assert_eq!(evidence.publish.load(Ordering::SeqCst), 1);
    assert_eq!(evidence.delete.load(Ordering::SeqCst), 2);
}

#[test]
fn production_coordinator_serializes_retired_reconcile_and_recovers_completed_fence() {
    let temporary = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([41; 32]);
    let recovery = SigningKey::from_bytes(&[42; 32]);
    let trust_path = temporary.path().join("trust.sqlite3");
    let trust = TrustStore::open_with_keys(
        &trust_path,
        project,
        recovery.verifying_key().to_bytes(),
        Arc::new(Keys),
    )
    .unwrap();
    let record = CanonicalRecord {
        kind: RecordKind::Rotation,
        project_id: [41; 32],
        device_id: [43; 32],
        roster_epoch: 1,
        sequence: 1,
        payload: vec![1],
        signature: [0; 64],
    };
    let hash = record.domain_hash().unwrap();
    let connection = rusqlite::Connection::open(&trust_path).unwrap();
    connection
        .execute(
            "UPDATE trust_meta SET roster_epoch=1,current_key_id=?1 WHERE singleton=1",
            [[2_u8; 16].as_slice()],
        )
        .unwrap();
    connection.execute("INSERT INTO trust_devices(device_id,signing_public,agreement_public,status,approved_epoch,revoked_epoch) VALUES(?1,?2,?3,'approved',1,NULL)", rusqlite::params![[44_u8;32].as_slice(), recovery.verifying_key().to_bytes().as_slice(), [45_u8;32].as_slice()]).unwrap();
    connection.execute("INSERT INTO trust_rotation_acks(key_id,generation,roster_epoch,device_id,control_hash,nonce) VALUES(?1,1,1,?2,?3,?4)", rusqlite::params![[2_u8;16].as_slice(), [44_u8;32].as_slice(), hash.as_slice(), [46_u8;32].as_slice()]).unwrap();
    connection.execute("INSERT INTO trust_rotation_journal(rotation_id,from_key_id,to_key_id,phase,roster_epoch,op_id,control_hash,persisted_key,approved_count,acked_count,ack_generation,old_object_count,inflight_count,reachable_count,old_key_deleted) VALUES(?1,?2,?3,'retired',1,?4,?5,1,1,1,1,0,0,0,0)", rusqlite::params![[47_u8;32].as_slice(), [0_u8;16].as_slice(), [2_u8;16].as_slice(), [48_u8;32].as_slice(), hash.as_slice()]).unwrap();
    drop(connection);
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(Keys),
    )
    .unwrap();
    cas.test_install_retirement_fence(KeyId([0; 16])).unwrap();
    let evidence = Evidence::default();
    let plan = RotationPlan {
        rotation_id: [47; 32],
        from_key_id: KeyId([0; 16]),
        to_key_id: KeyId([2; 16]),
        control_record: &record,
    };
    let coordinator = RotationCoordinator {
        trust: &trust,
        keys: &evidence,
        publisher: &evidence,
        cas: &cas,
    };
    std::thread::scope(|scope| {
        let first = scope.spawn(|| coordinator.reconcile(&plan));
        let second = scope.spawn(|| coordinator.reconcile(&plan));
        assert!(first.join().unwrap().unwrap());
        assert!(second.join().unwrap().unwrap());
    });
    assert_eq!(evidence.delete.load(Ordering::SeqCst), 1);
    assert!(!temporary
        .path()
        .join("cas/.retire-00000000000000000000000000000000.fence")
        .exists());
    cas.test_install_retirement_fence(KeyId([0; 16])).unwrap();
    assert!(coordinator.reconcile(&plan).unwrap());
    assert!(!temporary
        .path()
        .join("cas/.retire-00000000000000000000000000000000.fence")
        .exists());
}

#[test]
fn signed_rotation_ack_rejects_key_generation_and_control_hash_relabeling() {
    let temporary = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([51; 32]);
    let signing = SigningKey::from_bytes(&[52; 32]);
    let path = temporary.path().join("trust.sqlite3");
    let trust = TrustStore::open_with_keys(
        &path,
        project,
        signing.verifying_key().to_bytes(),
        Arc::new(Keys),
    )
    .unwrap();
    let control_hash = [53; 32];
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute(
            "UPDATE trust_meta SET roster_epoch=1,current_key_id=?1 WHERE singleton=1",
            [[2_u8; 16].as_slice()],
        )
        .unwrap();
    connection.execute("INSERT INTO trust_devices(device_id,signing_public,agreement_public,status,approved_epoch,revoked_epoch) VALUES(?1,?2,?3,'approved',1,NULL)", rusqlite::params![[54_u8;32].as_slice(), signing.verifying_key().to_bytes().as_slice(), [55_u8;32].as_slice()]).unwrap();
    connection.execute("INSERT INTO trust_rotation_journal(rotation_id,from_key_id,to_key_id,phase,roster_epoch,op_id,control_hash,persisted_key) VALUES(?1,?2,?3,'activated',1,?4,?5,1)", rusqlite::params![[56_u8;32].as_slice(), [0_u8;16].as_slice(), [2_u8;16].as_slice(), [57_u8;32].as_slice(), control_hash.as_slice()]).unwrap();
    drop(connection);
    let mut ack = SignedRotationAck {
        project_id: [51; 32],
        observer_device: [54; 32],
        roster_epoch: 1,
        key_id: [2; 16],
        generation: 7,
        control_hash,
        nonce: [58; 32],
        signature: [0; 64],
    };
    ack.signature = signing.sign(&ack.signing_preimage()).to_bytes();
    trust.record_rotation_ack(&ack).unwrap();
    for relabel in 0..3 {
        let mut forged = ack.clone();
        match relabel {
            0 => forged.key_id[0] ^= 1,
            1 => forged.generation += 1,
            2 => forged.control_hash[0] ^= 1,
            _ => unreachable!(),
        }
        assert!(matches!(
            trust.record_rotation_ack(&forged),
            Err(TrustError::ForgedSignature)
        ));
    }
}

struct BlockingPersist {
    entered: Arc<std::sync::Barrier>,
    release: Arc<std::sync::Barrier>,
}
impl KeyPersistEvidence for BlockingPersist {
    fn persist_new_key(&self, _: [u8; 32], _: KeyId) -> Result<(), RotationError> {
        self.entered.wait();
        self.release.wait();
        Ok(())
    }
    fn delete_old_key(&self, _: [u8; 32], _: KeyId) -> Result<(), RotationError> {
        Ok(())
    }
}

#[test]
fn production_coordinator_holds_control_mutation_gate_through_prepare_insert() {
    let temporary = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([61; 32]);
    let recovery = SigningKey::from_bytes(&[62; 32]);
    let trust = TrustStore::open_with_keys(
        temporary.path().join("trust.sqlite3"),
        project,
        recovery.verifying_key().to_bytes(),
        Arc::new(Keys),
    )
    .unwrap();
    let rotation_fields = ControlFields {
        project_id: [61; 32],
        device_id: [63; 32],
        roster_epoch: 1,
        nonce: [64; 32],
        signing_public_key: [0; 32],
        agreement_public_key: [0; 32],
        key_id: [2; 16],
    };
    let rotation = signed_control(
        &recovery,
        RecordKind::Rotation,
        &rotation_fields,
        RotationPayload {
            fields: rotation_fields.clone(),
            dek_commitment: ProjectKey::new([6; 32]).rotation_commitment(&[61; 32], &[2; 16]),
        }
        .encode(),
    );
    let grant_fields = ControlFields {
        project_id: [61; 32],
        device_id: [65; 32],
        roster_epoch: 1,
        nonce: [66; 32],
        signing_public_key: recovery.verifying_key().to_bytes(),
        agreement_public_key: [67; 32],
        key_id: [2; 16],
    };
    let grant = signed_control(
        &recovery,
        RecordKind::DeviceGrant,
        &grant_fields,
        DeviceGrantPayload {
            fields: grant_fields.clone(),
            ephemeral_public_key: [68; 32],
            wrap_nonce: [69; 24],
            wrapped_dek: [70; 48],
            tls_certificate_hash: [71; 32],
        }
        .encode(),
    );
    let cas = CasStore::open(
        temporary.path().join("cas"),
        CasLimits::default(),
        Arc::new(Keys),
    )
    .unwrap();
    let entered = Arc::new(std::sync::Barrier::new(2));
    let release = Arc::new(std::sync::Barrier::new(2));
    let started = Arc::new(std::sync::Barrier::new(2));
    let keys = BlockingPersist {
        entered: entered.clone(),
        release: release.clone(),
    };
    let evidence = Evidence::default();
    let plan = RotationPlan {
        rotation_id: [71; 32],
        from_key_id: KeyId([0; 16]),
        to_key_id: KeyId([2; 16]),
        control_record: &rotation,
    };
    let coordinator = RotationCoordinator {
        trust: &trust,
        keys: &keys,
        publisher: &evidence,
        cas: &cas,
    };
    std::thread::scope(|scope| {
        let prepare = scope.spawn(|| coordinator.reconcile(&plan));
        entered.wait();
        let trust_ref = &trust;
        let grant_ref = &grant;
        let control = scope.spawn({
            let started = started.clone();
            move || {
                started.wait();
                trust_ref.apply_control_record(grant_ref)
            }
        });
        started.wait();
        for _ in 0..100 {
            std::thread::yield_now();
        }
        assert!(!control.is_finished());
        release.wait();
        assert!(!prepare.join().unwrap().unwrap());
        assert!(control.join().unwrap().is_ok());
    });
}

#[derive(Default)]
struct Evidence {
    persist: AtomicUsize,
    publish: AtomicUsize,
    delete: AtomicUsize,
    acks: AtomicUsize,
    cas: AtomicUsize,
    fail_delete: AtomicBool,
}
impl KeyPersistEvidence for Evidence {
    fn persist_new_key(&self, _: [u8; 32], _: KeyId) -> Result<(), RotationError> {
        self.persist.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
    fn delete_old_key(&self, _: [u8; 32], _: KeyId) -> Result<(), RotationError> {
        self.delete.fetch_add(1, Ordering::SeqCst);
        if self.fail_delete.swap(false, Ordering::SeqCst) {
            Err(RotationError::Evidence("delete failed".into()))
        } else {
            Ok(())
        }
    }
}
impl ControlPublishEvidence for Evidence {
    fn publish(
        &self,
        _: [u8; 32],
        record: &CanonicalRecord,
    ) -> Result<PublishReceipt, RotationError> {
        self.publish.fetch_add(1, Ordering::SeqCst);
        Ok(PublishReceipt {
            op_id: [7; 32],
            control_hash: record.domain_hash().unwrap(),
        })
    }
}
impl AckEvidence for Evidence {
    fn counts(&self, _: KeyId) -> Result<AckCounts, RotationError> {
        self.acks.fetch_add(1, Ordering::SeqCst);
        Ok(AckCounts {
            approved_non_revoked: 1,
            acked: 1,
        })
    }
}
impl CasMigrationEvidence for Evidence {
    fn counts(&self, _: KeyId) -> Result<CasMigrationCounts, RotationError> {
        self.cas.fetch_add(1, Ordering::SeqCst);
        Ok(CasMigrationCounts {
            old_key_objects: 0,
            inflight: 0,
            reachable: 0,
        })
    }
}

#[test]
fn rotation_activation_rolls_back_on_missing_or_mismatched_dek_commitment() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x31; 32]);
    let project = [0x32; 32];
    let mut rotation_fields = fields(project, 1, 0x33);
    rotation_fields.key_id = [2; 16];
    let record = signed_control(
        &recovery,
        RecordKind::Rotation,
        &rotation_fields,
        RotationPayload {
            fields: rotation_fields.clone(),
            dek_commitment: [0xff; 32],
        }
        .encode(),
    );

    let missing_path = temporary.path().join("missing.sqlite3");
    let missing = TrustStore::open(
        &missing_path,
        ProjectId::from_bytes(project),
        recovery.verifying_key().to_bytes(),
    )
    .unwrap();
    assert!(matches!(
        missing.apply_control_record(&record),
        Err(TrustError::MissingProjectKey)
    ));
    assert_eq!(missing.epoch().unwrap(), 0);

    let mismatch_path = temporary.path().join("mismatch.sqlite3");
    let mismatch = TrustStore::open_with_keys(
        &mismatch_path,
        ProjectId::from_bytes(project),
        recovery.verifying_key().to_bytes(),
        Arc::new(Keys),
    )
    .unwrap();
    assert!(matches!(
        mismatch.apply_control_record(&record),
        Err(TrustError::DekCommitmentMismatch)
    ));
    assert_eq!(mismatch.epoch().unwrap(), 0);
    let corrected = signed_control(
        &recovery,
        RecordKind::Rotation,
        &rotation_fields,
        RotationPayload {
            fields: rotation_fields.clone(),
            dek_commitment: ProjectKey::new([6; 32])
                .rotation_commitment(&project, &rotation_fields.key_id),
        }
        .encode(),
    );
    mismatch.apply_control_record(&corrected).unwrap();
    assert_eq!(mismatch.epoch().unwrap(), 1);
}

#[test]
fn unexpected_trigger_is_quarantined_and_mid_mutation_drift_rolls_back() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x41; 32]);
    let project = ProjectId::from_bytes([0x42; 32]);
    let path = temporary.path().join("key-state.sqlite3");
    {
        let _store = TrustStore::open(&path, project, recovery.verifying_key().to_bytes()).unwrap();
    }
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TRIGGER hostile BEFORE INSERT ON trust_nonces BEGIN SELECT RAISE(IGNORE); END;",
        )
        .unwrap();
    let error = TrustStore::open(&path, project, recovery.verifying_key().to_bytes())
        .err()
        .unwrap();
    let TrustError::Quarantined {
        path: quarantine, ..
    } = error
    else {
        panic!("expected quarantine")
    };
    assert!(quarantine.exists());
    assert!(std::path::PathBuf::from(format!("{}-wal", quarantine.display())).exists());
    assert!(std::path::PathBuf::from(format!("{}-shm", quarantine.display())).exists());
    assert!(!path.exists());
    drop(connection);

    let drift_path = temporary.path().join("drift.sqlite3");
    let store =
        TrustStore::open(&drift_path, project, recovery.verifying_key().to_bytes()).unwrap();
    let drift = rusqlite::Connection::open(&drift_path).unwrap();
    drift
        .execute_batch("CREATE TRIGGER drift AFTER INSERT ON trust_devices BEGIN SELECT 1; END;")
        .unwrap();
    drop(drift);
    let grant_fields = fields(*project.as_bytes(), 1, 0x44);
    let grant = signed_control(
        &recovery,
        RecordKind::DeviceGrant,
        &grant_fields,
        DeviceGrantPayload {
            fields: grant_fields.clone(),
            ephemeral_public_key: [1; 32],
            wrap_nonce: [2; 24],
            wrapped_dek: [3; 48],
            tls_certificate_hash: [4; 32],
        }
        .encode(),
    );
    assert!(matches!(
        store.apply_control_record(&grant),
        Err(TrustError::InvalidSchema)
    ));
    assert_eq!(store.epoch().unwrap(), 0);
}
