use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use rusqlite::{params, Connection, OpenFlags, OptionalExtension, Transaction};
use sync_protocol::{CanonicalRecord, RecordKind};

use super::{ObjectId, ProjectId};

const APPLICATION_ID: i64 = 0x544d_4f4c; // "TMOL"
const SCHEMA_VERSION: i64 = 1;
const ACK_VERSION: u16 = 1;
const ACK_TYPE_FRONTIER: u8 = 1;
const ACK_DOMAIN: &[u8] = b"term-mesh oplog signed ack\0";
const MAX_ACK_FRONTIERS: usize = 4096;
const TOMBSTONE_PAYLOAD_VERSION: u16 = 1;
const TOMBSTONE_PAYLOAD_TYPE_DELETE: u8 = 1;
const TOMBSTONE_PAYLOAD_BYTES: usize = 4 + 2 + 1 + 32 + 8;
pub const TOMBSTONE_RETENTION_MS: i64 = 90 * 24 * 60 * 60 * 1000;

const CREATE_ENTRIES: &str = "CREATE TABLE oplog_entries (
    project_id       BLOB NOT NULL CHECK(length(project_id) = 32),
    device_id        BLOB NOT NULL CHECK(length(device_id) = 32),
    device_seq       INTEGER NOT NULL CHECK(device_seq > 0),
    canonical_hash   BLOB NOT NULL CHECK(length(canonical_hash) = 32),
    canonical_record BLOB NOT NULL,
    committed_at_ms  INTEGER NOT NULL,
    PRIMARY KEY(project_id, device_id, device_seq)
) STRICT";
const CREATE_FRONTIERS: &str = "CREATE TABLE oplog_frontiers (
    project_id       BLOB NOT NULL CHECK(length(project_id) = 32),
    device_id        BLOB NOT NULL CHECK(length(device_id) = 32),
    contiguous_seq   INTEGER NOT NULL CHECK(contiguous_seq >= 0),
    PRIMARY KEY(project_id, device_id)
) STRICT";
const CREATE_QUARANTINE: &str = "CREATE TABLE oplog_quarantine (
    quarantine_id    INTEGER PRIMARY KEY,
    project_id       BLOB NOT NULL CHECK(length(project_id) = 32),
    device_id        BLOB NOT NULL CHECK(length(device_id) = 32),
    device_seq       INTEGER NOT NULL CHECK(device_seq > 0),
    existing_hash    BLOB NOT NULL CHECK(length(existing_hash) = 32),
    incoming_hash    BLOB NOT NULL CHECK(length(incoming_hash) = 32),
    incoming_record  BLOB NOT NULL,
    reason           TEXT NOT NULL,
    quarantined_at_ms INTEGER NOT NULL
) STRICT";
const CREATE_TOMBSTONES: &str = "CREATE TABLE oplog_tombstones (
    project_id       BLOB NOT NULL CHECK(length(project_id) = 32),
    device_id        BLOB NOT NULL CHECK(length(device_id) = 32),
    device_seq       INTEGER NOT NULL CHECK(device_seq > 0),
    content_root     BLOB NOT NULL CHECK(length(content_root) = 32),
    retained_until_ms INTEGER NOT NULL,
    PRIMARY KEY(project_id, device_id, device_seq),
    FOREIGN KEY(project_id, device_id, device_seq)
      REFERENCES oplog_entries(project_id, device_id, device_seq) ON DELETE CASCADE
) STRICT";
const CREATE_ACKS: &str = "CREATE TABLE oplog_device_acks (
    project_id       BLOB NOT NULL CHECK(length(project_id) = 32),
    observer_device  BLOB NOT NULL CHECK(length(observer_device) = 32),
    target_device    BLOB NOT NULL CHECK(length(target_device) = 32),
    ack_sequence     INTEGER NOT NULL CHECK(ack_sequence >= 0),
    PRIMARY KEY(project_id, observer_device, target_device)
) STRICT";
const CREATE_GC_RUNS: &str = "CREATE TABLE oplog_gc_runs (
    run_id            BLOB PRIMARY KEY NOT NULL CHECK(length(run_id) = 16),
    project_id        BLOB NOT NULL CHECK(length(project_id) = 32),
    started_at_ms     INTEGER NOT NULL,
    state             TEXT NOT NULL CHECK(state IN ('running', 'completed'))
) STRICT";
const CREATE_GC_CANDIDATES: &str = "CREATE TABLE oplog_gc_candidates (
    run_id            BLOB NOT NULL CHECK(length(run_id) = 16),
    object_id         BLOB NOT NULL CHECK(length(object_id) = 32),
    state             TEXT NOT NULL CHECK(state IN ('pending', 'deleted', 'skipped')),
    PRIMARY KEY(run_id, object_id),
    FOREIGN KEY(run_id) REFERENCES oplog_gc_runs(run_id) ON DELETE CASCADE
) STRICT";
const CREATE_BASELINES: &str = "CREATE TABLE oplog_baselines (
    project_id BLOB PRIMARY KEY CHECK(length(project_id)=32),
    roster_epoch INTEGER NOT NULL CHECK(roster_epoch>0),
    operation_id BLOB NOT NULL CHECK(length(operation_id)=16),
    manifest_root BLOB NOT NULL CHECK(length(manifest_root)=32),
    frontier_hash BLOB NOT NULL CHECK(length(frontier_hash)=32),
    control_hash BLOB NOT NULL CHECK(length(control_hash)=32),
    generation INTEGER NOT NULL CHECK(generation>0)
) STRICT";

pub(super) struct BaselineInstallToken {
    pub project_id: ProjectId,
    pub roster_epoch: u64,
    pub operation_id: [u8; 16],
    pub manifest_root: [u8; 32],
    pub frontier_hash: [u8; 32],
    pub control_hash: [u8; 32],
}

pub trait OplogTrustProvider: Send + Sync {
    fn verify(&self, record: &CanonicalRecord) -> Result<(), OplogTrustError>;

    fn verify_ack(&self, ack: &SignedDeviceAck) -> Result<(), OplogTrustError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeviceFrontier {
    pub device_id: [u8; 32],
    pub sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignedDeviceAck {
    pub project_id: ProjectId,
    pub observer_device: [u8; 32],
    pub roster_epoch: u64,
    pub frontiers: Vec<DeviceFrontier>,
    pub signature: [u8; 64],
}

impl SignedDeviceAck {
    pub fn signing_preimage(&self) -> Result<Vec<u8>, OplogError> {
        self.canonical_bytes_with_signature([0; 64])
    }

    pub fn canonical_bytes(&self) -> Result<Vec<u8>, OplogError> {
        self.canonical_bytes_with_signature(self.signature)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, OplogError> {
        let header_bytes = ACK_DOMAIN.len() + 2 + 1 + 32 + 32 + 8 + 4;
        let minimum = header_bytes + 64;
        if bytes.len() < minimum || &bytes[..ACK_DOMAIN.len()] != ACK_DOMAIN {
            return Err(OplogError::InvalidAck("bad domain or truncated record"));
        }
        let mut offset = ACK_DOMAIN.len();
        let version = u16::from_be_bytes([bytes[offset], bytes[offset + 1]]);
        offset += 2;
        if version != ACK_VERSION || bytes[offset] != ACK_TYPE_FRONTIER {
            return Err(OplogError::InvalidAck("unsupported version or type"));
        }
        offset += 1;
        let mut project_id = [0; 32];
        project_id.copy_from_slice(&bytes[offset..offset + 32]);
        offset += 32;
        let mut observer_device = [0; 32];
        observer_device.copy_from_slice(&bytes[offset..offset + 32]);
        offset += 32;
        let mut epoch = [0; 8];
        epoch.copy_from_slice(&bytes[offset..offset + 8]);
        offset += 8;
        let mut count = [0; 4];
        count.copy_from_slice(&bytes[offset..offset + 4]);
        offset += 4;
        let count = u32::from_be_bytes(count) as usize;
        if count == 0 || count > MAX_ACK_FRONTIERS {
            return Err(OplogError::InvalidAck("invalid frontier count"));
        }
        let expected = offset
            .checked_add(
                count
                    .checked_mul(40)
                    .ok_or(OplogError::InvalidAck("length overflow"))?,
            )
            .and_then(|length| length.checked_add(64))
            .ok_or(OplogError::InvalidAck("length overflow"))?;
        if bytes.len() != expected {
            return Err(OplogError::InvalidAck("non-canonical length"));
        }
        let mut frontiers = Vec::with_capacity(count);
        for _ in 0..count {
            let mut device_id = [0; 32];
            device_id.copy_from_slice(&bytes[offset..offset + 32]);
            offset += 32;
            let mut sequence = [0; 8];
            sequence.copy_from_slice(&bytes[offset..offset + 8]);
            offset += 8;
            frontiers.push(DeviceFrontier {
                device_id,
                sequence: u64::from_be_bytes(sequence),
            });
        }
        let mut signature = [0; 64];
        signature.copy_from_slice(&bytes[offset..]);
        let ack = Self {
            project_id: ProjectId::from_bytes(project_id),
            observer_device,
            roster_epoch: u64::from_be_bytes(epoch),
            frontiers,
            signature,
        };
        if ack.canonical_bytes()? != bytes {
            return Err(OplogError::InvalidAck("non-canonical record"));
        }
        Ok(ack)
    }

    fn canonical_bytes_with_signature(&self, signature: [u8; 64]) -> Result<Vec<u8>, OplogError> {
        if self.frontiers.is_empty() {
            return Err(OplogError::InvalidAck("empty frontier"));
        }
        if self.frontiers.len() > MAX_ACK_FRONTIERS {
            return Err(OplogError::InvalidAck("too many frontiers"));
        }
        let count = self.frontiers.len() as u32;
        let mut previous = None;
        let mut bytes = Vec::with_capacity(
            ACK_DOMAIN.len() + 2 + 1 + 32 + 32 + 8 + 4 + self.frontiers.len() * 40 + 64,
        );
        bytes.extend_from_slice(ACK_DOMAIN);
        bytes.extend_from_slice(&ACK_VERSION.to_be_bytes());
        bytes.push(ACK_TYPE_FRONTIER);
        bytes.extend_from_slice(self.project_id.as_bytes());
        bytes.extend_from_slice(&self.observer_device);
        bytes.extend_from_slice(&self.roster_epoch.to_be_bytes());
        bytes.extend_from_slice(&count.to_be_bytes());
        for frontier in &self.frontiers {
            if previous.is_some_and(|device| device >= frontier.device_id) {
                return Err(OplogError::InvalidAck(
                    "frontiers must be strictly device-sorted",
                ));
            }
            sequence_i64_allow_zero(frontier.sequence)?;
            bytes.extend_from_slice(&frontier.device_id);
            bytes.extend_from_slice(&frontier.sequence.to_be_bytes());
            previous = Some(frontier.device_id);
        }
        bytes.extend_from_slice(&signature);
        Ok(bytes)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TombstonePayload {
    pub content_root: ObjectId,
    pub deleted_at_ms: i64,
}

impl TombstonePayload {
    pub fn canonical_bytes(self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(TOMBSTONE_PAYLOAD_BYTES);
        bytes.extend_from_slice(b"TMDL");
        bytes.extend_from_slice(&TOMBSTONE_PAYLOAD_VERSION.to_be_bytes());
        bytes.push(TOMBSTONE_PAYLOAD_TYPE_DELETE);
        bytes.extend_from_slice(&self.content_root.0);
        bytes.extend_from_slice(&self.deleted_at_ms.to_be_bytes());
        bytes
    }

    fn decode(bytes: &[u8]) -> Result<Self, OplogError> {
        if bytes.len() != TOMBSTONE_PAYLOAD_BYTES
            || &bytes[..4] != b"TMDL"
            || u16::from_be_bytes([bytes[4], bytes[5]]) != TOMBSTONE_PAYLOAD_VERSION
            || bytes[6] != TOMBSTONE_PAYLOAD_TYPE_DELETE
        {
            return Err(OplogError::InvalidTombstonePayload);
        }
        let mut root = [0; 32];
        root.copy_from_slice(&bytes[7..39]);
        let mut timestamp = [0; 8];
        timestamp.copy_from_slice(&bytes[39..47]);
        Ok(Self {
            content_root: ObjectId(root),
            deleted_at_ms: i64::from_be_bytes(timestamp),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OplogTrustError {
    ForgedSignature,
    StaleEpoch,
    RevokedDevice,
    UnauthorizedDevice,
    Other(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DurableAck {
    project_id: ProjectId,
    device_id: [u8; 32],
    sequence: u64,
    kind: RecordKind,
    commit_hash: [u8; 32],
}

impl DurableAck {
    pub fn project_id(&self) -> ProjectId {
        self.project_id
    }

    pub fn device_id(&self) -> &[u8; 32] {
        &self.device_id
    }

    pub fn sequence(&self) -> u64 {
        self.sequence
    }

    pub fn kind(&self) -> RecordKind {
        self.kind
    }

    pub fn commit_hash(&self) -> &[u8; 32] {
        &self.commit_hash
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppendOutcome {
    Applied(DurableAck),
    Duplicate(DurableAck),
    Quarantined { quarantine_id: i64 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SequenceRange {
    pub start: u64,
    pub end_exclusive: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DurableBatchAck {
    pub batch_hash: [u8; 32],
    pub outcomes: Vec<AppendOutcome>,
    pub applied_count: u64,
    pub duplicate_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BatchIngestOutcome {
    Ack(DurableBatchAck),
    Collision { quarantine_id: i64 },
}

pub struct OplogStore {
    path: PathBuf,
    project_id: ProjectId,
    connection: Mutex<Connection>,
    trust: Arc<dyn OplogTrustProvider>,
}

impl OplogStore {
    pub(super) fn install_baseline(
        &self,
        token: &BaselineInstallToken,
        frontier: &BTreeMap<[u8; 32], u64>,
    ) -> Result<(), OplogError> {
        if token.project_id != self.project_id || hash_frontier(frontier) != token.frontier_hash {
            return Err(OplogError::InvalidAck("baseline binding"));
        }
        let mut connection = self.connection()?;
        let transaction = connection.transaction()?;
        let existing: Option<(i64, Vec<u8>, Vec<u8>, Vec<u8>, Vec<u8>)> = transaction
            .query_row(
                "SELECT roster_epoch,operation_id,manifest_root,frontier_hash,control_hash FROM oplog_baselines WHERE project_id=?1",
                [self.project_id.as_bytes().as_slice()],
                |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?,row.get(4)?)),
            )
            .optional()?;
        if let Some((epoch, operation, root, frontier_hash, control_hash)) = existing {
            if operation.as_slice() == token.operation_id {
                if u64::try_from(epoch).ok() != Some(token.roster_epoch)
                    || root.as_slice() != token.manifest_root
                    || frontier_hash.as_slice() != token.frontier_hash
                    || control_hash.as_slice() != token.control_hash
                {
                    return Err(OplogError::InvalidAck("baseline record swap"));
                }
                let mut statement = transaction.prepare(
                    "SELECT device_id,contiguous_seq FROM oplog_frontiers WHERE project_id=?1 ORDER BY device_id",
                )?;
                let rows = statement.query_map([self.project_id.as_bytes().as_slice()], |row| {
                    Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, i64>(1)?))
                })?;
                let mut persisted = BTreeMap::new();
                for row in rows {
                    let (device, sequence) = row?;
                    let device = device
                        .try_into()
                        .map_err(|_| OplogError::CorruptState("baseline frontier device"))?;
                    let sequence = u64::try_from(sequence)
                        .map_err(|_| OplogError::CorruptState("baseline frontier sequence"))?;
                    if persisted.insert(device, sequence).is_some() {
                        return Err(OplogError::CorruptState("duplicate baseline frontier"));
                    }
                }
                drop(statement);
                if &persisted != frontier {
                    return Err(OplogError::InvalidAck("baseline frontier swap"));
                }
                validate_transaction_schema(&transaction)?;
                transaction.commit()?;
                return Ok(());
            }
        }
        transaction.execute(
            "DELETE FROM oplog_frontiers WHERE project_id=?1",
            [self.project_id.as_bytes().as_slice()],
        )?;
        for (device, sequence) in frontier {
            transaction.execute("INSERT INTO oplog_frontiers(project_id,device_id,contiguous_seq)VALUES(?1,?2,?3)ON CONFLICT(project_id,device_id)DO UPDATE SET contiguous_seq=excluded.contiguous_seq",
                params![self.project_id.as_bytes(), device, sequence_i64_allow_zero(*sequence)?])?;
        }
        transaction.execute("INSERT INTO oplog_baselines VALUES(?1,?2,?3,?4,?5,?6,1)ON CONFLICT(project_id)DO UPDATE SET roster_epoch=excluded.roster_epoch,operation_id=excluded.operation_id,manifest_root=excluded.manifest_root,frontier_hash=excluded.frontier_hash,control_hash=excluded.control_hash,generation=oplog_baselines.generation+1",
            params![self.project_id.as_bytes(), token.roster_epoch as i64, token.operation_id, token.manifest_root, token.frontier_hash, token.control_hash])?;
        validate_transaction_schema(&transaction)?;
        transaction.commit()?;
        Ok(())
    }
    pub fn open(
        path: impl Into<PathBuf>,
        project_id: ProjectId,
        trust: Arc<dyn OplogTrustProvider>,
    ) -> Result<Self, OplogError> {
        let path = path.into();
        let connection = if path.exists() {
            preflight_existing(&path)?;
            let read_only = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY)
                .map_err(|error| OplogError::Quarantined {
                    path: path.clone(),
                    reason: error.to_string(),
                })?;
            validate_schema(&read_only).map_err(|reason| OplogError::Quarantined {
                path: path.clone(),
                reason,
            })?;
            drop(read_only);
            let connection = Connection::open(&path)?;
            configure(&connection)?;
            connection
        } else {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            let connection = Connection::open(&path)?;
            initialize(&connection)?;
            connection
        };
        Ok(Self {
            path,
            project_id,
            connection: Mutex::new(connection),
            trust,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn project_id(&self) -> ProjectId {
        self.project_id
    }

    pub fn ingest(
        &self,
        record: &CanonicalRecord,
        committed_at_ms: i64,
    ) -> Result<AppendOutcome, OplogError> {
        if record.project_id != *self.project_id.as_bytes() {
            return Err(OplogError::CrossProject);
        }
        if !matches!(record.kind, RecordKind::Oplog | RecordKind::Tombstone) {
            return Err(OplogError::WrongRecordKind);
        }
        if record.sequence == 0 {
            return Err(OplogError::InvalidSequence);
        }
        let sequence = sequence_i64(record.sequence)?;
        self.trust.verify(record).map_err(OplogError::Trust)?;
        let canonical = record.canonical_bytes().map_err(OplogError::Protocol)?;
        let incoming_hash = record.domain_hash().map_err(OplogError::Protocol)?;

        let mut connection = self.connection()?;
        let transaction = connection.transaction()?;
        let existing: Option<(Vec<u8>, Vec<u8>)> = transaction
            .query_row(
                "SELECT canonical_hash, canonical_record FROM oplog_entries
                 WHERE project_id = ?1 AND device_id = ?2 AND device_seq = ?3",
                params![
                    self.project_id.as_bytes().as_slice(),
                    record.device_id,
                    sequence
                ],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        if let Some((existing_hash, existing_record)) = existing {
            let existing_hash: [u8; 32] = existing_hash
                .try_into()
                .map_err(|_| OplogError::CorruptState("stored hash length"))?;
            if existing_hash == incoming_hash && existing_record == canonical {
                transaction.commit()?;
                return Ok(AppendOutcome::Duplicate(DurableAck {
                    project_id: self.project_id,
                    device_id: record.device_id,
                    sequence: record.sequence,
                    kind: record.kind,
                    commit_hash: incoming_hash,
                }));
            }
            let changed = transaction.execute(
                "INSERT INTO oplog_quarantine
                 (project_id, device_id, device_seq, existing_hash, incoming_hash,
                  incoming_record, reason, quarantined_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'op_id payload mismatch', ?7)",
                params![
                    self.project_id.as_bytes().as_slice(),
                    record.device_id,
                    sequence,
                    existing_hash,
                    incoming_hash,
                    canonical,
                    committed_at_ms,
                ],
            )?;
            require_one(changed, "quarantine insert")?;
            let quarantine_id = transaction.last_insert_rowid();
            validate_transaction_schema(&transaction)?;
            transaction.commit()?;
            return Ok(AppendOutcome::Quarantined { quarantine_id });
        }

        let tombstone = if record.kind == RecordKind::Tombstone {
            Some(TombstonePayload::decode(&record.payload)?)
        } else {
            None
        };

        let changed = transaction.execute(
            "INSERT INTO oplog_entries
             (project_id, device_id, device_seq, canonical_hash, canonical_record, committed_at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                self.project_id.as_bytes().as_slice(),
                record.device_id,
                sequence,
                incoming_hash,
                canonical,
                committed_at_ms,
            ],
        )?;
        require_one(changed, "oplog entry insert")?;
        if let Some(tombstone) = tombstone {
            if tombstone.deleted_at_ms != committed_at_ms {
                return Err(OplogError::TombstoneTimestampMismatch);
            }
            let retained_until = tombstone
                .deleted_at_ms
                .checked_add(TOMBSTONE_RETENTION_MS)
                .ok_or(OplogError::TimestampOverflow)?;
            let changed = transaction.execute(
                "INSERT INTO oplog_tombstones
                 (project_id, device_id, device_seq, content_root, retained_until_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    self.project_id.as_bytes().as_slice(),
                    record.device_id,
                    sequence,
                    tombstone.content_root.0,
                    retained_until,
                ],
            )?;
            require_one(changed, "tombstone materialization")?;
        }
        advance_frontier(&transaction, self.project_id, record.device_id)?;
        validate_transaction_schema(&transaction)?;
        transaction.commit()?;
        Ok(AppendOutcome::Applied(DurableAck {
            project_id: self.project_id,
            device_id: record.device_id,
            sequence: record.sequence,
            kind: record.kind,
            commit_hash: incoming_hash,
        }))
    }

    pub fn frontier(&self) -> Result<BTreeMap<[u8; 32], u64>, OplogError> {
        let connection = self.connection()?;
        let mut statement = connection.prepare(
            "SELECT device_id, contiguous_seq FROM oplog_frontiers
             WHERE project_id = ?1 ORDER BY device_id",
        )?;
        let rows = statement.query_map([self.project_id.as_bytes().as_slice()], |row| {
            let device: Vec<u8> = row.get(0)?;
            let sequence: i64 = row.get(1)?;
            Ok((device, sequence))
        })?;
        let mut frontier = BTreeMap::new();
        for row in rows {
            let (device, sequence) = row?;
            frontier.insert(
                device
                    .try_into()
                    .map_err(|_| OplogError::CorruptState("frontier device length"))?,
                u64::try_from(sequence)
                    .map_err(|_| OplogError::CorruptState("negative frontier"))?,
            );
        }
        Ok(frontier)
    }

    pub fn retained_floor(&self) -> Result<BTreeMap<[u8; 32], u64>, OplogError> {
        let connection = self.connection()?;
        let mut statement=connection.prepare("SELECT device_id,min(device_seq) FROM oplog_entries WHERE project_id=?1 GROUP BY device_id ORDER BY device_id")?;
        let rows = statement.query_map([self.project_id.as_bytes().as_slice()], |row| {
            Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, i64>(1)?))
        })?;
        let mut out = BTreeMap::new();
        for row in rows {
            let (d, s) = row?;
            out.insert(
                d.try_into()
                    .map_err(|_| OplogError::CorruptState("retained device length"))?,
                u64::try_from(s)
                    .map_err(|_| OplogError::CorruptState("negative retained floor"))?,
            );
        }
        Ok(out)
    }

    #[cfg(test)]
    pub fn test_prune_before(&self, device_id: [u8; 32], floor: u64) -> Result<(), OplogError> {
        self.connection()?.execute(
            "DELETE FROM oplog_entries WHERE project_id=?1 AND device_id=?2 AND device_seq<?3",
            params![
                self.project_id.as_bytes().as_slice(),
                device_id,
                sequence_i64(floor)?
            ],
        )?;
        Ok(())
    }

    pub fn missing_tail(
        &self,
        remote_frontier: &BTreeMap<[u8; 32], u64>,
    ) -> Result<Vec<([u8; 32], SequenceRange)>, OplogError> {
        let local = self.frontier()?;
        let mut ranges = Vec::new();
        for (device_id, remote_sequence) in remote_frontier {
            let local_sequence = local.get(device_id).copied().unwrap_or(0);
            if *remote_sequence > local_sequence {
                ranges.push((
                    *device_id,
                    SequenceRange {
                        start: local_sequence
                            .checked_add(1)
                            .ok_or(OplogError::SequenceOverflow)?,
                        end_exclusive: remote_sequence
                            .checked_add(1)
                            .ok_or(OplogError::SequenceOverflow)?,
                    },
                ));
            }
        }
        Ok(ranges)
    }

    pub fn export_range(
        &self,
        device_id: [u8; 32],
        range: SequenceRange,
        max_records: usize,
        max_bytes: usize,
    ) -> Result<Vec<CanonicalRecord>, OplogError> {
        if range.start >= range.end_exclusive
            || max_records == 0
            || max_records > 1024
            || max_bytes == 0
            || max_bytes > 8 * 1024 * 1024
        {
            return Err(OplogError::InvalidSequence);
        }
        let connection = self.connection()?;
        let mut statement=connection.prepare("SELECT canonical_record FROM oplog_entries WHERE project_id=?1 AND device_id=?2 AND device_seq>=?3 AND device_seq<?4 ORDER BY device_seq LIMIT ?5")?;
        let rows = statement.query_map(
            params![
                self.project_id.as_bytes().as_slice(),
                device_id,
                sequence_i64(range.start)?,
                sequence_i64(range.end_exclusive)?,
                max_records as i64
            ],
            |row| row.get::<_, Vec<u8>>(0),
        )?;
        let mut total = 0usize;
        let mut out = Vec::new();
        for row in rows {
            let bytes = row?;
            total = total
                .checked_add(bytes.len())
                .ok_or(OplogError::SequenceOverflow)?;
            if total > max_bytes {
                break;
            }
            out.push(CanonicalRecord::decode(&bytes).map_err(OplogError::Protocol)?);
        }
        Ok(out)
    }

    pub fn ingest_batch(
        &self,
        records: &[CanonicalRecord],
        committed_at_ms: i64,
    ) -> Result<BatchIngestOutcome, OplogError> {
        if records.is_empty() || records.len() > 1024 {
            return Err(OplogError::InvalidSequence);
        }
        let mut hasher = blake3::Hasher::new();
        hasher.update(b"term-mesh oplog batch v1\0");
        let mut outcomes = Vec::with_capacity(records.len());
        let mut total = 2_usize;
        for record in records {
            let bytes = record.canonical_bytes().map_err(OplogError::Protocol)?;
            total = total
                .checked_add(4)
                .and_then(|n| n.checked_add(bytes.len()))
                .ok_or(OplogError::SequenceOverflow)?;
            if total > 8 * 1024 * 1024 {
                return Err(OplogError::InvalidSequence);
            }
            hasher.update(&(bytes.len() as u32).to_be_bytes());
            hasher.update(&bytes);
        }
        for record in records {
            match self.ingest(record, committed_at_ms)? {
                AppendOutcome::Quarantined { quarantine_id } => {
                    return Ok(BatchIngestOutcome::Collision { quarantine_id });
                }
                outcome => outcomes.push(outcome),
            }
        }
        let applied_count = outcomes
            .iter()
            .filter(|outcome| matches!(outcome, AppendOutcome::Applied(_)))
            .count() as u64;
        let duplicate_count = outcomes
            .iter()
            .filter(|outcome| matches!(outcome, AppendOutcome::Duplicate(_)))
            .count() as u64;
        Ok(BatchIngestOutcome::Ack(DurableBatchAck {
            batch_hash: *hasher.finalize().as_bytes(),
            outcomes,
            applied_count,
            duplicate_count,
        }))
    }

    pub fn missing_ranges(&self, device_id: [u8; 32]) -> Result<Vec<SequenceRange>, OplogError> {
        let connection = self.connection()?;
        let frontier: i64 = connection
            .query_row(
                "SELECT contiguous_seq FROM oplog_frontiers
                 WHERE project_id = ?1 AND device_id = ?2",
                params![self.project_id.as_bytes().as_slice(), device_id],
                |row| row.get(0),
            )
            .optional()?
            .unwrap_or(0);
        let mut statement = connection.prepare(
            "SELECT device_seq FROM oplog_entries
             WHERE project_id = ?1 AND device_id = ?2 AND device_seq > ?3
             ORDER BY device_seq",
        )?;
        let present = statement
            .query_map(
                params![self.project_id.as_bytes().as_slice(), device_id, frontier],
                |row| row.get::<_, i64>(0),
            )?
            .collect::<Result<Vec<_>, _>>()?;
        if present.is_empty() {
            return Ok(Vec::new());
        }
        let mut ranges = Vec::new();
        let mut next = u64::try_from(frontier)
            .map_err(|_| OplogError::CorruptState("negative frontier"))?
            .checked_add(1)
            .ok_or(OplogError::SequenceOverflow)?;
        for sequence in present {
            let sequence = u64::try_from(sequence)
                .map_err(|_| OplogError::CorruptState("negative entry sequence"))?;
            if sequence > next {
                ranges.push(SequenceRange {
                    start: next,
                    end_exclusive: sequence,
                });
            }
            next = sequence
                .checked_add(1)
                .ok_or(OplogError::SequenceOverflow)?;
        }
        Ok(ranges)
    }

    pub fn ingest_device_ack(&self, ack: &SignedDeviceAck) -> Result<(), OplogError> {
        if ack.project_id != self.project_id {
            return Err(OplogError::CrossProject);
        }
        ack.canonical_bytes()?;
        self.trust.verify_ack(ack).map_err(OplogError::Trust)?;
        let mut connection = self.connection()?;
        let transaction = connection.transaction()?;
        for frontier in &ack.frontiers {
            let changed = transaction.execute(
                "INSERT INTO oplog_device_acks
                 (project_id, observer_device, target_device, ack_sequence)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(project_id, observer_device, target_device)
                 DO UPDATE SET ack_sequence = max(ack_sequence, excluded.ack_sequence)",
                params![
                    self.project_id.as_bytes().as_slice(),
                    ack.observer_device,
                    frontier.device_id,
                    sequence_i64_allow_zero(frontier.sequence)?,
                ],
            )?;
            require_one(changed, "device ack upsert")?;
        }
        validate_transaction_schema(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn quarantine_count(&self) -> Result<u64, OplogError> {
        let count: i64 = self.connection()?.query_row(
            "SELECT count(*) FROM oplog_quarantine WHERE project_id = ?1",
            [self.project_id.as_bytes().as_slice()],
            |row| row.get(0),
        )?;
        Ok(count as u64)
    }

    pub(super) fn protected_tombstone_roots(
        &self,
        now_ms: i64,
        active_devices: &[[u8; 32]],
    ) -> Result<Vec<ObjectId>, OplogError> {
        let connection = self.connection()?;
        let mut statement = connection.prepare(
            "SELECT device_id, device_seq, content_root, retained_until_ms
             FROM oplog_tombstones WHERE project_id = ?1",
        )?;
        let rows = statement
            .query_map([self.project_id.as_bytes().as_slice()], |row| {
                Ok((
                    row.get::<_, Vec<u8>>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, Vec<u8>>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let mut protected = Vec::new();
        for (origin, sequence, root, retained_until) in rows {
            let mut acknowledged = retained_until <= now_ms;
            for observer in active_devices {
                if !acknowledged {
                    break;
                }
                let ack = connection
                    .query_row(
                        "SELECT ack_sequence FROM oplog_device_acks
                         WHERE project_id = ?1 AND observer_device = ?2 AND target_device = ?3",
                        params![self.project_id.as_bytes().as_slice(), observer, &origin],
                        |row| row.get::<_, i64>(0),
                    )
                    .optional()?;
                acknowledged = ack.is_some_and(|ack| ack >= sequence);
            }
            if !acknowledged {
                protected
                    .push(ObjectId(root.try_into().map_err(|_| {
                        OplogError::CorruptState("tombstone root length")
                    })?));
            }
        }
        Ok(protected)
    }

    pub(super) fn begin_gc_run(
        &self,
        run_id: [u8; 16],
        candidates: &[ObjectId],
        started_at_ms: i64,
    ) -> Result<(), OplogError> {
        let mut connection = self.connection()?;
        let transaction = connection.transaction()?;
        let changed = transaction.execute(
            "INSERT INTO oplog_gc_runs (run_id, project_id, started_at_ms, state)
             VALUES (?1, ?2, ?3, 'running')",
            params![run_id, self.project_id.as_bytes().as_slice(), started_at_ms],
        )?;
        require_one(changed, "gc run insert")?;
        for candidate in candidates {
            let changed = transaction.execute(
                "INSERT INTO oplog_gc_candidates (run_id, object_id, state)
                 VALUES (?1, ?2, 'pending')",
                params![run_id, candidate.0],
            )?;
            require_one(changed, "gc candidate insert")?;
        }
        validate_transaction_schema(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    pub(super) fn running_gc_run(&self) -> Result<Option<[u8; 16]>, OplogError> {
        let run: Option<Vec<u8>> = self
            .connection()?
            .query_row(
                "SELECT run_id FROM oplog_gc_runs
                 WHERE project_id = ?1 AND state = 'running' ORDER BY started_at_ms LIMIT 1",
                [self.project_id.as_bytes().as_slice()],
                |row| row.get(0),
            )
            .optional()?;
        run.map(|run| {
            run.try_into()
                .map_err(|_| OplogError::CorruptState("gc run id length"))
        })
        .transpose()
    }

    pub(super) fn pending_gc_candidates(
        &self,
        run_id: [u8; 16],
    ) -> Result<Vec<ObjectId>, OplogError> {
        let connection = self.connection()?;
        let mut statement = connection.prepare(
            "SELECT object_id FROM oplog_gc_candidates
             WHERE run_id = ?1 AND state = 'pending' ORDER BY object_id",
        )?;
        let candidates = statement
            .query_map([run_id.as_slice()], |row| row.get::<_, Vec<u8>>(0))?
            .map(|row| {
                let row = row?;
                Ok(ObjectId(row.try_into().map_err(|_| {
                    OplogError::CorruptState("gc object id length")
                })?))
            })
            .collect::<Result<Vec<_>, OplogError>>()?;
        Ok(candidates)
    }

    pub(super) fn mark_gc_candidate(
        &self,
        run_id: [u8; 16],
        object_id: ObjectId,
        state: &'static str,
    ) -> Result<(), OplogError> {
        if !matches!(state, "deleted" | "skipped") {
            return Err(OplogError::CorruptState("invalid gc state"));
        }
        let changed = self.connection()?.execute(
            "UPDATE oplog_gc_candidates SET state = ?1
             WHERE run_id = ?2 AND object_id = ?3 AND state = 'pending'",
            params![state, run_id, object_id.0],
        )?;
        require_one(changed, "gc candidate update")?;
        Ok(())
    }

    pub(super) fn complete_gc_run(&self, run_id: [u8; 16]) -> Result<(), OplogError> {
        let changed = self.connection()?.execute(
            "UPDATE oplog_gc_runs SET state = 'completed'
             WHERE run_id = ?1 AND state = 'running'
               AND NOT EXISTS (
                 SELECT 1 FROM oplog_gc_candidates
                 WHERE run_id = ?1 AND state = 'pending'
               )",
            [run_id.as_slice()],
        )?;
        if changed != 1 {
            return Err(OplogError::GcRunIncomplete);
        }
        Ok(())
    }

    fn connection(&self) -> Result<MutexGuard<'_, Connection>, OplogError> {
        self.connection.lock().map_err(|_| OplogError::Poisoned)
    }
}

fn advance_frontier(
    transaction: &Transaction<'_>,
    project_id: ProjectId,
    device_id: [u8; 32],
) -> Result<(), OplogError> {
    let existing: Option<i64> = transaction
        .query_row(
            "SELECT contiguous_seq FROM oplog_frontiers
             WHERE project_id = ?1 AND device_id = ?2",
            params![project_id.as_bytes().as_slice(), device_id],
            |row| row.get(0),
        )
        .optional()?;
    let mut frontier = existing.unwrap_or(0);
    if existing.is_none() {
        let inserted = transaction.execute(
            "INSERT INTO oplog_frontiers
             (project_id, device_id, contiguous_seq) VALUES (?1, ?2, 0)",
            params![project_id.as_bytes().as_slice(), device_id],
        )?;
        require_one(inserted, "frontier insert")?;
    }
    loop {
        let Some(next) = frontier.checked_add(1) else {
            break;
        };
        let exists: bool = transaction.query_row(
            "SELECT EXISTS(
               SELECT 1 FROM oplog_entries
               WHERE project_id = ?1 AND device_id = ?2 AND device_seq = ?3
             )",
            params![project_id.as_bytes().as_slice(), device_id, next],
            |row| row.get(0),
        )?;
        if !exists {
            break;
        }
        frontier = next;
    }
    let changed = transaction.execute(
        "UPDATE oplog_frontiers SET contiguous_seq = ?1
         WHERE project_id = ?2 AND device_id = ?3",
        params![frontier, project_id.as_bytes().as_slice(), device_id],
    )?;
    require_one(changed, "frontier update")?;
    Ok(())
}

fn require_one(changed: usize, mutation: &'static str) -> Result<(), OplogError> {
    if changed == 1 {
        Ok(())
    } else {
        Err(OplogError::MutationNotApplied(mutation))
    }
}

fn hash_frontier(frontier: &BTreeMap<[u8; 32], u64>) -> [u8; 32] {
    let mut hasher = blake3::Hasher::new();
    hasher.update(b"term-mesh baseline frontier v1\0");
    for (device, sequence) in frontier {
        hasher.update(device);
        hasher.update(&sequence.to_be_bytes());
    }
    *hasher.finalize().as_bytes()
}

fn validate_transaction_schema(transaction: &Transaction<'_>) -> Result<(), OplogError> {
    validate_schema(transaction).map_err(OplogError::SchemaDrift)
}

fn initialize(connection: &Connection) -> Result<(), OplogError> {
    configure(connection)?;
    connection.execute_batch(&format!(
        "BEGIN IMMEDIATE;
         {CREATE_ENTRIES};
         {CREATE_FRONTIERS};
         {CREATE_QUARANTINE};
         {CREATE_TOMBSTONES};
         {CREATE_ACKS};
         {CREATE_GC_RUNS};
         {CREATE_GC_CANDIDATES};
         {CREATE_BASELINES};
         PRAGMA application_id = {APPLICATION_ID};
         PRAGMA user_version = {SCHEMA_VERSION};
         COMMIT;"
    ))?;
    Ok(())
}

fn configure(connection: &Connection) -> Result<(), OplogError> {
    connection.execute_batch(
        "PRAGMA journal_mode=WAL;
         PRAGMA foreign_keys=ON;
         PRAGMA synchronous=FULL;",
    )?;
    Ok(())
}

fn validate_schema(connection: &Connection) -> Result<(), String> {
    let integrity: String = connection
        .query_row("PRAGMA quick_check(1)", [], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    if integrity != "ok" {
        return Err(format!("quick_check failed: {integrity}"));
    }
    let application_id: i64 = connection
        .query_row("PRAGMA application_id", [], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    if application_id != APPLICATION_ID || version != SCHEMA_VERSION {
        return Err("oplog application/schema version mismatch".to_string());
    }
    let mut object_statement = connection
        .prepare(
            "SELECT type, name FROM sqlite_schema
             WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
        )
        .map_err(|error| error.to_string())?;
    let objects = object_statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|error| error.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| error.to_string())?;
    let expected_objects = vec![
        ("table".to_string(), "oplog_baselines".to_string()),
        ("table".to_string(), "oplog_device_acks".to_string()),
        ("table".to_string(), "oplog_entries".to_string()),
        ("table".to_string(), "oplog_frontiers".to_string()),
        ("table".to_string(), "oplog_gc_candidates".to_string()),
        ("table".to_string(), "oplog_gc_runs".to_string()),
        ("table".to_string(), "oplog_quarantine".to_string()),
        ("table".to_string(), "oplog_tombstones".to_string()),
    ];
    if objects != expected_objects {
        return Err("canonical schema object set drifted".to_string());
    }
    for (name, expected) in [
        ("oplog_entries", CREATE_ENTRIES),
        ("oplog_frontiers", CREATE_FRONTIERS),
        ("oplog_quarantine", CREATE_QUARANTINE),
        ("oplog_tombstones", CREATE_TOMBSTONES),
        ("oplog_device_acks", CREATE_ACKS),
        ("oplog_gc_runs", CREATE_GC_RUNS),
        ("oplog_gc_candidates", CREATE_GC_CANDIDATES),
        ("oplog_baselines", CREATE_BASELINES),
    ] {
        let sql: Option<String> = connection
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
                [name],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| error.to_string())?;
        if sql.as_deref().map(normalize_sql) != Some(normalize_sql(expected)) {
            return Err(format!("canonical schema drift for {name}"));
        }
    }
    Ok(())
}

fn normalize_sql(sql: &str) -> String {
    sql.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn preflight_existing(path: &Path) -> Result<(), OplogError> {
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() {
        return Err(OplogError::Quarantined {
            path: path.to_path_buf(),
            reason: "oplog path is not a regular file".to_string(),
        });
    }
    Ok(())
}

fn sequence_i64(sequence: u64) -> Result<i64, OplogError> {
    if sequence == 0 {
        return Err(OplogError::InvalidSequence);
    }
    sequence_i64_allow_zero(sequence)
}

fn sequence_i64_allow_zero(sequence: u64) -> Result<i64, OplogError> {
    i64::try_from(sequence).map_err(|_| OplogError::SequenceOverflow)
}

#[derive(Debug)]
pub enum OplogError {
    Io(std::io::Error),
    Database(rusqlite::Error),
    Protocol(sync_protocol::ProtocolError),
    Trust(OplogTrustError),
    Quarantined { path: PathBuf, reason: String },
    CrossProject,
    WrongRecordKind,
    InvalidSequence,
    InvalidAck(&'static str),
    InvalidTombstonePayload,
    TombstoneTimestampMismatch,
    MutationNotApplied(&'static str),
    SchemaDrift(String),
    SequenceOverflow,
    TimestampOverflow,
    GcRunIncomplete,
    CorruptState(&'static str),
    Poisoned,
}

impl fmt::Display for OplogError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for OplogError {}

impl From<std::io::Error> for OplogError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<rusqlite::Error> for OplogError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Database(error)
    }
}
