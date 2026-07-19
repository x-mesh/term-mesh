//! Canonical, allocation-bounded contracts for project sync.
//!
//! Decoding is deliberately pure: callers receive a fully validated value and
//! can mutate durable state only after this module returns `Ok`.

use std::fmt;

use thiserror::Error;

mod wire;
pub use wire::*;

pub const PROTOCOL_V1: u16 = 1;
pub const MAX_VERSION_OFFERS: usize = 16;
pub const CANONICAL_RECORD_FIXED_BYTES: usize = HEADER_BYTES + SIGNATURE_BYTES;
pub const MAX_RECORD_PAYLOAD_BYTES: usize = MAX_WIRE_BYTES
    - WIRE_HEADER_BYTES
    - OPLOG_BATCH_FIXED_BYTES
    - BLOB_LENGTH_PREFIX_BYTES
    - CANONICAL_RECORD_FIXED_BYTES;
pub const MAX_PAYLOAD_BYTES: usize = MAX_RECORD_PAYLOAD_BYTES;
pub const SIGNATURE_BYTES: usize = 64;
pub const ID_BYTES: usize = 32;
pub const KEY_ID_BYTES: usize = 16;
pub const CONTROL_NONCE_BYTES: usize = 32;
pub const SYNC_ALPN: &[u8] = b"term-mesh-sync/1";
pub const PROJECT_SYNC_CAPABILITY: &str = "project-sync.v1";

/// Advertised by a peer that records real directory permission bits in its
/// manifest and installs them on apply.
///
/// Gated rather than versioned because the wire is backward-compatible in only
/// one direction: a build without this rejects any non-zero directory mode
/// outright (`push_bad_mode`), so sending one to a peer that has not advertised
/// it fails the whole push. Absent the capability both sides keep sending
/// `NO_MODE`, which every build understands.
pub const DIRECTORY_MODE_CAPABILITY: &str = "dir-mode.v1";
pub const MAX_CAPABILITIES: usize = 16;
pub const MAX_CAPABILITY_BYTES: usize = 64;
pub const MAX_SYNC_HELLO_BYTES: usize = 2048;

const MAGIC: &[u8; 4] = b"TMPS";
const HEADER_BYTES: usize = 4 + 2 + 1 + 1 + ID_BYTES + ID_BYTES + 8 + 8 + 4;
const MIN_RECORD_BYTES: usize = CANONICAL_RECORD_FIXED_BYTES;
const HASH_DOMAIN: &str = "term-mesh project-sync canonical record v1";
const MAX_GIT_REF_BYTES: usize = 1024;
const ROTATION_ACK_MAGIC: &[u8; 4] = b"TMRA";
const ROTATION_ACK_BYTES: usize =
    4 + 2 + 2 + ID_BYTES + ID_BYTES + 8 + KEY_ID_BYTES + 8 + 32 + 32 + SIGNATURE_BYTES;
const SYNC_HELLO_MAGIC: &[u8; 4] = b"TMSH";
const SYNC_HELLO_FIXED_BYTES: usize = 4 + 2 + 2 + ID_BYTES + ID_BYTES + 8 + 2 + 1 + 1 + 32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncHello {
    pub project_id: [u8; ID_BYTES],
    pub device_id: [u8; ID_BYTES],
    pub roster_epoch: u64,
    pub selected_version: u16,
    pub version_offers: Vec<u16>,
    pub capabilities: Vec<String>,
    pub nonce: [u8; 32],
}

impl SyncHello {
    pub fn canonical_bytes(&self) -> Result<Vec<u8>, ProtocolError> {
        validate_hello_parts(&self.version_offers, &self.capabilities)?;
        let mut out = Vec::with_capacity(SYNC_HELLO_FIXED_BYTES + 128);
        out.extend_from_slice(SYNC_HELLO_MAGIC);
        out.extend_from_slice(&PROTOCOL_V1.to_be_bytes());
        out.extend_from_slice(&[0, 0]);
        out.extend_from_slice(&self.project_id);
        out.extend_from_slice(&self.device_id);
        out.extend_from_slice(&self.roster_epoch.to_be_bytes());
        out.extend_from_slice(&self.selected_version.to_be_bytes());
        out.push(self.version_offers.len() as u8);
        out.push(self.capabilities.len() as u8);
        out.extend_from_slice(&self.nonce);
        for version in &self.version_offers {
            out.extend_from_slice(&version.to_be_bytes());
        }
        for capability in &self.capabilities {
            out.push(capability.len() as u8);
            out.extend_from_slice(capability.as_bytes());
        }
        if out.len() > MAX_SYNC_HELLO_BYTES {
            return Err(ProtocolError::InvalidSyncHello("hello too large"));
        }
        Ok(out)
    }

    pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
        if input.len() < SYNC_HELLO_FIXED_BYTES || input.len() > MAX_SYNC_HELLO_BYTES {
            return Err(ProtocolError::InvalidSyncHello("wrong length"));
        }
        if &input[..4] != SYNC_HELLO_MAGIC || input[4..6] != PROTOCOL_V1.to_be_bytes() {
            return Err(ProtocolError::InvalidSyncHello("bad magic or version"));
        }
        if input[6..8] != [0, 0] {
            return Err(ProtocolError::InvalidSyncHello("reserved bytes"));
        }
        let mut offset = 8;
        let project_id = take_array(input, &mut offset);
        let device_id = take_array(input, &mut offset);
        let roster_epoch = u64::from_be_bytes(take_array(input, &mut offset));
        let selected_version = u16::from_be_bytes(take_array(input, &mut offset));
        let offer_count = input[offset] as usize;
        let capability_count = input[offset + 1] as usize;
        offset += 2;
        let nonce = take_array(input, &mut offset);
        if offer_count > MAX_VERSION_OFFERS || capability_count > MAX_CAPABILITIES {
            return Err(ProtocolError::InvalidSyncHello("count limit"));
        }
        let offers_end = offset
            .checked_add(offer_count * 2)
            .ok_or(ProtocolError::LengthOverflow)?;
        if offers_end > input.len() {
            return Err(ProtocolError::InvalidSyncHello("truncated offers"));
        }
        let mut version_offers = Vec::with_capacity(offer_count);
        while offset < offers_end {
            version_offers.push(u16::from_be_bytes([input[offset], input[offset + 1]]));
            offset += 2;
        }
        let mut capabilities = Vec::with_capacity(capability_count);
        for _ in 0..capability_count {
            let length = *input
                .get(offset)
                .ok_or(ProtocolError::InvalidSyncHello("truncated capability"))?
                as usize;
            offset += 1;
            if length == 0 || length > MAX_CAPABILITY_BYTES || offset + length > input.len() {
                return Err(ProtocolError::InvalidSyncHello("invalid capability length"));
            }
            let value = std::str::from_utf8(&input[offset..offset + length])
                .map_err(|_| ProtocolError::InvalidSyncHello("capability utf8"))?;
            capabilities.push(value.to_owned());
            offset += length;
        }
        if offset != input.len() {
            return Err(ProtocolError::InvalidSyncHello("trailing bytes"));
        }
        validate_hello_parts(&version_offers, &capabilities)?;
        Ok(Self {
            project_id,
            device_id,
            roster_epoch,
            selected_version,
            version_offers,
            capabilities,
            nonce,
        })
    }

    pub fn validate_negotiation(&self) -> Result<u16, ProtocolError> {
        if !self
            .capabilities
            .iter()
            .any(|value| value == PROJECT_SYNC_CAPABILITY)
        {
            return Err(ProtocolError::MissingCapability);
        }
        negotiate_version(&self.version_offers, self.selected_version)
    }
}

fn validate_hello_parts(offers: &[u16], capabilities: &[String]) -> Result<(), ProtocolError> {
    if offers.is_empty() || offers.len() > MAX_VERSION_OFFERS {
        return Err(ProtocolError::InvalidSyncHello("version offer count"));
    }
    if capabilities.len() > MAX_CAPABILITIES {
        return Err(ProtocolError::InvalidSyncHello("capability count"));
    }
    if offers.windows(2).any(|pair| pair[0] <= pair[1]) {
        return Err(ProtocolError::InvalidSyncHello(
            "version offers must be unique and descending",
        ));
    }
    if capabilities
        .windows(2)
        .any(|pair| pair[0].as_bytes() >= pair[1].as_bytes())
    {
        return Err(ProtocolError::InvalidSyncHello(
            "capabilities must be unique and sorted",
        ));
    }
    for capability in capabilities {
        if capability.is_empty()
            || capability.len() > MAX_CAPABILITY_BYTES
            || !capability.is_ascii()
        {
            return Err(ProtocolError::InvalidSyncHello("invalid capability"));
        }
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignedRotationAck {
    pub project_id: [u8; ID_BYTES],
    pub observer_device: [u8; ID_BYTES],
    pub roster_epoch: u64,
    pub key_id: [u8; KEY_ID_BYTES],
    pub generation: u64,
    pub control_hash: [u8; 32],
    pub nonce: [u8; 32],
    pub signature: [u8; SIGNATURE_BYTES],
}

impl SignedRotationAck {
    pub fn signing_preimage(&self) -> Vec<u8> {
        self.encode_with_signature([0; SIGNATURE_BYTES])
    }
    pub fn canonical_bytes(&self) -> Vec<u8> {
        self.encode_with_signature(self.signature)
    }
    pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
        if input.len() != ROTATION_ACK_BYTES {
            return Err(ProtocolError::InvalidRotationAck("wrong length"));
        }
        if &input[..4] != ROTATION_ACK_MAGIC {
            return Err(ProtocolError::InvalidRotationAck("bad magic"));
        }
        if u16::from_be_bytes(input[4..6].try_into().unwrap()) != PROTOCOL_V1
            || input[6..8] != [0, 0]
        {
            return Err(ProtocolError::InvalidRotationAck(
                "bad version or reserved bytes",
            ));
        }
        let mut offset = 8;
        let ack = Self {
            project_id: take_array(input, &mut offset),
            observer_device: take_array(input, &mut offset),
            roster_epoch: u64::from_be_bytes(take_array(input, &mut offset)),
            key_id: take_array(input, &mut offset),
            generation: u64::from_be_bytes(take_array(input, &mut offset)),
            control_hash: take_array(input, &mut offset),
            nonce: take_array(input, &mut offset),
            signature: take_array(input, &mut offset),
        };
        Ok(ack)
    }
    fn encode_with_signature(&self, signature: [u8; SIGNATURE_BYTES]) -> Vec<u8> {
        let mut out = Vec::with_capacity(ROTATION_ACK_BYTES);
        out.extend_from_slice(ROTATION_ACK_MAGIC);
        out.extend_from_slice(&PROTOCOL_V1.to_be_bytes());
        out.extend_from_slice(&[0, 0]);
        out.extend_from_slice(&self.project_id);
        out.extend_from_slice(&self.observer_device);
        out.extend_from_slice(&self.roster_epoch.to_be_bytes());
        out.extend_from_slice(&self.key_id);
        out.extend_from_slice(&self.generation.to_be_bytes());
        out.extend_from_slice(&self.control_hash);
        out.extend_from_slice(&self.nonce);
        out.extend_from_slice(&signature);
        out
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum RecordKind {
    DeviceGrant = 1,
    DeviceRevoke = 2,
    Manifest = 3,
    Oplog = 4,
    Tombstone = 5,
    Conflict = 6,
    GitRef = 7,
    Rotation = 8,
}

impl TryFrom<u8> for RecordKind {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::DeviceGrant),
            2 => Ok(Self::DeviceRevoke),
            3 => Ok(Self::Manifest),
            4 => Ok(Self::Oplog),
            5 => Ok(Self::Tombstone),
            6 => Ok(Self::Conflict),
            7 => Ok(Self::GitRef),
            8 => Ok(Self::Rotation),
            other => Err(ProtocolError::UnknownRecordKind(other)),
        }
    }
}

const CONTROL_MAGIC: &[u8; 4] = b"TMCT";
const CONTROL_HEADER_BYTES: usize = 4 + 2 + 1 + 1;
const CONTROL_COMMON_BYTES: usize =
    ID_BYTES + ID_BYTES + 8 + CONTROL_NONCE_BYTES + 32 + 32 + KEY_ID_BYTES;
const WRAPPED_DEK_BYTES: usize = 48;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlFields {
    pub project_id: [u8; ID_BYTES],
    pub device_id: [u8; ID_BYTES],
    pub roster_epoch: u64,
    pub nonce: [u8; CONTROL_NONCE_BYTES],
    pub signing_public_key: [u8; 32],
    pub agreement_public_key: [u8; 32],
    pub key_id: [u8; KEY_ID_BYTES],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceGrantPayload {
    pub fields: ControlFields,
    pub ephemeral_public_key: [u8; 32],
    pub wrap_nonce: [u8; 24],
    pub wrapped_dek: [u8; WRAPPED_DEK_BYTES],
    pub tls_certificate_hash: [u8; 32],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceRevokePayload {
    pub fields: ControlFields,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RotationPayload {
    pub fields: ControlFields,
    pub dek_commitment: [u8; 32],
}

impl DeviceGrantPayload {
    pub const ENCODED_BYTES: usize =
        CONTROL_HEADER_BYTES + CONTROL_COMMON_BYTES + 32 + 24 + 48 + 32;

    pub fn encode(&self) -> Vec<u8> {
        let mut out =
            encode_control_header(RecordKind::DeviceGrant, &self.fields, Self::ENCODED_BYTES);
        out.extend_from_slice(&self.ephemeral_public_key);
        out.extend_from_slice(&self.wrap_nonce);
        out.extend_from_slice(&self.wrapped_dek);
        out.extend_from_slice(&self.tls_certificate_hash);
        out
    }

    pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
        let fields = decode_control_fields(input, RecordKind::DeviceGrant, Self::ENCODED_BYTES)?;
        let mut offset = CONTROL_HEADER_BYTES + CONTROL_COMMON_BYTES;
        let ephemeral_public_key = take_array(input, &mut offset);
        let wrap_nonce = take_array(input, &mut offset);
        let wrapped_dek = take_array(input, &mut offset);
        let tls_certificate_hash = take_array(input, &mut offset);
        Ok(Self {
            fields,
            ephemeral_public_key,
            wrap_nonce,
            wrapped_dek,
            tls_certificate_hash,
        })
    }
}

impl DeviceRevokePayload {
    pub const ENCODED_BYTES: usize = CONTROL_HEADER_BYTES + CONTROL_COMMON_BYTES;

    pub fn encode(&self) -> Vec<u8> {
        encode_control_header(RecordKind::DeviceRevoke, &self.fields, Self::ENCODED_BYTES)
    }

    pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
        Ok(Self {
            fields: decode_control_fields(input, RecordKind::DeviceRevoke, Self::ENCODED_BYTES)?,
        })
    }
}

impl RotationPayload {
    pub const ENCODED_BYTES: usize = CONTROL_HEADER_BYTES + CONTROL_COMMON_BYTES + 32;

    pub fn encode(&self) -> Vec<u8> {
        let mut out =
            encode_control_header(RecordKind::Rotation, &self.fields, Self::ENCODED_BYTES);
        out.extend_from_slice(&self.dek_commitment);
        out
    }

    pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
        let fields = decode_control_fields(input, RecordKind::Rotation, Self::ENCODED_BYTES)?;
        let mut offset = CONTROL_HEADER_BYTES + CONTROL_COMMON_BYTES;
        Ok(Self {
            fields,
            dek_commitment: take_array(input, &mut offset),
        })
    }
}

fn encode_control_header(kind: RecordKind, fields: &ControlFields, capacity: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(capacity);
    out.extend_from_slice(CONTROL_MAGIC);
    out.extend_from_slice(&PROTOCOL_V1.to_be_bytes());
    out.push(kind as u8);
    out.push(0);
    out.extend_from_slice(&fields.project_id);
    out.extend_from_slice(&fields.device_id);
    out.extend_from_slice(&fields.roster_epoch.to_be_bytes());
    out.extend_from_slice(&fields.nonce);
    out.extend_from_slice(&fields.signing_public_key);
    out.extend_from_slice(&fields.agreement_public_key);
    out.extend_from_slice(&fields.key_id);
    out
}

fn decode_control_fields(
    input: &[u8],
    expected_kind: RecordKind,
    expected_len: usize,
) -> Result<ControlFields, ProtocolError> {
    if input.len() != expected_len {
        return Err(ProtocolError::InvalidControlPayload("wrong payload length"));
    }
    if &input[..4] != CONTROL_MAGIC {
        return Err(ProtocolError::InvalidControlPayload("bad payload magic"));
    }
    if u16::from_be_bytes([input[4], input[5]]) != PROTOCOL_V1 {
        return Err(ProtocolError::InvalidControlPayload(
            "unsupported payload version",
        ));
    }
    if input[6] != expected_kind as u8 || input[7] != 0 {
        return Err(ProtocolError::InvalidControlPayload(
            "wrong payload kind or reserved byte",
        ));
    }
    let mut offset = CONTROL_HEADER_BYTES;
    Ok(ControlFields {
        project_id: take_array(input, &mut offset),
        device_id: take_array(input, &mut offset),
        roster_epoch: {
            let bytes: [u8; 8] = take_array(input, &mut offset);
            u64::from_be_bytes(bytes)
        },
        nonce: take_array(input, &mut offset),
        signing_public_key: take_array(input, &mut offset),
        agreement_public_key: take_array(input, &mut offset),
        key_id: take_array(input, &mut offset),
    })
}

fn take_array<const N: usize>(input: &[u8], offset: &mut usize) -> [u8; N] {
    let end = *offset + N;
    let value = input[*offset..end]
        .try_into()
        .expect("validated fixed payload length");
    *offset = end;
    value
}

#[derive(Clone, PartialEq, Eq)]
pub struct CanonicalRecord {
    pub kind: RecordKind,
    pub project_id: [u8; ID_BYTES],
    pub device_id: [u8; ID_BYTES],
    pub roster_epoch: u64,
    pub sequence: u64,
    pub payload: Vec<u8>,
    pub signature: [u8; SIGNATURE_BYTES],
}

impl fmt::Debug for CanonicalRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CanonicalRecord")
            .field("kind", &self.kind)
            .field("project_id", &self.project_id)
            .field("device_id", &self.device_id)
            .field("roster_epoch", &self.roster_epoch)
            .field("sequence", &self.sequence)
            .field("payload_len", &self.payload.len())
            .field("signature", &"[redacted]")
            .finish()
    }
}

impl CanonicalRecord {
    pub fn checked_encoded_len(&self) -> Result<usize, ProtocolError> {
        if self.payload.len() > MAX_RECORD_PAYLOAD_BYTES {
            return Err(ProtocolError::PayloadTooLarge {
                actual: self.payload.len(),
                maximum: MAX_RECORD_PAYLOAD_BYTES,
            });
        }
        CANONICAL_RECORD_FIXED_BYTES
            .checked_add(self.payload.len())
            .ok_or(ProtocolError::LengthOverflow)
    }
    pub fn canonical_bytes(&self) -> Result<Vec<u8>, ProtocolError> {
        let encoded_len = self.checked_encoded_len()?;
        let mut out = Vec::with_capacity(encoded_len);
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&PROTOCOL_V1.to_be_bytes());
        out.push(self.kind as u8);
        out.push(0); // Reserved; non-zero is non-canonical in v1.
        out.extend_from_slice(&self.project_id);
        out.extend_from_slice(&self.device_id);
        out.extend_from_slice(&self.roster_epoch.to_be_bytes());
        out.extend_from_slice(&self.sequence.to_be_bytes());
        out.extend_from_slice(&(self.payload.len() as u32).to_be_bytes());
        out.extend_from_slice(&self.payload);
        out.extend_from_slice(&self.signature);
        Ok(out)
    }

    pub fn domain_hash(&self) -> Result<[u8; 32], ProtocolError> {
        Ok(blake3::derive_key(HASH_DOMAIN, &self.canonical_bytes()?))
    }

    /// Returns the exact bytes an implementation signs or verifies.
    ///
    /// This is intentionally separate from [`Self::domain_hash`]. The content
    /// hash commits to the signature, while this preimage zeroes the signature
    /// field to avoid a circular signing dependency.
    pub fn signing_preimage(&self) -> Result<Vec<u8>, ProtocolError> {
        let mut bytes = self.canonical_bytes()?;
        let signature_start = bytes.len() - SIGNATURE_BYTES;
        bytes[signature_start..].fill(0);
        Ok(bytes)
    }

    pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
        if input.len() < MIN_RECORD_BYTES {
            return Err(ProtocolError::Truncated {
                actual: input.len(),
                minimum: MIN_RECORD_BYTES,
            });
        }
        let maximum = MIN_RECORD_BYTES + MAX_PAYLOAD_BYTES;
        if input.len() > maximum {
            return Err(ProtocolError::RecordTooLarge {
                actual: input.len(),
                maximum,
            });
        }
        if &input[..4] != MAGIC {
            return Err(ProtocolError::BadMagic);
        }

        let version = u16::from_be_bytes([input[4], input[5]]);
        if version != PROTOCOL_V1 {
            return Err(ProtocolError::UnsupportedVersion(version));
        }
        let kind = RecordKind::try_from(input[6])?;
        if input[7] != 0 {
            return Err(ProtocolError::NonCanonical("reserved byte is non-zero"));
        }

        let mut project_id = [0; ID_BYTES];
        project_id.copy_from_slice(&input[8..40]);
        let mut device_id = [0; ID_BYTES];
        device_id.copy_from_slice(&input[40..72]);
        let roster_epoch = read_u64(input, 72);
        let sequence = read_u64(input, 80);
        let payload_len = read_u32(input, 88) as usize;
        if payload_len > MAX_PAYLOAD_BYTES {
            return Err(ProtocolError::PayloadTooLarge {
                actual: payload_len,
                maximum: MAX_PAYLOAD_BYTES,
            });
        }
        let expected = MIN_RECORD_BYTES
            .checked_add(payload_len)
            .ok_or(ProtocolError::LengthOverflow)?;
        if input.len() < expected {
            return Err(ProtocolError::Truncated {
                actual: input.len(),
                minimum: expected,
            });
        }
        if input.len() > expected {
            return Err(ProtocolError::NonCanonical("trailing bytes"));
        }

        let payload_end = HEADER_BYTES + payload_len;
        let payload = input[HEADER_BYTES..payload_end].to_vec();
        let mut signature = [0; SIGNATURE_BYTES];
        signature.copy_from_slice(&input[payload_end..expected]);
        Ok(Self {
            kind,
            project_id,
            device_id,
            roster_epoch,
            sequence,
            payload,
            signature,
        })
    }
}

pub fn negotiate_version(peer_offers: &[u16], peer_selected: u16) -> Result<u16, ProtocolError> {
    if peer_offers.len() > MAX_VERSION_OFFERS {
        return Err(ProtocolError::TooManyVersionOffers {
            actual: peer_offers.len(),
            maximum: MAX_VERSION_OFFERS,
        });
    }
    let required = peer_offers
        .iter()
        .copied()
        .filter(|version| *version == PROTOCOL_V1)
        .max()
        .ok_or(ProtocolError::NoCommonVersion)?;
    if peer_selected != required {
        return Err(ProtocolError::Downgrade {
            selected: peer_selected,
            required,
        });
    }
    Ok(required)
}

pub fn validate_mesh_ref(peer_id: &str, reference: &str) -> Result<(), ProtocolError> {
    if peer_id.is_empty()
        || !peer_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(ProtocolError::InvalidPeerId);
    }
    let prefix = format!("refs/mesh/{peer_id}/");
    if reference.len() > MAX_GIT_REF_BYTES
        || reference
            .bytes()
            .any(|byte| byte <= b' ' || byte == 0x7f || b"~^:?*[\\".contains(&byte))
        || reference.contains("..")
        || reference.contains("@{")
        || reference.ends_with('.')
    {
        return Err(ProtocolError::GitNamespaceViolation);
    }
    let suffix = reference
        .strip_prefix(&prefix)
        .ok_or(ProtocolError::GitNamespaceViolation)?;
    if suffix.is_empty()
        || suffix.starts_with('/')
        || suffix.ends_with('/')
        || suffix.split('/').any(|part| {
            part.is_empty()
                || part.starts_with('.')
                || part.ends_with(".lock")
                || part == "."
                || part == ".."
        })
    {
        return Err(ProtocolError::GitNamespaceViolation);
    }
    Ok(())
}

fn read_u64(input: &[u8], offset: usize) -> u64 {
    u64::from_be_bytes(
        input[offset..offset + 8]
            .try_into()
            .expect("fixed validated range"),
    )
}

fn read_u32(input: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes(
        input[offset..offset + 4]
            .try_into()
            .expect("fixed validated range"),
    )
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ProtocolError {
    #[error("record is truncated: {actual} bytes, need at least {minimum}")]
    Truncated { actual: usize, minimum: usize },
    #[error("record exceeds limit: {actual} bytes, maximum {maximum}")]
    RecordTooLarge { actual: usize, maximum: usize },
    #[error("payload exceeds limit: {actual} bytes, maximum {maximum}")]
    PayloadTooLarge { actual: usize, maximum: usize },
    #[error("record length overflow")]
    LengthOverflow,
    #[error("invalid project-sync magic")]
    BadMagic,
    #[error("unsupported project-sync version {0}")]
    UnsupportedVersion(u16),
    #[error("unknown record kind {0}")]
    UnknownRecordKind(u8),
    #[error("non-canonical record: {0}")]
    NonCanonical(&'static str),
    #[error("no mutually supported protocol version")]
    NoCommonVersion,
    #[error("downgrade rejected: selected {selected}, required {required}")]
    Downgrade { selected: u16, required: u16 },
    #[error("too many version offers: {actual}, maximum {maximum}")]
    TooManyVersionOffers { actual: usize, maximum: usize },
    #[error("invalid peer id")]
    InvalidPeerId,
    #[error("git ref is outside the peer mesh namespace")]
    GitNamespaceViolation,
    #[error("invalid control payload: {0}")]
    InvalidControlPayload(&'static str),
    #[error("invalid rotation ack: {0}")]
    InvalidRotationAck(&'static str),
    #[error("invalid sync hello: {0}")]
    InvalidSyncHello(&'static str),
    #[error("required project-sync capability is absent")]
    MissingCapability,
    #[error("invalid sync wire message: {0}")]
    InvalidWire(&'static str),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotation_ack_vector_is_canonical_and_relabel_changes_preimage() {
        let ack = SignedRotationAck {
            project_id: [1; 32],
            observer_device: [2; 32],
            roster_epoch: 3,
            key_id: [4; 16],
            generation: 5,
            control_hash: [6; 32],
            nonce: [7; 32],
            signature: [8; 64],
        };
        let encoded = ack.canonical_bytes();
        assert_eq!(encoded.len(), ROTATION_ACK_BYTES);
        assert_eq!(SignedRotationAck::decode(&encoded).unwrap(), ack);
        let preimage = ack.signing_preimage();
        for relabel in 0..3 {
            let mut changed = ack.clone();
            match relabel {
                0 => changed.key_id[0] ^= 1,
                1 => changed.generation += 1,
                2 => changed.control_hash[0] ^= 1,
                _ => unreachable!(),
            }
            assert_ne!(changed.signing_preimage(), preimage);
        }
        let mut trailing = encoded.clone();
        trailing.push(0);
        assert!(SignedRotationAck::decode(&trailing).is_err());
    }
}
