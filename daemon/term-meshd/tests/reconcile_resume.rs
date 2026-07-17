#[path = "../src/sync/mod.rs"]
mod sync;

use std::collections::BTreeMap;
use std::sync::Arc;

use ed25519_dalek::{Signer, SigningKey};
use sync::{
    logical_transfer_fixture, BaselineCrashHook, BaselineInstallPhase, EntryKind, HeadDecision,
    KeyId, ManifestBuilder, ManifestEntry, ManifestIndex, ManifestScanner, ObjectId, OplogStore,
    OplogTrustError, OplogTrustProvider, ProjectId, ProjectKey, ReconcileError,
    ReconcileOrchestrator, ReconcileStore, ResumeToken, ScanLimits, ScanObserver, StageId,
    StreamRouter, SyncMode, TransferCheckpoint, TransferSession, TransportPeerSnapshot, WireTrace,
};
use sync_protocol::{
    CanonicalRecord, ControlFields, DeviceGrantPayload, DeviceRevokePayload, RecordKind,
    StreamPreface, WireBinding, WireBody, WireFrame,
};

struct AllowOplogTrust;
impl OplogTrustProvider for AllowOplogTrust {
    fn verify(&self, _: &CanonicalRecord) -> Result<(), OplogTrustError> {
        Ok(())
    }
    fn verify_ack(&self, _: &sync::SignedDeviceAck) -> Result<(), OplogTrustError> {
        Ok(())
    }
}

struct CrashAfter(BaselineInstallPhase);
impl BaselineCrashHook for CrashAfter {
    fn after_phase(&self, phase: BaselineInstallPhase) -> Result<(), ReconcileError> {
        if phase == self.0 {
            Err(ReconcileError::Trace)
        } else {
            Ok(())
        }
    }
}

struct PauseAfterPrepared {
    ready: std::sync::mpsc::Sender<()>,
    release: std::sync::Mutex<std::sync::mpsc::Receiver<()>>,
}

impl BaselineCrashHook for PauseAfterPrepared {
    fn after_phase(&self, phase: BaselineInstallPhase) -> Result<(), ReconcileError> {
        if phase == BaselineInstallPhase::Prepared {
            self.ready.send(()).unwrap();
            self.release.lock().unwrap().recv().unwrap();
        }
        Ok(())
    }
}

fn baseline_phase(path: &std::path::Path, operation_id: [u8; 16]) -> String {
    rusqlite::Connection::open(path)
        .unwrap()
        .query_row(
            "SELECT phase FROM baseline_installs WHERE operation_id=?1",
            [operation_id],
            |row| row.get(0),
        )
        .unwrap()
}

fn baseline_row_count(path: &std::path::Path) -> i64 {
    rusqlite::Connection::open(path)
        .unwrap()
        .query_row("SELECT count(*) FROM baseline_installs", [], |row| {
            row.get(0)
        })
        .unwrap()
}

fn baseline_generation(path: &std::path::Path, project: ProjectId) -> i64 {
    rusqlite::Connection::open(path)
        .unwrap()
        .query_row(
            "SELECT generation FROM oplog_baselines WHERE project_id=?1",
            [project.as_bytes().as_slice()],
            |row| row.get(0),
        )
        .unwrap()
}

fn oplog_record(project: ProjectId, sequence: u64) -> CanonicalRecord {
    CanonicalRecord {
        kind: RecordKind::Oplog,
        project_id: *project.as_bytes(),
        device_id: [2; 32],
        roster_epoch: 1,
        sequence,
        payload: sequence.to_be_bytes().to_vec(),
        signature: [7; 64],
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

fn control_fields(project: ProjectId, device: [u8; 32], epoch: u64) -> ControlFields {
    ControlFields {
        project_id: *project.as_bytes(),
        device_id: device,
        roster_epoch: epoch,
        nonce: [epoch as u8; 32],
        signing_public_key: [31; 32],
        agreement_public_key: [32; 32],
        key_id: [epoch as u8; 16],
    }
}

fn approve_peer(
    path: &std::path::Path,
    project: ProjectId,
) -> (sync::TrustStore, SigningKey, Vec<u8>, TransportPeerSnapshot) {
    let recovery = SigningKey::from_bytes(&[29; 32]);
    let trust = sync::TrustStore::open(path, project, recovery.verifying_key().to_bytes()).unwrap();
    let certificate = b"authenticated peer certificate".to_vec();
    let fields = control_fields(project, [2; 32], 1);
    let grant = DeviceGrantPayload {
        fields: fields.clone(),
        ephemeral_public_key: [33; 32],
        wrap_nonce: [34; 24],
        wrapped_dek: [35; 48],
        tls_certificate_hash: *blake3::hash(&certificate).as_bytes(),
    };
    trust
        .apply_control_record(&signed_control(
            &recovery,
            RecordKind::DeviceGrant,
            &fields,
            grant.encode(),
        ))
        .unwrap();
    let peer = trust.authorize_transport_certificate(&certificate).unwrap();
    (trust, recovery, certificate, peer)
}

fn complete_manifest(
    path: &std::path::Path,
    scan_id: [u8; 16],
) -> (ManifestIndex, sync::CompletedManifestHandle, [u8; 32]) {
    let index = ManifestIndex::begin(path, scan_id).unwrap();
    let entry = ManifestEntry {
        relative_path: "file.txt".into(),
        kind: EntryKind::File,
        executable: false,
        length: 4,
        content_hash: [41; 32],
        symlink_target: None,
    };
    let mut builder = ManifestBuilder::new();
    builder.push(&entry).unwrap();
    ScanObserver::entry(&index, &entry).unwrap();
    let manifest = builder.finish();
    let root = manifest.root.0;
    let handle = index.finish(manifest).unwrap();
    (index, handle, root)
}

fn complete_two_entry_manifest(path: &std::path::Path, scan_id: [u8; 16]) -> ([u8; 32], u64) {
    let index = ManifestIndex::begin(path, scan_id).unwrap();
    let entries = [
        ManifestEntry {
            relative_path: "a.txt".into(),
            kind: EntryKind::File,
            executable: false,
            length: 1,
            content_hash: [1; 32],
            symlink_target: None,
        },
        ManifestEntry {
            relative_path: "b.txt".into(),
            kind: EntryKind::File,
            executable: false,
            length: 1,
            content_hash: [2; 32],
            symlink_target: None,
        },
    ];
    let mut builder = ManifestBuilder::new();
    for entry in &entries {
        builder.push(entry).unwrap();
        ScanObserver::entry(&index, entry).unwrap();
    }
    let manifest = builder.finish();
    let handle = index.finish(manifest).unwrap();
    (handle.root(), handle.entry_count())
}

fn complete_many_entry_manifest(
    path: &std::path::Path,
    scan_id: [u8; 16],
    count: usize,
) -> (ManifestIndex, sync::CompletedManifestHandle) {
    let index = ManifestIndex::begin(path, scan_id).unwrap();
    let mut builder = ManifestBuilder::new();
    for ordinal in 0..count {
        let entry = ManifestEntry {
            relative_path: format!("file-{ordinal:05}.txt"),
            kind: EntryKind::File,
            executable: false,
            length: ordinal as u64,
            content_hash: *blake3::hash(&ordinal.to_be_bytes()).as_bytes(),
            symlink_target: None,
        };
        builder.push(&entry).unwrap();
        ScanObserver::entry(&index, &entry).unwrap();
    }
    let handle = index.finish(builder.finish()).unwrap();
    (index, handle)
}

fn persisted_shard_root(
    connection: &rusqlite::Connection,
    scan_id: [u8; 16],
    first: u64,
    last: u64,
) -> [u8; 32] {
    let mut hasher = blake3::Hasher::new();
    hasher.update(b"term-mesh manifest shard v1\0");
    let mut statement = connection
        .prepare(
            "SELECT entry FROM entries WHERE scan_id=?1 AND ordinal>=?2 AND ordinal<?3 ORDER BY ordinal",
        )
        .unwrap();
    let rows = statement
        .query_map(rusqlite::params![scan_id, first, last], |row| {
            row.get::<_, Vec<u8>>(0)
        })
        .unwrap();
    for row in rows {
        let bytes = row.unwrap();
        hasher.update(&(bytes.len() as u32).to_be_bytes());
        hasher.update(&bytes);
    }
    *hasher.finalize().as_bytes()
}

fn peer(project_id: ProjectId) -> TransportPeerSnapshot {
    TransportPeerSnapshot {
        project_id,
        device_id: [2; 32],
        roster_epoch: 1,
        certificate_hash: [3; 32],
    }
}

#[test]
fn candidate_is_durable_before_swap_and_frontiers_fail_closed() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("heads.db");
    let project = ProjectId::from_bytes([1; 32]);
    let store = ReconcileStore::open(&path, project).unwrap();
    let first = BTreeMap::from([([1; 32], 2), ([2; 32], 1)]);
    let HeadDecision::Initial(id) = store.offer(&peer(project), [4; 32], &first, false).unwrap()
    else {
        panic!()
    };
    drop(store); // crash after candidate persistence, before head swap
    let store = ReconcileStore::open(&path, project).unwrap();
    store.commit_candidate_unchecked(id).unwrap();
    assert_eq!(
        store.offer(&peer(project), [4; 32], &first, false).unwrap(),
        HeadDecision::Duplicate
    );
    assert_eq!(
        store.offer(&peer(project), [5; 32], &first, false).unwrap(),
        HeadDecision::Quarantined
    );
    assert_eq!(
        store
            .offer(
                &peer(project),
                [4; 32],
                &BTreeMap::from([([1; 32], 1), ([2; 32], 1)]),
                false
            )
            .unwrap(),
        HeadDecision::Stale
    );
    let concurrent = BTreeMap::from([([1; 32], 1), ([2; 32], 2)]);
    let HeadDecision::Conflict(conflict) = store
        .offer(&peer(project), [6; 32], &concurrent, false)
        .unwrap()
    else {
        panic!()
    };
    assert!(matches!(
        store.commit_candidate_unchecked(conflict),
        Err(ReconcileError::Stale)
    ));
}

#[test]
fn two_pending_candidates_commit_deterministically_without_head_overwrite() {
    let temp = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([12; 32]);
    let store = ReconcileStore::open(&temp.path().join("two.db"), project).unwrap();
    let frontier = BTreeMap::from([([1; 32], 1)]);
    let HeadDecision::Initial(first) = store
        .offer(&peer(project), [1; 32], &frontier, false)
        .unwrap()
    else {
        panic!()
    };
    let HeadDecision::Initial(second) = store
        .offer(&peer(project), [2; 32], &frontier, false)
        .unwrap()
    else {
        panic!()
    };
    store.commit_candidate_unchecked(first).unwrap();
    assert!(matches!(
        store.commit_candidate_unchecked(second),
        Err(ReconcileError::Conflict)
    ));
    assert_eq!(
        store
            .offer(&peer(project), [1; 32], &frontier, false)
            .unwrap(),
        HeadDecision::Duplicate
    );
}

#[test]
fn authenticated_complete_candidate_commits_after_reopen_and_converges() {
    let temp = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([51; 32]);
    let (trust, _recovery, _certificate, peer) =
        approve_peer(&temp.path().join("trust.db"), project);
    let (manifest, handle, root) = complete_manifest(&temp.path().join("manifest.db"), [1; 16]);
    let heads = temp.path().join("heads.db");
    let frontier = BTreeMap::from([([2; 32], 1)]);
    let store = ReconcileStore::open(&heads, project).unwrap();
    let HeadDecision::Initial(candidate) = ReconcileOrchestrator::new(&store, &trust)
        .offer_authenticated(&peer, root, &frontier, true)
        .unwrap()
    else {
        panic!()
    };
    drop(store);

    let store = ReconcileStore::open(&heads, project).unwrap();
    ReconcileOrchestrator::new(&store, &trust)
        .commit_persisted(candidate, &peer, &manifest, &handle)
        .unwrap();
    let trace_path = temp.path().join("actual-no-change.jsonl");
    let trace = WireTrace::create(&trace_path).unwrap();
    assert!(ReconcileOrchestrator::new(&store, &trust)
        .no_change(&peer, root, &frontier, &trace)
        .unwrap());
    let trace_text = std::fs::read_to_string(&trace_path).unwrap();
    assert_eq!(trace_text.lines().count(), 1);
    assert!(trace_text.contains("\"path_items\":0"));
    assert!(
        !trace_text.contains("certificate")
            && !trace_text.contains("key_id")
            && !trace_text.contains("plaintext")
    );
    drop(store);
    let reopened = ReconcileStore::open(&heads, project).unwrap();
    assert_eq!(reopened.test_head_root(peer.device_id).unwrap(), Some(root));
    assert_eq!(
        reopened.offer(&peer, root, &frontier, false).unwrap(),
        HeadDecision::Duplicate
    );
}

#[test]
fn commit_gate_rejects_incomplete_root_with_head_unchanged() {
    let temp = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([52; 32]);
    let (trust, _recovery, _certificate, peer) =
        approve_peer(&temp.path().join("trust.db"), project);
    let (manifest, handle, _) = complete_manifest(&temp.path().join("manifest.db"), [2; 16]);
    let store = ReconcileStore::open(&temp.path().join("heads.db"), project).unwrap();
    let root = [53; 32];
    let HeadDecision::Initial(candidate) = store
        .offer(&peer, root, &BTreeMap::from([([2; 32], 1)]), true)
        .unwrap()
    else {
        panic!()
    };
    assert!(matches!(
        store.commit_candidate(candidate, &peer, &trust, &manifest, &handle),
        Err(ReconcileError::Binding)
    ));
    assert_eq!(store.test_head_root(peer.device_id).unwrap(), None);
}

#[test]
fn commit_gate_rejects_revoke_epoch_change_and_removal_with_heads_unchanged() {
    for case in ["revoke", "epoch", "remove"] {
        let temp = tempfile::tempdir().unwrap();
        let project = ProjectId::from_bytes([54; 32]);
        let trust_path = temp.path().join("trust.db");
        let (trust, recovery, _certificate, peer) = approve_peer(&trust_path, project);
        let (manifest, handle, root) = complete_manifest(&temp.path().join("manifest.db"), [3; 16]);
        let store = ReconcileStore::open(&temp.path().join("heads.db"), project).unwrap();
        let HeadDecision::Initial(candidate) = store
            .offer(&peer, root, &BTreeMap::from([([2; 32], 1)]), true)
            .unwrap()
        else {
            panic!()
        };

        match case {
            "revoke" => {
                let fields = control_fields(project, peer.device_id, 2);
                let payload = DeviceRevokePayload {
                    fields: fields.clone(),
                };
                trust
                    .apply_control_record(&signed_control(
                        &recovery,
                        RecordKind::DeviceRevoke,
                        &fields,
                        payload.encode(),
                    ))
                    .unwrap();
            }
            "epoch" => {
                let fields = control_fields(project, [9; 32], 2);
                let payload = DeviceGrantPayload {
                    fields: fields.clone(),
                    ephemeral_public_key: [61; 32],
                    wrap_nonce: [62; 24],
                    wrapped_dek: [63; 48],
                    tls_certificate_hash: [64; 32],
                };
                trust
                    .apply_control_record(&signed_control(
                        &recovery,
                        RecordKind::DeviceGrant,
                        &fields,
                        payload.encode(),
                    ))
                    .unwrap();
            }
            "remove" => {
                let connection = rusqlite::Connection::open(&trust_path).unwrap();
                connection
                    .execute(
                        "DELETE FROM trust_dek_wraps WHERE device_id=?1",
                        [peer.device_id.as_slice()],
                    )
                    .unwrap();
                connection
                    .execute(
                        "DELETE FROM trust_devices WHERE device_id=?1",
                        [peer.device_id.as_slice()],
                    )
                    .unwrap();
            }
            _ => unreachable!(),
        }
        assert!(matches!(
            store.commit_candidate(candidate, &peer, &trust, &manifest, &handle),
            Err(ReconcileError::Binding)
        ));
        assert_eq!(
            store.test_head_root(peer.device_id).unwrap(),
            None,
            "case={case}"
        );
    }
}

#[test]
fn unknown_schema_object_is_quarantined_without_replacement() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("drift.db");
    let project = ProjectId::from_bytes([13; 32]);
    drop(ReconcileStore::open(&path, project).unwrap());
    rusqlite::Connection::open(&path)
        .unwrap()
        .execute_batch("CREATE TRIGGER forbidden AFTER INSERT ON heads BEGIN SELECT 1; END;")
        .unwrap();
    assert!(matches!(
        ReconcileStore::open(&path, project),
        Err(ReconcileError::Schema)
    ));
    assert!(!path.exists());
    assert!(std::fs::read_dir(temp.path()).unwrap().any(|entry| entry
        .unwrap()
        .file_name()
        .to_string_lossy()
        .contains("quarantine")));
}

#[test]
fn legacy_head_schema_adds_active_baseline_index_once_on_reopen() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("legacy-heads.db");
    let project = ProjectId::from_bytes([14; 32]);
    drop(ReconcileStore::open(&path, project).unwrap());
    rusqlite::Connection::open(&path)
        .unwrap()
        .execute_batch("DROP INDEX baseline_installs_one_active_project")
        .unwrap();

    drop(ReconcileStore::open(&path, project).unwrap());
    drop(ReconcileStore::open(&path, project).unwrap());
    let index_count: i64 = rusqlite::Connection::open(&path)
        .unwrap()
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='baseline_installs_one_active_project'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(index_count, 1);
}

#[test]
fn retained_incremental_and_floor_missed_full_baseline_converge() {
    let device = [7; 32];
    assert_eq!(
        ReconcileStore::mode(
            &BTreeMap::from([(device, 40)]),
            &BTreeMap::from([(device, 41)])
        ),
        SyncMode::Incremental
    );
    assert_eq!(
        ReconcileStore::mode(
            &BTreeMap::from([(device, 9)]),
            &BTreeMap::from([(device, 41)])
        ),
        SyncMode::FullResync
    );
    let temp = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([8; 32]);
    let store = ReconcileStore::open(&temp.path().join("baseline.db"), project).unwrap();
    let baseline = BTreeMap::from([(device, 41)]);
    let HeadDecision::Initial(id) = store
        .offer(&peer(project), [9; 32], &baseline, true)
        .unwrap()
    else {
        panic!()
    };
    store.commit_candidate_unchecked(id).unwrap();
    assert_eq!(
        store
            .offer(&peer(project), [9; 32], &baseline, false)
            .unwrap(),
        HeadDecision::Duplicate
    );
}

#[test]
fn thirty_day_orchestrator_incremental_crash_resume_and_full_fallback_converge() {
    const DAY_MS: i64 = 24 * 60 * 60 * 1000;
    let now = 2_000_000_000_000_i64;
    let departed_at = now - 30 * DAY_MS;
    assert_eq!(now - departed_at, 30 * DAY_MS);
    let temp = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([81; 32]);
    let (trust, _, _, peer) = approve_peer(&temp.path().join("trust.db"), project);
    let heads = ReconcileStore::open(&temp.path().join("heads.db"), project).unwrap();
    let source = OplogStore::open(
        temp.path().join("source.db"),
        project,
        Arc::new(AllowOplogTrust),
    )
    .unwrap();
    let destination_path = temp.path().join("destination.db");
    let destination =
        OplogStore::open(&destination_path, project, Arc::new(AllowOplogTrust)).unwrap();
    for sequence in 1..=1025 {
        source
            .ingest(&oplog_record(project, sequence), departed_at)
            .unwrap();
    }
    assert_eq!(source.retained_floor().unwrap().get(&[2; 32]), Some(&1));

    let first = source
        .export_range(
            [2; 32],
            sync::SequenceRange {
                start: 1,
                end_exclusive: 1026,
            },
            1024,
            8 * 1024 * 1024,
        )
        .unwrap();
    assert_eq!(first.len(), 1024);
    assert!(matches!(
        destination.ingest_batch(&first, now).unwrap(),
        sync::BatchIngestOutcome::Ack(_)
    ));
    drop(destination); // durable batch committed, ACK lost
    let destination =
        OplogStore::open(&destination_path, project, Arc::new(AllowOplogTrust)).unwrap();
    let sync::BatchIngestOutcome::Ack(replay) = destination.ingest_batch(&first, now).unwrap()
    else {
        panic!()
    };
    assert_eq!((replay.applied_count, replay.duplicate_count), (0, 1024));
    let orchestrator = ReconcileOrchestrator::new(&heads, &trust);
    assert_eq!(
        orchestrator
            .sync_incremental(&source, &destination, now)
            .unwrap(),
        1
    );
    assert_eq!(destination.frontier().unwrap(), source.frontier().unwrap());
    assert_eq!(
        orchestrator
            .sync_incremental(&source, &destination, now)
            .unwrap(),
        0
    );
    let metrics_destination = OplogStore::open(
        temp.path().join("metrics-destination.db"),
        project,
        Arc::new(AllowOplogTrust),
    )
    .unwrap();
    let report = orchestrator
        .sync_incremental_report(&source, &metrics_destination, now)
        .unwrap();
    assert_eq!(
        (
            report.applied_records,
            report.batches,
            report.max_batch_records,
            report.record_cap,
            report.byte_cap,
        ),
        (1025, 2, 1024, 1024, 8 * 1024 * 1024)
    );
    assert!(report.max_batch_bytes > 0 && report.max_batch_bytes <= report.byte_cap);
    assert_eq!(
        orchestrator
            .sync_incremental_report(&source, &metrics_destination, now)
            .unwrap(),
        sync::IncrementalSyncReport {
            applied_records: 0,
            batches: 0,
            max_batch_records: 0,
            max_batch_bytes: 0,
            record_cap: 1024,
            byte_cap: 8 * 1024 * 1024,
        }
    );
    let trace_path = temp.path().join("incremental.jsonl");
    drop(WireTrace::create(&trace_path).unwrap());
    assert_eq!(std::fs::metadata(trace_path).unwrap().len(), 0);

    let behind_path = temp.path().join("behind.db");
    let behind = OplogStore::open(&behind_path, project, Arc::new(AllowOplogTrust)).unwrap();
    source.test_prune_before([2; 32], 3).unwrap();
    assert!(matches!(
        orchestrator.sync_incremental(&source, &behind, now),
        Err(ReconcileError::FullResyncRequired)
    ));
    let (manifest, handle, root) =
        complete_manifest(&temp.path().join("fallback-manifest.db"), [82; 16]);
    let frontier = source.frontier().unwrap();
    orchestrator
        .install_full_baseline(&peer, [83; 16], &frontier, &manifest, &handle, &behind)
        .unwrap();
    assert_eq!(heads.test_head_root(peer.device_id).unwrap(), Some(root));
    drop(behind);
    let behind = OplogStore::open(&behind_path, project, Arc::new(AllowOplogTrust)).unwrap();
    let immediate = orchestrator
        .sync_incremental_report(&source, &behind, now)
        .unwrap();
    assert_eq!(immediate.applied_records, 0);
    assert_eq!((immediate.batches, immediate.max_batch_records), (0, 0));
}

#[test]
fn baseline_install_crash_after_every_phase_reopens_and_resumes_idempotently() {
    for (case_index, crash_phase) in [
        BaselineInstallPhase::Prepared,
        BaselineInstallPhase::OplogInstalled,
        BaselineInstallPhase::HeadCommitted,
        BaselineInstallPhase::Completed,
    ]
    .into_iter()
    .enumerate()
    {
        let temp = tempfile::tempdir().unwrap();
        let project = ProjectId::from_bytes([120 + case_index as u8; 32]);
        let trust_path = temp.path().join("trust.db");
        let heads_path = temp.path().join("heads.db");
        let manifest_path = temp.path().join("manifest.db");
        let oplog_path = temp.path().join("oplog.db");
        let operation_id = [130 + case_index as u8; 16];
        let (trust, recovery, _, peer) = approve_peer(&trust_path, project);
        let (manifest, handle, root) = complete_manifest(&manifest_path, [140; 16]);
        let heads = ReconcileStore::open(&heads_path, project).unwrap();
        let oplog = OplogStore::open(&oplog_path, project, Arc::new(AllowOplogTrust)).unwrap();
        let frontier = BTreeMap::from([([2; 32], 77)]);
        assert!(matches!(
            ReconcileOrchestrator::new(&heads, &trust).install_full_baseline_with_hook(
                &peer,
                operation_id,
                &frontier,
                &manifest,
                &handle,
                &oplog,
                &CrashAfter(crash_phase),
            ),
            Err(ReconcileError::Trace)
        ));
        drop(oplog);
        drop(heads);
        drop(manifest);
        drop(trust);

        let trust =
            sync::TrustStore::open(&trust_path, project, recovery.verifying_key().to_bytes())
                .unwrap();
        let heads = ReconcileStore::open(&heads_path, project).unwrap();
        let oplog = OplogStore::open(&oplog_path, project, Arc::new(AllowOplogTrust)).unwrap();
        let orchestrator = ReconcileOrchestrator::new(&heads, &trust);
        assert_eq!(
            orchestrator
                .reconcile_baseline_install(operation_id, &manifest_path, &oplog)
                .unwrap(),
            BaselineInstallPhase::Completed
        );
        assert_eq!(
            orchestrator
                .reconcile_baseline_install(operation_id, &manifest_path, &oplog)
                .unwrap(),
            BaselineInstallPhase::Completed
        );
        assert_eq!(baseline_phase(&heads_path, operation_id), "completed");
        assert_eq!(heads.test_head_root(peer.device_id).unwrap(), Some(root));
        assert_eq!(oplog.frontier().unwrap(), frontier);
        assert_eq!(baseline_generation(&oplog_path, project), 1);
    }
}

#[test]
fn concurrent_baseline_resume_serializes_without_duplicate_side_effects() {
    let temp = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([151; 32]);
    let trust_path = temp.path().join("trust.db");
    let heads_path = temp.path().join("heads.db");
    let manifest_path = temp.path().join("manifest.db");
    let oplog_path = temp.path().join("oplog.db");
    let operation_id = [152; 16];
    let (trust, _, _, peer) = approve_peer(&trust_path, project);
    let (manifest, handle, root) = complete_manifest(&manifest_path, [153; 16]);
    let heads = Arc::new(ReconcileStore::open(&heads_path, project).unwrap());
    let oplog =
        Arc::new(OplogStore::open(&oplog_path, project, Arc::new(AllowOplogTrust)).unwrap());
    assert!(ReconcileOrchestrator::new(&heads, &trust)
        .install_full_baseline_with_hook(
            &peer,
            operation_id,
            &BTreeMap::from([([2; 32], 10)]),
            &manifest,
            &handle,
            &oplog,
            &CrashAfter(BaselineInstallPhase::Prepared),
        )
        .is_err());
    let trust = Arc::new(trust);
    let mut workers = Vec::new();
    for _ in 0..2 {
        let heads = heads.clone();
        let trust = trust.clone();
        let oplog = oplog.clone();
        let manifest_path = manifest_path.clone();
        workers.push(std::thread::spawn(move || {
            ReconcileOrchestrator::new(&heads, &trust).reconcile_baseline_install(
                operation_id,
                &manifest_path,
                &oplog,
            )
        }));
    }
    let outcomes: Vec<_> = workers
        .into_iter()
        .map(|worker| worker.join().unwrap())
        .collect();
    assert!(outcomes
        .iter()
        .any(|result| { matches!(result, Ok(BaselineInstallPhase::Completed)) }));
    assert!(outcomes.iter().all(|result| {
        matches!(
            result,
            Ok(BaselineInstallPhase::Completed) | Err(ReconcileError::ProjectBusy)
        )
    }));
    assert_eq!(
        ReconcileOrchestrator::new(&heads, &trust)
            .reconcile_baseline_install(operation_id, &manifest_path, &oplog)
            .unwrap(),
        BaselineInstallPhase::Completed
    );
    assert_eq!(heads.test_head_root(peer.device_id).unwrap(), Some(root));
    assert_eq!(baseline_generation(&oplog_path, project), 1);
}

#[test]
fn post_oplog_trust_or_manifest_failure_blocks_without_head_or_auto_unblock() {
    for case in ["revoke", "epoch", "manifest-root"] {
        let temp = tempfile::tempdir().unwrap();
        let project = ProjectId::from_bytes([161; 32]);
        let trust_path = temp.path().join("trust.db");
        let heads_path = temp.path().join("heads.db");
        let manifest_path = temp.path().join("manifest.db");
        let oplog_path = temp.path().join("oplog.db");
        let operation_id = [162; 16];
        let (trust, recovery, _, peer) = approve_peer(&trust_path, project);
        let (manifest, handle, _) = complete_manifest(&manifest_path, [163; 16]);
        let heads = ReconcileStore::open(&heads_path, project).unwrap();
        let oplog = OplogStore::open(&oplog_path, project, Arc::new(AllowOplogTrust)).unwrap();
        assert!(ReconcileOrchestrator::new(&heads, &trust)
            .install_full_baseline_with_hook(
                &peer,
                operation_id,
                &BTreeMap::from([([2; 32], 4)]),
                &manifest,
                &handle,
                &oplog,
                &CrashAfter(BaselineInstallPhase::OplogInstalled),
            )
            .is_err());
        match case {
            "revoke" => {
                let fields = control_fields(project, peer.device_id, 2);
                let payload = DeviceRevokePayload {
                    fields: fields.clone(),
                };
                trust
                    .apply_control_record(&signed_control(
                        &recovery,
                        RecordKind::DeviceRevoke,
                        &fields,
                        payload.encode(),
                    ))
                    .unwrap();
            }
            "epoch" => {
                let fields = control_fields(project, [9; 32], 2);
                let payload = DeviceGrantPayload {
                    fields: fields.clone(),
                    ephemeral_public_key: [61; 32],
                    wrap_nonce: [62; 24],
                    wrapped_dek: [63; 48],
                    tls_certificate_hash: [64; 32],
                };
                trust
                    .apply_control_record(&signed_control(
                        &recovery,
                        RecordKind::DeviceGrant,
                        &fields,
                        payload.encode(),
                    ))
                    .unwrap();
            }
            "manifest-root" => {
                drop(manifest);
                rusqlite::Connection::open(&manifest_path)
                    .unwrap()
                    .execute(
                        "UPDATE entries SET entry=zeroblob(length(entry)) WHERE ordinal=0",
                        [],
                    )
                    .unwrap();
            }
            _ => unreachable!(),
        }
        assert!(ReconcileOrchestrator::new(&heads, &trust)
            .reconcile_baseline_install(operation_id, &manifest_path, &oplog)
            .is_err());
        assert_eq!(
            baseline_phase(&heads_path, operation_id),
            "blocked",
            "{case}"
        );
        assert_eq!(
            heads.test_head_root(peer.device_id).unwrap(),
            None,
            "{case}"
        );
        drop(heads);
        let heads = ReconcileStore::open(&heads_path, project).unwrap();
        assert!(matches!(
            ReconcileOrchestrator::new(&heads, &trust).reconcile_baseline_install(
                operation_id,
                &manifest_path,
                &oplog
            ),
            Err(ReconcileError::Blocked)
        ));
    }
}

#[test]
fn prepared_baseline_blocks_every_project_sync_entrypoint_across_reopen() {
    let temp = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([164; 32]);
    let trust_path = temp.path().join("trust.db");
    let heads_path = temp.path().join("heads.db");
    let manifest_path = temp.path().join("manifest.db");
    let oplog_path = temp.path().join("oplog.db");
    let operation_a = [165; 16];
    let operation_b = [166; 16];
    let (trust, _, _, peer) = approve_peer(&trust_path, project);
    let (manifest, handle, root) = complete_manifest(&manifest_path, [167; 16]);
    let heads = ReconcileStore::open(&heads_path, project).unwrap();
    let oplog = OplogStore::open(&oplog_path, project, Arc::new(AllowOplogTrust)).unwrap();
    let frontier = BTreeMap::from([([2; 32], 4)]);
    assert!(matches!(
        ReconcileOrchestrator::new(&heads, &trust).install_full_baseline_with_hook(
            &peer,
            operation_a,
            &frontier,
            &manifest,
            &handle,
            &oplog,
            &CrashAfter(BaselineInstallPhase::Prepared),
        ),
        Err(ReconcileError::Trace)
    ));
    assert_eq!(baseline_phase(&heads_path, operation_a), "prepared");
    drop(heads);

    let heads = ReconcileStore::open(&heads_path, project).unwrap();
    let orchestrator = ReconcileOrchestrator::new(&heads, &trust);
    assert!(matches!(
        orchestrator.install_full_baseline(
            &peer,
            operation_b,
            &frontier,
            &manifest,
            &handle,
            &oplog,
        ),
        Err(ReconcileError::BaselineInProgress)
    ));
    assert!(matches!(
        orchestrator.offer_authenticated(&peer, root, &frontier, true),
        Err(ReconcileError::BaselineInProgress)
    ));
    assert!(matches!(
        orchestrator.commit_full_baseline(&peer, &frontier, &manifest, &handle),
        Err(ReconcileError::BaselineInProgress)
    ));
    assert!(matches!(
        orchestrator.sync_incremental(&oplog, &oplog, 1),
        Err(ReconcileError::BaselineInProgress)
    ));
    let trace = WireTrace::create(&temp.path().join("blocked-no-change.jsonl")).unwrap();
    assert!(matches!(
        orchestrator.no_change(&peer, root, &frontier, &trace),
        Err(ReconcileError::BaselineInProgress)
    ));
    let operation_b_rows: i64 = rusqlite::Connection::open(&heads_path)
        .unwrap()
        .query_row(
            "SELECT count(*) FROM baseline_installs WHERE operation_id=?1",
            [operation_b],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(operation_b_rows, 0);
    assert_eq!(
        orchestrator
            .reconcile_baseline_install(operation_a, &manifest_path, &oplog)
            .unwrap(),
        BaselineInstallPhase::Completed
    );
    assert_eq!(baseline_phase(&heads_path, operation_a), "completed");
    assert_eq!(heads.test_head_root(peer.device_id).unwrap(), Some(root));
    assert_eq!(baseline_generation(&oplog_path, project), 1);
}

#[test]
fn concurrent_baseline_operations_admit_exactly_one_project_journal() {
    use std::sync::Barrier;

    let temp = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([168; 32]);
    let heads_path = temp.path().join("heads.db");
    let oplog_path = temp.path().join("oplog.db");
    let manifest_a_path = temp.path().join("manifest-a.db");
    let manifest_b_path = temp.path().join("manifest-b.db");
    let operation_a = [169; 16];
    let operation_b = [170; 16];
    let (trust, _, _, peer) = approve_peer(&temp.path().join("trust.db"), project);
    let (manifest_a, handle_a, _) = complete_manifest(&manifest_a_path, [171; 16]);
    let (manifest_b, handle_b) = complete_many_entry_manifest(&manifest_b_path, [172; 16], 2);
    let heads = Arc::new(ReconcileStore::open(&heads_path, project).unwrap());
    let trust = Arc::new(trust);
    let oplog =
        Arc::new(OplogStore::open(&oplog_path, project, Arc::new(AllowOplogTrust)).unwrap());
    let manifest_a = Arc::new(manifest_a);
    let manifest_b = Arc::new(manifest_b);
    let barrier = Arc::new(Barrier::new(3));
    let frontier = BTreeMap::from([([2; 32], 7)]);

    let spawn_install =
        |operation_id, manifest: Arc<ManifestIndex>, handle: sync::CompletedManifestHandle| {
            let heads = heads.clone();
            let trust = trust.clone();
            let oplog = oplog.clone();
            let barrier = barrier.clone();
            let frontier = frontier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                ReconcileOrchestrator::new(&heads, &trust).install_full_baseline_with_hook(
                    &peer,
                    operation_id,
                    &frontier,
                    &manifest,
                    &handle,
                    &oplog,
                    &CrashAfter(BaselineInstallPhase::Prepared),
                )
            })
        };
    let first = spawn_install(operation_a, manifest_a, handle_a);
    let second = spawn_install(operation_b, manifest_b, handle_b);
    barrier.wait();
    let outcomes = [first.join().unwrap(), second.join().unwrap()];
    assert_eq!(
        outcomes
            .iter()
            .filter(|result| matches!(result, Err(ReconcileError::Trace)))
            .count(),
        1
    );
    assert_eq!(
        outcomes
            .iter()
            .filter(|result| {
                matches!(
                    result,
                    Err(ReconcileError::BaselineInProgress | ReconcileError::ProjectBusy)
                )
            })
            .count(),
        1
    );
    let active: Vec<Vec<u8>> = {
        let connection = rusqlite::Connection::open(&heads_path).unwrap();
        let mut statement = connection
            .prepare("SELECT operation_id FROM baseline_installs WHERE phase!='completed'")
            .unwrap();
        statement
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(active.len(), 1);
    assert!(active[0].as_slice() == operation_a || active[0].as_slice() == operation_b);
}

#[test]
fn project_lease_blocks_baseline_while_incremental_is_paused_after_gate() {
    use std::sync::mpsc;
    use std::time::Duration;

    let temp = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([173; 32]);
    let heads_path = temp.path().join("heads.db");
    let (trust, _, _, peer) = approve_peer(&temp.path().join("trust.db"), project);
    let trust = Arc::new(trust);
    let first_heads = Arc::new(ReconcileStore::open(&heads_path, project).unwrap());
    let second_heads = ReconcileStore::open(&heads_path, project).unwrap();
    let source = Arc::new(
        OplogStore::open(
            &temp.path().join("source.db"),
            project,
            Arc::new(AllowOplogTrust),
        )
        .unwrap(),
    );
    let destination = Arc::new(
        OplogStore::open(
            &temp.path().join("destination.db"),
            project,
            Arc::new(AllowOplogTrust),
        )
        .unwrap(),
    );
    source.ingest(&oplog_record(project, 1), 1).unwrap();
    let (manifest, handle, root) = complete_manifest(&temp.path().join("manifest.db"), [174; 16]);
    let (ready_tx, ready_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let worker = {
        let heads = first_heads.clone();
        let trust = trust.clone();
        let source = source.clone();
        let destination = destination.clone();
        std::thread::spawn(move || {
            ReconcileOrchestrator::new(&heads, &trust).test_sync_incremental_report_after_gate(
                &source,
                &destination,
                2,
                || {
                    ready_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                },
            )
        })
    };
    ready_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    assert!(matches!(
        ReconcileOrchestrator::new(&second_heads, &trust).install_full_baseline(
            &peer,
            [175; 16],
            &BTreeMap::from([([2; 32], 4)]),
            &manifest,
            &handle,
            &destination,
        ),
        Err(ReconcileError::ProjectBusy)
    ));
    assert!(matches!(
        ReconcileOrchestrator::new(&second_heads, &trust).reconcile_baseline_install(
            [175; 16],
            &temp.path().join("manifest.db"),
            &destination,
        ),
        Err(ReconcileError::ProjectBusy)
    ));
    assert_eq!(baseline_row_count(&heads_path), 0);
    assert!(destination.frontier().unwrap().is_empty());
    assert_eq!(second_heads.test_head_root(peer.device_id).unwrap(), None);
    release_tx.send(()).unwrap();
    assert_eq!(worker.join().unwrap().unwrap().applied_records, 1);
    assert_eq!(destination.frontier().unwrap().get(&[2; 32]), Some(&1));
    assert_eq!(second_heads.test_head_root(peer.device_id).unwrap(), None);
    assert_ne!(root, [0; 32]);
}

#[test]
fn project_lease_blocks_incremental_while_baseline_is_paused_and_releases_on_drop() {
    use std::sync::mpsc;
    use std::time::Duration;

    let temp = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([176; 32]);
    let heads_path = temp.path().join("heads.db");
    let manifest_path = temp.path().join("manifest.db");
    let oplog_path = temp.path().join("destination.db");
    let operation_id = [177; 16];
    let (trust, _, _, peer) = approve_peer(&temp.path().join("trust.db"), project);
    let trust = Arc::new(trust);
    let first_heads = Arc::new(ReconcileStore::open(&heads_path, project).unwrap());
    let second_heads = ReconcileStore::open(&heads_path, project).unwrap();
    let (manifest, handle, root) = complete_manifest(&manifest_path, [178; 16]);
    let manifest = Arc::new(manifest);
    let destination =
        Arc::new(OplogStore::open(&oplog_path, project, Arc::new(AllowOplogTrust)).unwrap());
    let source = OplogStore::open(
        &temp.path().join("source.db"),
        project,
        Arc::new(AllowOplogTrust),
    )
    .unwrap();
    source.ingest(&oplog_record(project, 1), 1).unwrap();
    let (ready_tx, ready_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let worker = {
        let heads = first_heads.clone();
        let trust = trust.clone();
        let manifest = manifest.clone();
        let destination = destination.clone();
        std::thread::spawn(move || {
            let hook = PauseAfterPrepared {
                ready: ready_tx,
                release: std::sync::Mutex::new(release_rx),
            };
            ReconcileOrchestrator::new(&heads, &trust).install_full_baseline_with_hook(
                &peer,
                operation_id,
                &BTreeMap::from([([2; 32], 4)]),
                &manifest,
                &handle,
                &destination,
                &hook,
            )
        })
    };
    ready_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    assert_eq!(baseline_phase(&heads_path, operation_id), "prepared");
    assert!(matches!(
        ReconcileOrchestrator::new(&second_heads, &trust).sync_incremental_report(
            &source,
            &destination,
            2
        ),
        Err(ReconcileError::ProjectBusy)
    ));
    assert!(destination.frontier().unwrap().is_empty());
    release_tx.send(()).unwrap();
    worker.join().unwrap().unwrap();
    assert_eq!(baseline_phase(&heads_path, operation_id), "completed");
    assert_eq!(
        second_heads.test_head_root(peer.device_id).unwrap(),
        Some(root)
    );
    assert_eq!(baseline_generation(&oplog_path, project), 1);

    drop(first_heads);
    let reopened = ReconcileStore::open(&heads_path, project).unwrap();
    assert_eq!(
        ReconcileOrchestrator::new(&reopened, &trust)
            .reconcile_baseline_install(operation_id, &manifest_path, &destination)
            .unwrap(),
        BaselineInstallPhase::Completed
    );
}

#[test]
fn project_lease_rejects_symlink_lock_file_without_head_mutation() {
    use std::os::unix::fs::{symlink, PermissionsExt};

    let temp = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([179; 32]);
    let heads_path = temp.path().join("heads.db");
    let heads = ReconcileStore::open(&heads_path, project).unwrap();
    let lock_dir = temp.path().join(".term-mesh-project-locks");
    std::fs::create_dir(&lock_dir).unwrap();
    std::fs::set_permissions(&lock_dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    let target = temp.path().join("target");
    std::fs::write(&target, b"keep").unwrap();
    symlink(&target, lock_dir.join(format!("{project}.lock"))).unwrap();
    assert!(heads
        .offer(
            &peer(project),
            [180; 32],
            &BTreeMap::from([([2; 32], 1)]),
            false,
        )
        .is_err());
    assert_eq!(std::fs::read(target).unwrap(), b"keep");
    let candidates: i64 = rusqlite::Connection::open(&heads_path)
        .unwrap()
        .query_row("SELECT count(*) FROM candidates", [], |row| row.get(0))
        .unwrap();
    assert_eq!(candidates, 0);
}

#[test]
fn baseline_record_swap_mismatch_fails_without_mutation() {
    let temp = tempfile::tempdir().unwrap();
    let project = ProjectId::from_bytes([171; 32]);
    let trust_path = temp.path().join("trust.db");
    let heads_path = temp.path().join("heads.db");
    let manifest_path = temp.path().join("manifest.db");
    let oplog_path = temp.path().join("oplog.db");
    let operation_id = [172; 16];
    let (trust, _, _, peer) = approve_peer(&trust_path, project);
    let (manifest, handle, _) = complete_manifest(&manifest_path, [173; 16]);
    let heads = ReconcileStore::open(&heads_path, project).unwrap();
    let oplog = OplogStore::open(&oplog_path, project, Arc::new(AllowOplogTrust)).unwrap();
    assert!(ReconcileOrchestrator::new(&heads, &trust)
        .install_full_baseline_with_hook(
            &peer,
            operation_id,
            &BTreeMap::from([([2; 32], 4)]),
            &manifest,
            &handle,
            &oplog,
            &CrashAfter(BaselineInstallPhase::OplogInstalled),
        )
        .is_err());
    rusqlite::Connection::open(&oplog_path)
        .unwrap()
        .execute(
            "UPDATE oplog_baselines SET control_hash=?1 WHERE operation_id=?2",
            rusqlite::params![[99_u8; 32], operation_id],
        )
        .unwrap();
    assert!(matches!(
        ReconcileOrchestrator::new(&heads, &trust).reconcile_baseline_install(
            operation_id,
            &manifest_path,
            &oplog
        ),
        Err(ReconcileError::Binding)
    ));
    assert_eq!(heads.test_head_root(peer.device_id).unwrap(), None);
    assert_eq!(baseline_phase(&heads_path, operation_id), "blocked");
}

#[test]
fn million_entry_source_streams_to_persisted_index_and_no_change_has_zero_paths() {
    let temp = tempfile::tempdir().unwrap();
    let index = Arc::new(ManifestIndex::begin(&temp.path().join("million.db"), [9; 16]).unwrap());
    let scanner = ManifestScanner::with_observer(
        ScanLimits {
            max_entries: 1_000_000,
            max_depth: 128,
            max_children_per_directory: 1024,
            max_buffered_paths: 1024,
            max_open_files: 32,
            max_symlink_bytes: 4096,
            hash_buffer_bytes: 64 * 1024,
        },
        Box::new(index.clone()),
    )
    .unwrap();
    let (manifest, metrics) = scanner.scan_synthetic(1_000_000).unwrap();
    index.finish(manifest).unwrap();
    assert_eq!(index.shard_roots().unwrap().len(), 977);
    assert_eq!(index.page(0).unwrap().len(), 1024);
    assert_eq!(
        (
            metrics.entries,
            metrics.peak_buffered_children,
            metrics.peak_open_files
        ),
        (1_000_000, 0, 0)
    );
    let trace_path = temp.path().join("no-change.jsonl");
    WireTrace::create(&trace_path)
        .unwrap()
        .summary(0, 0, 0)
        .unwrap();
    let trace = std::fs::read_to_string(trace_path).unwrap();
    assert!(trace.contains("\"path_items\":0") && trace.contains("\"path_bytes\":0"));
    assert!(
        !trace.contains("plaintext") && !trace.contains("ciphertext") && !trace.contains("key_id")
    );
}

#[test]
fn manifest_long_entry_boundary_is_always_wire_transmittable() {
    let temp = tempfile::tempdir().unwrap();
    let index = ManifestIndex::begin(&temp.path().join("boundary.db"), [4; 16]).unwrap();
    let entry = ManifestEntry {
        relative_path: "a".into(),
        kind: EntryKind::Symlink,
        executable: false,
        length: 0,
        content_hash: [0; 32],
        symlink_target: Some("x".repeat(sync_protocol::MAX_MANIFEST_PAGE_BYTES - 57)),
    };
    let mut builder = ManifestBuilder::new();
    builder.push(&entry).unwrap();
    ScanObserver::entry(&index, &entry).unwrap();
    index.finish(builder.finish()).unwrap();
    let page = index.page(0).unwrap();
    let frame = WireFrame {
        binding: WireBinding {
            project_id: [1; 32],
            roster_epoch: 1,
            operation_id: [2; 16],
        },
        body: WireBody::ManifestNodeBatch(sync_protocol::ManifestNodeBatch { nodes: page }),
    };
    assert!(frame.canonical_bytes().is_ok());

    let oversized = ManifestEntry {
        symlink_target: Some("x".repeat(sync_protocol::MAX_MANIFEST_PAGE_BYTES - 56)),
        ..entry
    };
    let other = ManifestIndex::begin(&temp.path().join("oversized.db"), [5; 16]).unwrap();
    assert!(ScanObserver::entry(&other, &oversized).is_err());
}

#[test]
fn manifest_root_mismatch_never_completes_and_duplicate_root_handles_remain_valid() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("handles.db");
    let entry = ManifestEntry {
        relative_path: "same".into(),
        kind: EntryKind::File,
        executable: false,
        length: 1,
        content_hash: [71; 32],
        symlink_target: None,
    };
    let mut builder = ManifestBuilder::new();
    builder.push(&entry).unwrap();
    let expected = builder.finish();

    let bad = ManifestIndex::begin(&path, [70; 16]).unwrap();
    ScanObserver::entry(&bad, &entry).unwrap();
    let mut forged = expected;
    forged.root.0[0] ^= 1;
    assert!(matches!(
        bad.finish(forged),
        Err(ReconcileError::ManifestMismatch)
    ));

    let first = ManifestIndex::begin(&path, [71; 16]).unwrap();
    ScanObserver::entry(&first, &entry).unwrap();
    let first_handle = first.finish(expected).unwrap();
    let second = ManifestIndex::begin(&path, [72; 16]).unwrap();
    ScanObserver::entry(&second, &entry).unwrap();
    let second_handle = second.finish(expected).unwrap();
    assert_eq!(first_handle.root(), second_handle.root());
    second.test_verify_handle(&first_handle).unwrap();
    first.test_verify_handle(&second_handle).unwrap();
}

#[test]
fn completed_manifest_sqlite_tamper_matrix_fails_closed_without_a_handle() {
    for (case_index, case) in [
        "entry-byte",
        "entry-noncanonical",
        "entry-path",
        "shard-hash",
        "shard-bounds",
        "shard-order",
        "scan-count",
        "entry-order",
        "entry-delete",
        "entry-extra",
    ]
    .into_iter()
    .enumerate()
    {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join(format!("{case}.db"));
        let scan_id = [case_index as u8 + 100; 16];
        let (root, count) = complete_two_entry_manifest(&path, scan_id);
        let connection = rusqlite::Connection::open(&path).unwrap();
        match case {
            "entry-byte" => {
                let mut entry: Vec<u8> = connection
                    .query_row(
                        "SELECT entry FROM entries WHERE scan_id=?1 AND ordinal=0",
                        [scan_id],
                        |row| row.get(0),
                    )
                    .unwrap();
                entry[10] ^= 1;
                connection
                    .execute(
                        "UPDATE entries SET entry=?1 WHERE scan_id=?2 AND ordinal=0",
                        rusqlite::params![entry, scan_id],
                    )
                    .unwrap();
            }
            "entry-noncanonical" => {
                let mut entry: Vec<u8> = connection
                    .query_row(
                        "SELECT entry FROM entries WHERE scan_id=?1 AND ordinal=0",
                        [scan_id],
                        |row| row.get(0),
                    )
                    .unwrap();
                entry.push(0);
                connection
                    .execute(
                        "UPDATE entries SET entry=?1 WHERE scan_id=?2 AND ordinal=0",
                        rusqlite::params![entry, scan_id],
                    )
                    .unwrap();
            }
            "entry-path" => {
                connection
                    .execute(
                        "UPDATE entries SET path='wrong.txt' WHERE scan_id=?1 AND ordinal=0",
                        [scan_id],
                    )
                    .unwrap();
            }
            "shard-hash" => {
                connection
                    .execute(
                        "UPDATE shards SET root=?1 WHERE scan_id=?2 AND shard_index=0",
                        rusqlite::params![[9_u8; 32], scan_id],
                    )
                    .unwrap();
            }
            "shard-bounds" => {
                connection
                    .execute(
                        "UPDATE shards SET last_ordinal=1 WHERE scan_id=?1 AND shard_index=0",
                        [scan_id],
                    )
                    .unwrap();
            }
            "shard-order" => {
                connection
                    .execute(
                        "UPDATE shards SET shard_index=1 WHERE scan_id=?1 AND shard_index=0",
                        [scan_id],
                    )
                    .unwrap();
            }
            "scan-count" => {
                connection
                    .execute("UPDATE scans SET entry_count=1 WHERE scan_id=?1", [scan_id])
                    .unwrap();
            }
            "entry-order" => {
                connection.execute_batch("BEGIN IMMEDIATE").unwrap();
                connection
                    .execute(
                        "UPDATE entries SET ordinal=10 WHERE scan_id=?1 AND ordinal=0",
                        [scan_id],
                    )
                    .unwrap();
                connection
                    .execute(
                        "UPDATE entries SET ordinal=0 WHERE scan_id=?1 AND ordinal=1",
                        [scan_id],
                    )
                    .unwrap();
                connection
                    .execute(
                        "UPDATE entries SET ordinal=1 WHERE scan_id=?1 AND ordinal=10",
                        [scan_id],
                    )
                    .unwrap();
                connection.execute_batch("COMMIT").unwrap();
            }
            "entry-delete" => {
                connection
                    .execute(
                        "DELETE FROM entries WHERE scan_id=?1 AND ordinal=1",
                        [scan_id],
                    )
                    .unwrap();
            }
            "entry-extra" => {
                let entry: Vec<u8> = connection
                    .query_row(
                        "SELECT entry FROM entries WHERE scan_id=?1 AND ordinal=1",
                        [scan_id],
                        |row| row.get(0),
                    )
                    .unwrap();
                connection
                    .execute(
                        "INSERT INTO entries VALUES(?1,2,'extra.txt',?2)",
                        rusqlite::params![scan_id, entry],
                    )
                    .unwrap();
            }
            _ => unreachable!(),
        }
        drop(connection);
        assert!(
            ManifestIndex::open_completed(&path, scan_id, root, count).is_err(),
            "case={case}"
        );
        assert!(
            path.exists(),
            "content tamper must be non-destructive: {case}"
        );
    }
}

#[test]
fn canonical_manifest_shards_reject_rehashed_split_and_merge_layouts() {
    for case in ["split", "merge"] {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join(format!("{case}.db"));
        let scan_id = if case == "split" {
            [181; 16]
        } else {
            [182; 16]
        };
        let (index, handle) = complete_many_entry_manifest(&path, scan_id, 1025);
        assert_eq!(index.shard_roots().unwrap().len(), 2);
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection
            .execute("DELETE FROM shards WHERE scan_id=?1", [scan_id])
            .unwrap();
        let bounds: &[(u64, u64)] = if case == "split" {
            &[(0, 512), (512, 1024), (1024, 1025)]
        } else {
            &[(0, 1025)]
        };
        for (shard_index, (first, last)) in bounds.iter().copied().enumerate() {
            let root = persisted_shard_root(&connection, scan_id, first, last);
            connection
                .execute(
                    "INSERT INTO shards VALUES(?1,?2,?3,?4,?5)",
                    rusqlite::params![scan_id, shard_index as u64, root, first, last],
                )
                .unwrap();
        }
        drop(connection);
        assert!(index.test_verify_handle(&handle).is_err(), "case={case}");
    }
}

#[test]
fn verified_manifest_snapshot_blocks_raw_writer_and_tamper_never_commits_head() {
    use std::sync::mpsc;
    use std::time::Duration;

    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("writer-race.db");
    let scan_id = [183; 16];
    let (index, handle, _) = complete_manifest(&path, scan_id);
    let (ready_tx, ready_rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    let writer_path = path.clone();
    let writer = std::thread::spawn(move || {
        let connection = rusqlite::Connection::open(writer_path).unwrap();
        connection.busy_timeout(Duration::from_secs(2)).unwrap();
        ready_tx.send(()).unwrap();
        let result = connection.execute(
            "UPDATE entries SET entry=zeroblob(length(entry)) WHERE scan_id=?1 AND ordinal=0",
            [scan_id],
        );
        done_tx.send(result).unwrap();
    });
    index
        .test_with_verified_handle(&handle, || {
            ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert!(matches!(
                done_rx.recv_timeout(Duration::from_millis(150)),
                Err(mpsc::RecvTimeoutError::Timeout)
            ));
            Ok(())
        })
        .unwrap();
    assert_eq!(
        done_rx
            .recv_timeout(Duration::from_secs(2))
            .unwrap()
            .unwrap(),
        1
    );
    writer.join().unwrap();
    assert!(index.test_verify_handle(&handle).is_err());

    let project = ProjectId::from_bytes([184; 32]);
    let (trust, _, _, peer) = approve_peer(&temp.path().join("trust.db"), project);
    let manifest_path = temp.path().join("head-manifest.db");
    let (manifest, handle, root) = complete_manifest(&manifest_path, [185; 16]);
    let heads = ReconcileStore::open(&temp.path().join("heads.db"), project).unwrap();
    let frontier = BTreeMap::from([([2; 32], 1)]);
    let HeadDecision::Initial(candidate) = heads.offer(&peer, root, &frontier, true).unwrap()
    else {
        panic!()
    };
    rusqlite::Connection::open(&manifest_path)
        .unwrap()
        .execute(
            "UPDATE entries SET entry=zeroblob(length(entry)) WHERE ordinal=0",
            [],
        )
        .unwrap();
    assert!(ReconcileOrchestrator::new(&heads, &trust)
        .commit_persisted(candidate, &peer, &manifest, &handle)
        .is_err());
    assert_eq!(heads.test_head_root(peer.device_id).unwrap(), None);
}

#[test]
fn concurrent_entry_finish_and_page_serialize_without_deadlock() {
    use std::sync::{Arc, Barrier};
    use std::time::Duration;
    let temp = tempfile::tempdir().unwrap();
    let index = Arc::new(ManifestIndex::begin(&temp.path().join("race.db"), [73; 16]).unwrap());
    let entry = ManifestEntry {
        relative_path: "race".into(),
        kind: EntryKind::File,
        executable: false,
        length: 1,
        content_hash: [73; 32],
        symlink_target: None,
    };
    let barrier = Arc::new(Barrier::new(2));
    let writer = {
        let index = index.clone();
        let barrier = barrier.clone();
        let entry = entry.clone();
        std::thread::spawn(move || {
            barrier.wait();
            ScanObserver::entry(&*index, &entry)
        })
    };
    barrier.wait();
    let _ = index.page(0).unwrap();
    writer.join().unwrap().unwrap();
    let mut builder = ManifestBuilder::new();
    builder.push(&entry).unwrap();
    index.finish(builder.finish()).unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = index.clone();
    std::thread::spawn(move || {
        tx.send(reader.page(0)).unwrap();
    });
    assert!(rx.recv_timeout(Duration::from_secs(2)).unwrap().is_ok());
}

#[test]
fn checkpoint_mac_and_exact_resume_boundary_are_enforced() {
    let key = ProjectKey::new([7; 32]);
    let checkpoint = TransferCheckpoint {
        project_id: ProjectId::from_bytes([1; 32]),
        operation_id: [2; 16],
        object_id: ObjectId([3; 32]),
        stage_id: StageId::from_bytes([4; 16]),
        resume_token: ResumeToken::from_bytes([5; 32]),
        key_id: KeyId([6; 16]),
        generation: 231,
        verified_ranges: vec![(0, 231)],
        mac: [0; 32],
    }
    .seal(&key)
    .unwrap();
    let bytes = checkpoint.canonical_bytes().unwrap();
    assert_eq!(
        TransferCheckpoint::decode(&bytes, &key).unwrap(),
        checkpoint
    );
    let mut tampered = bytes.clone();
    tampered[40] ^= 1;
    assert!(TransferCheckpoint::decode(&tampered, &key).is_err());
    assert!(TransferCheckpoint::decode(&bytes, &ProjectKey::new([8; 32])).is_err());
    let report = logical_transfer_fixture();
    assert_eq!(
        (
            report.logical_bytes,
            report.total_chunks,
            report.verified_before_restart
        ),
        (1_073_741_824, 256, 231)
    );
    assert_eq!(
        (
            report.retransmitted_chunks,
            report.retransmitted_verified_chunks,
            report.peak_buffer_bytes
        ),
        (25, 0, 4 * 1024 * 1024)
    );
    assert_ne!(report.observable_digest, [0; 32]);
}

#[tokio::test]
async fn transfer_binding_mismatch_has_zero_queue_and_trace_mutations() {
    let temp = tempfile::tempdir().unwrap();
    let trace_path = temp.path().join("binding.jsonl");
    let trace = WireTrace::create(&trace_path).unwrap();
    let (sender, _router) = StreamRouter::bounded();
    let expected = WireBinding {
        project_id: [1; 32],
        roster_epoch: 2,
        operation_id: [3; 16],
    };
    let session = TransferSession::new(&sender, &trace, expected);
    let frame = WireFrame {
        binding: WireBinding {
            project_id: [9; 32],
            ..expected
        },
        body: WireBody::StreamPreface(StreamPreface {
            lane: 0,
            declared_length: None,
        }),
    };
    assert!(session.enqueue(&frame, false).await.is_err());
    assert_eq!(std::fs::metadata(trace_path).unwrap().len(), 0);
}

#[test]
fn wire_trace_rejects_existing_symlink_target() {
    use std::os::unix::fs::symlink;
    let temp = tempfile::tempdir().unwrap();
    let real = temp.path().join("real");
    std::fs::write(&real, b"keep").unwrap();
    let link = temp.path().join("trace.jsonl");
    symlink(&real, &link).unwrap();
    assert!(WireTrace::create(&link).is_err());
    assert_eq!(std::fs::read(real).unwrap(), b"keep");
}
