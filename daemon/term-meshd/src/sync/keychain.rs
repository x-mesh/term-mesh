use std::fmt;
use std::io;
use std::sync::{Arc, Mutex};
use zeroize::Zeroizing;

use super::{CasError, KeyId, ProjectId, ProjectKey, ProjectKeyMaterial, ProjectKeyProvider};

const TLS_IDENTITY_MAGIC: &[u8; 4] = b"TMID";
const TLS_IDENTITY_VERSION: u16 = 1;
const TLS_IDENTITY_HEADER: usize = 4 + 2 + 2 + 4 + 4 + 32;
const TLS_IDENTITY_MAX_PART: usize = 64 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeychainProtection {
    AfterFirstUnlockThisDeviceOnly,
    WhenUnlockedThisDeviceOnlyUserPresence,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeychainItem {
    pub service: String,
    pub account: String,
    pub protection: KeychainProtection,
}

pub trait KeychainBackend: Send + Sync {
    fn put(&self, item: &KeychainItem, secret: &[u8]) -> Result<(), KeychainError>;
    fn get(&self, item: &KeychainItem) -> Result<Zeroizing<Vec<u8>>, KeychainError>;
    fn delete(&self, item: &KeychainItem) -> Result<(), KeychainError>;
}

pub struct DeviceTlsIdentity {
    pub certificate_der: Vec<u8>,
    private_key_der: Zeroizing<Vec<u8>>,
}

impl DeviceTlsIdentity {
    pub fn generate() -> Result<Self, KeychainError> {
        let rcgen::CertifiedKey { cert, signing_key } =
            rcgen::generate_simple_self_signed(vec!["term-mesh.local".into()])
                .map_err(|error| KeychainError::Certificate(error.to_string()))?;
        Ok(Self {
            certificate_der: cert.der().to_vec(),
            private_key_der: Zeroizing::new(signing_key.serialize_der()),
        })
    }

    pub fn certificate_hash(&self) -> [u8; 32] {
        *blake3::hash(&self.certificate_der).as_bytes()
    }

    pub(crate) fn private_key_der(&self) -> &[u8] {
        &self.private_key_der
    }
}

pub fn persist_device_tls_identity(
    backend: &dyn KeychainBackend,
    project_id: [u8; 32],
    device_id: [u8; 32],
    identity: &DeviceTlsIdentity,
) -> Result<(), KeychainError> {
    validate_identity(identity)?;
    backend.put(
        &tls_identity_item(project_id, device_id, "tls-identity-v1"),
        &encode_identity(identity)?,
    )
}

pub fn load_device_tls_identity(
    backend: &dyn KeychainBackend,
    project_id: [u8; 32],
    device_id: [u8; 32],
) -> Result<DeviceTlsIdentity, KeychainError> {
    let envelope_item = tls_identity_item(project_id, device_id, "tls-identity-v1");
    match backend.get(&envelope_item) {
        Ok(envelope) => decode_identity(&envelope),
        Err(KeychainError::NotFound) => {
            let key_item = tls_identity_item(project_id, device_id, "tls-private-key");
            let cert_item = tls_identity_item(project_id, device_id, "tls-certificate");
            let identity = DeviceTlsIdentity {
                private_key_der: backend.get(&key_item)?,
                certificate_der: backend.get(&cert_item)?.to_vec(),
            };
            validate_identity(&identity)?;
            persist_device_tls_identity(backend, project_id, device_id, &identity)?;
            backend.delete(&key_item)?;
            backend.delete(&cert_item)?;
            Ok(identity)
        }
        Err(error) => Err(error),
    }
}

// ── Project key (CAS data-encryption key) ────────────────────────────────────
//
// The CAS encrypts every chunk under a per-project DEK. `bootstrap-trust`
// generates one random DEK per project and stores it here (both peers must hold
// the same DEK to decrypt each other's objects); `KeychainProjectKeyProvider`
// hands it to `CasStore`. v0 has exactly one key per project (no rotation).

const PROJECT_KEY_MAGIC: &[u8; 4] = b"TMDK";
const PROJECT_KEY_VERSION: u16 = 1;
/// magic(4) + version(2) + key_id(16) + key(32).
const PROJECT_KEY_ENCODED_LEN: usize = 4 + 2 + 16 + 32;

fn project_key_item(project_id: [u8; 32]) -> KeychainItem {
    KeychainItem {
        service: format!("term-mesh.sync.dek.{}", hex::encode(project_id)),
        account: "project-key-v1".into(),
        protection: KeychainProtection::AfterFirstUnlockThisDeviceOnly,
    }
}

fn encode_project_key(material: &ProjectKeyMaterial) -> Vec<u8> {
    let mut out = Vec::with_capacity(PROJECT_KEY_ENCODED_LEN);
    out.extend_from_slice(PROJECT_KEY_MAGIC);
    out.extend_from_slice(&PROJECT_KEY_VERSION.to_be_bytes());
    out.extend_from_slice(&material.key_id.0);
    out.extend_from_slice(material.key.expose_for_wrapping());
    out
}

fn decode_project_key(input: &[u8]) -> Result<ProjectKeyMaterial, KeychainError> {
    if input.len() != PROJECT_KEY_ENCODED_LEN
        || &input[..4] != PROJECT_KEY_MAGIC
        || u16::from_be_bytes([input[4], input[5]]) != PROJECT_KEY_VERSION
    {
        return Err(KeychainError::InvalidProjectKey);
    }
    let mut key_id = [0u8; 16];
    key_id.copy_from_slice(&input[6..22]);
    let mut key = [0u8; 32];
    key.copy_from_slice(&input[22..54]);
    Ok(ProjectKeyMaterial {
        key_id: KeyId(key_id),
        key: ProjectKey::new(key),
    })
}

/// A fresh random project DEK (16-byte key id + 32-byte key). The two peers of a
/// project share one DEK, so bootstrap generates it once and provisions it into
/// each daemon's keychain.
pub fn generate_project_key() -> Result<ProjectKeyMaterial, KeychainError> {
    let mut key_id = [0u8; 16];
    getrandom::getrandom(&mut key_id).map_err(|error| KeychainError::Random(error.to_string()))?;
    let mut key = [0u8; 32];
    getrandom::getrandom(&mut key).map_err(|error| KeychainError::Random(error.to_string()))?;
    Ok(ProjectKeyMaterial {
        key_id: KeyId(key_id),
        key: ProjectKey::new(key),
    })
}

pub fn persist_project_key(
    backend: &dyn KeychainBackend,
    project_id: [u8; 32],
    material: &ProjectKeyMaterial,
) -> Result<(), KeychainError> {
    backend.put(&project_key_item(project_id), &encode_project_key(material))
}

pub fn load_project_key(
    backend: &dyn KeychainBackend,
    project_id: [u8; 32],
) -> Result<ProjectKeyMaterial, KeychainError> {
    let raw = backend.get(&project_key_item(project_id))?;
    decode_project_key(&raw)
}

/// A [`ProjectKeyProvider`] backed by the keychain: `CasStore` reads each
/// project's DEK (provisioned by `bootstrap-trust`) through this. A project with
/// no provisioned key, or a request for an unknown key id, surfaces as a
/// `CasError` so the CAS operation fails cleanly rather than with a wrong key.
pub struct KeychainProjectKeyProvider {
    backend: Arc<dyn KeychainBackend>,
}

impl KeychainProjectKeyProvider {
    pub fn new(backend: Arc<dyn KeychainBackend>) -> Self {
        Self { backend }
    }
}

impl ProjectKeyProvider for KeychainProjectKeyProvider {
    fn current_project_key(&self, project_id: ProjectId) -> Result<ProjectKeyMaterial, CasError> {
        load_project_key(self.backend.as_ref(), *project_id.as_bytes())
            .map_err(|_| CasError::Io(io::Error::other("project_key_unavailable")))
    }

    fn project_key(&self, project_id: ProjectId, key_id: KeyId) -> Result<ProjectKey, CasError> {
        let material = load_project_key(self.backend.as_ref(), *project_id.as_bytes())
            .map_err(|_| CasError::Io(io::Error::other("project_key_unavailable")))?;
        if material.key_id == key_id {
            Ok(material.key)
        } else {
            Err(CasError::Io(io::Error::other("project_key_id_unknown")))
        }
    }
}

fn encode_identity(identity: &DeviceTlsIdentity) -> Result<Vec<u8>, KeychainError> {
    if identity.private_key_der.len() > TLS_IDENTITY_MAX_PART
        || identity.certificate_der.len() > TLS_IDENTITY_MAX_PART
    {
        return Err(KeychainError::InvalidTlsIdentity);
    }
    let mut out = Vec::with_capacity(
        TLS_IDENTITY_HEADER + identity.private_key_der.len() + identity.certificate_der.len() + 32,
    );
    out.extend_from_slice(TLS_IDENTITY_MAGIC);
    out.extend_from_slice(&TLS_IDENTITY_VERSION.to_be_bytes());
    out.extend_from_slice(&[0, 0]);
    out.extend_from_slice(&(identity.private_key_der.len() as u32).to_be_bytes());
    out.extend_from_slice(&(identity.certificate_der.len() as u32).to_be_bytes());
    out.extend_from_slice(&identity.certificate_hash());
    out.extend_from_slice(identity.private_key_der());
    out.extend_from_slice(&identity.certificate_der);
    let integrity = blake3::hash(&out);
    out.extend_from_slice(integrity.as_bytes());
    Ok(out)
}

fn decode_identity(input: &[u8]) -> Result<DeviceTlsIdentity, KeychainError> {
    if input.len() < TLS_IDENTITY_HEADER + 32 || &input[..4] != TLS_IDENTITY_MAGIC {
        return Err(KeychainError::InvalidTlsIdentity);
    }
    if u16::from_be_bytes([input[4], input[5]]) != TLS_IDENTITY_VERSION || input[6..8] != [0, 0] {
        return Err(KeychainError::InvalidTlsIdentity);
    }
    let key_len = u32::from_be_bytes(input[8..12].try_into().unwrap()) as usize;
    let cert_len = u32::from_be_bytes(input[12..16].try_into().unwrap()) as usize;
    if key_len == 0
        || cert_len == 0
        || key_len > TLS_IDENTITY_MAX_PART
        || cert_len > TLS_IDENTITY_MAX_PART
    {
        return Err(KeychainError::InvalidTlsIdentity);
    }
    let expected = TLS_IDENTITY_HEADER
        .checked_add(key_len)
        .and_then(|n| n.checked_add(cert_len))
        .and_then(|n| n.checked_add(32))
        .ok_or(KeychainError::InvalidTlsIdentity)?;
    if input.len() != expected
        || blake3::hash(&input[..expected - 32]).as_bytes() != &input[expected - 32..]
    {
        return Err(KeychainError::InvalidTlsIdentity);
    }
    let key_end = TLS_IDENTITY_HEADER + key_len;
    let cert_end = key_end + cert_len;
    let identity = DeviceTlsIdentity {
        private_key_der: Zeroizing::new(input[TLS_IDENTITY_HEADER..key_end].to_vec()),
        certificate_der: input[key_end..cert_end].to_vec(),
    };
    if identity.certificate_hash().as_slice() != &input[16..48] {
        return Err(KeychainError::InvalidTlsIdentity);
    }
    validate_identity(&identity)?;
    Ok(identity)
}

fn validate_identity(identity: &DeviceTlsIdentity) -> Result<(), KeychainError> {
    use rcgen::PublicKeyData;
    let key = rcgen::KeyPair::try_from(identity.private_key_der())
        .map_err(|_| KeychainError::InvalidTlsIdentity)?;
    let certificate_spki = certificate_spki(&identity.certificate_der)?;
    if certificate_spki != key.subject_public_key_info() {
        return Err(KeychainError::InvalidTlsIdentity);
    }
    Ok(())
}

fn certificate_spki(certificate: &[u8]) -> Result<&[u8], KeychainError> {
    let (_, cert_content, cert_end) = der_item(certificate, 0)?;
    if cert_end != certificate.len() {
        return Err(KeychainError::InvalidTlsIdentity);
    }
    let (_, tbs_content, _) = der_item(certificate, cert_content)?;
    let mut offset = tbs_content;
    if certificate.get(offset) == Some(&0xa0) {
        offset = der_item(certificate, offset)?.2;
    }
    for _ in 0..5 {
        offset = der_item(certificate, offset)?.2;
    }
    let start = offset;
    let (tag, _, end) = der_item(certificate, offset)?;
    if tag != 0x30 {
        return Err(KeychainError::InvalidTlsIdentity);
    }
    Ok(&certificate[start..end])
}

fn der_item(input: &[u8], offset: usize) -> Result<(u8, usize, usize), KeychainError> {
    let tag = *input.get(offset).ok_or(KeychainError::InvalidTlsIdentity)?;
    let first = *input
        .get(offset + 1)
        .ok_or(KeychainError::InvalidTlsIdentity)?;
    let (length, header) = if first & 0x80 == 0 {
        (first as usize, 2)
    } else {
        let count = (first & 0x7f) as usize;
        if count == 0 || count > 4 {
            return Err(KeychainError::InvalidTlsIdentity);
        }
        let mut value = 0usize;
        for byte in input
            .get(offset + 2..offset + 2 + count)
            .ok_or(KeychainError::InvalidTlsIdentity)?
        {
            value = value
                .checked_mul(256)
                .and_then(|v| v.checked_add(*byte as usize))
                .ok_or(KeychainError::InvalidTlsIdentity)?;
        }
        (value, 2 + count)
    };
    let content = offset
        .checked_add(header)
        .ok_or(KeychainError::InvalidTlsIdentity)?;
    let end = content
        .checked_add(length)
        .filter(|end| *end <= input.len())
        .ok_or(KeychainError::InvalidTlsIdentity)?;
    Ok((tag, content, end))
}

fn tls_identity_item(project_id: [u8; 32], device_id: [u8; 32], account: &str) -> KeychainItem {
    KeychainItem {
        service: format!(
            "term-mesh.sync.tls.{}.{}",
            hex::encode(project_id),
            hex::encode(device_id)
        ),
        account: account.into(),
        protection: KeychainProtection::AfterFirstUnlockThisDeviceOnly,
    }
}

pub trait RandomSource: Send + Sync {
    fn fill(&self, output: &mut [u8]) -> Result<(), KeychainError>;
}

pub struct SystemRandom;

impl RandomSource for SystemRandom {
    fn fill(&self, output: &mut [u8]) -> Result<(), KeychainError> {
        getrandom::getrandom(output).map_err(|error| KeychainError::Random(error.to_string()))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PresenceAction {
    ExportRecovery,
    ImportRecovery,
    RevokeDevice,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PresenceGrantContext {
    pub action: PresenceAction,
    pub project_id: [u8; 32],
    pub target_id: [u8; 32],
    pub material_digest: [u8; 32],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct BoundPresenceContext {
    request: PresenceGrantContext,
    trusted_uid: u32,
}

pub trait PeerIdentityProvider: Send + Sync {
    fn trusted_uid(&self) -> Result<u32, KeychainError>;
}

pub struct PresenceCapability {
    token: [u8; 32],
    context: BoundPresenceContext,
}

/// Mints a process-local, action-bound capability only after a protected
/// Keychain sentinel read succeeds. RPC possession or the caller UID alone is
/// therefore insufficient for recovery export/import or device revocation.
pub struct UserPresenceAuthorizer<B, R, P> {
    backend: B,
    random: R,
    peer_identity: P,
    daemon_uid: u32,
    outstanding: Mutex<Vec<PresenceCapability>>,
}

impl<B: KeychainBackend, R: RandomSource, P: PeerIdentityProvider> UserPresenceAuthorizer<B, R, P> {
    pub fn new(backend: B, random: R, peer_identity: P, daemon_uid: u32) -> Self {
        Self {
            backend,
            random,
            peer_identity,
            daemon_uid,
            outstanding: Mutex::new(Vec::new()),
        }
    }

    pub fn authorize(
        &self,
        context: PresenceGrantContext,
    ) -> Result<PresenceCapability, KeychainError> {
        let trusted_uid = self.peer_identity.trusted_uid()?;
        if trusted_uid != self.daemon_uid {
            return Err(KeychainError::UntrustedPeer);
        }
        let context = BoundPresenceContext {
            request: context,
            trusted_uid,
        };
        let sentinel = self
            .backend
            .get(&presence_sentinel_item(context.request.project_id))?;
        if sentinel.is_empty() {
            return Err(KeychainError::InvalidSentinel);
        }
        let mut token = [0; 32];
        self.random.fill(&mut token)?;
        let mut outstanding = self
            .outstanding
            .lock()
            .map_err(|_| KeychainError::Poisoned)?;
        if outstanding
            .iter()
            .any(|entry| constant_time_eq(&entry.token, &token))
        {
            return Err(KeychainError::RandomCollision);
        }
        outstanding.push(PresenceCapability { token, context });
        Ok(PresenceCapability { token, context })
    }

    pub fn consume(
        &self,
        capability: PresenceCapability,
        expected: PresenceGrantContext,
    ) -> Result<(), KeychainError> {
        let trusted_uid = self.peer_identity.trusted_uid()?;
        let expected = BoundPresenceContext {
            request: expected,
            trusted_uid,
        };
        let mut outstanding = self
            .outstanding
            .lock()
            .map_err(|_| KeychainError::Poisoned)?;
        let mut found = None;
        for (index, entry) in outstanding.iter().enumerate() {
            if constant_time_eq(&entry.token, &capability.token) {
                found = Some(index);
            }
        }
        let actual = found.map(|index| outstanding.swap_remove(index));
        if capability.context != expected
            || actual.as_ref().map(|grant| grant.context) != Some(expected)
        {
            return Err(KeychainError::WrongCapability);
        }
        Ok(())
    }
}

fn constant_time_eq(left: &[u8; 32], right: &[u8; 32]) -> bool {
    left.iter()
        .zip(right)
        .fold(0_u8, |difference, (a, b)| difference | (a ^ b))
        == 0
}

fn presence_sentinel_item(project_id: [u8; 32]) -> KeychainItem {
    KeychainItem {
        service: format!("term-mesh.sync.recovery.{}", hex::encode(project_id)),
        account: "presence-sentinel".into(),
        protection: KeychainProtection::WhenUnlockedThisDeviceOnlyUserPresence,
    }
}

#[cfg(target_os = "macos")]
pub struct MacOsKeychain;

// Apple Security.framework SecBase.h: errSecItemNotFound.
#[cfg(target_os = "macos")]
const ERR_SEC_ITEM_NOT_FOUND: i32 = -25300;

#[cfg(target_os = "macos")]
impl MacOsKeychain {
    fn query(
        item: &KeychainItem,
        include_access_control: bool,
    ) -> Result<security_framework::passwords::PasswordOptions, KeychainError> {
        use security_framework::access_control::{ProtectionMode, SecAccessControl};
        use security_framework::passwords::{AccessControlOptions, PasswordOptions};

        let mut options = PasswordOptions::new_generic_password(&item.service, &item.account);
        options.set_access_synchronized(Some(false));
        options.use_protected_keychain();
        if include_access_control {
            let (protection, flags) = match item.protection {
                KeychainProtection::AfterFirstUnlockThisDeviceOnly => (
                    ProtectionMode::AccessibleAfterFirstUnlockThisDeviceOnly,
                    AccessControlOptions::empty(),
                ),
                KeychainProtection::WhenUnlockedThisDeviceOnlyUserPresence => (
                    ProtectionMode::AccessibleWhenUnlockedThisDeviceOnly,
                    AccessControlOptions::USER_PRESENCE,
                ),
            };
            let access = SecAccessControl::create_with_protection(Some(protection), flags.bits())
                .map_err(|error| KeychainError::Platform(error.to_string()))?;
            options.set_access_control(access);
        }
        Ok(options)
    }

    fn normalize_delete_result(
        result: security_framework::base::Result<()>,
    ) -> Result<(), KeychainError> {
        match result {
            Ok(()) => Ok(()),
            Err(error) if error.code() == ERR_SEC_ITEM_NOT_FOUND => Ok(()),
            Err(error) => Err(KeychainError::Platform(error.to_string())),
        }
    }
}

#[cfg(target_os = "macos")]
impl KeychainBackend for MacOsKeychain {
    fn put(&self, item: &KeychainItem, secret: &[u8]) -> Result<(), KeychainError> {
        security_framework::passwords::set_generic_password_options(
            secret,
            Self::query(item, true)?,
        )
        .map_err(|error| KeychainError::Platform(error.to_string()))
    }

    fn get(&self, item: &KeychainItem) -> Result<Zeroizing<Vec<u8>>, KeychainError> {
        match security_framework::passwords::generic_password(Self::query(item, false)?) {
            Ok(secret) => Ok(Zeroizing::new(secret)),
            Err(error) if error.code() == ERR_SEC_ITEM_NOT_FOUND => Err(KeychainError::NotFound),
            Err(error) => Err(KeychainError::Platform(error.to_string())),
        }
    }

    fn delete(&self, item: &KeychainItem) -> Result<(), KeychainError> {
        Self::normalize_delete_result(
            security_framework::passwords::delete_generic_password_options(Self::query(
                item, false,
            )?),
        )
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum KeychainError {
    NotFound,
    Platform(String),
    Random(String),
    InvalidSentinel,
    WrongCapability,
    ConsumedCapability,
    RandomCollision,
    MaterialDigestMismatch,
    UntrustedPeer,
    Poisoned,
    Certificate(String),
    InvalidTlsIdentity,
    InvalidProjectKey,
}

impl fmt::Display for KeychainError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for KeychainError {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct MemoryKeychain {
        values: Mutex<HashMap<(String, String), Vec<u8>>>,
    }

    impl KeychainBackend for MemoryKeychain {
        fn put(&self, item: &KeychainItem, secret: &[u8]) -> Result<(), KeychainError> {
            self.values
                .lock()
                .map_err(|_| KeychainError::Poisoned)?
                .insert(
                    (item.service.clone(), item.account.clone()),
                    secret.to_vec(),
                );
            Ok(())
        }

        fn get(&self, item: &KeychainItem) -> Result<Zeroizing<Vec<u8>>, KeychainError> {
            self.values
                .lock()
                .map_err(|_| KeychainError::Poisoned)?
                .get(&(item.service.clone(), item.account.clone()))
                .cloned()
                .map(Zeroizing::new)
                .ok_or(KeychainError::NotFound)
        }

        fn delete(&self, item: &KeychainItem) -> Result<(), KeychainError> {
            self.values
                .lock()
                .map_err(|_| KeychainError::Poisoned)?
                .remove(&(item.service.clone(), item.account.clone()));
            Ok(())
        }
    }

    #[test]
    fn tls_identity_round_trips_only_through_keychain_backend() {
        let backend = MemoryKeychain::default();
        let identity = DeviceTlsIdentity::generate().unwrap();
        let expected_hash = identity.certificate_hash();
        persist_device_tls_identity(&backend, [1; 32], [2; 32], &identity).unwrap();
        let loaded = load_device_tls_identity(&backend, [1; 32], [2; 32]).unwrap();
        assert_eq!(loaded.certificate_hash(), expected_hash);
        assert_eq!(loaded.private_key_der(), identity.private_key_der());
        assert!(matches!(
            load_device_tls_identity(&backend, [1; 32], [3; 32]),
            Err(KeychainError::NotFound)
        ));
    }

    #[test]
    fn project_key_round_trips_and_provider_answers_only_the_current_id() {
        let backend = std::sync::Arc::new(MemoryKeychain::default());
        let material = generate_project_key().unwrap();
        let key_id = material.key_id;
        let key_bytes = *material.key.expose_for_wrapping();
        persist_project_key(backend.as_ref(), [7; 32], &material).unwrap();

        // Round-trips through the keychain, byte-for-byte.
        let loaded = load_project_key(backend.as_ref(), [7; 32]).unwrap();
        assert_eq!(loaded.key_id, key_id);
        assert_eq!(loaded.key.expose_for_wrapping(), &key_bytes);

        let provider = KeychainProjectKeyProvider::new(backend.clone());
        let project = ProjectId::from_bytes([7; 32]);
        // Current key resolves; the same key id resolves to the same bytes.
        assert_eq!(provider.current_project_key(project).unwrap().key_id, key_id);
        assert_eq!(
            provider.project_key(project, key_id).unwrap().expose_for_wrapping(),
            &key_bytes
        );
        // An unknown key id and an unprovisioned project both fail cleanly.
        assert!(provider.project_key(project, KeyId([0xff; 16])).is_err());
        assert!(provider
            .current_project_key(ProjectId::from_bytes([9; 32]))
            .is_err());
    }

    #[test]
    fn tls_identity_envelope_detects_corruption_and_migrates_legacy_atomically() {
        let backend = MemoryKeychain::default();
        let identity = DeviceTlsIdentity::generate().unwrap();
        let key = tls_identity_item([1; 32], [2; 32], "tls-private-key");
        let cert = tls_identity_item([1; 32], [2; 32], "tls-certificate");
        backend.put(&key, identity.private_key_der()).unwrap();
        backend.put(&cert, &identity.certificate_der).unwrap();
        let loaded = load_device_tls_identity(&backend, [1; 32], [2; 32]).unwrap();
        assert_eq!(loaded.certificate_hash(), identity.certificate_hash());
        assert_eq!(backend.get(&key), Err(KeychainError::NotFound));
        assert_eq!(backend.get(&cert), Err(KeychainError::NotFound));

        let envelope = tls_identity_item([1; 32], [2; 32], "tls-identity-v1");
        let mut values = backend.values.lock().unwrap();
        values
            .get_mut(&(envelope.service.clone(), envelope.account.clone()))
            .unwrap()[20] ^= 1;
        drop(values);
        assert!(matches!(
            load_device_tls_identity(&backend, [1; 32], [2; 32]),
            Err(KeychainError::InvalidTlsIdentity)
        ));
    }

    struct FailEnvelope(MemoryKeychain);
    impl KeychainBackend for FailEnvelope {
        fn put(&self, item: &KeychainItem, secret: &[u8]) -> Result<(), KeychainError> {
            if item.account == "tls-identity-v1" {
                Err(KeychainError::Platform("injected put failure".into()))
            } else {
                self.0.put(item, secret)
            }
        }
        fn get(&self, item: &KeychainItem) -> Result<Zeroizing<Vec<u8>>, KeychainError> {
            self.0.get(item)
        }
        fn delete(&self, item: &KeychainItem) -> Result<(), KeychainError> {
            self.0.delete(item)
        }
    }

    #[test]
    fn failed_legacy_migration_preserves_both_old_items() {
        let backend = FailEnvelope(MemoryKeychain::default());
        let identity = DeviceTlsIdentity::generate().unwrap();
        let key = tls_identity_item([3; 32], [4; 32], "tls-private-key");
        let cert = tls_identity_item([3; 32], [4; 32], "tls-certificate");
        backend.0.put(&key, identity.private_key_der()).unwrap();
        backend.0.put(&cert, &identity.certificate_der).unwrap();
        assert!(matches!(
            load_device_tls_identity(&backend, [3; 32], [4; 32]),
            Err(KeychainError::Platform(_))
        ));
        assert!(backend.get(&key).is_ok());
        assert!(backend.get(&cert).is_ok());
    }

    struct Sentinel;
    impl KeychainBackend for Sentinel {
        fn put(&self, _: &KeychainItem, _: &[u8]) -> Result<(), KeychainError> {
            Ok(())
        }
        fn get(&self, _: &KeychainItem) -> Result<Zeroizing<Vec<u8>>, KeychainError> {
            Ok(Zeroizing::new(vec![1]))
        }
        fn delete(&self, _: &KeychainItem) -> Result<(), KeychainError> {
            Ok(())
        }
    }
    struct FixedRandom;
    impl RandomSource for FixedRandom {
        fn fill(&self, output: &mut [u8]) -> Result<(), KeychainError> {
            output.fill(7);
            Ok(())
        }
    }
    #[derive(Clone, Copy)]
    struct Identity(u32);
    impl PeerIdentityProvider for Identity {
        fn trusted_uid(&self) -> Result<u32, KeychainError> {
            Ok(self.0)
        }
    }

    fn context(action: PresenceAction) -> PresenceGrantContext {
        PresenceGrantContext {
            action,
            project_id: [1; 32],
            target_id: [2; 32],
            material_digest: [3; 32],
        }
    }

    #[test]
    fn presence_capability_is_action_bound_and_single_use() {
        let auth = UserPresenceAuthorizer::new(Sentinel, FixedRandom, Identity(501), 501);
        let wrong = auth
            .authorize(context(PresenceAction::ExportRecovery))
            .unwrap();
        assert_eq!(
            auth.consume(wrong, context(PresenceAction::RevokeDevice)),
            Err(KeychainError::WrongCapability)
        );
        let capability = auth
            .authorize(context(PresenceAction::RevokeDevice))
            .unwrap();
        assert_eq!(
            auth.consume(capability, context(PresenceAction::RevokeDevice)),
            Ok(())
        );
        assert_eq!(
            auth.consume(
                PresenceCapability {
                    token: [7; 32],
                    context: BoundPresenceContext {
                        request: context(PresenceAction::RevokeDevice),
                        trusted_uid: 501,
                    },
                },
                context(PresenceAction::RevokeDevice),
            ),
            Err(KeychainError::WrongCapability)
        );
    }

    #[test]
    fn presence_grant_rejects_cross_context_and_concurrent_replay() {
        use std::sync::Arc;
        use std::thread;
        for mutate in 0..3 {
            let auth = UserPresenceAuthorizer::new(Sentinel, FixedRandom, Identity(501), 501);
            let expected = context(PresenceAction::RevokeDevice);
            let capability = auth.authorize(expected).unwrap();
            let mut wrong = expected;
            match mutate {
                0 => wrong.project_id[0] ^= 1,
                1 => wrong.target_id[0] ^= 1,
                2 => wrong.material_digest[0] ^= 1,
                _ => unreachable!(),
            }
            assert_eq!(
                auth.consume(capability, wrong),
                Err(KeychainError::WrongCapability)
            );
            assert_eq!(
                auth.consume(
                    PresenceCapability {
                        token: [7; 32],
                        context: BoundPresenceContext {
                            request: expected,
                            trusted_uid: 501,
                        },
                    },
                    expected,
                ),
                Err(KeychainError::WrongCapability)
            );
        }

        let auth = Arc::new(UserPresenceAuthorizer::new(
            Sentinel,
            FixedRandom,
            Identity(501),
            501,
        ));
        let expected = context(PresenceAction::RevokeDevice);
        let capability = auth.authorize(expected).unwrap();
        let duplicate = PresenceCapability {
            token: capability.token,
            context: capability.context,
        };
        let first = {
            let auth = auth.clone();
            thread::spawn(move || auth.consume(capability, expected))
        };
        let second = {
            let auth = auth.clone();
            thread::spawn(move || auth.consume(duplicate, expected))
        };
        let results = [first.join().unwrap(), second.join().unwrap()];
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    }

    struct Cancelled;
    impl KeychainBackend for Cancelled {
        fn put(&self, _: &KeychainItem, _: &[u8]) -> Result<(), KeychainError> {
            Err(KeychainError::Platform("OSStatus -128 userCanceled".into()))
        }
        fn get(&self, _: &KeychainItem) -> Result<Zeroizing<Vec<u8>>, KeychainError> {
            Err(KeychainError::Platform("OSStatus -128 userCanceled".into()))
        }
        fn delete(&self, _: &KeychainItem) -> Result<(), KeychainError> {
            Err(KeychainError::Platform(
                "OSStatus -25300 itemNotFound".into(),
            ))
        }
    }

    #[test]
    fn keychain_cancel_and_osstatus_fail_closed_without_fallback() {
        let auth = UserPresenceAuthorizer::new(Cancelled, FixedRandom, Identity(501), 501);
        assert!(
            matches!(auth.authorize(context(PresenceAction::ExportRecovery)), Err(KeychainError::Platform(message)) if message.contains("-128"))
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_delete_is_idempotent_only_for_item_not_found() {
        use security_framework::base::Error;

        assert_eq!(MacOsKeychain::normalize_delete_result(Ok(())), Ok(()));
        assert_eq!(
            MacOsKeychain::normalize_delete_result(Err(Error::from_code(ERR_SEC_ITEM_NOT_FOUND))),
            Ok(())
        );
        assert!(matches!(
            MacOsKeychain::normalize_delete_result(Err(Error::from_code(libc::EPERM))),
            Err(KeychainError::Platform(_))
        ));
    }

    #[test]
    fn trusted_peer_uid_mismatch_fails_before_keychain_prompt() {
        let auth = UserPresenceAuthorizer::new(Sentinel, FixedRandom, Identity(502), 501);
        assert_eq!(
            auth.authorize(context(PresenceAction::ExportRecovery))
                .err(),
            Some(KeychainError::UntrustedPeer)
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "requires a codesigned test host with Keychain data-protection entitlement; plain cargo test returns errSecMissingEntitlement"]
    fn macos_background_keychain_smoke_is_non_prompting() {
        let backend = MacOsKeychain;
        let item = KeychainItem {
            service: format!(
                "term-mesh.test.{}.{}",
                std::process::id(),
                std::thread::current().name().unwrap_or("keychain")
            ),
            account: "background-smoke".into(),
            protection: KeychainProtection::AfterFirstUnlockThisDeviceOnly,
        };
        struct Cleanup<'a>(&'a MacOsKeychain, KeychainItem);
        impl Drop for Cleanup<'_> {
            fn drop(&mut self) {
                let _ = self.0.delete(&self.1);
            }
        }
        let cleanup = Cleanup(&backend, item.clone());
        backend.put(&item, b"temporary-secret").unwrap();
        assert_eq!(backend.get(&item).unwrap().as_slice(), b"temporary-secret");
        backend.delete(&item).unwrap();
        std::mem::forget(cleanup);
    }

    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "manual UserPresence prompt/cancel: cd daemon && cargo test -p term-meshd keychain::tests::macos_user_presence_prompt_cancel_manual -- --ignored --nocapture"]
    fn macos_user_presence_prompt_cancel_manual() {
        let backend = MacOsKeychain;
        let item = presence_sentinel_item([0xfe; 32]);
        struct Cleanup<'a>(&'a MacOsKeychain, KeychainItem);
        impl Drop for Cleanup<'_> {
            fn drop(&mut self) {
                let _ = self.0.delete(&self.1);
            }
        }
        let _cleanup = Cleanup(&backend, item.clone());
        backend.put(&item, b"manual-sentinel").unwrap();
        let result = backend.get(&item);
        match result {
            Ok(secret) => println!("UserPresence result: success ({} bytes)", secret.len()),
            Err(KeychainError::Platform(message)) if message.contains("-128") => {
                println!("UserPresence result: user canceled (-128)")
            }
            Err(KeychainError::Platform(message)) if message.contains("-34018") => {
                println!("UserPresence result: missing entitlement (-34018)")
            }
            other => panic!("unexpected UserPresence result: {other:?}"),
        }
    }
}
