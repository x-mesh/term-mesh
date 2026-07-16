#[path = "../src/sync/mod.rs"]
mod sync;

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use sync_protocol::{CanonicalRecord, RecordKind};

use sync::{
    AppendOutcome, CasGc, DeviceFrontier, DeviceStatus, GcCoordinator, GcEngine, GcError,
    GcSnapshot, GcSnapshotLease, ObjectId, OplogError, OplogStore, OplogTrustError,
    OplogTrustProvider, ProjectId, SequenceRange, SignedDeviceAck, TombstonePayload,
};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

struct AllowTrust;

impl OplogTrustProvider for AllowTrust {
    fn verify(&self, _record: &CanonicalRecord) -> Result<(), OplogTrustError> {
        Ok(())
    }

    fn verify_ack(&self, _ack: &SignedDeviceAck) -> Result<(), OplogTrustError> {
        Ok(())
    }
}

struct StrictTrust;

impl OplogTrustProvider for StrictTrust {
    fn verify(&self, record: &CanonicalRecord) -> Result<(), OplogTrustError> {
        if record.signature != [7; 64] {
            return Err(OplogTrustError::ForgedSignature);
        }
        if record.roster_epoch != 5 {
            return Err(OplogTrustError::StaleEpoch);
        }
        if record.device_id == [9; 32] {
            return Err(OplogTrustError::RevokedDevice);
        }
        Ok(())
    }

    fn verify_ack(&self, ack: &SignedDeviceAck) -> Result<(), OplogTrustError> {
        if ack.signature != [7; 64] {
            return Err(OplogTrustError::ForgedSignature);
        }
        if ack.roster_epoch != 5 {
            return Err(OplogTrustError::StaleEpoch);
        }
        if ack.observer_device == [9; 32] {
            return Err(OplogTrustError::RevokedDevice);
        }
        Ok(())
    }
}

fn project(byte: u8) -> ProjectId {
    ProjectId::from_bytes([byte; 32])
}

fn record(
    project_id: ProjectId,
    device_id: [u8; 32],
    sequence: u64,
    payload: &[u8],
) -> CanonicalRecord {
    CanonicalRecord {
        kind: RecordKind::Oplog,
        project_id: *project_id.as_bytes(),
        device_id,
        roster_epoch: 5,
        sequence,
        payload: payload.to_vec(),
        signature: [7; 64],
    }
}

fn tombstone_record(
    project_id: ProjectId,
    device_id: [u8; 32],
    sequence: u64,
    content_root: ObjectId,
    deleted_at_ms: i64,
) -> CanonicalRecord {
    CanonicalRecord {
        kind: RecordKind::Tombstone,
        payload: TombstonePayload {
            content_root,
            deleted_at_ms,
        }
        .canonical_bytes(),
        ..record(project_id, device_id, sequence, &[])
    }
}

fn signed_ack(
    project_id: ProjectId,
    observer_device: [u8; 32],
    frontiers: Vec<DeviceFrontier>,
) -> SignedDeviceAck {
    SignedDeviceAck {
        project_id,
        observer_device,
        roster_epoch: 5,
        frontiers,
        signature: [7; 64],
    }
}

fn open_store(
    path: &std::path::Path,
    project_id: ProjectId,
    trust: Arc<dyn OplogTrustProvider>,
) -> OplogStore {
    OplogStore::open(path, project_id, trust).unwrap()
}

fn ack(outcome: AppendOutcome) -> sync::DurableAck {
    match outcome {
        AppendOutcome::Applied(ack) | AppendOutcome::Duplicate(ack) => ack,
        AppendOutcome::Quarantined { .. } => panic!("expected durable ack"),
    }
}

#[test]
fn duplicate_is_idempotent_and_payload_mismatch_is_durably_quarantined() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("oplog.sqlite3");
    let project_id = project(1);
    let store = open_store(&path, project_id, Arc::new(AllowTrust));
    let original = record(project_id, [1; 32], 1, b"first");
    assert!(matches!(
        store.ingest(&original, 1).unwrap(),
        AppendOutcome::Applied(_)
    ));
    assert!(matches!(
        store.ingest(&original, 2).unwrap(),
        AppendOutcome::Duplicate(_)
    ));
    let different = record(project_id, [1; 32], 1, b"different");
    assert!(matches!(
        store.ingest(&different, 3).unwrap(),
        AppendOutcome::Quarantined { .. }
    ));
    assert_eq!(store.quarantine_count().unwrap(), 1);
    drop(store);

    let reopened = open_store(&path, project_id, Arc::new(AllowTrust));
    assert_eq!(reopened.quarantine_count().unwrap(), 1);
    assert!(matches!(
        reopened.ingest(&original, 4).unwrap(),
        AppendOutcome::Duplicate(_)
    ));
}

#[test]
fn gaps_and_out_of_order_records_only_advance_contiguous_frontier() {
    let temp = tempfile::tempdir().unwrap();
    let project_id = project(2);
    let store = open_store(
        &temp.path().join("oplog.sqlite3"),
        project_id,
        Arc::new(AllowTrust),
    );
    let device = [2; 32];
    store
        .ingest(&record(project_id, device, 1, b"1"), 1)
        .unwrap();
    store
        .ingest(&record(project_id, device, 3, b"3"), 2)
        .unwrap();
    assert_eq!(store.frontier().unwrap().get(&device), Some(&1));
    assert_eq!(
        store.missing_ranges(device).unwrap(),
        vec![SequenceRange {
            start: 2,
            end_exclusive: 3,
        }]
    );
    store
        .ingest(&record(project_id, device, 2, b"2"), 3)
        .unwrap();
    assert_eq!(store.frontier().unwrap().get(&device), Some(&3));
    assert!(store.missing_ranges(device).unwrap().is_empty());

    let other = [3; 32];
    store
        .ingest(&record(project_id, other, 2, b"2"), 4)
        .unwrap();
    assert_eq!(store.frontier().unwrap().get(&other), Some(&0));
    assert_eq!(
        store.missing_ranges(other).unwrap(),
        vec![SequenceRange {
            start: 1,
            end_exclusive: 2,
        }]
    );
    store
        .ingest(&record(project_id, other, 1, b"1"), 5)
        .unwrap();
    assert_eq!(store.frontier().unwrap().get(&other), Some(&2));
}

#[test]
fn maximum_sqlite_sequence_has_bounded_missing_range_arithmetic() {
    let temp = tempfile::tempdir().unwrap();
    let project_id = project(22);
    let store = open_store(
        &temp.path().join("oplog.sqlite3"),
        project_id,
        Arc::new(AllowTrust),
    );
    let device = [22; 32];
    store
        .ingest(&record(project_id, device, i64::MAX as u64, b"maximum"), 1)
        .unwrap();
    assert_eq!(store.frontier().unwrap().get(&device), Some(&0));
    assert_eq!(
        store.missing_ranges(device).unwrap(),
        vec![SequenceRange {
            start: 1,
            end_exclusive: i64::MAX as u64,
        }]
    );
    assert!(matches!(
        store.ingest(
            &record(project_id, device, i64::MAX as u64 + 1, b"overflow"),
            2,
        ),
        Err(OplogError::SequenceOverflow)
    ));
}

#[test]
fn durable_ack_survives_post_commit_crash_and_is_never_issued_pre_commit() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("oplog.sqlite3");
    let project_id = project(3);
    let committed = record(project_id, [3; 32], 1, b"committed");
    let uncommitted = record(project_id, [4; 32], 1, b"never inserted");
    let store = open_store(&path, project_id, Arc::new(AllowTrust));
    let durable = ack(store.ingest(&committed, 1).unwrap());
    assert_eq!(durable.sequence(), 1);
    drop(store); // crash after commit and before transport sends ACK

    let reopened = open_store(&path, project_id, Arc::new(AllowTrust));
    let replay = ack(reopened.ingest(&committed, 2).unwrap());
    assert_eq!(replay.commit_hash(), durable.commit_hash());
    assert!(!reopened
        .frontier()
        .unwrap()
        .contains_key(&uncommitted.device_id));
}

#[test]
fn batch_ack_reopen_is_idempotent_and_missing_tail_is_exact() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("oplog.sqlite3");
    let project_id = project(33);
    let device = [3; 32];
    let records = vec![
        record(project_id, device, 1, b"one"),
        record(project_id, device, 2, b"two"),
    ];
    let store = open_store(&path, project_id, Arc::new(AllowTrust));
    let sync::BatchIngestOutcome::Ack(first) = store.ingest_batch(&records, 1).unwrap() else {
        panic!()
    };
    assert_eq!(first.outcomes.len(), 2);
    assert_eq!(
        store
            .missing_tail(&std::collections::BTreeMap::from([(device, 5)]))
            .unwrap(),
        vec![(
            device,
            SequenceRange {
                start: 3,
                end_exclusive: 6
            }
        )]
    );
    drop(store);
    let reopened = open_store(&path, project_id, Arc::new(AllowTrust));
    let sync::BatchIngestOutcome::Ack(replay) = reopened.ingest_batch(&records, 2).unwrap() else {
        panic!()
    };
    assert_eq!(replay.batch_hash, first.batch_hash);
    assert!(replay
        .outcomes
        .iter()
        .all(|outcome| matches!(outcome, AppendOutcome::Duplicate(_))));
}

#[test]
fn mid_batch_collision_is_durable_but_never_returns_batch_ack() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("collision.sqlite3");
    let project_id = project(34);
    let device = [4; 32];
    let store = open_store(&path, project_id, Arc::new(AllowTrust));
    store
        .ingest(&record(project_id, device, 2, b"original"), 1)
        .unwrap();
    let batch = vec![
        record(project_id, device, 1, b"one"),
        record(project_id, device, 2, b"collision"),
        record(project_id, device, 3, b"must-not-ack"),
    ];
    assert!(matches!(
        store.ingest_batch(&batch, 2).unwrap(),
        sync::BatchIngestOutcome::Collision { .. }
    ));
    drop(store);
    let reopened = open_store(&path, project_id, Arc::new(AllowTrust));
    assert_eq!(reopened.quarantine_count().unwrap(), 1);
    assert_eq!(reopened.frontier().unwrap().get(&device), Some(&2));
}

#[test]
fn forged_stale_revoked_and_cross_project_records_fail_before_mutation() {
    let temp = tempfile::tempdir().unwrap();
    let project_id = project(4);
    let store = open_store(
        &temp.path().join("oplog.sqlite3"),
        project_id,
        Arc::new(StrictTrust),
    );
    let mut forged = record(project_id, [4; 32], 1, b"x");
    forged.signature = [0; 64];
    assert!(matches!(
        store.ingest(&forged, 1),
        Err(OplogError::Trust(OplogTrustError::ForgedSignature))
    ));
    let mut stale = record(project_id, [4; 32], 1, b"x");
    stale.roster_epoch = 4;
    assert!(matches!(
        store.ingest(&stale, 1),
        Err(OplogError::Trust(OplogTrustError::StaleEpoch))
    ));
    assert!(matches!(
        store.ingest(&record(project_id, [9; 32], 1, b"x"), 1),
        Err(OplogError::Trust(OplogTrustError::RevokedDevice))
    ));
    assert!(matches!(
        store.ingest(&record(project(99), [4; 32], 1, b"x"), 1),
        Err(OplogError::CrossProject)
    ));
    assert!(store.frontier().unwrap().is_empty());
}

#[test]
fn signed_ack_binds_identity_epoch_and_frontier_and_fails_closed() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("oplog.sqlite3");
    let project_id = project(40);
    let store = open_store(&path, project_id, Arc::new(StrictTrust));
    let target = [4; 32];
    let valid = signed_ack(
        project_id,
        [4; 32],
        vec![DeviceFrontier {
            device_id: target,
            sequence: 7,
        }],
    );
    let preimage = valid.signing_preimage().unwrap();
    let encoded = valid.canonical_bytes().unwrap();
    assert_eq!(SignedDeviceAck::decode(&encoded).unwrap(), valid);
    let mut wrong_type = encoded.clone();
    wrong_type[b"term-mesh oplog signed ack\0".len() + 2] = 2;
    assert!(matches!(
        SignedDeviceAck::decode(&wrong_type),
        Err(OplogError::InvalidAck(_))
    ));
    let mut changed = valid.clone();
    changed.observer_device = [5; 32];
    assert_ne!(preimage, changed.signing_preimage().unwrap());
    changed = valid.clone();
    changed.frontiers[0].sequence = 8;
    assert_ne!(preimage, changed.signing_preimage().unwrap());

    let mut forged = valid.clone();
    forged.signature = [0; 64];
    assert!(matches!(
        store.ingest_device_ack(&forged),
        Err(OplogError::Trust(OplogTrustError::ForgedSignature))
    ));
    let mut stale = valid.clone();
    stale.roster_epoch = 4;
    assert!(matches!(
        store.ingest_device_ack(&stale),
        Err(OplogError::Trust(OplogTrustError::StaleEpoch))
    ));
    let revoked = signed_ack(
        project_id,
        [9; 32],
        vec![DeviceFrontier {
            device_id: target,
            sequence: 7,
        }],
    );
    assert!(matches!(
        store.ingest_device_ack(&revoked),
        Err(OplogError::Trust(OplogTrustError::RevokedDevice))
    ));
    let cross_project = signed_ack(
        project(41),
        [4; 32],
        vec![DeviceFrontier {
            device_id: target,
            sequence: 7,
        }],
    );
    assert!(matches!(
        store.ingest_device_ack(&cross_project),
        Err(OplogError::CrossProject)
    ));
    assert_eq!(ack_row_count(&path), 0);

    store.ingest_device_ack(&valid).unwrap();
    let lower = signed_ack(
        project_id,
        [4; 32],
        vec![DeviceFrontier {
            device_id: target,
            sequence: 3,
        }],
    );
    store.ingest_device_ack(&lower).unwrap();
    assert_eq!(stored_ack(&path, [4; 32], target), Some(7));
}

#[test]
fn tombstone_is_materialized_only_from_matching_verified_delete_op() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("oplog.sqlite3");
    let project_id = project(42);
    let store = open_store(&path, project_id, Arc::new(StrictTrust));
    let origin = [4; 32];
    let delete = tombstone_record(project_id, origin, 1, root(42), 100);
    let durable = ack(store.ingest(&delete, 100).unwrap());
    assert_eq!(durable.kind(), RecordKind::Tombstone);
    assert_eq!(durable.commit_hash(), &delete.domain_hash().unwrap());
    assert_eq!(tombstone_row_count(&path), 1);

    let other_kind = CanonicalRecord {
        kind: RecordKind::Oplog,
        sequence: 2,
        payload: TombstonePayload {
            content_root: root(43),
            deleted_at_ms: 100,
        }
        .canonical_bytes(),
        ..delete.clone()
    };
    let other_ack = ack(store.ingest(&other_kind, 100).unwrap());
    assert_eq!(other_ack.kind(), RecordKind::Oplog);
    assert_eq!(tombstone_row_count(&path), 1);

    let backdated = tombstone_record(project_id, origin, 3, root(44), 99);
    assert!(matches!(
        store.ingest(&backdated, 100),
        Err(OplogError::TombstoneTimestampMismatch)
    ));
    assert_eq!(tombstone_row_count(&path), 1);
    assert_eq!(store.frontier().unwrap().get(&origin), Some(&2));
}

fn ack_row_count(path: &std::path::Path) -> i64 {
    rusqlite::Connection::open(path)
        .unwrap()
        .query_row("SELECT count(*) FROM oplog_device_acks", [], |row| {
            row.get(0)
        })
        .unwrap()
}

fn stored_ack(path: &std::path::Path, observer: [u8; 32], target: [u8; 32]) -> Option<i64> {
    use rusqlite::OptionalExtension;
    rusqlite::Connection::open(path)
        .unwrap()
        .query_row(
            "SELECT ack_sequence FROM oplog_device_acks
             WHERE observer_device = ?1 AND target_device = ?2",
            rusqlite::params![observer, target],
            |row| row.get(0),
        )
        .optional()
        .unwrap()
}

fn tombstone_row_count(path: &std::path::Path) -> i64 {
    rusqlite::Connection::open(path)
        .unwrap()
        .query_row("SELECT count(*) FROM oplog_tombstones", [], |row| {
            row.get(0)
        })
        .unwrap()
}

struct FakeCoordinator(Mutex<GcSnapshot>);

struct FakeSnapshotLease(GcSnapshot);

impl GcSnapshotLease for FakeSnapshotLease {
    fn snapshot(&self) -> Result<GcSnapshot, GcError> {
        Ok(self.0.clone())
    }
}

impl GcCoordinator for FakeCoordinator {
    fn snapshot(&self, _project_id: ProjectId) -> Result<GcSnapshot, GcError> {
        Ok(self.0.lock().unwrap().clone())
    }

    fn acquire_snapshot_lease(
        &self,
        _project_id: ProjectId,
        _object_id: ObjectId,
    ) -> Result<Option<Box<dyn GcSnapshotLease>>, GcError> {
        Ok(Some(Box::new(FakeSnapshotLease(
            self.0.lock().unwrap().clone(),
        ))))
    }
}

struct FakeCas {
    live: Mutex<HashSet<ObjectId>>,
    fail_once: Mutex<Option<ObjectId>>,
}

impl CasGc for FakeCas {
    fn list_live(&self) -> Result<Vec<ObjectId>, GcError> {
        let mut live = self
            .live
            .lock()
            .unwrap()
            .iter()
            .copied()
            .collect::<Vec<_>>();
        live.sort_by_key(|object_id| object_id.0);
        Ok(live)
    }

    fn delete_durable(&self, object_id: ObjectId) -> Result<(), GcError> {
        let mut fail = self.fail_once.lock().unwrap();
        if fail.as_ref() == Some(&object_id) {
            *fail = None;
            return Err(GcError::Cas("injected unlink/fsync failure".to_string()));
        }
        self.live.lock().unwrap().remove(&object_id);
        Ok(())
    }
}

fn root(byte: u8) -> ObjectId {
    ObjectId([byte; 32])
}

#[test]
fn tombstones_require_age_and_all_active_device_acks_and_reachable_roots_survive() {
    let temp = tempfile::tempdir().unwrap();
    let project_id = project(5);
    let oplog = Arc::new(open_store(
        &temp.path().join("oplog.sqlite3"),
        project_id,
        Arc::new(AllowTrust),
    ));
    let origin = [5; 32];
    oplog
        .ingest(
            &tombstone_record(project_id, origin, 1, root(1), 20 * DAY_MS),
            20 * DAY_MS,
        )
        .unwrap();
    oplog
        .ingest(
            &tombstone_record(project_id, origin, 2, root(2), -100 * DAY_MS),
            -100 * DAY_MS,
        )
        .unwrap();
    oplog
        .ingest(
            &tombstone_record(project_id, origin, 3, root(3), -100 * DAY_MS),
            -100 * DAY_MS,
        )
        .unwrap();
    let active_a = [5; 32];
    let active_b = [6; 32];
    oplog
        .ingest_device_ack(&signed_ack(
            project_id,
            active_a,
            vec![DeviceFrontier {
                device_id: origin,
                sequence: 3,
            }],
        ))
        .unwrap();
    // active_b ACKs only sequence 1: sequence 2 remains protected by roster gate.
    oplog
        .ingest_device_ack(&signed_ack(
            project_id,
            active_b,
            vec![DeviceFrontier {
                device_id: origin,
                sequence: 1,
            }],
        ))
        .unwrap();
    // Then explicitly ACK sequence 3 while sequence 2 is also covered monotonically.
    oplog
        .ingest_device_ack(&signed_ack(
            project_id,
            active_b,
            vec![DeviceFrontier {
                device_id: origin,
                sequence: 3,
            }],
        ))
        .unwrap();

    let reachable_conflict = root(4);
    let inflight_transfer = root(5);
    let unreferenced = root(6);
    let coordinator = Arc::new(FakeCoordinator(Mutex::new(GcSnapshot {
        devices: vec![
            DeviceStatus {
                device_id: active_a,
                revoked: false,
            },
            DeviceStatus {
                device_id: active_b,
                revoked: false,
            },
            DeviceStatus {
                device_id: [7; 32],
                revoked: true,
            },
        ],
        roots: vec![reachable_conflict, inflight_transfer],
    })));
    let cas = Arc::new(FakeCas {
        live: Mutex::new(HashSet::from([
            root(1),
            root(2),
            root(3),
            reachable_conflict,
            inflight_transfer,
            unreferenced,
        ])),
        fail_once: Mutex::new(None),
    });
    let engine = GcEngine::new(oplog, coordinator, cas.clone());
    engine.run(100 * DAY_MS).unwrap();
    let remaining = cas.live.lock().unwrap();
    assert!(remaining.contains(&root(1))); // younger than 90 days
                                           // root(2) is covered because sequence 3 ACK covers earlier sequence 2.
    assert!(!remaining.contains(&root(2)));
    assert!(!remaining.contains(&root(3)));
    assert!(remaining.contains(&reachable_conflict));
    assert!(remaining.contains(&inflight_transfer));
    assert!(!remaining.contains(&unreferenced));
}

#[test]
fn ninety_days_without_one_approved_device_ack_never_collects_tombstone() {
    let temp = tempfile::tempdir().unwrap();
    let project_id = project(6);
    let oplog = Arc::new(open_store(
        &temp.path().join("oplog.sqlite3"),
        project_id,
        Arc::new(AllowTrust),
    ));
    let origin = [6; 32];
    oplog
        .ingest(
            &tombstone_record(project_id, origin, 1, root(10), -100 * DAY_MS),
            -100 * DAY_MS,
        )
        .unwrap();
    oplog
        .ingest_device_ack(&signed_ack(
            project_id,
            origin,
            vec![DeviceFrontier {
                device_id: origin,
                sequence: 1,
            }],
        ))
        .unwrap();
    let coordinator = Arc::new(FakeCoordinator(Mutex::new(GcSnapshot {
        devices: vec![
            DeviceStatus {
                device_id: origin,
                revoked: false,
            },
            DeviceStatus {
                device_id: [8; 32],
                revoked: false,
            },
        ],
        roots: Vec::new(),
    })));
    let cas = Arc::new(FakeCas {
        live: Mutex::new(HashSet::from([root(10)])),
        fail_once: Mutex::new(None),
    });
    GcEngine::new(oplog, coordinator, cas.clone())
        .run(100 * DAY_MS)
        .unwrap();
    assert!(cas.live.lock().unwrap().contains(&root(10)));
}

struct ActivatingCoordinator {
    snapshot: Mutex<GcSnapshot>,
    activate_on_lease: ObjectId,
}

struct ApprovingCoordinator {
    snapshot: Mutex<GcSnapshot>,
    approve_on_lease: DeviceStatus,
}

struct UnavailableLeaseCoordinator {
    snapshot: GcSnapshot,
}

impl GcCoordinator for UnavailableLeaseCoordinator {
    fn snapshot(&self, _project_id: ProjectId) -> Result<GcSnapshot, GcError> {
        Ok(self.snapshot.clone())
    }

    fn acquire_snapshot_lease(
        &self,
        _project_id: ProjectId,
        _object_id: ObjectId,
    ) -> Result<Option<Box<dyn GcSnapshotLease>>, GcError> {
        Ok(None)
    }
}

impl GcCoordinator for ActivatingCoordinator {
    fn snapshot(&self, _project_id: ProjectId) -> Result<GcSnapshot, GcError> {
        Ok(self.snapshot.lock().unwrap().clone())
    }

    fn acquire_snapshot_lease(
        &self,
        _project_id: ProjectId,
        object_id: ObjectId,
    ) -> Result<Option<Box<dyn GcSnapshotLease>>, GcError> {
        let mut snapshot = self.snapshot.lock().unwrap();
        if object_id == self.activate_on_lease {
            snapshot.roots.push(object_id);
        }
        Ok(Some(Box::new(FakeSnapshotLease(snapshot.clone()))))
    }
}

impl GcCoordinator for ApprovingCoordinator {
    fn snapshot(&self, _project_id: ProjectId) -> Result<GcSnapshot, GcError> {
        Ok(self.snapshot.lock().unwrap().clone())
    }

    fn acquire_snapshot_lease(
        &self,
        _project_id: ProjectId,
        _object_id: ObjectId,
    ) -> Result<Option<Box<dyn GcSnapshotLease>>, GcError> {
        let mut snapshot = self.snapshot.lock().unwrap();
        snapshot.devices.push(self.approve_on_lease);
        Ok(Some(Box::new(FakeSnapshotLease(snapshot.clone()))))
    }
}

#[test]
fn gc_lease_closes_activation_race_before_durable_delete() {
    let temp = tempfile::tempdir().unwrap();
    let project_id = project(66);
    let oplog = Arc::new(open_store(
        &temp.path().join("oplog.sqlite3"),
        project_id,
        Arc::new(AllowTrust),
    ));
    let candidate = root(66);
    let coordinator = Arc::new(ActivatingCoordinator {
        snapshot: Mutex::new(GcSnapshot {
            devices: vec![DeviceStatus {
                device_id: [66; 32],
                revoked: false,
            }],
            roots: Vec::new(),
        }),
        activate_on_lease: candidate,
    });
    let cas = Arc::new(FakeCas {
        live: Mutex::new(HashSet::from([candidate])),
        fail_once: Mutex::new(None),
    });
    let report = GcEngine::new(oplog, coordinator, cas.clone())
        .run(1)
        .unwrap();
    assert_eq!(report.skipped, 1);
    assert!(cas.live.lock().unwrap().contains(&candidate));
}

#[test]
fn gc_skips_when_root_lease_is_unavailable() {
    let temp = tempfile::tempdir().unwrap();
    let project_id = project(67);
    let oplog = Arc::new(open_store(
        &temp.path().join("oplog.sqlite3"),
        project_id,
        Arc::new(AllowTrust),
    ));
    let candidate = root(67);
    let coordinator = Arc::new(UnavailableLeaseCoordinator {
        snapshot: GcSnapshot {
            devices: vec![DeviceStatus {
                device_id: [67; 32],
                revoked: false,
            }],
            roots: Vec::new(),
        },
    });
    let cas = Arc::new(FakeCas {
        live: Mutex::new(HashSet::from([candidate])),
        fail_once: Mutex::new(None),
    });
    let report = GcEngine::new(oplog, coordinator, cas.clone())
        .run(1)
        .unwrap();
    assert_eq!(report.skipped, 1);
    assert!(cas.live.lock().unwrap().contains(&candidate));
}

#[test]
fn gc_snapshot_lease_catches_new_device_approval_without_ack() {
    let temp = tempfile::tempdir().unwrap();
    let project_id = project(68);
    let oplog = Arc::new(open_store(
        &temp.path().join("oplog.sqlite3"),
        project_id,
        Arc::new(AllowTrust),
    ));
    let origin = [68; 32];
    let candidate = root(68);
    oplog
        .ingest(
            &tombstone_record(project_id, origin, 1, candidate, -100 * DAY_MS),
            -100 * DAY_MS,
        )
        .unwrap();
    oplog
        .ingest_device_ack(&signed_ack(
            project_id,
            origin,
            vec![DeviceFrontier {
                device_id: origin,
                sequence: 1,
            }],
        ))
        .unwrap();
    let coordinator = Arc::new(ApprovingCoordinator {
        snapshot: Mutex::new(GcSnapshot {
            devices: vec![DeviceStatus {
                device_id: origin,
                revoked: false,
            }],
            roots: Vec::new(),
        }),
        approve_on_lease: DeviceStatus {
            device_id: [69; 32],
            revoked: false,
        },
    });
    let cas = Arc::new(FakeCas {
        live: Mutex::new(HashSet::from([candidate])),
        fail_once: Mutex::new(None),
    });
    let report = GcEngine::new(oplog, coordinator, cas.clone())
        .run(100 * DAY_MS)
        .unwrap();
    assert_eq!(report.deleted, 0);
    assert_eq!(report.skipped, 1);
    assert!(cas.live.lock().unwrap().contains(&candidate));
}

#[test]
fn gc_journal_recovers_idempotently_and_rechecks_new_roots() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("oplog.sqlite3");
    let project_id = project(7);
    let oplog = Arc::new(open_store(&path, project_id, Arc::new(AllowTrust)));
    let coordinator = Arc::new(FakeCoordinator(Mutex::new(GcSnapshot {
        devices: vec![DeviceStatus {
            device_id: [7; 32],
            revoked: false,
        }],
        roots: Vec::new(),
    })));
    let first = root(20);
    let second = root(21);
    let cas = Arc::new(FakeCas {
        live: Mutex::new(HashSet::from([first, second])),
        fail_once: Mutex::new(Some(second)),
    });
    let engine = GcEngine::new(oplog.clone(), coordinator.clone(), cas.clone());
    assert!(matches!(engine.run(1), Err(GcError::Cas(_))));
    assert!(!cas.live.lock().unwrap().contains(&first));
    assert!(cas.live.lock().unwrap().contains(&second));
    drop(engine);
    drop(oplog); // process restart

    coordinator.0.lock().unwrap().roots.push(second); // became reachable before recovery
    let reopened = Arc::new(open_store(&path, project_id, Arc::new(AllowTrust)));
    let report = GcEngine::new(reopened, coordinator, cas.clone())
        .recover(2)
        .unwrap();
    assert_eq!(report.skipped, 1);
    assert!(cas.live.lock().unwrap().contains(&second));
}

#[test]
fn schema_drift_is_quarantined_without_reinitialization() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("oplog.sqlite3");
    let project_id = project(8);
    drop(open_store(&path, project_id, Arc::new(AllowTrust)));
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection.pragma_update(None, "user_version", 999).unwrap();
    drop(connection);
    assert!(matches!(
        OplogStore::open(&path, project_id, Arc::new(AllowTrust)),
        Err(OplogError::Quarantined { .. })
    ));
    assert!(path.exists());
}

#[test]
fn unexpected_before_insert_trigger_is_quarantined_and_cannot_spoof_ack() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("oplog.sqlite3");
    let project_id = project(88);
    let store = open_store(&path, project_id, Arc::new(AllowTrust));
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TRIGGER ack_spoof BEFORE INSERT ON oplog_device_acks
             BEGIN SELECT RAISE(IGNORE); END;",
        )
        .unwrap();
    assert!(matches!(
        store.ingest_device_ack(&signed_ack(
            project_id,
            [8; 32],
            vec![DeviceFrontier {
                device_id: [9; 32],
                sequence: 99,
            }],
        )),
        Err(OplogError::MutationNotApplied("device ack upsert"))
    ));
    let count: i64 = connection
        .query_row("SELECT count(*) FROM oplog_device_acks", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(count, 0);
    drop(connection);
    drop(store);
    assert!(matches!(
        OplogStore::open(&path, project_id, Arc::new(AllowTrust)),
        Err(OplogError::Quarantined { .. })
    ));
}

#[test]
fn post_open_entry_ignore_trigger_cannot_issue_durable_ack() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("oplog.sqlite3");
    let project_id = project(89);
    let store = open_store(&path, project_id, Arc::new(AllowTrust));
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TRIGGER entry_spoof BEFORE INSERT ON oplog_entries
             BEGIN SELECT RAISE(IGNORE); END;",
        )
        .unwrap();
    assert!(matches!(
        store.ingest(&record(project_id, [8; 32], 1, b"ignored"), 1),
        Err(OplogError::MutationNotApplied("oplog entry insert"))
    ));
    let entries: i64 = connection
        .query_row("SELECT count(*) FROM oplog_entries", [], |row| row.get(0))
        .unwrap();
    assert_eq!(entries, 0);
    assert!(store.frontier().unwrap().is_empty());
}

#[test]
fn post_open_quarantine_ignore_trigger_cannot_claim_durable_quarantine() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("oplog.sqlite3");
    let project_id = project(90);
    let store = open_store(&path, project_id, Arc::new(AllowTrust));
    let original = record(project_id, [9; 32], 1, b"original");
    store.ingest(&original, 1).unwrap();
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TRIGGER quarantine_spoof BEFORE INSERT ON oplog_quarantine
             BEGIN SELECT RAISE(IGNORE); END;",
        )
        .unwrap();
    let mismatch = record(project_id, [9; 32], 1, b"mismatch");
    assert!(matches!(
        store.ingest(&mismatch, 2),
        Err(OplogError::MutationNotApplied("quarantine insert"))
    ));
    assert_eq!(store.quarantine_count().unwrap(), 0);
}
