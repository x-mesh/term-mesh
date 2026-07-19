//! Dev/test-grade mutual-trust provisioning for the mesh sync transport
//! (Phase S0 of `docs/design/mesh-project-sync-wiring-plan.md`).
//!
//! In production a device is approved through an interactive user-presence +
//! Keychain flow that guards the project **recovery key** (the `pairing.*` RPCs,
//! currently stubbed `USER_PRESENCE_REQUIRED`). That gate protects the recovery
//! key itself — **not** the grant mechanism: a device becomes `approved` by
//! applying a recovery-key-signed [`DeviceGrant`](RecordKind::DeviceGrant)
//! [`CanonicalRecord`] via [`TrustStore::apply_control_record`], which verifies a
//! real ed25519 signature against the store's `recovery_signing_public`.
//!
//! This module drives exactly that mechanism with a **directly supplied**
//! recovery key, so an explicit-endpoint bootstrap between two already-known
//! machines can establish mutual trust without the interactive flow. The crypto
//! is real; the only dev-grade concession is that the caller holds the recovery
//! key. When `pairing.approve` is wired to a real user-presence flow (Phase S4)
//! it will call the same `apply_control_record` path — this helper is the seam,
//! not a backdoor around it.

use ed25519_dalek::{Signer, SigningKey};
use sync_protocol::{CanonicalRecord, ControlFields, DeviceGrantPayload, RecordKind};

use super::{ProjectId, TrustError, TrustStore};

/// One device participating in a bootstrapped roster.
///
/// A grant needs only the device's *certificate hash*, not its private TLS key —
/// so a daemon can grant a **remote** peer it knows only by hash (the private key
/// never leaves the peer's machine). The local device supplies the full identity
/// elsewhere (to persist its private half); here every roster member, local or
/// remote, is just `(device_id, certificate_hash, epoch)`.
#[derive(Debug, Clone, Copy)]
pub struct BootstrapDevice {
    /// Stable 32-byte device id. In this dev bootstrap it also seeds the
    /// device's control signing key (`SigningKey::from_bytes(device_id)`),
    /// matching the roster-test convention; production derives that key
    /// independently and grants carry its public half.
    pub device_id: [u8; 32],
    /// The device's TLS certificate hash (`DeviceTlsIdentity::certificate_hash`),
    /// pinned into every roster member's trust store so the QUIC handshake can
    /// authorize it.
    pub certificate_hash: [u8; 32],
    /// Monotonic roster epoch at which this device is granted. Must be `> 0` and
    /// strictly increasing across the roster (grants apply in epoch order).
    pub epoch: u64,
}

/// Build a recovery-key-signed `DeviceGrant` record for `device`.
///
/// The `ephemeral_public_key` / `wrap_nonce` / `wrapped_dek` fields carry the
/// per-device DEK-wrap in production; for the S0 transport bring-up (no data
/// encryption yet) they are fixed placeholders — the transport only consumes the
/// `tls_certificate_hash` + signing key from the applied grant.
fn signed_grant(
    recovery: &SigningKey,
    project_id: [u8; 32],
    device: &BootstrapDevice,
) -> CanonicalRecord {
    let signing = SigningKey::from_bytes(&device.device_id);
    let fields = ControlFields {
        project_id,
        device_id: device.device_id,
        roster_epoch: device.epoch,
        nonce: [device.epoch as u8; 32],
        signing_public_key: signing.verifying_key().to_bytes(),
        agreement_public_key: [device.epoch as u8; 32],
        key_id: [9; 16],
    };
    let payload = DeviceGrantPayload {
        fields: fields.clone(),
        ephemeral_public_key: [3; 32],
        wrap_nonce: [4; 24],
        wrapped_dek: [5; 48],
        tls_certificate_hash: device.certificate_hash,
    }
    .encode();
    let mut record = CanonicalRecord {
        kind: RecordKind::DeviceGrant,
        project_id,
        device_id: device.device_id,
        roster_epoch: device.epoch,
        sequence: device.epoch,
        payload,
        signature: [0; 64],
    };
    record.signature = recovery
        .sign(
            &record
                .signing_preimage()
                .expect("device-grant signing preimage is always encodable"),
        )
        .to_bytes();
    record
}

/// Apply every roster member's grant to `store`, so it trusts the whole roster
/// (including itself). Grants apply in ascending epoch order to respect the
/// store's monotonic roster epoch. Idempotent per the underlying
/// `apply_control_record` (re-applying a grant updates in place).
pub fn seed_trust_store(
    store: &TrustStore,
    project_id: ProjectId,
    recovery: &SigningKey,
    devices: &[BootstrapDevice],
) -> Result<(), TrustError> {
    let project_bytes = *project_id.as_bytes();
    let mut ordered: Vec<&BootstrapDevice> = devices.iter().collect();
    ordered.sort_by_key(|device| device.epoch);
    for device in ordered {
        store.apply_control_record(&signed_grant(recovery, project_bytes, device))?;
    }
    Ok(())
}
