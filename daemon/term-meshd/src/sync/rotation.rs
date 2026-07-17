use chacha20poly1305::aead::{Aead, Payload};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce};
use hkdf::Hkdf;
use rusqlite::{params, OptionalExtension};
use sha2::Sha256;
use sync_protocol::CanonicalRecord;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

use super::trust::validate_schema;
use super::{
    CasError, CasStore, KeyId, ProjectId, ProjectKey, RandomSource, TrustError, TrustStore,
};

const WRAP_INFO: &[u8] = b"term-mesh project DEK wrap v1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WrappedProjectKey {
    pub key_id: KeyId,
    pub ephemeral_public: [u8; 32],
    pub nonce: [u8; 24],
    pub ciphertext: [u8; 48],
}

pub fn wrap_project_key(
    random: &dyn RandomSource,
    project_id: ProjectId,
    device_id: [u8; 32],
    roster_epoch: u64,
    key_id: KeyId,
    key: &ProjectKey,
    receiver_public: [u8; 32],
) -> Result<WrappedProjectKey, RotationError> {
    let mut ephemeral_secret = Zeroizing::new([0; 32]);
    random.fill(&mut *ephemeral_secret)?;
    let secret = StaticSecret::from(*ephemeral_secret);
    let ephemeral_public = PublicKey::from(&secret).to_bytes();
    let shared = secret.diffie_hellman(&PublicKey::from(receiver_public));
    if !shared.was_contributory() {
        return Err(RotationError::NonContributoryKey);
    }
    let derived = derive_wrap_key(
        shared.as_bytes(),
        project_id,
        device_id,
        roster_epoch,
        key_id,
        ephemeral_public,
        receiver_public,
    )?;
    let mut nonce = [0; 24];
    random.fill(&mut nonce)?;
    let aad = wrap_aad(
        project_id,
        device_id,
        roster_epoch,
        key_id,
        ephemeral_public,
        receiver_public,
    );
    let encoded = XChaCha20Poly1305::new_from_slice(&*derived)
        .map_err(|_| RotationError::Crypto)?
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: key.expose_for_wrapping(),
                aad: &aad,
            },
        )
        .map_err(|_| RotationError::Crypto)?;
    let ciphertext = encoded.try_into().map_err(|_| RotationError::Crypto)?;
    Ok(WrappedProjectKey {
        key_id,
        ephemeral_public,
        nonce,
        ciphertext,
    })
}

pub fn unwrap_project_key(
    project_id: ProjectId,
    device_id: [u8; 32],
    roster_epoch: u64,
    wrapped: &WrappedProjectKey,
    receiver_secret: Zeroizing<[u8; 32]>,
) -> Result<ProjectKey, RotationError> {
    let secret = StaticSecret::from(*receiver_secret);
    let receiver_public = PublicKey::from(&secret).to_bytes();
    let shared = secret.diffie_hellman(&PublicKey::from(wrapped.ephemeral_public));
    if !shared.was_contributory() {
        return Err(RotationError::NonContributoryKey);
    }
    let derived = derive_wrap_key(
        shared.as_bytes(),
        project_id,
        device_id,
        roster_epoch,
        wrapped.key_id,
        wrapped.ephemeral_public,
        receiver_public,
    )?;
    let aad = wrap_aad(
        project_id,
        device_id,
        roster_epoch,
        wrapped.key_id,
        wrapped.ephemeral_public,
        receiver_public,
    );
    let plaintext = Zeroizing::new(
        XChaCha20Poly1305::new_from_slice(&*derived)
            .map_err(|_| RotationError::Crypto)?
            .decrypt(
                XNonce::from_slice(&wrapped.nonce),
                Payload {
                    msg: &wrapped.ciphertext,
                    aad: &aad,
                },
            )
            .map_err(|_| RotationError::Crypto)?,
    );
    let key = Zeroizing::new(
        plaintext
            .as_slice()
            .try_into()
            .map_err(|_| RotationError::Crypto)?,
    );
    Ok(ProjectKey::from_zeroizing(key))
}

fn derive_wrap_key(
    shared: &[u8; 32],
    project_id: ProjectId,
    device_id: [u8; 32],
    roster_epoch: u64,
    key_id: KeyId,
    ephemeral_public: [u8; 32],
    receiver_public: [u8; 32],
) -> Result<Zeroizing<[u8; 32]>, RotationError> {
    let aad = wrap_aad(
        project_id,
        device_id,
        roster_epoch,
        key_id,
        ephemeral_public,
        receiver_public,
    );
    let hkdf = Hkdf::<Sha256>::new(Some(project_id.as_bytes()), shared);
    let mut output = Zeroizing::new([0; 32]);
    let mut info = Vec::with_capacity(WRAP_INFO.len() + aad.len());
    info.extend_from_slice(WRAP_INFO);
    info.extend_from_slice(&aad);
    hkdf.expand(&info, &mut *output)
        .map_err(|_| RotationError::Crypto)?;
    Ok(output)
}

fn wrap_aad(
    project_id: ProjectId,
    device_id: [u8; 32],
    roster_epoch: u64,
    key_id: KeyId,
    ephemeral_public: [u8; 32],
    receiver_public: [u8; 32],
) -> Vec<u8> {
    let mut aad = Vec::with_capacity(152);
    aad.extend_from_slice(project_id.as_bytes());
    aad.extend_from_slice(&device_id);
    aad.extend_from_slice(&roster_epoch.to_be_bytes());
    aad.extend_from_slice(&key_id.0);
    aad.extend_from_slice(&ephemeral_public);
    aad.extend_from_slice(&receiver_public);
    aad
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RotationPhase {
    Prepared,
    Published,
    Activated,
    AckWait,
    Retired,
    Completed,
}

impl RotationPhase {
    fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "prepared" => Self::Prepared,
            "published" => Self::Published,
            "activated" => Self::Activated,
            "ack_wait" => Self::AckWait,
            "retired" => Self::Retired,
            "completed" => Self::Completed,
            _ => return None,
        })
    }
}

pub struct RotationPlan<'a> {
    pub rotation_id: [u8; 32],
    pub from_key_id: KeyId,
    pub to_key_id: KeyId,
    pub control_record: &'a CanonicalRecord,
}

pub trait KeyPersistEvidence: Send + Sync {
    fn persist_new_key(
        &self,
        idempotency_key: [u8; 32],
        key_id: KeyId,
    ) -> Result<(), RotationError>;
    fn delete_old_key(&self, idempotency_key: [u8; 32], key_id: KeyId)
        -> Result<(), RotationError>;
}
pub struct PublishReceipt {
    pub op_id: [u8; 32],
    pub control_hash: [u8; 32],
}
pub trait ControlPublishEvidence: Send + Sync {
    fn publish(
        &self,
        idempotency_key: [u8; 32],
        record: &CanonicalRecord,
    ) -> Result<PublishReceipt, RotationError>;
}

/// Production coordinator. ACK and CAS retirement evidence comes only from
/// leases owned by TrustStore/CasStore; callers cannot supply counts.
pub struct RotationCoordinator<'a> {
    pub trust: &'a TrustStore,
    pub keys: &'a dyn KeyPersistEvidence,
    pub publisher: &'a dyn ControlPublishEvidence,
    pub cas: &'a CasStore,
}

impl RotationCoordinator<'_> {
    pub fn reconcile(&self, plan: &RotationPlan<'_>) -> Result<bool, RotationError> {
        let _rotation_guard = self.trust.rotation_guard()?;
        let phase = load_phase(self.trust, plan)?;
        let epoch = plan.control_record.roster_epoch;
        match phase {
            None => {
                let _mutation_guard = self.trust.rotation_mutation_guard()?;
                self.trust.verify_rotation_plan(
                    plan.control_record,
                    plan.from_key_id,
                    plan.to_key_id,
                )?;
                self.keys
                    .persist_new_key(plan.rotation_id, plan.to_key_id)?;
                insert_prepared(self.trust, plan)?;
                Ok(false)
            }
            Some(RotationPhase::Prepared) => {
                let receipt = self
                    .publisher
                    .publish(plan.rotation_id, plan.control_record)?;
                let expected = plan
                    .control_record
                    .domain_hash()
                    .map_err(|_| RotationError::JournalConflict)?;
                if receipt.control_hash != expected {
                    return Err(RotationError::JournalConflict);
                }
                journal_update(
                    self.trust,
                    plan,
                    "prepared",
                    "published",
                    "op_id=?4,control_hash=?5",
                    &[&receipt.op_id.as_slice(), &receipt.control_hash.as_slice()],
                )?;
                Ok(false)
            }
            Some(RotationPhase::Published) => {
                if self.trust.current_key_id()? != plan.to_key_id || self.trust.epoch()? < epoch {
                    self.trust.apply_control_record(plan.control_record)?;
                }
                journal_update(self.trust, plan, "published", "activated", "", &[])?;
                Ok(false)
            }
            Some(RotationPhase::Activated) => {
                let ack = self.trust.acquire_rotation_ack_lease(plan.to_key_id)?;
                let snapshot = ack.snapshot();
                if snapshot.epoch != epoch
                    || snapshot.approved == 0
                    || snapshot.acked != snapshot.approved
                {
                    return Err(RotationError::AwaitingAcknowledgements);
                }
                let cas = self.cas.acquire_retirement_fence(plan.from_key_id)?;
                ack.revalidate()?;
                cas.revalidate()?;
                let counts = cas.counts();
                let mut connection = self.trust.connection()?;
                let transaction = connection.transaction()?;
                require_one(transaction.execute(
                    "UPDATE trust_rotation_journal SET phase='ack_wait',approved_count=?2,acked_count=?3,ack_generation=?4 WHERE rotation_id=?1 AND phase='activated'",
                    params![plan.rotation_id.as_slice(), i64::try_from(snapshot.approved).map_err(|_| RotationError::InvalidEpoch)?, i64::try_from(snapshot.acked).map_err(|_| RotationError::InvalidEpoch)?, i64::try_from(snapshot.generation).map_err(|_| RotationError::InvalidEpoch)?],
                )?)?;
                validate_schema(&transaction)?;
                transaction.commit()?;
                if counts.old_key_objects != 0 || counts.inflight != 0 || counts.reachable != 0 {
                    return Err(RotationError::CasMigrationIncomplete);
                }
                Ok(false)
            }
            Some(RotationPhase::AckWait) => {
                let ack = self.trust.acquire_rotation_ack_lease(plan.to_key_id)?;
                let snapshot = ack.snapshot();
                validate_stored_ack(
                    self.trust,
                    plan,
                    snapshot.approved,
                    snapshot.acked,
                    snapshot.generation,
                )?;
                let cas = self.cas.acquire_retirement_fence(plan.from_key_id)?;
                let counts = cas.counts();
                if counts.old_key_objects != 0 || counts.inflight != 0 || counts.reachable != 0 {
                    return Err(RotationError::CasMigrationIncomplete);
                }
                ack.revalidate()?;
                cas.revalidate()?;
                let migration = CasMigrationCounts {
                    old_key_objects: counts.old_key_objects,
                    inflight: counts.inflight,
                    reachable: counts.reachable,
                };
                journal_counts(
                    self.trust,
                    plan,
                    "ack_wait",
                    "retired",
                    0,
                    0,
                    Some(migration),
                )?;
                Ok(false)
            }
            Some(RotationPhase::Retired) => {
                let ack = self.trust.acquire_rotation_ack_lease(plan.to_key_id)?;
                let snapshot = ack.snapshot();
                validate_stored_ack(
                    self.trust,
                    plan,
                    snapshot.approved,
                    snapshot.acked,
                    snapshot.generation,
                )?;
                let cas = self.cas.acquire_retirement_fence(plan.from_key_id)?;
                let counts = cas.counts();
                if counts.old_key_objects != 0 || counts.inflight != 0 || counts.reachable != 0 {
                    return Err(RotationError::CasMigrationIncomplete);
                }
                ack.revalidate()?;
                cas.revalidate()?;
                self.keys
                    .delete_old_key(plan.rotation_id, plan.from_key_id)?;
                journal_update(
                    self.trust,
                    plan,
                    "retired",
                    "completed",
                    "old_key_deleted=1",
                    &[],
                )?;
                cas.complete()?;
                Ok(true)
            }
            Some(RotationPhase::Completed) => {
                self.cas
                    .complete_retirement_fence_idempotent(plan.from_key_id)?;
                Ok(true)
            }
        }
    }
}

fn load_phase(
    trust: &TrustStore,
    plan: &RotationPlan<'_>,
) -> Result<Option<RotationPhase>, RotationError> {
    let connection = trust.connection()?;
    let row: Option<(Vec<u8>,Vec<u8>,i64,String,Option<Vec<u8>>)> = connection.query_row(
        "SELECT from_key_id,to_key_id,roster_epoch,phase,control_hash FROM trust_rotation_journal WHERE rotation_id=?1",
        [plan.rotation_id.as_slice()], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?,row.get(4)?)),
    ).optional()?;
    let Some((from, to, epoch, phase, hash)) = row else {
        return Ok(None);
    };
    let expected = plan
        .control_record
        .domain_hash()
        .map_err(|_| RotationError::JournalConflict)?;
    if from != plan.from_key_id.0
        || to != plan.to_key_id.0
        || epoch != plan.control_record.roster_epoch as i64
        || hash.as_deref() != Some(expected.as_slice())
    {
        return Err(RotationError::JournalConflict);
    }
    Ok(Some(
        RotationPhase::parse(&phase).ok_or(RotationError::JournalConflict)?,
    ))
}

fn insert_prepared(trust: &TrustStore, plan: &RotationPlan<'_>) -> Result<(), RotationError> {
    let mut connection = trust.connection()?;
    let transaction = connection.transaction()?;
    let hash = plan
        .control_record
        .domain_hash()
        .map_err(|_| RotationError::JournalConflict)?;
    require_one(transaction.execute(
        "INSERT INTO trust_rotation_journal(rotation_id,from_key_id,to_key_id,phase,roster_epoch,control_hash,persisted_key) VALUES(?1,?2,?3,'prepared',?4,?5,1)",
        params![plan.rotation_id.as_slice(), plan.from_key_id.0.as_slice(), plan.to_key_id.0.as_slice(), i64::try_from(plan.control_record.roster_epoch).map_err(|_| RotationError::InvalidEpoch)?, hash.as_slice()],
    )?)?;
    validate_schema(&transaction)?;
    transaction.commit()?;
    Ok(())
}

fn journal_update(
    trust: &TrustStore,
    plan: &RotationPlan<'_>,
    from: &str,
    to: &str,
    assignments: &str,
    extra: &[&dyn rusqlite::ToSql],
) -> Result<(), RotationError> {
    let mut connection = trust.connection()?;
    let transaction = connection.transaction()?;
    let sql = if assignments.is_empty() {
        "UPDATE trust_rotation_journal SET phase=?2 WHERE rotation_id=?1 AND phase=?3".to_owned()
    } else {
        format!("UPDATE trust_rotation_journal SET phase=?2,{assignments} WHERE rotation_id=?1 AND phase=?3")
    };
    let rotation_id = plan.rotation_id.as_slice();
    let mut values: Vec<&dyn rusqlite::ToSql> = vec![&rotation_id, &to, &from];
    values.extend_from_slice(extra);
    require_one(transaction.execute(&sql, values.as_slice())?)?;
    validate_schema(&transaction)?;
    transaction.commit()?;
    Ok(())
}

fn journal_counts(
    trust: &TrustStore,
    plan: &RotationPlan<'_>,
    from: &str,
    to: &str,
    approved: u64,
    acked: u64,
    cas: Option<CasMigrationCounts>,
) -> Result<(), RotationError> {
    let mut connection = trust.connection()?;
    let transaction = connection.transaction()?;
    let changed = if let Some(cas) = cas {
        transaction.execute("UPDATE trust_rotation_journal SET phase=?2,old_object_count=?4,inflight_count=?5,reachable_count=?6 WHERE rotation_id=?1 AND phase=?3", params![plan.rotation_id.as_slice(),to,from,i64::try_from(cas.old_key_objects).map_err(|_| RotationError::InvalidEpoch)?,i64::try_from(cas.inflight).map_err(|_| RotationError::InvalidEpoch)?,i64::try_from(cas.reachable).map_err(|_| RotationError::InvalidEpoch)?])?
    } else {
        transaction.execute("UPDATE trust_rotation_journal SET phase=?2,approved_count=?4,acked_count=?5,ack_generation=0 WHERE rotation_id=?1 AND phase=?3", params![plan.rotation_id.as_slice(),to,from,i64::try_from(approved).map_err(|_| RotationError::InvalidEpoch)?,i64::try_from(acked).map_err(|_| RotationError::InvalidEpoch)?])?
    };
    require_one(changed)?;
    validate_schema(&transaction)?;
    transaction.commit()?;
    Ok(())
}

fn validate_stored_ack(
    trust: &TrustStore,
    plan: &RotationPlan<'_>,
    approved: u64,
    acked: u64,
    generation: u64,
) -> Result<(), RotationError> {
    let connection = trust.connection()?;
    let stored: (i64,i64,i64) = connection.query_row(
        "SELECT approved_count,acked_count,ack_generation FROM trust_rotation_journal WHERE rotation_id=?1",
        [plan.rotation_id.as_slice()], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?)),
    )?;
    if stored != (approved as i64, acked as i64, generation as i64) {
        return Err(RotationError::JournalConflict);
    }
    Ok(())
}
#[cfg(test)]
pub(crate) struct AckCounts {
    pub approved_non_revoked: u64,
    pub acked: u64,
}
#[cfg(test)]
pub(crate) trait AckEvidence: Send + Sync {
    fn counts(&self, key_id: KeyId) -> Result<AckCounts, RotationError>;
}
pub(crate) struct CasMigrationCounts {
    pub old_key_objects: u64,
    pub inflight: u64,
    pub reachable: u64,
}
#[cfg(test)]
pub(crate) trait CasMigrationEvidence: Send + Sync {
    fn counts(&self, old_key_id: KeyId) -> Result<CasMigrationCounts, RotationError>;
}

#[cfg(test)]
pub(crate) struct RotationOrchestrator<'a> {
    pub trust: &'a TrustStore,
    pub keys: &'a dyn KeyPersistEvidence,
    pub publisher: &'a dyn ControlPublishEvidence,
    pub acknowledgements: &'a dyn AckEvidence,
    pub cas: &'a dyn CasMigrationEvidence,
}

#[cfg(test)]
impl RotationOrchestrator<'_> {
    /// Executes at most one durable boundary. Repeated calls reconcile after
    /// interruption; callers cannot select or skip a phase.
    pub fn reconcile(&self, plan: &RotationPlan<'_>) -> Result<bool, RotationError> {
        let epoch = plan.control_record.roster_epoch;
        let phase = self.load_and_validate(plan)?;
        match phase {
            None => {
                self.trust.verify_rotation_plan(
                    plan.control_record,
                    plan.from_key_id,
                    plan.to_key_id,
                )?;
                self.keys
                    .persist_new_key(plan.rotation_id, plan.to_key_id)?;
                let mut connection = self.trust.connection()?;
                let transaction = connection.transaction()?;
                require_one(transaction.execute(
                    "INSERT INTO trust_rotation_journal(rotation_id,from_key_id,to_key_id,phase,roster_epoch,control_hash,persisted_key) VALUES(?1,?2,?3,'prepared',?4,?5,1)",
                    params![plan.rotation_id.as_slice(), plan.from_key_id.0.as_slice(), plan.to_key_id.0.as_slice(), i64::try_from(epoch).map_err(|_| RotationError::InvalidEpoch)?, plan.control_record.domain_hash().map_err(|_| RotationError::JournalConflict)?.as_slice()],
                )?)?;
                validate_schema(&transaction)?;
                transaction.commit()?;
                Ok(false)
            }
            Some(RotationPhase::Prepared) => {
                let receipt = self
                    .publisher
                    .publish(plan.rotation_id, plan.control_record)?;
                if receipt.control_hash
                    != plan
                        .control_record
                        .domain_hash()
                        .map_err(|_| RotationError::JournalConflict)?
                {
                    return Err(RotationError::JournalConflict);
                }
                self.update(
                    plan,
                    "prepared",
                    "published",
                    "op_id=?4,control_hash=?5",
                    &[
                        &receipt.op_id.as_slice() as &dyn rusqlite::ToSql,
                        &receipt.control_hash.as_slice() as &dyn rusqlite::ToSql,
                    ],
                )?;
                Ok(false)
            }
            Some(RotationPhase::Published) => {
                if self.trust.current_key_id()? != plan.to_key_id || self.trust.epoch()? < epoch {
                    self.trust.apply_control_record(plan.control_record)?;
                }
                self.update(plan, "published", "activated", "", &[])?;
                Ok(false)
            }
            Some(RotationPhase::Activated) => {
                let counts = self.acknowledgements.counts(plan.to_key_id)?;
                if counts.approved_non_revoked == 0 || counts.acked != counts.approved_non_revoked {
                    return Err(RotationError::AwaitingAcknowledgements);
                }
                self.update_counts(
                    plan,
                    "activated",
                    "ack_wait",
                    counts.approved_non_revoked,
                    counts.acked,
                    None,
                )?;
                Ok(false)
            }
            Some(RotationPhase::AckWait) => {
                let counts = self.cas.counts(plan.from_key_id)?;
                if counts.old_key_objects != 0 || counts.inflight != 0 || counts.reachable != 0 {
                    return Err(RotationError::CasMigrationIncomplete);
                }
                self.update_counts(plan, "ack_wait", "retired", 0, 0, Some(counts))?;
                Ok(false)
            }
            Some(RotationPhase::Retired) => {
                self.keys
                    .delete_old_key(plan.rotation_id, plan.from_key_id)?;
                self.update(plan, "retired", "completed", "old_key_deleted=1", &[])?;
                Ok(true)
            }
            Some(RotationPhase::Completed) => Ok(true),
        }
    }

    fn load_and_validate(
        &self,
        plan: &RotationPlan<'_>,
    ) -> Result<Option<RotationPhase>, RotationError> {
        let connection = self.trust.connection()?;
        let row: Option<(Vec<u8>,Vec<u8>,i64,String,Option<Vec<u8>>)> = connection.query_row(
            "SELECT from_key_id,to_key_id,roster_epoch,phase,control_hash FROM trust_rotation_journal WHERE rotation_id=?1",
            [plan.rotation_id.as_slice()], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?,row.get(4)?)),
        ).optional()?;
        let Some((from, to, epoch, phase, stored_hash)) = row else {
            return Ok(None);
        };
        if from != plan.from_key_id.0
            || to != plan.to_key_id.0
            || epoch != plan.control_record.roster_epoch as i64
            || stored_hash.as_deref()
                != Some(
                    plan.control_record
                        .domain_hash()
                        .map_err(|_| RotationError::JournalConflict)?
                        .as_slice(),
                )
        {
            return Err(RotationError::JournalConflict);
        }
        Ok(Some(
            RotationPhase::parse(&phase).ok_or(RotationError::JournalConflict)?,
        ))
    }

    fn update(
        &self,
        plan: &RotationPlan<'_>,
        from: &str,
        to: &str,
        assignments: &str,
        extra: &[&dyn rusqlite::ToSql],
    ) -> Result<(), RotationError> {
        let mut connection = self.trust.connection()?;
        let transaction = connection.transaction()?;
        let sql = if assignments.is_empty() {
            "UPDATE trust_rotation_journal SET phase=?2 WHERE rotation_id=?1 AND phase=?3"
                .to_owned()
        } else {
            format!("UPDATE trust_rotation_journal SET phase=?2,{assignments} WHERE rotation_id=?1 AND phase=?3")
        };
        let rotation_id = plan.rotation_id.as_slice();
        let mut params: Vec<&dyn rusqlite::ToSql> = vec![&rotation_id, &to, &from];
        params.extend_from_slice(extra);
        require_one(transaction.execute(&sql, params.as_slice())?)?;
        validate_schema(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    fn update_counts(
        &self,
        plan: &RotationPlan<'_>,
        from: &str,
        to: &str,
        approved: u64,
        acked: u64,
        cas: Option<CasMigrationCounts>,
    ) -> Result<(), RotationError> {
        let mut connection = self.trust.connection()?;
        let transaction = connection.transaction()?;
        let changed = if let Some(cas) = cas {
            transaction.execute("UPDATE trust_rotation_journal SET phase=?2,old_object_count=?4,inflight_count=?5,reachable_count=?6 WHERE rotation_id=?1 AND phase=?3", params![plan.rotation_id.as_slice(),to,from,i64::try_from(cas.old_key_objects).map_err(|_| RotationError::InvalidEpoch)?,i64::try_from(cas.inflight).map_err(|_| RotationError::InvalidEpoch)?,i64::try_from(cas.reachable).map_err(|_| RotationError::InvalidEpoch)?])?
        } else {
            transaction.execute("UPDATE trust_rotation_journal SET phase=?2,approved_count=?4,acked_count=?5,ack_generation=0 WHERE rotation_id=?1 AND phase=?3", params![plan.rotation_id.as_slice(),to,from,i64::try_from(approved).map_err(|_| RotationError::InvalidEpoch)?,i64::try_from(acked).map_err(|_| RotationError::InvalidEpoch)?])?
        };
        require_one(changed)?;
        validate_schema(&transaction)?;
        transaction.commit()?;
        Ok(())
    }
}

fn require_one(changed: usize) -> Result<(), RotationError> {
    if changed == 1 {
        Ok(())
    } else {
        Err(RotationError::JournalConflict)
    }
}

#[derive(Debug)]
pub enum RotationError {
    Keychain(super::KeychainError),
    Trust(TrustError),
    Sql(rusqlite::Error),
    Crypto,
    InvalidEpoch,
    JournalConflict,
    NonContributoryKey,
    AwaitingAcknowledgements,
    CasMigrationIncomplete,
    Evidence(String),
}
impl std::fmt::Display for RotationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for RotationError {}
impl From<super::KeychainError> for RotationError {
    fn from(value: super::KeychainError) -> Self {
        Self::Keychain(value)
    }
}
impl From<TrustError> for RotationError {
    fn from(value: TrustError) -> Self {
        Self::Trust(value)
    }
}
impl From<rusqlite::Error> for RotationError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Sql(value)
    }
}
impl From<CasError> for RotationError {
    fn from(value: CasError) -> Self {
        Self::Evidence(value.to_string())
    }
}
