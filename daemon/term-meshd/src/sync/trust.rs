use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use rusqlite::{params, Connection, OptionalExtension};
use sync_protocol::{
    CanonicalRecord, ControlFields, DeviceGrantPayload, DeviceRevokePayload, RecordKind,
    RotationPayload, SignedRotationAck,
};

use super::{
    DeviceStatus, GcCoordinator, GcError, GcSnapshot, GcSnapshotLease, ObjectId, OplogTrustError,
    OplogTrustProvider, ProjectId, ProjectKeyProvider, SignedDeviceAck,
};

const APPLICATION_ID: i64 = 0x544d_4b53; // TMKS
const SCHEMA_VERSION: i64 = 2;
const CREATE_TRUST_DEVICES_V2: &str = "CREATE TABLE trust_devices_v2 (
    device_id BLOB PRIMARY KEY CHECK(length(device_id) = 32),
    signing_public BLOB NOT NULL CHECK(length(signing_public) = 32),
    agreement_public BLOB NOT NULL CHECK(length(agreement_public) = 32),
    tls_certificate_hash BLOB CHECK(tls_certificate_hash IS NULL OR length(tls_certificate_hash) = 32),
    status TEXT NOT NULL CHECK(status IN ('approved', 'revoked')),
    approved_epoch INTEGER NOT NULL CHECK(approved_epoch > 0),
    revoked_epoch INTEGER CHECK(revoked_epoch IS NULL OR revoked_epoch >= approved_epoch)
) STRICT;";
const SCHEMA: &str = "
CREATE TABLE trust_meta (
    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
    project_id BLOB NOT NULL CHECK(length(project_id) = 32),
    recovery_signing_public BLOB NOT NULL CHECK(length(recovery_signing_public) = 32),
    roster_epoch INTEGER NOT NULL CHECK(roster_epoch >= 0),
    current_key_id BLOB NOT NULL CHECK(length(current_key_id) = 16)
) STRICT;
CREATE TABLE trust_devices (
    device_id BLOB PRIMARY KEY CHECK(length(device_id) = 32),
    signing_public BLOB NOT NULL CHECK(length(signing_public) = 32),
    agreement_public BLOB NOT NULL CHECK(length(agreement_public) = 32),
    tls_certificate_hash BLOB CHECK(tls_certificate_hash IS NULL OR length(tls_certificate_hash) = 32),
    status TEXT NOT NULL CHECK(status IN ('approved', 'revoked')),
    approved_epoch INTEGER NOT NULL CHECK(approved_epoch > 0),
    revoked_epoch INTEGER CHECK(revoked_epoch IS NULL OR revoked_epoch >= approved_epoch)
) STRICT;
CREATE TABLE trust_nonces (
    nonce BLOB PRIMARY KEY CHECK(length(nonce) = 32),
    record_kind INTEGER NOT NULL,
    roster_epoch INTEGER NOT NULL CHECK(roster_epoch > 0)
) STRICT;
CREATE TABLE trust_dek_wraps (
    device_id BLOB NOT NULL CHECK(length(device_id) = 32),
    key_id BLOB NOT NULL CHECK(length(key_id) = 16),
    ephemeral_public BLOB NOT NULL CHECK(length(ephemeral_public) = 32),
    wrap_nonce BLOB NOT NULL CHECK(length(wrap_nonce) = 24),
    wrapped_dek BLOB NOT NULL CHECK(length(wrapped_dek) = 48),
    PRIMARY KEY(device_id, key_id)
) STRICT;
CREATE TABLE trust_rotation_acks (
    key_id BLOB NOT NULL CHECK(length(key_id) = 16),
    generation INTEGER NOT NULL CHECK(generation >= 0),
    roster_epoch INTEGER NOT NULL CHECK(roster_epoch > 0),
    device_id BLOB NOT NULL CHECK(length(device_id) = 32),
    control_hash BLOB NOT NULL CHECK(length(control_hash) = 32),
    nonce BLOB NOT NULL UNIQUE CHECK(length(nonce) = 32),
    PRIMARY KEY(key_id, generation, device_id)
) STRICT;
CREATE TABLE trust_rotation_journal (
    rotation_id BLOB PRIMARY KEY CHECK(length(rotation_id) = 32),
    from_key_id BLOB NOT NULL CHECK(length(from_key_id) = 16),
    to_key_id BLOB NOT NULL CHECK(length(to_key_id) = 16),
    phase TEXT NOT NULL CHECK(phase IN ('prepared','published','activated','ack_wait','retired','completed')),
    roster_epoch INTEGER NOT NULL CHECK(roster_epoch > 0),
    op_id BLOB CHECK(op_id IS NULL OR length(op_id) = 32),
    control_hash BLOB CHECK(control_hash IS NULL OR length(control_hash) = 32),
    persisted_key INTEGER NOT NULL CHECK(persisted_key = 1),
    approved_count INTEGER CHECK(approved_count IS NULL OR approved_count >= 0),
    acked_count INTEGER CHECK(acked_count IS NULL OR acked_count >= 0),
    ack_generation INTEGER CHECK(ack_generation IS NULL OR ack_generation >= 0),
    old_object_count INTEGER CHECK(old_object_count IS NULL OR old_object_count >= 0),
    inflight_count INTEGER CHECK(inflight_count IS NULL OR inflight_count >= 0),
    reachable_count INTEGER CHECK(reachable_count IS NULL OR reachable_count >= 0),
    old_key_deleted INTEGER NOT NULL DEFAULT 0 CHECK(old_key_deleted IN (0,1)),
    CHECK(phase = 'prepared' OR (op_id IS NOT NULL AND control_hash IS NOT NULL)),
    CHECK(phase IN ('prepared','published','activated') OR (approved_count > 0 AND acked_count = approved_count AND ack_generation IS NOT NULL)),
    CHECK(phase IN ('prepared','published','activated','ack_wait') OR (old_object_count = 0 AND inflight_count = 0 AND reachable_count = 0)),
    CHECK(phase != 'completed' OR old_key_deleted = 1)
) STRICT;
CREATE TABLE trust_quarantine (
    record_hash BLOB PRIMARY KEY CHECK(length(record_hash) = 32),
    reason TEXT NOT NULL,
    received_at_ms INTEGER NOT NULL
) STRICT;
CREATE INDEX trust_devices_status_idx ON trust_devices(status, device_id);
CREATE INDEX trust_devices_tls_cert_idx ON trust_devices(tls_certificate_hash, status);
CREATE INDEX trust_dek_wraps_key_idx ON trust_dek_wraps(key_id, device_id);
CREATE INDEX trust_rotation_acks_epoch_idx ON trust_rotation_acks(roster_epoch,key_id,generation,device_id);
CREATE INDEX trust_rotation_phase_idx ON trust_rotation_journal(phase, roster_epoch);
";

pub struct TrustStore {
    path: PathBuf,
    connection: Mutex<Connection>,
    project_id: ProjectId,
    mutation_gate: Arc<ExclusiveGate>,
    rotation_gate: Mutex<()>,
    keys: Option<Arc<dyn ProjectKeyProvider>>,
}

impl TrustStore {
    pub fn open(
        path: impl Into<PathBuf>,
        project_id: ProjectId,
        recovery_signing_public: [u8; 32],
    ) -> Result<Self, TrustError> {
        Self::open_inner(path.into(), project_id, recovery_signing_public, None)
    }

    pub fn open_with_keys(
        path: impl Into<PathBuf>,
        project_id: ProjectId,
        recovery_signing_public: [u8; 32],
        keys: Arc<dyn ProjectKeyProvider>,
    ) -> Result<Self, TrustError> {
        Self::open_inner(path.into(), project_id, recovery_signing_public, Some(keys))
    }

    /// Reopen an EXISTING per-project trust store. The recovery signing public
    /// key is bound in `trust_meta` when the store is created and validated from
    /// there, so a reopen needs only the path + project id — the sync-context
    /// provider (P0) reconstructs the store this way without holding the recovery
    /// key. Errors if the store was never provisioned.
    pub fn open_existing(
        path: impl Into<PathBuf>,
        project_id: ProjectId,
    ) -> Result<Self, TrustError> {
        let path = path.into();
        if !path.exists() {
            return Err(TrustError::Io(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "trust store not provisioned",
            )));
        }
        // On reopen `open_inner` reads the bound recovery key from `trust_meta`
        // and ignores this argument, so a placeholder is safe and never stored.
        Self::open_inner(path, project_id, [0u8; 32], None)
    }

    fn open_inner(
        path: PathBuf,
        project_id: ProjectId,
        recovery_signing_public: [u8; 32],
        keys: Option<Arc<dyn ProjectKeyProvider>>,
    ) -> Result<Self, TrustError> {
        if path.exists() {
            preflight_and_migrate(&path)?;
        }
        let connection = Connection::open(&path)?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "synchronous", "FULL")?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version == 0 {
            connection.execute_batch(SCHEMA)?;
            connection.pragma_update(None, "application_id", APPLICATION_ID)?;
            connection.pragma_update(None, "user_version", SCHEMA_VERSION)?;
            require_one(connection.execute(
                "INSERT INTO trust_meta(singleton, project_id, recovery_signing_public, roster_epoch, current_key_id) VALUES(1, ?1, ?2, 0, zeroblob(16))",
                params![project_id.as_bytes().as_slice(), recovery_signing_public.as_slice()],
            )?, "initialize trust meta")?;
        }
        validate_schema(&connection)?;
        let stored: Vec<u8> = connection.query_row(
            "SELECT project_id FROM trust_meta WHERE singleton = 1",
            [],
            |row| row.get(0),
        )?;
        if stored.as_slice() != project_id.as_bytes() {
            return Err(TrustError::WrongProject);
        }
        Ok(Self {
            path,
            connection: Mutex::new(connection),
            project_id,
            mutation_gate: Arc::new(ExclusiveGate::default()),
            rotation_gate: Mutex::new(()),
            keys,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn epoch(&self) -> Result<u64, TrustError> {
        let value: i64 = self.connection()?.query_row(
            "SELECT roster_epoch FROM trust_meta WHERE singleton = 1",
            [],
            |row| row.get(0),
        )?;
        u64::try_from(value).map_err(|_| TrustError::InvalidEpoch)
    }

    pub(super) fn current_key_id(&self) -> Result<super::KeyId, TrustError> {
        let bytes: Vec<u8> = self.connection()?.query_row(
            "SELECT current_key_id FROM trust_meta WHERE singleton=1",
            [],
            |row| row.get(0),
        )?;
        Ok(super::KeyId(
            bytes.try_into().map_err(|_| TrustError::InvalidSchema)?,
        ))
    }

    pub(super) fn verify_rotation_plan(
        &self,
        record: &CanonicalRecord,
        from_key_id: super::KeyId,
        to_key_id: super::KeyId,
    ) -> Result<(), TrustError> {
        if record.kind != RecordKind::Rotation {
            return Err(TrustError::NotControlRecord);
        }
        let fields = self.verify_control(record)?;
        let rotation = RotationPayload::decode(&record.payload)?;
        if super::KeyId(fields.key_id) != to_key_id
            || self.current_key_id()? != from_key_id
            || record.roster_epoch
                != self
                    .epoch()?
                    .checked_add(1)
                    .ok_or(TrustError::InvalidEpoch)?
        {
            return Err(TrustError::BindingMismatch);
        }
        let keys = self.keys.as_ref().ok_or(TrustError::MissingProjectKey)?;
        let key = keys
            .project_key(self.project_id, to_key_id)
            .map_err(|_| TrustError::MissingProjectKey)?;
        if key.rotation_commitment(self.project_id.as_bytes(), &to_key_id.0)
            != rotation.dek_commitment
        {
            return Err(TrustError::DekCommitmentMismatch);
        }
        Ok(())
    }

    pub fn record_rotation_ack(&self, ack: &SignedRotationAck) -> Result<(), TrustError> {
        if ack.project_id != *self.project_id.as_bytes() {
            return Err(TrustError::BindingMismatch);
        }
        self.verify_device_signature(
            &ack.observer_device,
            ack.roster_epoch,
            &ack.signing_preimage(),
            &ack.signature,
        )
        .map_err(|_| TrustError::ForgedSignature)?;
        let _gate = self
            .mutation_gate
            .acquire()
            .map_err(|_| TrustError::Poisoned)?;
        if ack.roster_epoch != self.epoch()? {
            return Err(TrustError::StaleEpoch);
        }
        let connection = self.connection()?;
        let matching: i64 = connection.query_row(
            "SELECT count(*) FROM trust_rotation_journal WHERE to_key_id=?1 AND roster_epoch=?2 AND control_hash=?3",
            params![ack.key_id.as_slice(), i64::try_from(ack.roster_epoch).map_err(|_| TrustError::InvalidEpoch)?, ack.control_hash.as_slice()],
            |row| row.get(0),
        )?;
        let current: Vec<u8> = connection.query_row(
            "SELECT current_key_id FROM trust_meta WHERE singleton=1",
            [],
            |row| row.get(0),
        )?;
        if matching != 1 || current.as_slice() != ack.key_id {
            return Err(TrustError::BindingMismatch);
        }
        connection.execute(
            "INSERT OR IGNORE INTO trust_rotation_acks(key_id,generation,roster_epoch,device_id,control_hash,nonce) VALUES(?1,?2,?3,?4,?5,?6)",
            params![ack.key_id.as_slice(), i64::try_from(ack.generation).map_err(|_| TrustError::InvalidEpoch)?, i64::try_from(ack.roster_epoch).map_err(|_| TrustError::InvalidEpoch)?, ack.observer_device.as_slice(), ack.control_hash.as_slice(), ack.nonce.as_slice()],
        )?;
        validate_schema(&connection)?;
        Ok(())
    }

    pub(super) fn acquire_rotation_ack_lease(
        &self,
        key_id: super::KeyId,
    ) -> Result<TrustRotationAckLease<'_>, TrustError> {
        let guard = self
            .mutation_gate
            .acquire()
            .map_err(|_| TrustError::Poisoned)?;
        let snapshot = self.rotation_ack_snapshot(key_id)?;
        Ok(TrustRotationAckLease {
            trust: self,
            key_id,
            snapshot,
            _guard: guard,
        })
    }

    fn rotation_ack_snapshot(
        &self,
        key_id: super::KeyId,
    ) -> Result<RotationAckSnapshot, TrustError> {
        let connection = self.connection()?;
        let epoch: i64 = connection.query_row(
            "SELECT roster_epoch FROM trust_meta WHERE singleton=1",
            [],
            |row| row.get(0),
        )?;
        let generation: i64 = connection.query_row(
            "SELECT COALESCE(MAX(generation),0) FROM trust_rotation_acks WHERE key_id=?1 AND roster_epoch=?2",
            params![key_id.0.as_slice(), epoch], |row| row.get(0),
        )?;
        let approved: i64 = connection.query_row(
            "SELECT count(*) FROM trust_devices WHERE status='approved'",
            [],
            |row| row.get(0),
        )?;
        let acked: i64 = connection.query_row(
            "SELECT count(*) FROM trust_rotation_acks a JOIN trust_devices d ON d.device_id=a.device_id WHERE a.key_id=?1 AND a.generation=?2 AND a.roster_epoch=?3 AND d.status='approved'",
            params![key_id.0.as_slice(), generation, epoch], |row| row.get(0),
        )?;
        Ok(RotationAckSnapshot {
            epoch: u64::try_from(epoch).map_err(|_| TrustError::InvalidEpoch)?,
            generation: u64::try_from(generation).map_err(|_| TrustError::InvalidEpoch)?,
            approved: u64::try_from(approved).map_err(|_| TrustError::InvalidSchema)?,
            acked: u64::try_from(acked).map_err(|_| TrustError::InvalidSchema)?,
        })
    }

    pub fn apply_control_record(&self, record: &CanonicalRecord) -> Result<(), TrustError> {
        let _gate = self
            .mutation_gate
            .acquire()
            .map_err(|_| TrustError::Poisoned)?;
        let fields = self.verify_control(record)?;
        let mut connection = self.connection()?;
        let transaction = connection.transaction()?;
        let current: i64 = transaction.query_row(
            "SELECT roster_epoch FROM trust_meta WHERE singleton = 1",
            [],
            |row| row.get(0),
        )?;
        let next = i64::try_from(fields.roster_epoch).map_err(|_| TrustError::InvalidEpoch)?;
        if next != current + 1 {
            return Err(TrustError::StaleEpoch);
        }
        let inserted = transaction.execute(
            "INSERT OR IGNORE INTO trust_nonces(nonce, record_kind, roster_epoch) VALUES(?1, ?2, ?3)",
            params![fields.nonce.as_slice(), record.kind as u8, next],
        )?;
        if inserted != 1 {
            return Err(TrustError::ReplayedNonce);
        }
        match record.kind {
            RecordKind::DeviceGrant => {
                let grant = DeviceGrantPayload::decode(&record.payload)?;
                require_one(transaction.execute(
                    "INSERT INTO trust_devices(device_id, signing_public, agreement_public, tls_certificate_hash, status, approved_epoch, revoked_epoch) VALUES(?1,?2,?3,?4,'approved',?5,NULL)
                     ON CONFLICT(device_id) DO UPDATE SET signing_public=excluded.signing_public, agreement_public=excluded.agreement_public, tls_certificate_hash=excluded.tls_certificate_hash, status='approved', approved_epoch=excluded.approved_epoch, revoked_epoch=NULL",
                    params![fields.device_id.as_slice(), fields.signing_public_key.as_slice(), fields.agreement_public_key.as_slice(), grant.tls_certificate_hash.as_slice(), next],
                )?, "grant device")?;
                require_one(transaction.execute(
                    "INSERT OR REPLACE INTO trust_dek_wraps(device_id,key_id,ephemeral_public,wrap_nonce,wrapped_dek) VALUES(?1,?2,?3,?4,?5)",
                    params![fields.device_id.as_slice(), fields.key_id.as_slice(), grant.ephemeral_public_key.as_slice(), grant.wrap_nonce.as_slice(), grant.wrapped_dek.as_slice()],
                )?, "grant DEK wrap")?;
            }
            RecordKind::DeviceRevoke => {
                let expected_wraps: i64 = transaction.query_row(
                    "SELECT count(*) FROM trust_dek_wraps WHERE device_id=?1",
                    [fields.device_id.as_slice()],
                    |row| row.get(0),
                )?;
                let changed = transaction.execute(
                    "UPDATE trust_devices SET status='revoked', revoked_epoch=?2 WHERE device_id=?1 AND status='approved'",
                    params![fields.device_id.as_slice(), next],
                )?;
                if changed != 1 {
                    return Err(TrustError::UnknownOrRevokedDevice);
                }
                let deleted = transaction.execute(
                    "DELETE FROM trust_dek_wraps WHERE device_id=?1",
                    [fields.device_id.as_slice()],
                )?;
                if i64::try_from(deleted).map_err(|_| TrustError::InvalidSchema)? != expected_wraps
                {
                    return Err(TrustError::AffectedRows { actual: deleted });
                }
                let remaining: i64 = transaction.query_row(
                    "SELECT count(*) FROM trust_dek_wraps WHERE device_id=?1",
                    [fields.device_id.as_slice()],
                    |row| row.get(0),
                )?;
                if remaining != 0 {
                    return Err(TrustError::InvalidSchema);
                }
            }
            RecordKind::Rotation => {
                let rotation = RotationPayload::decode(&record.payload)?;
                let keys = self.keys.as_ref().ok_or(TrustError::MissingProjectKey)?;
                let key = keys
                    .project_key(self.project_id, super::KeyId(fields.key_id))
                    .map_err(|_| TrustError::MissingProjectKey)?;
                if key.rotation_commitment(self.project_id.as_bytes(), &fields.key_id)
                    != rotation.dek_commitment
                {
                    return Err(TrustError::DekCommitmentMismatch);
                }
                require_one(
                    transaction.execute(
                        "UPDATE trust_meta SET current_key_id=?1 WHERE singleton=1",
                        [fields.key_id.as_slice()],
                    )?,
                    "activate rotation key",
                )?;
            }
            _ => return Err(TrustError::NotControlRecord),
        }
        require_one(
            transaction.execute(
                "UPDATE trust_meta SET roster_epoch=?1 WHERE singleton=1",
                [next],
            )?,
            "advance roster epoch",
        )?;
        validate_schema(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    fn verify_control(&self, record: &CanonicalRecord) -> Result<ControlFields, TrustError> {
        let fields = match record.kind {
            RecordKind::DeviceGrant => DeviceGrantPayload::decode(&record.payload)?.fields,
            RecordKind::DeviceRevoke => DeviceRevokePayload::decode(&record.payload)?.fields,
            RecordKind::Rotation => RotationPayload::decode(&record.payload)?.fields,
            _ => return Err(TrustError::NotControlRecord),
        };
        if fields.project_id != record.project_id
            || fields.device_id != record.device_id
            || fields.roster_epoch != record.roster_epoch
            || record.project_id != *self.project_id.as_bytes()
        {
            return Err(TrustError::BindingMismatch);
        }
        let connection = self.connection()?;
        let replayed: Option<i64> = connection
            .query_row(
                "SELECT 1 FROM trust_nonces WHERE nonce=?1",
                [fields.nonce.as_slice()],
                |row| row.get(0),
            )
            .optional()?;
        if replayed.is_some() {
            return Err(TrustError::ReplayedNonce);
        }
        let public: Vec<u8> = connection.query_row(
            "SELECT recovery_signing_public FROM trust_meta WHERE singleton=1",
            [],
            |row| row.get(0),
        )?;
        verify_signature(&public, &record.signing_preimage()?, &record.signature)?;
        Ok(fields)
    }

    fn verify_device_signature(
        &self,
        device_id: &[u8; 32],
        epoch: u64,
        preimage: &[u8],
        signature: &[u8; 64],
    ) -> Result<(), OplogTrustError> {
        let connection = self.connection().map_err(other)?;
        let current: i64 = connection
            .query_row(
                "SELECT roster_epoch FROM trust_meta WHERE singleton=1",
                [],
                |row| row.get(0),
            )
            .map_err(other)?;
        if epoch != current as u64 {
            return Err(OplogTrustError::StaleEpoch);
        }
        let device: Option<(Vec<u8>, String)> = connection
            .query_row(
                "SELECT signing_public,status FROM trust_devices WHERE device_id=?1",
                [device_id.as_slice()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(other)?;
        let Some((public, status)) = device else {
            return Err(OplogTrustError::UnauthorizedDevice);
        };
        if status == "revoked" {
            return Err(OplogTrustError::RevokedDevice);
        }
        verify_signature(&public, preimage, signature).map_err(|_| OplogTrustError::ForgedSignature)
    }

    pub(super) fn connection(&self) -> Result<MutexGuard<'_, Connection>, TrustError> {
        self.connection.lock().map_err(|_| TrustError::Poisoned)
    }

    pub(super) fn rotation_guard(&self) -> Result<MutexGuard<'_, ()>, TrustError> {
        self.rotation_gate.lock().map_err(|_| TrustError::Poisoned)
    }

    pub(super) fn rotation_mutation_guard(&self) -> Result<ExclusiveGuard, TrustError> {
        self.mutation_gate
            .acquire()
            .map_err(|_| TrustError::Poisoned)
    }

    fn device_statuses(&self) -> Result<Vec<DeviceStatus>, TrustError> {
        let connection = self.connection()?;
        let mut statement =
            connection.prepare("SELECT device_id,status FROM trust_devices ORDER BY device_id")?;
        let rows = statement.query_map([], |row| {
            let id: Vec<u8> = row.get(0)?;
            let status: String = row.get(1)?;
            Ok((id, status))
        })?;
        rows.map(|row| {
            let (id, status) = row?;
            let device_id = id.try_into().map_err(|_| TrustError::InvalidPublicKey)?;
            Ok(DeviceStatus {
                device_id,
                revoked: status == "revoked",
            })
        })
        .collect()
    }

    pub fn authorize_transport_certificate(
        &self,
        certificate_der: &[u8],
    ) -> Result<TransportPeerSnapshot, TrustError> {
        let certificate_hash = *blake3::hash(certificate_der).as_bytes();
        let connection = self.connection()?;
        let epoch: i64 = connection.query_row(
            "SELECT roster_epoch FROM trust_meta WHERE singleton=1",
            [],
            |row| row.get(0),
        )?;
        let peers = connection
            .prepare("SELECT device_id FROM trust_devices WHERE tls_certificate_hash=?1 AND status='approved'")?
            .query_map([certificate_hash.as_slice()], |row| row.get::<_, Vec<u8>>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        if peers.len() != 1 {
            return Err(TrustError::UnauthorizedTransportCertificate);
        }
        Ok(TransportPeerSnapshot {
            project_id: self.project_id,
            device_id: peers[0]
                .as_slice()
                .try_into()
                .map_err(|_| TrustError::InvalidSchema)?,
            roster_epoch: u64::try_from(epoch).map_err(|_| TrustError::InvalidEpoch)?,
            certificate_hash,
        })
    }

    pub fn revalidate_transport_peer(
        &self,
        snapshot: &TransportPeerSnapshot,
    ) -> Result<(), TrustError> {
        if snapshot.project_id != self.project_id || snapshot.roster_epoch != self.epoch()? {
            return Err(TrustError::StaleEpoch);
        }
        let matching: i64 = self.connection()?.query_row(
            "SELECT count(*) FROM trust_devices WHERE device_id=?1 AND tls_certificate_hash=?2 AND status='approved'",
            params![snapshot.device_id.as_slice(), snapshot.certificate_hash.as_slice()],
            |row| row.get(0),
        )?;
        if matching != 1 {
            return Err(TrustError::UnauthorizedTransportCertificate);
        }
        Ok(())
    }

    pub(super) fn acquire_transport_authorization_lease(
        &self,
        snapshot: &TransportPeerSnapshot,
    ) -> Result<TransportAuthorizationLease<'_>, TrustError> {
        let guard = self
            .mutation_gate
            .acquire()
            .map_err(|_| TrustError::Poisoned)?;
        self.revalidate_transport_peer(snapshot)?;
        Ok(TransportAuthorizationLease {
            trust: self,
            snapshot: *snapshot,
            _guard: guard,
        })
    }

    #[cfg(test)]
    pub fn test_mutation_fingerprint(&self) -> Result<(i64, i64, i64, i64), TrustError> {
        let connection = self.connection()?;
        Ok((
            connection.query_row(
                "SELECT roster_epoch FROM trust_meta WHERE singleton=1",
                [],
                |row| row.get(0),
            )?,
            connection.query_row("SELECT count(*) FROM trust_devices", [], |row| row.get(0))?,
            connection.query_row("SELECT count(*) FROM trust_nonces", [], |row| row.get(0))?,
            connection.query_row("SELECT count(*) FROM trust_dek_wraps", [], |row| row.get(0))?,
        ))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TransportPeerSnapshot {
    pub project_id: ProjectId,
    pub device_id: [u8; 32],
    pub roster_epoch: u64,
    pub certificate_hash: [u8; 32],
}

pub(super) struct TransportAuthorizationLease<'a> {
    trust: &'a TrustStore,
    snapshot: TransportPeerSnapshot,
    _guard: ExclusiveGuard,
}

impl TransportAuthorizationLease<'_> {
    pub fn revalidate(&self) -> Result<(), TrustError> {
        self.trust.revalidate_transport_peer(&self.snapshot)
    }
}

#[derive(Clone, Copy)]
pub(super) struct RotationAckSnapshot {
    pub epoch: u64,
    pub generation: u64,
    pub approved: u64,
    pub acked: u64,
}

pub(super) struct TrustRotationAckLease<'a> {
    trust: &'a TrustStore,
    key_id: super::KeyId,
    snapshot: RotationAckSnapshot,
    _guard: ExclusiveGuard,
}

impl TrustRotationAckLease<'_> {
    pub fn snapshot(&self) -> RotationAckSnapshot {
        self.snapshot
    }
    pub fn revalidate(&self) -> Result<(), TrustError> {
        let current = self.trust.rotation_ack_snapshot(self.key_id)?;
        if current.epoch != self.snapshot.epoch
            || current.generation != self.snapshot.generation
            || current.approved != self.snapshot.approved
            || current.acked != self.snapshot.acked
        {
            return Err(TrustError::StaleEpoch);
        }
        Ok(())
    }
}

#[derive(Default)]
struct ExclusiveGate {
    held: Mutex<bool>,
    ready: Condvar,
}

impl ExclusiveGate {
    fn acquire(self: &Arc<Self>) -> Result<ExclusiveGuard, ()> {
        let mut held = self.held.lock().map_err(|_| ())?;
        while *held {
            held = self.ready.wait(held).map_err(|_| ())?;
        }
        *held = true;
        Ok(ExclusiveGuard { gate: self.clone() })
    }
}

pub(super) struct ExclusiveGuard {
    gate: Arc<ExclusiveGate>,
}
impl Drop for ExclusiveGuard {
    fn drop(&mut self) {
        if let Ok(mut held) = self.gate.held.lock() {
            *held = false;
            self.gate.ready.notify_one();
        }
    }
}

pub trait TrustRootProvider: Send + Sync {
    fn snapshot_roots(&self, project_id: ProjectId) -> Result<Vec<ObjectId>, String>;
}

pub struct TrustGcCoordinator {
    trust: Arc<TrustStore>,
    roots: Arc<dyn TrustRootProvider>,
}

impl TrustGcCoordinator {
    pub fn new(trust: Arc<TrustStore>, roots: Arc<dyn TrustRootProvider>) -> Self {
        Self { trust, roots }
    }

    /// Root activation must use this same exclusion gate so GC can hold a
    /// roster+root snapshot stable through durable CAS deletion.
    pub fn with_root_activation<T>(&self, mutation: impl FnOnce() -> T) -> Result<T, GcError> {
        let _guard = self
            .trust
            .mutation_gate
            .acquire()
            .map_err(|_| GcError::Provider("trust gate poisoned".into()))?;
        Ok(mutation())
    }

    fn snapshot_locked(&self, project_id: ProjectId) -> Result<GcSnapshot, GcError> {
        if project_id != self.trust.project_id {
            return Err(GcError::Provider("wrong trust project".into()));
        }
        Ok(GcSnapshot {
            devices: self
                .trust
                .device_statuses()
                .map_err(|error| GcError::Provider(error.to_string()))?,
            roots: self
                .roots
                .snapshot_roots(project_id)
                .map_err(GcError::Provider)?,
        })
    }
}

impl GcCoordinator for TrustGcCoordinator {
    fn snapshot(&self, project_id: ProjectId) -> Result<GcSnapshot, GcError> {
        let _guard = self
            .trust
            .mutation_gate
            .acquire()
            .map_err(|_| GcError::Provider("trust gate poisoned".into()))?;
        self.snapshot_locked(project_id)
    }

    fn acquire_snapshot_lease(
        &self,
        project_id: ProjectId,
        _: ObjectId,
    ) -> Result<Option<Box<dyn GcSnapshotLease>>, GcError> {
        let guard = self
            .trust
            .mutation_gate
            .acquire()
            .map_err(|_| GcError::Provider("trust gate poisoned".into()))?;
        Ok(Some(Box::new(TrustLease {
            coordinator: TrustGcCoordinator {
                trust: self.trust.clone(),
                roots: self.roots.clone(),
            },
            project_id,
            _guard: guard,
        })))
    }
}

struct TrustLease {
    coordinator: TrustGcCoordinator,
    project_id: ProjectId,
    _guard: ExclusiveGuard,
}
impl GcSnapshotLease for TrustLease {
    fn snapshot(&self) -> Result<GcSnapshot, GcError> {
        self.coordinator.snapshot_locked(self.project_id)
    }
}

impl OplogTrustProvider for TrustStore {
    fn verify(&self, record: &CanonicalRecord) -> Result<(), OplogTrustError> {
        if record.project_id != *self.project_id.as_bytes() {
            return Err(OplogTrustError::UnauthorizedDevice);
        }
        let preimage = record.signing_preimage().map_err(other)?;
        self.verify_device_signature(
            &record.device_id,
            record.roster_epoch,
            &preimage,
            &record.signature,
        )
    }

    fn verify_ack(&self, ack: &SignedDeviceAck) -> Result<(), OplogTrustError> {
        if ack.project_id != self.project_id {
            return Err(OplogTrustError::UnauthorizedDevice);
        }
        let preimage = ack.signing_preimage().map_err(other)?;
        self.verify_device_signature(
            &ack.observer_device,
            ack.roster_epoch,
            &preimage,
            &ack.signature,
        )
    }
}

fn verify_signature(public: &[u8], message: &[u8], signature: &[u8; 64]) -> Result<(), TrustError> {
    let public: [u8; 32] = public
        .try_into()
        .map_err(|_| TrustError::InvalidPublicKey)?;
    let key = VerifyingKey::from_bytes(&public).map_err(|_| TrustError::InvalidPublicKey)?;
    key.verify(message, &Signature::from_bytes(signature))
        .map_err(|_| TrustError::ForgedSignature)
}

pub(super) fn validate_schema(connection: &Connection) -> Result<(), TrustError> {
    let app: i64 = connection.pragma_query_value(None, "application_id", |row| row.get(0))?;
    let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if app != APPLICATION_ID || version != SCHEMA_VERSION {
        return Err(TrustError::InvalidSchema);
    }
    let quick: String = connection.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
    if quick != "ok" {
        return Err(TrustError::InvalidSchema);
    }
    validate_schema_objects(connection)
}

fn validate_schema_objects(connection: &Connection) -> Result<(), TrustError> {
    let mut statement = connection.prepare(
        "SELECT type,name,sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name",
    )?;
    let actual = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut expected = SCHEMA
        .split(';')
        .filter_map(|statement| {
            let sql = statement.trim();
            if sql.is_empty() {
                return None;
            }
            let words = sql.split_whitespace().collect::<Vec<_>>();
            let kind = if words.get(1) == Some(&"TABLE") {
                "table"
            } else {
                "index"
            };
            Some((kind.to_owned(), words[2].to_owned(), normalize_sql(sql)))
        })
        .collect::<Vec<_>>();
    expected.sort_by(|left, right| (&left.0, &left.1).cmp(&(&right.0, &right.1)));
    let actual = actual
        .into_iter()
        .map(|(kind, name, sql)| (kind, name, normalize_sql(&sql)))
        .collect::<Vec<_>>();
    if actual != expected {
        return Err(TrustError::InvalidSchema);
    }
    Ok(())
}

fn preflight_and_migrate(path: &Path) -> Result<(), TrustError> {
    let mut connection = Connection::open(path)?;
    let app: i64 = connection.pragma_query_value(None, "application_id", |row| row.get(0))?;
    let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    let quick: String = connection.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
    if app == APPLICATION_ID && version == 1 && quick == "ok" {
        let transaction = connection.transaction()?;
        transaction.execute_batch(&format!(
            "DROP INDEX trust_devices_status_idx;
             {CREATE_TRUST_DEVICES_V2}
             INSERT INTO trust_devices_v2(device_id,signing_public,agreement_public,tls_certificate_hash,status,approved_epoch,revoked_epoch)
               SELECT device_id,signing_public,agreement_public,NULL,status,approved_epoch,revoked_epoch FROM trust_devices;
             DROP TABLE trust_devices;
             ALTER TABLE trust_devices_v2 RENAME TO trust_devices;
             CREATE INDEX trust_devices_status_idx ON trust_devices(status, device_id);
             CREATE INDEX trust_devices_tls_cert_idx ON trust_devices(tls_certificate_hash, status);"
        ))?;
        validate_schema_objects(&transaction)?;
        transaction.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        transaction.commit()?;
    }
    if let Err(error) = validate_schema(&connection) {
        drop(connection);
        let suffix = format!("quarantine.{}.{}", std::process::id(), now_nanos());
        let quarantine = path.with_file_name(format!(
            "{}.{}",
            path.file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("key-state.sqlite3"),
            suffix
        ));
        fs::rename(path, &quarantine)?;
        for extension in ["-wal", "-shm"] {
            let source = PathBuf::from(format!("{}{}", path.display(), extension));
            if source.exists() {
                fs::rename(
                    &source,
                    PathBuf::from(format!("{}{}", quarantine.display(), extension)),
                )?;
            }
        }
        fs::File::open(path.parent().ok_or(TrustError::InvalidSchema)?)?.sync_all()?;
        return Err(TrustError::Quarantined {
            path: quarantine,
            reason: error.to_string(),
        });
    }
    Ok(())
}

fn require_one(changed: usize, _: &'static str) -> Result<(), TrustError> {
    if changed == 1 {
        Ok(())
    } else {
        Err(TrustError::AffectedRows { actual: changed })
    }
}

fn normalize_sql(sql: &str) -> String {
    sql.replace("\"trust_devices\"", "trust_devices")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}
fn now_nanos() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos())
}

#[cfg(test)]
mod migration_tests {
    use super::*;

    #[test]
    fn real_v1_rows_migrate_canonically_and_reopen() {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("trust.sqlite3");
        let v1 = SCHEMA
            .replace(
                "    tls_certificate_hash BLOB CHECK(tls_certificate_hash IS NULL OR length(tls_certificate_hash) = 32),\n",
                "",
            )
            .replace(
                "CREATE INDEX trust_devices_tls_cert_idx ON trust_devices(tls_certificate_hash, status);\n",
                "",
            );
        let connection = Connection::open(&path).unwrap();
        connection.execute_batch(&v1).unwrap();
        connection
            .pragma_update(None, "application_id", APPLICATION_ID)
            .unwrap();
        connection.pragma_update(None, "user_version", 1).unwrap();
        connection
            .execute(
                "INSERT INTO trust_meta VALUES(1,?1,?2,7,?3)",
                params![
                    [1_u8; 32].as_slice(),
                    [2_u8; 32].as_slice(),
                    [3_u8; 16].as_slice()
                ],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO trust_devices VALUES(?1,?2,?3,'approved',7,NULL)",
                params![
                    [4_u8; 32].as_slice(),
                    [5_u8; 32].as_slice(),
                    [6_u8; 32].as_slice()
                ],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO trust_nonces VALUES(?1,1,7)",
                [[7_u8; 32].as_slice()],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO trust_dek_wraps VALUES(?1,?2,?3,?4,?5)",
                params![
                    [4_u8; 32].as_slice(),
                    [3_u8; 16].as_slice(),
                    [8_u8; 32].as_slice(),
                    [9_u8; 24].as_slice(),
                    [10_u8; 48].as_slice()
                ],
            )
            .unwrap();
        drop(connection);

        let store = TrustStore::open(&path, ProjectId::from_bytes([1; 32]), [2; 32]).unwrap();
        assert_eq!(store.epoch().unwrap(), 7);
        let connection = store.connection().unwrap();
        assert_eq!(
            connection
                .query_row(
                    "SELECT count(*) FROM trust_devices WHERE tls_certificate_hash IS NULL",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            1
        );
        assert_eq!(
            connection
                .query_row("SELECT count(*) FROM trust_nonces", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            connection
                .query_row("SELECT count(*) FROM trust_dek_wraps", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            1
        );
        validate_schema(&connection).unwrap();
        drop(connection);
        drop(store);
        TrustStore::open(&path, ProjectId::from_bytes([1; 32]), [2; 32]).unwrap();
        assert!(std::fs::read_dir(temporary.path()).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains("quarantine")
        }));
    }
}

fn other(error: impl std::fmt::Display) -> OplogTrustError {
    OplogTrustError::Other(error.to_string())
}

#[derive(Debug)]
pub enum TrustError {
    Sql(rusqlite::Error),
    Io(std::io::Error),
    Protocol(sync_protocol::ProtocolError),
    InvalidSchema,
    WrongProject,
    InvalidEpoch,
    Poisoned,
    ForgedSignature,
    InvalidPublicKey,
    ReplayedNonce,
    StaleEpoch,
    BindingMismatch,
    UnknownOrRevokedDevice,
    NotControlRecord,
    MissingProjectKey,
    UnauthorizedTransportCertificate,
    DekCommitmentMismatch,
    AffectedRows { actual: usize },
    Quarantined { path: PathBuf, reason: String },
}
impl std::fmt::Display for TrustError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for TrustError {}
impl From<rusqlite::Error> for TrustError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Sql(value)
    }
}
impl From<std::io::Error> for TrustError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}
impl From<sync_protocol::ProtocolError> for TrustError {
    fn from(value: sync_protocol::ProtocolError) -> Self {
        Self::Protocol(value)
    }
}
