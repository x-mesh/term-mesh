use super::project_lock::{acquire_project_file_lease, ProjectLease, ProjectLockError};
use super::{
    manifest::decode_index_entry, EntryKind, Manifest, ManifestBuilder, ManifestEntry, ProjectId,
    ScanCheckpoint, ScanError, ScanObserver, TransportPeerSnapshot, TrustStore,
};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use std::collections::BTreeMap;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const MANIFEST_SHARD_ENTRIES: u64 = 1024;
const MAX_MANIFEST_PAGE_BYTES: usize = 1024 * 1024;

const APP_ID: i64 = 0x544d_5243;
const VERSION: i64 = 1;
const MAX_FRONTIERS: usize = 4096;
const MAX_OPLOG_BATCH_RECORDS: usize = 1024;
const MAX_OPLOG_BATCH_BYTES: usize = 8 * 1024 * 1024;
const HEAD_TABLES: &[(&str, &str)] = &[
    ("baseline_installs", "CREATE TABLE baseline_installs(operation_id BLOB PRIMARY KEY CHECK(length(operation_id)=16),project BLOB NOT NULL CHECK(length(project)=32),roster_epoch INTEGER NOT NULL CHECK(roster_epoch>0),peer BLOB NOT NULL CHECK(length(peer)=32),root BLOB NOT NULL CHECK(length(root)=32),frontier BLOB NOT NULL,frontier_hash BLOB NOT NULL CHECK(length(frontier_hash)=32),control_hash BLOB NOT NULL CHECK(length(control_hash)=32),manifest_scan_id BLOB NOT NULL CHECK(length(manifest_scan_id)=16),manifest_entry_count INTEGER NOT NULL CHECK(manifest_entry_count>=0),candidate_id INTEGER NOT NULL,phase TEXT NOT NULL CHECK(phase IN('prepared','oplog_installed','head_committed','completed','blocked')),prepared_at_ms INTEGER NOT NULL) STRICT"),
    ("heads", "CREATE TABLE heads(peer BLOB PRIMARY KEY CHECK(length(peer)=32),root BLOB NOT NULL CHECK(length(root)=32),frontier BLOB NOT NULL) STRICT"),
    ("candidates", "CREATE TABLE candidates(id INTEGER PRIMARY KEY,peer BLOB NOT NULL CHECK(length(peer)=32),roster_epoch INTEGER NOT NULL CHECK(roster_epoch>0),certificate_hash BLOB NOT NULL CHECK(length(certificate_hash)=32),root BLOB NOT NULL CHECK(length(root)=32),frontier BLOB NOT NULL,relation TEXT NOT NULL CHECK(relation IN ('initial','dominates','concurrent','full')),state TEXT NOT NULL CHECK(state IN ('pending','committed','conflict'))) STRICT"),
    ("quarantine", "CREATE TABLE quarantine(id INTEGER PRIMARY KEY,peer BLOB NOT NULL CHECK(length(peer)=32),root BLOB NOT NULL CHECK(length(root)=32),reason TEXT NOT NULL) STRICT"),
];
const HEAD_SCHEMA: &[(&str, &str)] = &[
    HEAD_TABLES[0],
    HEAD_TABLES[1],
    HEAD_TABLES[2],
    HEAD_TABLES[3],
    ("baseline_installs_one_active_project", "CREATE UNIQUE INDEX baseline_installs_one_active_project ON baseline_installs(project) WHERE phase!='completed'"),
];
const MANIFEST_APP_ID: i64 = 0x544d_4d49;
const MANIFEST_SCHEMA: &[(&str, &str)] = &[
    ("entries", "CREATE TABLE entries(scan_id BLOB NOT NULL CHECK(length(scan_id)=16),ordinal INTEGER NOT NULL,path TEXT NOT NULL,entry BLOB NOT NULL,PRIMARY KEY(scan_id,ordinal),UNIQUE(scan_id,path)) STRICT"),
    ("scans", "CREATE TABLE scans(scan_id BLOB PRIMARY KEY CHECK(length(scan_id)=16),root BLOB CHECK(root IS NULL OR length(root)=32),entry_count INTEGER NOT NULL CHECK(entry_count>=0),complete INTEGER NOT NULL CHECK(complete IN(0,1))) STRICT"),
    ("shards", "CREATE TABLE shards(scan_id BLOB NOT NULL CHECK(length(scan_id)=16),shard_index INTEGER NOT NULL CHECK(shard_index>=0),root BLOB NOT NULL CHECK(length(root)=32),first_ordinal INTEGER NOT NULL CHECK(first_ordinal>=0),last_ordinal INTEGER NOT NULL CHECK(last_ordinal>first_ordinal),PRIMARY KEY(scan_id,shard_index)) STRICT"),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrontierRelation {
    Equal,
    RemoteDominates,
    LocalDominates,
    Concurrent,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncMode {
    Incremental,
    FullResync,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IncrementalSyncReport {
    pub applied_records: u64,
    pub batches: u64,
    pub max_batch_records: usize,
    pub max_batch_bytes: usize,
    pub record_cap: usize,
    pub byte_cap: usize,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HeadDecision {
    Initial(i64),
    Candidate(i64),
    Stale,
    Duplicate,
    Conflict(i64),
    Quarantined,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BaselineInstallPhase {
    Prepared,
    OplogInstalled,
    HeadCommitted,
    Completed,
    Blocked,
}

impl BaselineInstallPhase {
    fn as_str(self) -> &'static str {
        match self {
            Self::Prepared => "prepared",
            Self::OplogInstalled => "oplog_installed",
            Self::HeadCommitted => "head_committed",
            Self::Completed => "completed",
            Self::Blocked => "blocked",
        }
    }

    fn parse(value: &str) -> Result<Self, ReconcileError> {
        match value {
            "prepared" => Ok(Self::Prepared),
            "oplog_installed" => Ok(Self::OplogInstalled),
            "head_committed" => Ok(Self::HeadCommitted),
            "completed" => Ok(Self::Completed),
            "blocked" => Ok(Self::Blocked),
            _ => Err(ReconcileError::Corrupt),
        }
    }
}

pub trait BaselineCrashHook {
    fn after_phase(&self, phase: BaselineInstallPhase) -> Result<(), ReconcileError>;
}

struct NoBaselineCrash;
impl BaselineCrashHook for NoBaselineCrash {
    fn after_phase(&self, _: BaselineInstallPhase) -> Result<(), ReconcileError> {
        Ok(())
    }
}

struct BaselineInstallRecord {
    operation_id: [u8; 16],
    project: ProjectId,
    peer: TransportPeerSnapshot,
    root: [u8; 32],
    frontier: BTreeMap<[u8; 32], u64>,
    frontier_hash: [u8; 32],
    control_hash: [u8; 32],
    manifest_scan_id: [u8; 16],
    manifest_entry_count: u64,
    candidate_id: i64,
    phase: BaselineInstallPhase,
}

pub struct ReconcileStore {
    project: ProjectId,
    head_path: PathBuf,
    connection: Mutex<Connection>,
    baseline_resume: Mutex<()>,
}

impl ReconcileStore {
    fn acquire_project_lease(&self) -> Result<ProjectLease, ReconcileError> {
        acquire_project_file_lease(&self.head_path, self.project).map_err(ReconcileError::from)
    }

    #[cfg(test)]
    pub fn test_project_lease_is_available(&self) -> Result<(), ReconcileError> {
        let _lease = self.acquire_project_lease()?;
        Ok(())
    }

    #[cfg(test)]
    pub fn test_with_project_lease<T>(
        &self,
        action: impl FnOnce() -> T,
    ) -> Result<T, ReconcileError> {
        let _lease = self.acquire_project_lease()?;
        Ok(action())
    }

    fn ensure_project_available(&self) -> Result<(), ReconcileError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| ReconcileError::Poisoned)?;
        let active: Option<String> = connection
            .query_row(
                "SELECT phase FROM baseline_installs WHERE project=?1 AND phase!='completed'",
                [self.project.as_bytes().as_slice()],
                |row| row.get(0),
            )
            .optional()?;
        match active.as_deref() {
            None => Ok(()),
            Some("blocked") => Err(ReconcileError::BaselineBlocked),
            Some(_) => Err(ReconcileError::BaselineInProgress),
        }
    }

    fn baseline_install(
        &self,
        operation_id: [u8; 16],
    ) -> Result<BaselineInstallRecord, ReconcileError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| ReconcileError::Poisoned)?;
        validate_schema(&connection, APP_ID, HEAD_SCHEMA)?;
        let record = load_baseline_install(&connection, operation_id)?;
        if record.project != self.project || record.operation_id != operation_id {
            return Err(ReconcileError::Binding);
        }
        Ok(record)
    }

    fn candidate_matches(&self, record: &BaselineInstallRecord) -> Result<String, ReconcileError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| ReconcileError::Poisoned)?;
        let (peer, epoch, certificate, root, frontier, relation, state): (
            Vec<u8>, i64, Vec<u8>, Vec<u8>, Vec<u8>, String, String,
        ) = connection.query_row(
            "SELECT peer,roster_epoch,certificate_hash,root,frontier,relation,state FROM candidates WHERE id=?1",
            [record.candidate_id],
            |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?,row.get(4)?,row.get(5)?,row.get(6)?)),
        )?;
        if peer.as_slice() != record.peer.device_id
            || u64::try_from(epoch).ok() != Some(record.peer.roster_epoch)
            || certificate.as_slice() != record.peer.certificate_hash
            || root.as_slice() != record.root
            || frontier != encode_frontier(&record.frontier)?
            || relation != "full"
            || !matches!(state.as_str(), "pending" | "committed")
        {
            return Err(ReconcileError::Binding);
        }
        Ok(state)
    }

    fn head_matches(&self, record: &BaselineInstallRecord) -> Result<bool, ReconcileError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| ReconcileError::Poisoned)?;
        let matching: i64 = connection.query_row(
            "SELECT count(*) FROM heads WHERE peer=?1 AND root=?2 AND frontier=?3",
            params![
                record.peer.device_id,
                record.root,
                encode_frontier(&record.frontier)?
            ],
            |row| row.get(0),
        )?;
        Ok(matching == 1)
    }

    fn prepared_candidate_is_current(
        &self,
        record: &BaselineInstallRecord,
    ) -> Result<(), ReconcileError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| ReconcileError::Poisoned)?;
        let current: Option<(Vec<u8>, Vec<u8>)> = connection
            .query_row(
                "SELECT root,frontier FROM heads WHERE peer=?1",
                [record.peer.device_id.as_slice()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((root, frontier)) = current else {
            return Ok(());
        };
        match relation(&decode_frontier(&frontier)?, &record.frontier) {
            FrontierRelation::RemoteDominates => Ok(()),
            FrontierRelation::Equal if root.as_slice() == record.root => Ok(()),
            _ => Err(ReconcileError::Stale),
        }
    }

    fn prepare_baseline_install(
        &self,
        operation_id: [u8; 16],
        peer: &TransportPeerSnapshot,
        handle: &CompletedManifestHandle,
        frontier: &BTreeMap<[u8; 32], u64>,
        frontier_hash: [u8; 32],
        control_hash: [u8; 32],
        candidate_id: i64,
        now_ms: i64,
    ) -> Result<(), ReconcileError> {
        let encoded = encode_frontier(frontier)?;
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| ReconcileError::Poisoned)?;
        let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let active: Option<(Vec<u8>, String)> = tx
            .query_row(
                "SELECT operation_id,phase FROM baseline_installs WHERE project=?1 AND phase!='completed'",
                [peer.project_id.as_bytes().as_slice()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        if let Some((active_operation, phase)) = active {
            if active_operation.as_slice() != operation_id {
                return Err(if phase == "blocked" {
                    ReconcileError::BaselineBlocked
                } else {
                    ReconcileError::BaselineInProgress
                });
            }
        } else {
            require_one(tx.execute("INSERT INTO baseline_installs VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,'prepared',?12)",
                params![operation_id, peer.project_id.as_bytes(), peer.roster_epoch as i64, peer.device_id, handle.root, encoded, frontier_hash, control_hash, handle.scan_id, handle.entry_count, candidate_id, now_ms])?)?;
        }
        let stored = load_baseline_install(&tx, operation_id)?;
        if stored.project != peer.project_id
            || stored.peer != *peer
            || stored.root != handle.root
            || stored.frontier != *frontier
            || stored.frontier_hash != frontier_hash
            || stored.control_hash != control_hash
            || stored.manifest_scan_id != handle.scan_id
            || stored.manifest_entry_count != handle.entry_count
            || stored.candidate_id != candidate_id
        {
            return Err(ReconcileError::Binding);
        }
        validate_schema(&tx, APP_ID, HEAD_SCHEMA)?;
        tx.commit()?;
        Ok(())
    }

    fn advance_baseline_install(
        &self,
        operation_id: [u8; 16],
        from: &str,
        to: &str,
    ) -> Result<(), ReconcileError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| ReconcileError::Poisoned)?;
        let changed = connection.execute(
            "UPDATE baseline_installs SET phase=?1 WHERE operation_id=?2 AND phase=?3",
            params![to, operation_id, from],
        )?;
        if changed == 0 {
            let phase: String = connection.query_row(
                "SELECT phase FROM baseline_installs WHERE operation_id=?1",
                [operation_id],
                |row| row.get(0),
            )?;
            if phase != to {
                return Err(ReconcileError::Stale);
            }
        } else {
            require_one(changed)?;
        }
        validate_schema(&connection, APP_ID, HEAD_SCHEMA)?;
        Ok(())
    }

    fn block_baseline_install(&self, operation_id: [u8; 16]) -> Result<(), ReconcileError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| ReconcileError::Poisoned)?;
        connection.execute(
            "UPDATE baseline_installs SET phase='blocked' WHERE operation_id=?1 AND phase='oplog_installed'",
            [operation_id],
        )?;
        validate_schema(&connection, APP_ID, HEAD_SCHEMA)
    }
    pub fn is_current(
        &self,
        peer: &TransportPeerSnapshot,
        root: [u8; 32],
        frontier: &BTreeMap<[u8; 32], u64>,
    ) -> Result<bool, ReconcileError> {
        // This is the authenticated remote/oplog head, not the locally visible filesystem
        // generation. ApplyStore::visible_state is the sole visible-state authority.
        let encoded = encode_frontier(frontier)?;
        let matching: i64 = self
            .connection
            .lock()
            .map_err(|_| ReconcileError::Poisoned)?
            .query_row(
                "SELECT count(*) FROM heads WHERE peer=?1 AND root=?2 AND frontier=?3",
                params![peer.device_id, root, encoded],
                |row| row.get(0),
            )?;
        Ok(matching == 1)
    }
    pub fn open(path: &Path, project: ProjectId) -> Result<Self, ReconcileError> {
        preflight_head_existing(path)?;
        let c = Connection::open(path)?;
        c.pragma_update(None, "journal_mode", "WAL")?;
        c.pragma_update(None, "synchronous", "FULL")?;
        let v: i64 = c.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if v == 0 {
            create_schema(&c, HEAD_SCHEMA)?;
            c.pragma_update(None, "application_id", APP_ID)?;
            c.pragma_update(None, "user_version", VERSION)?;
        }
        validate_schema(&c, APP_ID, HEAD_SCHEMA)?;
        Ok(Self {
            project,
            head_path: path.to_path_buf(),
            connection: Mutex::new(c),
            baseline_resume: Mutex::new(()),
        })
    }
    pub fn mode(remote: &BTreeMap<[u8; 32], u64>, retained: &BTreeMap<[u8; 32], u64>) -> SyncMode {
        if retained
            .iter()
            .any(|(d, f)| remote.get(d).copied().unwrap_or(0).saturating_add(1) < *f)
        {
            SyncMode::FullResync
        } else {
            SyncMode::Incremental
        }
    }
    pub fn offer(
        &self,
        peer: &TransportPeerSnapshot,
        root: [u8; 32],
        remote: &BTreeMap<[u8; 32], u64>,
        full: bool,
    ) -> Result<HeadDecision, ReconcileError> {
        let lease = self.acquire_project_lease()?;
        self.offer_with_lease(&lease, peer, root, remote, full)
    }

    fn offer_with_lease(
        &self,
        _lease: &ProjectLease,
        peer: &TransportPeerSnapshot,
        root: [u8; 32],
        remote: &BTreeMap<[u8; 32], u64>,
        full: bool,
    ) -> Result<HeadDecision, ReconcileError> {
        self.ensure_project_available()?;
        if peer.project_id != self.project || peer.roster_epoch == 0 {
            return Err(ReconcileError::Binding);
        }
        let frontier = encode_frontier(remote)?;
        let mut c = self
            .connection
            .lock()
            .map_err(|_| ReconcileError::Poisoned)?;
        let tx = c.transaction()?;
        let current: Option<(Vec<u8>, Vec<u8>)> = tx
            .query_row(
                "SELECT root,frontier FROM heads WHERE peer=?1",
                [peer.device_id.as_slice()],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let decision = if let Some((old_root, old_frontier)) = current {
            let local = decode_frontier(&old_frontier)?;
            match relation(&local, remote) {
                FrontierRelation::Equal if old_root == root => HeadDecision::Duplicate,
                FrontierRelation::Equal => {
                    tx.execute("INSERT INTO quarantine(peer,root,reason)VALUES(?1,?2,'equal frontier different root')",params![peer.device_id,root])?;
                    HeadDecision::Quarantined
                }
                FrontierRelation::LocalDominates => HeadDecision::Stale,
                FrontierRelation::RemoteDominates => HeadDecision::Candidate(insert_candidate(
                    &tx,
                    peer,
                    root,
                    &frontier,
                    if full { "full" } else { "dominates" },
                )?),
                FrontierRelation::Concurrent => {
                    let id = insert_candidate(&tx, peer, root, &frontier, "concurrent")?;
                    tx.execute("UPDATE candidates SET state='conflict' WHERE id=?1", [id])?;
                    HeadDecision::Conflict(id)
                }
            }
        } else {
            HeadDecision::Initial(insert_candidate(
                &tx,
                peer,
                root,
                &frontier,
                if full { "full" } else { "initial" },
            )?)
        };
        validate_schema(&tx, APP_ID, HEAD_SCHEMA)?;
        tx.commit()?;
        Ok(decision)
    }
    pub fn commit_candidate(
        &self,
        id: i64,
        peer: &TransportPeerSnapshot,
        trust: &TrustStore,
        manifest: &ManifestIndex,
        handle: &CompletedManifestHandle,
    ) -> Result<(), ReconcileError> {
        let lease = self.acquire_project_lease()?;
        self.ensure_project_available()?;
        self.commit_candidate_with_lease(&lease, id, peer, trust, manifest, handle)
    }

    fn commit_candidate_with_lease(
        &self,
        _lease: &ProjectLease,
        id: i64,
        peer: &TransportPeerSnapshot,
        trust: &TrustStore,
        manifest: &ManifestIndex,
        handle: &CompletedManifestHandle,
    ) -> Result<(), ReconcileError> {
        // Lock order: project flock -> manifest snapshot -> trust lease -> head DB/oplog.
        manifest.with_verified_handle(handle, || {
            let authorization = trust
                .acquire_transport_authorization_lease(peer)
                .map_err(|_| ReconcileError::Binding)?;
            let (device, epoch, certificate, root): (Vec<u8>, i64, Vec<u8>, Vec<u8>) = self
                .connection
                .lock()
                .map_err(|_| ReconcileError::Poisoned)?
                .query_row(
                    "SELECT peer,roster_epoch,certificate_hash,root FROM candidates WHERE id=?1 AND state='pending'",
                    [id],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
                )?;
            if device.as_slice() != peer.device_id
                || u64::try_from(epoch).ok() != Some(peer.roster_epoch)
                || certificate.as_slice() != peer.certificate_hash
                || root.as_slice() != handle.root
            {
                return Err(ReconcileError::Binding);
            }
            authorization
                .revalidate()
                .map_err(|_| ReconcileError::Binding)?;
            self.commit_candidate_inner(id, Some(peer))
        })
    }

    #[cfg(test)]
    pub fn test_head_root(&self, device_id: [u8; 32]) -> Result<Option<[u8; 32]>, ReconcileError> {
        let root: Option<Vec<u8>> = self
            .connection
            .lock()
            .map_err(|_| ReconcileError::Poisoned)?
            .query_row(
                "SELECT root FROM heads WHERE peer=?1",
                [device_id.as_slice()],
                |row| row.get(0),
            )
            .optional()?;
        root.map(|bytes| bytes.try_into().map_err(|_| ReconcileError::Corrupt))
            .transpose()
    }

    #[cfg(test)]
    pub fn commit_candidate_unchecked(&self, id: i64) -> Result<(), ReconcileError> {
        let _lease = self.acquire_project_lease()?;
        self.ensure_project_available()?;
        self.commit_candidate_inner(id, None)
    }

    fn commit_candidate_inner(
        &self,
        id: i64,
        expected_peer: Option<&TransportPeerSnapshot>,
    ) -> Result<(), ReconcileError> {
        let mut c = self
            .connection
            .lock()
            .map_err(|_| ReconcileError::Poisoned)?;
        let tx = c.transaction()?;
        let (peer, epoch, certificate, root, frontier, candidate_relation, state): (
            Vec<u8>,
            i64,
            Vec<u8>,
            Vec<u8>,
            Vec<u8>,
            String,
            String,
        ) = tx.query_row(
            "SELECT peer,roster_epoch,certificate_hash,root,frontier,relation,state FROM candidates WHERE id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)),
        )?;
        if let Some(expected) = expected_peer {
            if peer.as_slice() != expected.device_id
                || u64::try_from(epoch).ok() != Some(expected.roster_epoch)
                || certificate.as_slice() != expected.certificate_hash
            {
                return Err(ReconcileError::Binding);
            }
        }
        if state != "pending" || candidate_relation == "concurrent" {
            return Err(ReconcileError::Stale);
        }
        if let Some((existing_root, existing_frontier)) = tx
            .query_row(
                "SELECT root,frontier FROM heads WHERE peer=?1",
                [peer.as_slice()],
                |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, Vec<u8>>(1)?)),
            )
            .optional()?
        {
            match relation(
                &decode_frontier(&existing_frontier)?,
                &decode_frontier(&frontier)?,
            ) {
                FrontierRelation::RemoteDominates => {}
                FrontierRelation::Equal if existing_root == root => {
                    let changed = tx.execute(
                        "UPDATE candidates SET state='committed' WHERE id=?1 AND state='pending'",
                        [id],
                    )?;
                    require_one(changed)?;
                    validate_schema(&tx, APP_ID, HEAD_SCHEMA)?;
                    tx.commit()?;
                    return Ok(());
                }
                FrontierRelation::Equal => {
                    require_one(tx.execute(
                        "INSERT INTO quarantine(peer,root,reason)VALUES(?1,?2,'candidate equal frontier different root')",
                        params![peer, root],
                    )?)?;
                    require_one(tx.execute(
                        "UPDATE candidates SET state='conflict' WHERE id=?1 AND state='pending'",
                        [id],
                    )?)?;
                    validate_schema(&tx, APP_ID, HEAD_SCHEMA)?;
                    tx.commit()?;
                    return Err(ReconcileError::Conflict);
                }
                FrontierRelation::LocalDominates | FrontierRelation::Concurrent => {
                    return Err(ReconcileError::Stale)
                }
            }
        }
        require_one(tx.execute("INSERT INTO heads(peer,root,frontier)VALUES(?1,?2,?3)ON CONFLICT(peer)DO UPDATE SET root=excluded.root,frontier=excluded.frontier",params![peer,root,frontier])?)?;
        require_one(tx.execute(
            "UPDATE candidates SET state='committed' WHERE id=?1 AND state='pending'",
            [id],
        )?)?;
        validate_schema(&tx, APP_ID, HEAD_SCHEMA)?;
        tx.commit()?;
        Ok(())
    }
}

pub struct ReconcileOrchestrator<'a> {
    heads: &'a ReconcileStore,
    trust: &'a TrustStore,
}
impl<'a> ReconcileOrchestrator<'a> {
    pub fn new(heads: &'a ReconcileStore, trust: &'a TrustStore) -> Self {
        Self { heads, trust }
    }

    pub fn authenticated_peer(
        &self,
        certificate_der: &[u8],
    ) -> Result<TransportPeerSnapshot, ReconcileError> {
        self.trust
            .authorize_transport_certificate(certificate_der)
            .map_err(|_| ReconcileError::Binding)
    }

    pub fn select_mode(
        &self,
        remote: &BTreeMap<[u8; 32], u64>,
        retained: &BTreeMap<[u8; 32], u64>,
    ) -> SyncMode {
        ReconcileStore::mode(remote, retained)
    }

    pub fn offer_authenticated(
        &self,
        peer: &TransportPeerSnapshot,
        root: [u8; 32],
        frontier: &BTreeMap<[u8; 32], u64>,
        full: bool,
    ) -> Result<HeadDecision, ReconcileError> {
        let lease = self.heads.acquire_project_lease()?;
        self.offer_authenticated_with_lease(&lease, peer, root, frontier, full)
    }

    fn offer_authenticated_with_lease(
        &self,
        lease: &ProjectLease,
        peer: &TransportPeerSnapshot,
        root: [u8; 32],
        frontier: &BTreeMap<[u8; 32], u64>,
        full: bool,
    ) -> Result<HeadDecision, ReconcileError> {
        self.heads.ensure_project_available()?;
        self.trust
            .revalidate_transport_peer(peer)
            .map_err(|_| ReconcileError::Binding)?;
        self.heads
            .offer_with_lease(lease, peer, root, frontier, full)
    }

    pub fn commit_persisted(
        &self,
        id: i64,
        peer: &TransportPeerSnapshot,
        index: &ManifestIndex,
        handle: &CompletedManifestHandle,
    ) -> Result<(), ReconcileError> {
        let lease = self.heads.acquire_project_lease()?;
        self.heads.ensure_project_available()?;
        self.heads
            .commit_candidate_with_lease(&lease, id, peer, self.trust, index, handle)
    }

    pub fn sync_incremental(
        &self,
        source: &super::OplogStore,
        destination: &super::OplogStore,
        committed_at_ms: i64,
    ) -> Result<u64, ReconcileError> {
        Ok(self
            .sync_incremental_report(source, destination, committed_at_ms)?
            .applied_records)
    }

    pub fn sync_incremental_report(
        &self,
        source: &super::OplogStore,
        destination: &super::OplogStore,
        committed_at_ms: i64,
    ) -> Result<IncrementalSyncReport, ReconcileError> {
        let lease = self.heads.acquire_project_lease()?;
        self.sync_incremental_report_with_lease(&lease, source, destination, committed_at_ms)
    }

    fn sync_incremental_report_with_lease(
        &self,
        _lease: &ProjectLease,
        source: &super::OplogStore,
        destination: &super::OplogStore,
        committed_at_ms: i64,
    ) -> Result<IncrementalSyncReport, ReconcileError> {
        self.heads.ensure_project_available()?;
        let frontier = source.frontier().map_err(|_| ReconcileError::Oplog)?;
        let destination_frontier = destination.frontier().map_err(|_| ReconcileError::Oplog)?;
        let retained = source.retained_floor().map_err(|_| ReconcileError::Oplog)?;
        if self.select_mode(&destination_frontier, &retained) == SyncMode::FullResync {
            return Err(ReconcileError::FullResyncRequired);
        }
        let ranges = destination
            .missing_tail(&frontier)
            .map_err(|_| ReconcileError::Oplog)?;
        let mut report = IncrementalSyncReport {
            applied_records: 0,
            batches: 0,
            max_batch_records: 0,
            max_batch_bytes: 0,
            record_cap: MAX_OPLOG_BATCH_RECORDS,
            byte_cap: MAX_OPLOG_BATCH_BYTES,
        };
        for (device, range) in ranges {
            let mut start = range.start;
            while start < range.end_exclusive {
                let mut records = source
                    .export_range(
                        device,
                        super::SequenceRange {
                            start,
                            end_exclusive: range.end_exclusive,
                        },
                        MAX_OPLOG_BATCH_RECORDS,
                        MAX_OPLOG_BATCH_BYTES,
                    )
                    .map_err(|_| ReconcileError::Oplog)?;
                if records.is_empty() {
                    return Err(ReconcileError::Oplog);
                }
                let mut batch_bytes = framed_batch_bytes(&records)?;
                while batch_bytes > MAX_OPLOG_BATCH_BYTES && records.len() > 1 {
                    records.pop();
                    batch_bytes = framed_batch_bytes(&records)?;
                }
                if batch_bytes > MAX_OPLOG_BATCH_BYTES {
                    return Err(ReconcileError::Limit);
                }
                start = records
                    .last()
                    .and_then(|record| record.sequence.checked_add(1))
                    .ok_or(ReconcileError::Oplog)?;
                match destination
                    .ingest_batch(&records, committed_at_ms)
                    .map_err(|_| ReconcileError::Oplog)?
                {
                    super::BatchIngestOutcome::Ack(ack) => {
                        report.applied_records += ack.applied_count;
                        report.batches += 1;
                        report.max_batch_records = report.max_batch_records.max(records.len());
                        report.max_batch_bytes = report.max_batch_bytes.max(batch_bytes);
                    }
                    super::BatchIngestOutcome::Collision { .. } => {
                        return Err(ReconcileError::Oplog)
                    }
                }
            }
        }
        Ok(report)
    }

    #[cfg(test)]
    pub fn test_sync_incremental_report_after_gate(
        &self,
        source: &super::OplogStore,
        destination: &super::OplogStore,
        committed_at_ms: i64,
        after_gate: impl FnOnce(),
    ) -> Result<IncrementalSyncReport, ReconcileError> {
        let lease = self.heads.acquire_project_lease()?;
        self.heads.ensure_project_available()?;
        after_gate();
        self.sync_incremental_report_with_lease(&lease, source, destination, committed_at_ms)
    }

    pub fn commit_full_baseline(
        &self,
        peer: &TransportPeerSnapshot,
        frontier: &BTreeMap<[u8; 32], u64>,
        index: &ManifestIndex,
        handle: &CompletedManifestHandle,
    ) -> Result<HeadDecision, ReconcileError> {
        let lease = self.heads.acquire_project_lease()?;
        self.heads.ensure_project_available()?;
        index.with_verified_handle(handle, || Ok(()))?;
        self.trust
            .revalidate_transport_peer(peer)
            .map_err(|_| ReconcileError::Binding)?;
        let decision = self
            .heads
            .offer_with_lease(&lease, peer, handle.root, frontier, true)?;
        match decision {
            HeadDecision::Initial(id) | HeadDecision::Candidate(id) => {
                self.heads
                    .commit_candidate_with_lease(&lease, id, peer, self.trust, index, handle)?;
            }
            _ => {}
        }
        Ok(decision)
    }

    pub fn install_full_baseline(
        &self,
        peer: &TransportPeerSnapshot,
        operation_id: [u8; 16],
        frontier: &BTreeMap<[u8; 32], u64>,
        index: &ManifestIndex,
        handle: &CompletedManifestHandle,
        destination: &super::OplogStore,
    ) -> Result<HeadDecision, ReconcileError> {
        self.install_full_baseline_with_hook(
            peer,
            operation_id,
            frontier,
            index,
            handle,
            destination,
            &NoBaselineCrash,
        )
    }

    pub fn install_full_baseline_with_hook(
        &self,
        peer: &TransportPeerSnapshot,
        operation_id: [u8; 16],
        frontier: &BTreeMap<[u8; 32], u64>,
        index: &ManifestIndex,
        handle: &CompletedManifestHandle,
        destination: &super::OplogStore,
        crash: &dyn BaselineCrashHook,
    ) -> Result<HeadDecision, ReconcileError> {
        let lease = self.heads.acquire_project_lease()?;
        self.install_full_baseline_with_lease(
            &lease,
            peer,
            operation_id,
            frontier,
            index,
            handle,
            destination,
            crash,
        )
    }

    fn install_full_baseline_with_lease(
        &self,
        lease: &ProjectLease,
        peer: &TransportPeerSnapshot,
        operation_id: [u8; 16],
        frontier: &BTreeMap<[u8; 32], u64>,
        index: &ManifestIndex,
        handle: &CompletedManifestHandle,
        destination: &super::OplogStore,
        crash: &dyn BaselineCrashHook,
    ) -> Result<HeadDecision, ReconcileError> {
        self.heads.ensure_project_available()?;
        index.with_verified_handle(handle, || Ok(()))?;
        self.trust
            .revalidate_transport_peer(peer)
            .map_err(|_| ReconcileError::Binding)?;
        let frontier_hash = baseline_frontier_hash(frontier);
        let control_hash = baseline_control_hash(
            peer.project_id,
            peer.roster_epoch,
            operation_id,
            handle.root,
            frontier_hash,
        );
        let decision =
            self.offer_authenticated_with_lease(lease, peer, handle.root, frontier, true)?;
        let candidate_id = match decision {
            HeadDecision::Initial(id) | HeadDecision::Candidate(id) => id,
            _ => return Ok(decision),
        };
        let prepared_at_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| ReconcileError::Corrupt)?
            .as_millis()
            .try_into()
            .map_err(|_| ReconcileError::Corrupt)?;
        self.heads.prepare_baseline_install(
            operation_id,
            peer,
            handle,
            frontier,
            frontier_hash,
            control_hash,
            candidate_id,
            prepared_at_ms,
        )?;
        crash.after_phase(BaselineInstallPhase::Prepared)?;
        self.reconcile_baseline_install_with_lease(
            lease,
            operation_id,
            index.path(),
            destination,
            crash,
        )?;
        Ok(decision)
    }

    pub fn reconcile_baseline_install(
        &self,
        operation_id: [u8; 16],
        manifest_path: &Path,
        destination: &super::OplogStore,
    ) -> Result<BaselineInstallPhase, ReconcileError> {
        self.reconcile_baseline_install_with_hook(
            operation_id,
            manifest_path,
            destination,
            &NoBaselineCrash,
        )
    }

    pub fn reconcile_baseline_install_with_hook(
        &self,
        operation_id: [u8; 16],
        manifest_path: &Path,
        destination: &super::OplogStore,
        crash: &dyn BaselineCrashHook,
    ) -> Result<BaselineInstallPhase, ReconcileError> {
        let lease = self.heads.acquire_project_lease()?;
        self.reconcile_baseline_install_with_lease(
            &lease,
            operation_id,
            manifest_path,
            destination,
            crash,
        )
    }

    fn reconcile_baseline_install_with_lease(
        &self,
        _lease: &ProjectLease,
        operation_id: [u8; 16],
        manifest_path: &Path,
        destination: &super::OplogStore,
        crash: &dyn BaselineCrashHook,
    ) -> Result<BaselineInstallPhase, ReconcileError> {
        let _resume = self
            .heads
            .baseline_resume
            .lock()
            .map_err(|_| ReconcileError::Poisoned)?;
        loop {
            let record = self.heads.baseline_install(operation_id)?;
            if record.phase == BaselineInstallPhase::Completed {
                return Ok(record.phase);
            }
            if record.phase == BaselineInstallPhase::Blocked {
                return Err(ReconcileError::Blocked);
            }
            let result = self.reconcile_baseline_phase(_lease, &record, manifest_path, destination);
            if let Err(error) = result {
                if record.phase == BaselineInstallPhase::OplogInstalled {
                    let _ = self.heads.block_baseline_install(operation_id);
                }
                return Err(error);
            }
            let next = result?;
            crash.after_phase(next)?;
            if next == BaselineInstallPhase::Completed {
                return Ok(next);
            }
        }
    }

    fn reconcile_baseline_phase(
        &self,
        lease: &ProjectLease,
        record: &BaselineInstallRecord,
        manifest_path: &Path,
        destination: &super::OplogStore,
    ) -> Result<BaselineInstallPhase, ReconcileError> {
        if destination.project_id() != record.project {
            return Err(ReconcileError::Binding);
        }
        let (_index, handle) = ManifestIndex::open_completed(
            manifest_path,
            record.manifest_scan_id,
            record.root,
            record.manifest_entry_count,
        )?;
        if handle.scan_id != record.manifest_scan_id
            || handle.root != record.root
            || handle.entry_count != record.manifest_entry_count
        {
            return Err(ReconcileError::Binding);
        }
        let candidate_state = self.heads.candidate_matches(record)?;
        let token = super::oplog::BaselineInstallToken {
            project_id: record.project,
            roster_epoch: record.peer.roster_epoch,
            operation_id: record.operation_id,
            manifest_root: record.root,
            frontier_hash: record.frontier_hash,
            control_hash: record.control_hash,
        };
        match record.phase {
            BaselineInstallPhase::Prepared => {
                self.heads.prepared_candidate_is_current(record)?;
                match baseline_evidence(destination, &token, &record.frontier)? {
                    BaselineEvidence::Exact => {}
                    BaselineEvidence::SameOperationMismatch => return Err(ReconcileError::Binding),
                    BaselineEvidence::Absent | BaselineEvidence::OtherOperation => {
                        destination
                            .install_baseline(&token, &record.frontier)
                            .map_err(|_| ReconcileError::Oplog)?;
                    }
                }
                if baseline_evidence(destination, &token, &record.frontier)?
                    != BaselineEvidence::Exact
                {
                    return Err(ReconcileError::Oplog);
                }
                self.heads.advance_baseline_install(
                    record.operation_id,
                    BaselineInstallPhase::Prepared.as_str(),
                    BaselineInstallPhase::OplogInstalled.as_str(),
                )?;
                Ok(BaselineInstallPhase::OplogInstalled)
            }
            BaselineInstallPhase::OplogInstalled => {
                if baseline_evidence(destination, &token, &record.frontier)?
                    != BaselineEvidence::Exact
                {
                    return Err(ReconcileError::Binding);
                }
                if candidate_state == "pending" {
                    self.heads.commit_candidate_with_lease(
                        lease,
                        record.candidate_id,
                        &record.peer,
                        self.trust,
                        &_index,
                        &handle,
                    )?;
                } else {
                    let authorization = self
                        .trust
                        .acquire_transport_authorization_lease(&record.peer)
                        .map_err(|_| ReconcileError::Binding)?;
                    authorization
                        .revalidate()
                        .map_err(|_| ReconcileError::Binding)?;
                    if !self.heads.head_matches(record)? {
                        return Err(ReconcileError::Binding);
                    }
                }
                self.heads.advance_baseline_install(
                    record.operation_id,
                    BaselineInstallPhase::OplogInstalled.as_str(),
                    BaselineInstallPhase::HeadCommitted.as_str(),
                )?;
                Ok(BaselineInstallPhase::HeadCommitted)
            }
            BaselineInstallPhase::HeadCommitted => {
                if candidate_state != "committed" || !self.heads.head_matches(record)? {
                    return Err(ReconcileError::Binding);
                }
                self.heads.advance_baseline_install(
                    record.operation_id,
                    BaselineInstallPhase::HeadCommitted.as_str(),
                    BaselineInstallPhase::Completed.as_str(),
                )?;
                Ok(BaselineInstallPhase::Completed)
            }
            BaselineInstallPhase::Completed => Ok(BaselineInstallPhase::Completed),
            BaselineInstallPhase::Blocked => Err(ReconcileError::Blocked),
        }
    }

    pub fn no_change(
        &self,
        peer: &TransportPeerSnapshot,
        root: [u8; 32],
        frontier: &BTreeMap<[u8; 32], u64>,
        trace: &super::WireTrace,
    ) -> Result<bool, ReconcileError> {
        let _lease = self.heads.acquire_project_lease()?;
        self.heads.ensure_project_available()?;
        self.trust
            .revalidate_transport_peer(peer)
            .map_err(|_| ReconcileError::Binding)?;
        let unchanged = self.heads.is_current(peer, root, frontier)?;
        if unchanged {
            trace.summary(0, 0, 0).map_err(|_| ReconcileError::Trace)?;
        }
        Ok(unchanged)
    }
}

fn baseline_frontier_hash(frontier: &BTreeMap<[u8; 32], u64>) -> [u8; 32] {
    let mut hasher = blake3::Hasher::new();
    hasher.update(b"term-mesh baseline frontier v1\0");
    for (device, sequence) in frontier {
        hasher.update(device);
        hasher.update(&sequence.to_be_bytes());
    }
    *hasher.finalize().as_bytes()
}

fn framed_batch_bytes(records: &[sync_protocol::CanonicalRecord]) -> Result<usize, ReconcileError> {
    let mut total = 2usize;
    for record in records {
        let bytes = record
            .canonical_bytes()
            .map_err(|_| ReconcileError::Oplog)?;
        total = total
            .checked_add(4)
            .and_then(|value| value.checked_add(bytes.len()))
            .ok_or(ReconcileError::Limit)?;
    }
    Ok(total)
}

fn baseline_control_hash(
    project: ProjectId,
    roster_epoch: u64,
    operation_id: [u8; 16],
    root: [u8; 32],
    frontier_hash: [u8; 32],
) -> [u8; 32] {
    let mut control = blake3::Hasher::new();
    control.update(b"term-mesh baseline control v1\0");
    control.update(project.as_bytes());
    control.update(&roster_epoch.to_be_bytes());
    control.update(&operation_id);
    control.update(&root);
    control.update(&frontier_hash);
    *control.finalize().as_bytes()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BaselineEvidence {
    Absent,
    Exact,
    SameOperationMismatch,
    OtherOperation,
}

fn baseline_evidence(
    destination: &super::OplogStore,
    token: &super::oplog::BaselineInstallToken,
    frontier: &BTreeMap<[u8; 32], u64>,
) -> Result<BaselineEvidence, ReconcileError> {
    let connection = Connection::open_with_flags(
        destination.path(),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    type Stored = (i64, Vec<u8>, Vec<u8>, Vec<u8>, Vec<u8>);
    let stored: Option<Stored> = connection
        .query_row(
            "SELECT roster_epoch,operation_id,manifest_root,frontier_hash,control_hash FROM oplog_baselines WHERE project_id=?1",
            [token.project_id.as_bytes().as_slice()],
            |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?,row.get(4)?)),
        )
        .optional()?;
    let Some((epoch, operation, root, frontier_hash, control_hash)) = stored else {
        return Ok(BaselineEvidence::Absent);
    };
    if operation.as_slice() != token.operation_id {
        return Ok(BaselineEvidence::OtherOperation);
    }
    if u64::try_from(epoch).ok() != Some(token.roster_epoch)
        || root.as_slice() != token.manifest_root
        || frontier_hash.as_slice() != token.frontier_hash
        || control_hash.as_slice() != token.control_hash
    {
        return Ok(BaselineEvidence::SameOperationMismatch);
    }
    let mut statement = connection.prepare(
        "SELECT device_id,contiguous_seq FROM oplog_frontiers WHERE project_id=?1 ORDER BY device_id",
    )?;
    let rows = statement.query_map([token.project_id.as_bytes().as_slice()], |row| {
        Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, i64>(1)?))
    })?;
    let mut stored_frontier = BTreeMap::new();
    for row in rows {
        let (device, sequence) = row?;
        let device = device.try_into().map_err(|_| ReconcileError::Corrupt)?;
        let sequence = u64::try_from(sequence).map_err(|_| ReconcileError::Corrupt)?;
        if stored_frontier.insert(device, sequence).is_some() {
            return Err(ReconcileError::Corrupt);
        }
    }
    if &stored_frontier != frontier {
        return Ok(BaselineEvidence::SameOperationMismatch);
    }
    Ok(BaselineEvidence::Exact)
}

fn load_baseline_install(
    connection: &Connection,
    operation_id: [u8; 16],
) -> Result<BaselineInstallRecord, ReconcileError> {
    type Row = (
        Vec<u8>,
        i64,
        Vec<u8>,
        Vec<u8>,
        Vec<u8>,
        Vec<u8>,
        Vec<u8>,
        Vec<u8>,
        i64,
        i64,
        String,
        Vec<u8>,
    );
    let row: Row = connection.query_row(
        "SELECT b.project,b.roster_epoch,b.peer,b.root,b.frontier,b.frontier_hash,b.control_hash,b.manifest_scan_id,b.manifest_entry_count,b.candidate_id,b.phase,c.certificate_hash FROM baseline_installs b JOIN candidates c ON c.id=b.candidate_id WHERE b.operation_id=?1",
        [operation_id],
        |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?,row.get(4)?,row.get(5)?,row.get(6)?,row.get(7)?,row.get(8)?,row.get(9)?,row.get(10)?,row.get(11)?)),
    )?;
    let project = ProjectId::from_bytes(row.0.try_into().map_err(|_| ReconcileError::Corrupt)?);
    let roster_epoch = u64::try_from(row.1).map_err(|_| ReconcileError::Corrupt)?;
    let peer_id = row.2.try_into().map_err(|_| ReconcileError::Corrupt)?;
    let root = row.3.try_into().map_err(|_| ReconcileError::Corrupt)?;
    let frontier = decode_frontier(&row.4)?;
    if encode_frontier(&frontier)? != row.4 {
        return Err(ReconcileError::Corrupt);
    }
    let frontier_hash = row.5.try_into().map_err(|_| ReconcileError::Corrupt)?;
    let control_hash = row.6.try_into().map_err(|_| ReconcileError::Corrupt)?;
    let manifest_scan_id = row.7.try_into().map_err(|_| ReconcileError::Corrupt)?;
    let manifest_entry_count = u64::try_from(row.8).map_err(|_| ReconcileError::Corrupt)?;
    let certificate_hash = row.11.try_into().map_err(|_| ReconcileError::Corrupt)?;
    let peer = TransportPeerSnapshot {
        project_id: project,
        device_id: peer_id,
        roster_epoch,
        certificate_hash,
    };
    if baseline_frontier_hash(&frontier) != frontier_hash
        || baseline_control_hash(project, roster_epoch, operation_id, root, frontier_hash)
            != control_hash
    {
        return Err(ReconcileError::Binding);
    }
    Ok(BaselineInstallRecord {
        operation_id,
        project,
        peer,
        root,
        frontier,
        frontier_hash,
        control_hash,
        manifest_scan_id,
        manifest_entry_count,
        candidate_id: row.9,
        phase: BaselineInstallPhase::parse(&row.10)?,
    })
}

fn require_one(changed: usize) -> Result<(), ReconcileError> {
    if changed == 1 {
        Ok(())
    } else {
        Err(ReconcileError::AffectedRows(changed))
    }
}
fn insert_candidate(
    c: &Connection,
    peer: &TransportPeerSnapshot,
    root: [u8; 32],
    frontier: &[u8],
    relation: &str,
) -> Result<i64, rusqlite::Error> {
    c.execute(
        "INSERT INTO candidates(peer,roster_epoch,certificate_hash,root,frontier,relation,state)VALUES(?1,?2,?3,?4,?5,?6,'pending')",
        params![peer.device_id, peer.roster_epoch, peer.certificate_hash, root, frontier, relation],
    )?;
    Ok(c.last_insert_rowid())
}
pub fn relation(
    local: &BTreeMap<[u8; 32], u64>,
    remote: &BTreeMap<[u8; 32], u64>,
) -> FrontierRelation {
    let mut l = false;
    let mut r = false;
    for d in local.keys().chain(remote.keys()) {
        let a = local.get(d).copied().unwrap_or(0);
        let b = remote.get(d).copied().unwrap_or(0);
        l |= a > b;
        r |= b > a;
    }
    match (l, r) {
        (false, false) => FrontierRelation::Equal,
        (false, true) => FrontierRelation::RemoteDominates,
        (true, false) => FrontierRelation::LocalDominates,
        (true, true) => FrontierRelation::Concurrent,
    }
}
fn encode_frontier(v: &BTreeMap<[u8; 32], u64>) -> Result<Vec<u8>, ReconcileError> {
    if v.len() > MAX_FRONTIERS {
        return Err(ReconcileError::Limit);
    }
    let mut o = Vec::with_capacity(2 + v.len() * 40);
    o.extend_from_slice(&(v.len() as u16).to_be_bytes());
    for (d, s) in v {
        o.extend_from_slice(d);
        o.extend_from_slice(&s.to_be_bytes());
    }
    Ok(o)
}
fn decode_frontier(i: &[u8]) -> Result<BTreeMap<[u8; 32], u64>, ReconcileError> {
    if i.len() < 2 {
        return Err(ReconcileError::Corrupt);
    }
    let n = u16::from_be_bytes([i[0], i[1]]) as usize;
    if n > MAX_FRONTIERS || i.len() != 2 + n * 40 {
        return Err(ReconcileError::Corrupt);
    }
    let mut o = BTreeMap::new();
    for x in 0..n {
        let p = 2 + x * 40;
        let mut d = [0; 32];
        d.copy_from_slice(&i[p..p + 32]);
        if o.insert(d, u64::from_be_bytes(i[p + 32..p + 40].try_into().unwrap()))
            .is_some()
        {
            return Err(ReconcileError::Corrupt);
        }
    }
    Ok(o)
}

pub struct ManifestIndex {
    path: PathBuf,
    scan_id: [u8; 16],
    inner: Mutex<ManifestIndexInner>,
}
struct ManifestIndexInner {
    connection: Connection,
    state: ManifestIndexState,
    active: bool,
}
struct ManifestIndexState {
    ordinal: u64,
    shard_index: u64,
    shard_first: u64,
    shard_count: u64,
    shard_wire_bytes: usize,
    shard_hasher: blake3::Hasher,
    manifest: ManifestBuilder,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompletedManifestHandle {
    scan_id: [u8; 16],
    root: [u8; 32],
    entry_count: u64,
}
impl CompletedManifestHandle {
    pub fn root(&self) -> [u8; 32] {
        self.root
    }
    pub fn entry_count(&self) -> u64 {
        self.entry_count
    }
}
impl ManifestIndex {
    pub fn open_completed(
        path: &Path,
        scan_id: [u8; 16],
        expected_root: [u8; 32],
        expected_count: u64,
    ) -> Result<(Self, CompletedManifestHandle), ReconcileError> {
        preflight_existing(path, MANIFEST_APP_ID, MANIFEST_SCHEMA)?;
        let c = Connection::open(path)?;
        validate_schema(&c, MANIFEST_APP_ID, MANIFEST_SCHEMA)?;
        let matching:i64=c.query_row("SELECT count(*) FROM scans WHERE scan_id=?1 AND root=?2 AND entry_count=?3 AND complete=1",params![scan_id,expected_root,expected_count],|r|r.get(0))?;
        if matching != 1 {
            return Err(ReconcileError::MissingManifestRoot);
        }
        let handle = CompletedManifestHandle {
            scan_id,
            root: expected_root,
            entry_count: expected_count,
        };
        let index = Self {
            path: path.to_path_buf(),
            scan_id,
            inner: Mutex::new(ManifestIndexInner {
                connection: c,
                active: false,
                state: ManifestIndexState {
                    ordinal: expected_count,
                    shard_index: 0,
                    shard_first: 0,
                    shard_count: 0,
                    shard_wire_bytes: 2,
                    shard_hasher: manifest_shard_hasher(),
                    manifest: ManifestBuilder::new(),
                },
            }),
        };
        index.with_verified_handle(&handle, || Ok(()))?;
        Ok((index, handle))
    }
    pub fn begin(path: &Path, scan_id: [u8; 16]) -> Result<Self, ReconcileError> {
        preflight_existing(path, MANIFEST_APP_ID, MANIFEST_SCHEMA)?;
        let c = Connection::open(path)?;
        c.pragma_update(None, "journal_mode", "WAL")?;
        c.pragma_update(None, "synchronous", "FULL")?;
        let version: i64 = c.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version == 0 {
            create_schema(&c, MANIFEST_SCHEMA)?;
            c.pragma_update(None, "application_id", MANIFEST_APP_ID)?;
            c.pragma_update(None, "user_version", VERSION)?;
        }
        validate_schema(&c, MANIFEST_APP_ID, MANIFEST_SCHEMA)?;
        c.execute(
            "INSERT OR REPLACE INTO scans VALUES(?1,NULL,0,0)",
            [scan_id.as_slice()],
        )?;
        c.execute("DELETE FROM entries WHERE scan_id=?1", [scan_id])?;
        c.execute("DELETE FROM shards WHERE scan_id=?1", [scan_id])?;
        c.execute_batch("BEGIN IMMEDIATE")?;
        Ok(Self {
            path: path.to_path_buf(),
            scan_id,
            inner: Mutex::new(ManifestIndexInner {
                connection: c,
                active: true,
                state: ManifestIndexState {
                    ordinal: 0,
                    shard_index: 0,
                    shard_first: 0,
                    shard_count: 0,
                    shard_wire_bytes: 2,
                    shard_hasher: manifest_shard_hasher(),
                    manifest: ManifestBuilder::new(),
                },
            }),
        })
    }
    pub fn finish(&self, expected: Manifest) -> Result<CompletedManifestHandle, ReconcileError> {
        let mut inner = self.inner.lock().map_err(|_| ReconcileError::Poisoned)?;
        if !inner.active {
            return Err(ReconcileError::Stale);
        }
        let computed =
            std::mem::replace(&mut inner.state.manifest, ManifestBuilder::new()).finish();
        if computed != expected || computed.entry_count != inner.state.ordinal {
            inner.connection.execute_batch("ROLLBACK")?;
            inner.active = false;
            return Err(ReconcileError::ManifestMismatch);
        }
        let ManifestIndexInner {
            connection, state, ..
        } = &mut *inner;
        close_manifest_shard(connection, self.scan_id, state)?;
        let changed = connection.execute(
            "UPDATE scans SET root=?1,entry_count=?2,complete=1 WHERE scan_id=?3",
            params![computed.root.0, computed.entry_count, self.scan_id],
        )?;
        require_one(changed)?;
        validate_schema(connection, MANIFEST_APP_ID, MANIFEST_SCHEMA)?;
        connection.execute_batch("COMMIT")?;
        inner.active = false;
        Ok(CompletedManifestHandle {
            scan_id: self.scan_id,
            root: computed.root.0,
            entry_count: computed.entry_count,
        })
    }

    pub fn shard_roots(&self) -> Result<Vec<[u8; 32]>, ReconcileError> {
        let inner = self.inner.lock().map_err(|_| ReconcileError::Poisoned)?;
        let c = &inner.connection;
        let mut statement =
            c.prepare("SELECT root FROM shards WHERE scan_id=?1 ORDER BY shard_index")?;
        let rows = statement.query_map([self.scan_id], |row| row.get::<_, Vec<u8>>(0))?;
        rows.map(|row| {
            let bytes = row?;
            bytes.try_into().map_err(|_| ReconcileError::Corrupt)
        })
        .collect()
    }

    fn path(&self) -> &Path {
        &self.path
    }

    pub fn page(&self, shard_index: u64) -> Result<Vec<Vec<u8>>, ReconcileError> {
        let inner = self.inner.lock().map_err(|_| ReconcileError::Poisoned)?;
        let c = &inner.connection;
        let bounds: Option<(i64, i64)> = c
            .query_row(
                "SELECT first_ordinal,last_ordinal FROM shards WHERE scan_id=?1 AND shard_index=?2",
                params![self.scan_id, shard_index as i64],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((first, last)) = bounds else {
            return Ok(Vec::new());
        };
        let mut statement = c.prepare("SELECT entry FROM entries WHERE scan_id=?1 AND ordinal>=?2 AND ordinal<?3 ORDER BY ordinal")?;
        let mut rows = statement.query(params![self.scan_id, first, last])?;
        let mut page = Vec::new();
        let mut bytes = 2_usize;
        while let Some(row) = rows.next()? {
            let entry: Vec<u8> = row.get(0)?;
            bytes = bytes
                .checked_add(4 + entry.len())
                .ok_or(ReconcileError::Limit)?;
            if bytes > MAX_MANIFEST_PAGE_BYTES {
                return Err(ReconcileError::Limit);
            }
            page.push(entry);
        }
        Ok(page)
    }

    fn with_verified_handle<T>(
        &self,
        handle: &CompletedManifestHandle,
        operation: impl FnOnce() -> Result<T, ReconcileError>,
    ) -> Result<T, ReconcileError> {
        // Global mutation lock order: project flock -> manifest index -> trust authorization ->
        // head store/oplog. Callers that mutate cross-database state must already hold the flock.
        // BEGIN IMMEDIATE keeps external SQLite writers out until the commit closure finishes.
        let mut inner = self.inner.lock().map_err(|_| ReconcileError::Poisoned)?;
        let transaction = inner
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        verify_manifest_snapshot(&transaction, handle)?;
        let output = operation()?;
        transaction.commit()?;
        Ok(output)
    }

    #[cfg(test)]
    pub fn test_verify_handle(
        &self,
        handle: &CompletedManifestHandle,
    ) -> Result<(), ReconcileError> {
        self.with_verified_handle(handle, || Ok(()))
    }

    #[cfg(test)]
    pub fn test_with_verified_handle<T>(
        &self,
        handle: &CompletedManifestHandle,
        operation: impl FnOnce() -> Result<T, ReconcileError>,
    ) -> Result<T, ReconcileError> {
        self.with_verified_handle(handle, operation)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ManifestShardSpec {
    index: u64,
    first: u64,
    last: u64,
    count: u64,
    wire_bytes: usize,
    root: [u8; 32],
}

fn finish_expected_shard(
    specs: &mut Vec<ManifestShardSpec>,
    first: u64,
    last: u64,
    count: u64,
    wire_bytes: usize,
    hasher: &blake3::Hasher,
) {
    if count != 0 {
        specs.push(ManifestShardSpec {
            index: specs.len() as u64,
            first,
            last,
            count,
            wire_bytes,
            root: *hasher.finalize().as_bytes(),
        });
    }
}

fn verify_manifest_snapshot(
    connection: &Connection,
    handle: &CompletedManifestHandle,
) -> Result<(), ReconcileError> {
    let matching: i64 = connection.query_row(
        "SELECT count(*) FROM scans WHERE scan_id=?1 AND root=?2 AND entry_count=?3 AND complete=1",
        params![handle.scan_id, handle.root, handle.entry_count],
        |row| row.get(0),
    )?;
    if matching != 1 {
        return Err(ReconcileError::MissingManifestRoot);
    }
    let mut builder = ManifestBuilder::new();
    let mut ordinal = 0u64;
    let mut shard_first = 0u64;
    let mut shard_count = 0u64;
    let mut shard_wire_bytes = 2usize;
    let mut shard_hasher = manifest_shard_hasher();
    let mut expected_shards = Vec::new();
    let mut statement = connection
        .prepare("SELECT ordinal,path,entry FROM entries WHERE scan_id=?1 ORDER BY ordinal")?;
    let mut rows = statement.query([handle.scan_id])?;
    while let Some(row) = rows.next()? {
        let stored_ordinal: u64 = row.get(0)?;
        let stored_path: String = row.get(1)?;
        let bytes: Vec<u8> = row.get(2)?;
        if stored_ordinal != ordinal {
            return Err(ReconcileError::Corrupt);
        }
        let entry = decode_index_entry(&bytes).map_err(|_| ReconcileError::Corrupt)?;
        if encode_manifest_entry(&entry).map_err(|_| ReconcileError::Corrupt)? != bytes
            || stored_path != entry.relative_path
        {
            return Err(ReconcileError::Corrupt);
        }
        builder.push(&entry).map_err(|_| ReconcileError::Corrupt)?;
        let item_bytes = shard_item_wire_bytes(&bytes)?;
        if shard_must_close(shard_count, shard_wire_bytes, item_bytes)? {
            finish_expected_shard(
                &mut expected_shards,
                shard_first,
                ordinal,
                shard_count,
                shard_wire_bytes,
                &shard_hasher,
            );
            shard_first = ordinal;
            shard_count = 0;
            shard_wire_bytes = 2;
            shard_hasher = manifest_shard_hasher();
        }
        add_shard_item(
            &mut shard_hasher,
            &mut shard_count,
            &mut shard_wire_bytes,
            &bytes,
        )?;
        ordinal += 1;
    }
    drop(rows);
    drop(statement);
    finish_expected_shard(
        &mut expected_shards,
        shard_first,
        ordinal,
        shard_count,
        shard_wire_bytes,
        &shard_hasher,
    );
    let manifest = builder.finish();
    if ordinal != handle.entry_count || manifest.root.0 != handle.root {
        return Err(ReconcileError::ManifestMismatch);
    }

    let mut statement = connection.prepare(
        "SELECT shard_index,root,first_ordinal,last_ordinal FROM shards WHERE scan_id=?1 ORDER BY shard_index",
    )?;
    let rows = statement.query_map([handle.scan_id], |row| {
        Ok((
            row.get::<_, u64>(0)?,
            row.get::<_, Vec<u8>>(1)?,
            row.get::<_, u64>(2)?,
            row.get::<_, u64>(3)?,
        ))
    })?;
    let persisted = rows.collect::<Result<Vec<_>, _>>()?;
    let mut actual_shards = Vec::with_capacity(persisted.len());
    for (index, root, first, last) in persisted {
        let mut count = 0u64;
        let mut wire_bytes = 2usize;
        let mut query = connection.prepare(
            "SELECT entry FROM entries WHERE scan_id=?1 AND ordinal>=?2 AND ordinal<?3 ORDER BY ordinal",
        )?;
        let mut entries = query.query(params![handle.scan_id, first, last])?;
        while let Some(row) = entries.next()? {
            let bytes: Vec<u8> = row.get(0)?;
            wire_bytes = wire_bytes
                .checked_add(shard_item_wire_bytes(&bytes)?)
                .ok_or(ReconcileError::Limit)?;
            count += 1;
        }
        actual_shards.push(ManifestShardSpec {
            index,
            first,
            last,
            count,
            wire_bytes,
            root: root.try_into().map_err(|_| ReconcileError::Corrupt)?,
        });
    }
    if actual_shards != expected_shards {
        return Err(ReconcileError::Corrupt);
    }
    Ok(())
}
impl ScanObserver for ManifestIndex {
    fn checkpoint(&self, _: ScanCheckpoint, _: &str) {}
    fn entry(&self, e: &ManifestEntry) -> Result<(), ScanError> {
        let bytes = encode_manifest_entry(e)?;
        let item_wire_bytes = 4_usize
            .checked_add(bytes.len())
            .ok_or_else(|| ScanError::Io(std::io::Error::other("manifest entry too large")))?;
        if 2_usize
            .checked_add(item_wire_bytes)
            .is_none_or(|n| n > MAX_MANIFEST_PAGE_BYTES)
        {
            return Err(ScanError::Io(std::io::Error::other(
                "manifest entry exceeds wire page",
            )));
        }
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| ScanError::Io(std::io::Error::other("manifest index poisoned")))?;
        if !inner.active {
            return Err(ScanError::Io(std::io::Error::other("manifest scan closed")));
        }
        inner
            .state
            .manifest
            .push(e)
            .map_err(|error| ScanError::Io(std::io::Error::other(format!("{error:?}"))))?;
        let ManifestIndexInner {
            connection: c,
            state,
            ..
        } = &mut *inner;
        if shard_must_close(state.shard_count, state.shard_wire_bytes, item_wire_bytes)
            .map_err(|error| ScanError::Io(std::io::Error::other(error)))?
        {
            close_manifest_shard(c, self.scan_id, state)
                .map_err(|error| ScanError::Io(std::io::Error::other(error)))?;
        }
        c.execute(
            "INSERT INTO entries VALUES(?1,?2,?3,?4)",
            params![self.scan_id, state.ordinal as i64, e.relative_path, bytes],
        )
        .map_err(|error| ScanError::Io(std::io::Error::other(error)))?;
        add_shard_item(
            &mut state.shard_hasher,
            &mut state.shard_count,
            &mut state.shard_wire_bytes,
            &bytes,
        )
        .map_err(|error| ScanError::Io(std::io::Error::other(error)))?;
        state.ordinal += 1;
        if state.ordinal % MANIFEST_SHARD_ENTRIES == 0 {
            c.execute_batch("COMMIT;BEGIN IMMEDIATE")
                .map_err(|error| ScanError::Io(std::io::Error::other(error)))?;
        }
        Ok(())
    }
}

fn manifest_shard_hasher() -> blake3::Hasher {
    let mut hasher = blake3::Hasher::new();
    hasher.update(b"term-mesh manifest shard v1\0");
    hasher
}

fn shard_item_wire_bytes(entry: &[u8]) -> Result<usize, ReconcileError> {
    4usize.checked_add(entry.len()).ok_or(ReconcileError::Limit)
}

fn shard_must_close(
    count: u64,
    wire_bytes: usize,
    item_bytes: usize,
) -> Result<bool, ReconcileError> {
    let next = wire_bytes
        .checked_add(item_bytes)
        .ok_or(ReconcileError::Limit)?;
    Ok(count == MANIFEST_SHARD_ENTRIES || next > MAX_MANIFEST_PAGE_BYTES)
}

fn add_shard_item(
    hasher: &mut blake3::Hasher,
    count: &mut u64,
    wire_bytes: &mut usize,
    entry: &[u8],
) -> Result<(), ReconcileError> {
    let item_bytes = shard_item_wire_bytes(entry)?;
    let next = wire_bytes
        .checked_add(item_bytes)
        .ok_or(ReconcileError::Limit)?;
    if next > MAX_MANIFEST_PAGE_BYTES || *count >= MANIFEST_SHARD_ENTRIES {
        return Err(ReconcileError::Limit);
    }
    hasher.update(&(entry.len() as u32).to_be_bytes());
    hasher.update(entry);
    *wire_bytes = next;
    *count += 1;
    Ok(())
}

fn close_manifest_shard(
    connection: &Connection,
    scan_id: [u8; 16],
    state: &mut ManifestIndexState,
) -> Result<(), ReconcileError> {
    if state.shard_count == 0 {
        return Ok(());
    }
    let root = *state.shard_hasher.finalize().as_bytes();
    require_one(connection.execute(
        "INSERT INTO shards VALUES(?1,?2,?3,?4,?5)",
        params![
            scan_id,
            state.shard_index as i64,
            root,
            state.shard_first as i64,
            state.ordinal as i64
        ],
    )?)?;
    state.shard_index += 1;
    state.shard_first = state.ordinal;
    state.shard_count = 0;
    state.shard_wire_bytes = 2;
    state.shard_hasher = manifest_shard_hasher();
    Ok(())
}
impl ScanObserver for Arc<ManifestIndex> {
    fn checkpoint(&self, checkpoint: ScanCheckpoint, path: &str) {
        (**self).checkpoint(checkpoint, path);
    }
    fn entry(&self, entry: &ManifestEntry) -> Result<(), ScanError> {
        (**self).entry(entry)
    }
}

fn encode_manifest_entry(entry: &ManifestEntry) -> Result<Vec<u8>, ScanError> {
    let path = entry.relative_path.as_bytes();
    let target = entry.symlink_target.as_deref().unwrap_or("").as_bytes();
    let path_len = u32::try_from(path.len())
        .map_err(|_| ScanError::Io(std::io::Error::other("manifest path too long")))?;
    let target_len = u32::try_from(target.len())
        .map_err(|_| ScanError::Io(std::io::Error::other("manifest target too long")))?;
    let kind = match entry.kind {
        EntryKind::File => 1,
        EntryKind::Directory => 2,
        EntryKind::Symlink => 3,
    };
    let mut out = Vec::with_capacity(54 + path.len() + target.len());
    out.push(kind);
    out.push(u8::from(entry.executable));
    out.extend_from_slice(&entry.length.to_be_bytes());
    out.extend_from_slice(&entry.content_hash);
    out.extend_from_slice(&path_len.to_be_bytes());
    out.extend_from_slice(path);
    out.extend_from_slice(&target_len.to_be_bytes());
    out.extend_from_slice(target);
    Ok(out)
}

fn create_schema(connection: &Connection, schema: &[(&str, &str)]) -> Result<(), ReconcileError> {
    for (_, sql) in schema {
        connection.execute_batch(sql)?;
    }
    Ok(())
}

fn validate_schema(
    connection: &Connection,
    application_id: i64,
    expected: &[(&str, &str)],
) -> Result<(), ReconcileError> {
    let actual_application: i64 =
        connection.pragma_query_value(None, "application_id", |row| row.get(0))?;
    let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    let quick: String = connection.pragma_query_value(None, "quick_check", |row| row.get(0))?;
    if actual_application != application_id || version != VERSION || quick != "ok" {
        return Err(ReconcileError::Schema);
    }
    let mut statement = connection.prepare(
        "SELECT type,name,sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
        ))
    })?;
    let actual = rows.collect::<Result<Vec<_>, _>>()?;
    if actual.len() != expected.len() {
        return Err(ReconcileError::Schema);
    }
    for (kind, name, sql) in actual {
        let Some((_, expected_sql)) = expected
            .iter()
            .find(|(expected_name, _)| *expected_name == name)
        else {
            return Err(ReconcileError::Schema);
        };
        let expected_kind = if expected_sql.starts_with("CREATE UNIQUE INDEX") {
            "index"
        } else {
            "table"
        };
        if kind != expected_kind || sql.as_deref() != Some(*expected_sql) {
            return Err(ReconcileError::Schema);
        }
    }
    Ok(())
}

fn preflight_head_existing(path: &Path) -> Result<(), ReconcileError> {
    if !path.exists() || path.metadata()?.len() == 0 {
        return Ok(());
    }
    let mut connection = Connection::open(path)?;
    if validate_schema(&connection, APP_ID, HEAD_SCHEMA).is_ok() {
        return Ok(());
    }
    if validate_schema(&connection, APP_ID, HEAD_TABLES).is_ok() {
        let duplicate: bool = connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM baseline_installs WHERE phase!='completed' GROUP BY project HAVING count(*)>1)",
            [],
            |row| row.get(0),
        )?;
        if duplicate {
            return Err(ReconcileError::Schema);
        }
        let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute_batch(HEAD_SCHEMA[4].1)?;
        validate_schema(&tx, APP_ID, HEAD_SCHEMA)?;
        tx.commit()?;
        return Ok(());
    }
    drop(connection);
    quarantine_database_set(path)?;
    Err(ReconcileError::Schema)
}

fn preflight_existing(
    path: &Path,
    application_id: i64,
    schema: &[(&str, &str)],
) -> Result<(), ReconcileError> {
    if !path.exists() || path.metadata()?.len() == 0 {
        return Ok(());
    }
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let valid = Connection::open_with_flags(path, flags)
        .map_err(ReconcileError::Sql)
        .and_then(|connection| validate_schema(&connection, application_id, schema));
    if valid.is_ok() {
        return Ok(());
    }
    quarantine_database_set(path)?;
    Err(ReconcileError::Schema)
}

fn quarantine_database_set(path: &Path) -> Result<(), ReconcileError> {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| ReconcileError::Corrupt)?
        .as_nanos();
    for suffix in ["", "-wal", "-shm"] {
        let source = if suffix.is_empty() {
            path.to_path_buf()
        } else {
            std::path::PathBuf::from(format!("{}{suffix}", path.display()))
        };
        if source.exists() {
            let destination =
                std::path::PathBuf::from(format!("{}.quarantine-{stamp}{suffix}", path.display()));
            std::fs::rename(source, destination)?;
        }
    }
    if let Some(parent) = path.parent() {
        File::open(parent)?.sync_all()?;
    }
    Ok(())
}

#[derive(Debug)]
pub enum ReconcileError {
    Io(std::io::Error),
    Sql(rusqlite::Error),
    Schema,
    Binding,
    Limit,
    Corrupt,
    Stale,
    Conflict,
    AffectedRows(usize),
    MissingManifestRoot,
    ManifestMismatch,
    Trace,
    Oplog,
    FullResyncRequired,
    ProjectBusy,
    BaselineInProgress,
    BaselineBlocked,
    Blocked,
    Poisoned,
}
impl From<std::io::Error> for ReconcileError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}
impl From<rusqlite::Error> for ReconcileError {
    fn from(v: rusqlite::Error) -> Self {
        Self::Sql(v)
    }
}
impl From<ProjectLockError> for ReconcileError {
    fn from(value: ProjectLockError) -> Self {
        match value {
            ProjectLockError::Io(error) => Self::Io(error),
            ProjectLockError::Invalid => Self::Corrupt,
            ProjectLockError::Busy => Self::ProjectBusy,
        }
    }
}
impl std::fmt::Display for ReconcileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for ReconcileError {}
