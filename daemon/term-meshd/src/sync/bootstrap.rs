//! Piece 3 of the P2 sync-transport provisioning track: the **bootstrap-trust
//! flow** that composes the individually-built pieces (trust grants, keychain
//! identity + DEK, provisioning coordinates + peer address book) into the single
//! act of making a project sync-ready on a daemon — and, as a convenience for
//! the dev/test explicit-endpoint bootstrap, doing it symmetrically across two
//! daemons at once.
//!
//! Nothing here is new mechanism; it is the wiring that turns the S0 recipe
//! (`docs/design/mesh-project-sync-wiring-plan.md` §6 D3) into one call:
//!
//! 1. **Trust** — pin every roster member's recovery-key-signed `DeviceGrant`
//!    into the store ([`seed_trust_store`]), so the daemon trusts itself and its
//!    peers for the QUIC handshake.
//! 2. **Keychain** — persist this daemon's own TLS identity
//!    ([`persist_device_tls_identity`]) and the project's shared DEK
//!    ([`persist_project_key`]); both peers of a project hold the *same* DEK so
//!    each can decrypt the other's CAS chunks.
//! 3. **Provisioning** — record this daemon's own sync coordinates
//!    ([`SyncProvisioningStore::set_local`]) and each peer's reachable QUIC
//!    address ([`SyncProvisioningStore::set_peer_addr`]).
//!
//! The dev-grade concession is the same one [`seed_trust_store`] documents: the
//! caller supplies the project **recovery signing key** directly instead of
//! going through the interactive user-presence/Keychain flow (Phase S4). The
//! crypto is otherwise real. The sync-context registry (P0) reads exactly what
//! this writes; `tm-agent sync bootstrap-trust` (piece 4) drives it.

use std::net::SocketAddr;

use ed25519_dalek::SigningKey;

use super::{
    generate_project_key, persist_device_tls_identity, persist_project_key, seed_trust_store,
    BootstrapDevice, DeviceTlsIdentity, KeychainBackend, KeychainError, LocalCoordinates, ProjectId,
    ProjectKeyMaterial, ProvisioningError, SyncProvisioningStore, TrustError, TrustStore,
};

/// A failure at one of the three provisioning stores. Composition stops at the
/// first error; a partially-provisioned daemon is possible, so the caller should
/// treat a bootstrap failure as "re-run" (every write is idempotent/upsert).
#[derive(Debug)]
pub enum BootstrapError {
    /// Roster epochs must be non-zero and distinct across devices (grants apply
    /// in strictly-ascending epoch order — see [`BootstrapDevice::epoch`]).
    InvalidRoster,
    Trust(TrustError),
    Keychain(KeychainError),
    Provisioning(ProvisioningError),
}

impl From<TrustError> for BootstrapError {
    fn from(error: TrustError) -> Self {
        BootstrapError::Trust(error)
    }
}

impl From<KeychainError> for BootstrapError {
    fn from(error: KeychainError) -> Self {
        BootstrapError::Keychain(error)
    }
}

impl From<ProvisioningError> for BootstrapError {
    fn from(error: ProvisioningError) -> Self {
        BootstrapError::Provisioning(error)
    }
}

/// The stores and coordinates that belong to **one** daemon being provisioned.
/// The recovery key, DEK, roster, and project id are shared inputs passed
/// alongside (they are identical across the roster); this bundles only what is
/// this daemon's own.
pub struct DaemonProvisioning<'a> {
    /// This daemon's keychain (its TLS private key + the shared DEK land here).
    pub keychain: &'a dyn KeychainBackend,
    /// This daemon's per-project trust store (opened with the roster's recovery
    /// public key). Every roster grant is applied to it.
    pub trust: &'a TrustStore,
    /// This daemon's routing store (its own coordinates + the peer address book).
    pub provisioning: &'a SyncProvisioningStore,
    /// This daemon's stable device id — its `sync_local` coordinate and, in the
    /// dev bootstrap, the seed of its control signing key (see [`BootstrapDevice`]).
    pub device_id: [u8; 32],
    /// This daemon's own TLS identity; its private half is persisted here and its
    /// certificate hash is pinned into every roster member's trust store (via the
    /// matching `roster` entry).
    pub identity: &'a DeviceTlsIdentity,
    /// The epoch at which THIS daemon is rostered — recorded as its local
    /// coordinate and stamped into its outbound `SyncHello`.
    pub roster_epoch: u64,
    /// Peers this daemon can dial: `(peer id used in `sync.start`, reachable QUIC
    /// address)`. For a two-daemon project this is the single other daemon.
    pub peers: &'a [(String, SocketAddr)],
}

/// Make a project sync-ready on a single daemon: pin the whole roster's trust
/// grants, persist this daemon's TLS identity and the shared project DEK, and
/// record its routing coordinates + peer address book. Every write is an
/// upsert, so re-running is safe.
///
/// `roster` must list **every** participating device (including this one), each
/// with its TLS identity and epoch — the trust store trusts exactly this set.
/// `dek` is the project's single shared data-encryption key; pass the *same*
/// material to every daemon of the project.
pub fn provision_daemon(
    project_id: ProjectId,
    recovery: &SigningKey,
    dek: &ProjectKeyMaterial,
    roster: &[BootstrapDevice<'_>],
    daemon: &DaemonProvisioning<'_>,
) -> Result<(), BootstrapError> {
    let project_bytes = *project_id.as_bytes();

    // 1. Trust — pin every roster member's grant (self + peers) so the QUIC
    //    handshake authorizes them. Grants apply in ascending epoch order.
    seed_trust_store(daemon.trust, project_id, recovery, roster)?;

    // 2. Keychain — this daemon's own TLS private key + the shared project DEK.
    persist_device_tls_identity(daemon.keychain, project_bytes, daemon.device_id, daemon.identity)?;
    persist_project_key(daemon.keychain, project_bytes, dek)?;

    // 3. Provisioning — this daemon's own coordinates + where its peers live.
    daemon.provisioning.set_local(
        project_bytes,
        LocalCoordinates {
            device_id: daemon.device_id,
            roster_epoch: daemon.roster_epoch,
        },
    )?;
    for (peer_id, addr) in daemon.peers {
        daemon.provisioning.set_peer_addr(peer_id, *addr)?;
    }

    Ok(())
}

/// One daemon in a two-daemon bootstrap: its identity + epoch, the id/address
/// under which the *other* daemon reaches it, and its three stores.
pub struct BootstrapPeer<'a> {
    /// This daemon's stable device id.
    pub device_id: [u8; 32],
    /// This daemon's own TLS identity (generated locally on its machine).
    pub identity: &'a DeviceTlsIdentity,
    /// This daemon's roster epoch. Must be non-zero and differ from the peer's.
    pub epoch: u64,
    /// The peer id string the *other* daemon passes to `sync.start` to reach this
    /// one; stored in the other daemon's address book against `reachable_addr`.
    pub sync_peer_id: String,
    /// This daemon's reachable QUIC endpoint, recorded in the peer's address book.
    pub reachable_addr: SocketAddr,
    pub keychain: &'a dyn KeychainBackend,
    pub trust: &'a TrustStore,
    pub provisioning: &'a SyncProvisioningStore,
}

/// Provision one project symmetrically across two daemons in a single call: both
/// device grants land in both trust stores, one freshly-generated DEK is shared
/// by both keychains, and each daemon's address book points at the other. Returns
/// the shared DEK so a single-process bootstrap (a test or the hidden hardware-e2e
/// CLI) can build CAS stores that agree on the key without re-reading a keychain.
///
/// This is the "provisions a project across two daemons" entry point; for a real
/// cross-machine bootstrap where each daemon writes its own state, call
/// [`provision_daemon`] on each side with a roster the recovery-key holder built
/// from both cert hashes.
pub fn bootstrap_two_daemons(
    project_id: ProjectId,
    recovery: &SigningKey,
    a: &BootstrapPeer<'_>,
    b: &BootstrapPeer<'_>,
) -> Result<ProjectKeyMaterial, BootstrapError> {
    if a.epoch == 0 || b.epoch == 0 || a.epoch == b.epoch {
        return Err(BootstrapError::InvalidRoster);
    }

    // One DEK for the project — generated once here so both keychains hold
    // byte-identical material (each side must decrypt the other's CAS chunks).
    let dek = generate_project_key()?;

    // The roster both daemons trust: each device's grant carries its own cert
    // hash + signing key, so each store authorizes the whole set.
    let roster = [
        BootstrapDevice {
            device_id: a.device_id,
            identity: a.identity,
            epoch: a.epoch,
        },
        BootstrapDevice {
            device_id: b.device_id,
            identity: b.identity,
            epoch: b.epoch,
        },
    ];

    // A dials B (B's id → B's addr); B dials A. Each store learns only the other.
    provision_daemon(
        project_id,
        recovery,
        &dek,
        &roster,
        &DaemonProvisioning {
            keychain: a.keychain,
            trust: a.trust,
            provisioning: a.provisioning,
            device_id: a.device_id,
            identity: a.identity,
            roster_epoch: a.epoch,
            peers: &[(b.sync_peer_id.clone(), b.reachable_addr)],
        },
    )?;
    provision_daemon(
        project_id,
        recovery,
        &dek,
        &roster,
        &DaemonProvisioning {
            keychain: b.keychain,
            trust: b.trust,
            provisioning: b.provisioning,
            device_id: b.device_id,
            identity: b.identity,
            roster_epoch: b.epoch,
            peers: &[(a.sync_peer_id.clone(), a.reachable_addr)],
        },
    )?;

    Ok(dek)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::{load_project_key, KeychainItem};
    use std::collections::HashMap;
    use std::sync::Mutex;
    use zeroize::Zeroizing;

    #[derive(Default)]
    struct MemoryKeychain {
        values: Mutex<HashMap<(String, String), Vec<u8>>>,
    }

    impl KeychainBackend for MemoryKeychain {
        fn put(&self, item: &KeychainItem, secret: &[u8]) -> Result<(), KeychainError> {
            self.values
                .lock()
                .map_err(|_| KeychainError::Poisoned)?
                .insert((item.service.clone(), item.account.clone()), secret.to_vec());
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

    fn open_trust(dir: &std::path::Path, name: &str, project: ProjectId, recovery: &SigningKey) -> TrustStore {
        TrustStore::open(
            dir.join(name),
            project,
            recovery.verifying_key().to_bytes(),
        )
        .unwrap()
    }

    #[test]
    fn provision_daemon_writes_trust_keychain_and_provisioning() {
        let dir = tempfile::tempdir().unwrap();
        let recovery = SigningKey::from_bytes(&[0x41; 32]);
        let project = ProjectId::from_bytes([0x42; 32]);
        let device_self = [0x43; 32];
        let device_peer = [0x44; 32];
        let identity_self = DeviceTlsIdentity::generate().unwrap();
        let identity_peer = DeviceTlsIdentity::generate().unwrap();

        let keychain = MemoryKeychain::default();
        let trust = open_trust(dir.path(), "trust.sqlite3", project, &recovery);
        let provisioning = SyncProvisioningStore::open(dir.path().join("prov.db")).unwrap();
        let dek = generate_project_key().unwrap();

        let roster = [
            BootstrapDevice { device_id: device_self, identity: &identity_self, epoch: 1 },
            BootstrapDevice { device_id: device_peer, identity: &identity_peer, epoch: 2 },
        ];
        let addr: SocketAddr = "10.0.0.9:4433".parse().unwrap();
        provision_daemon(
            project,
            &recovery,
            &dek,
            &roster,
            &DaemonProvisioning {
                keychain: &keychain,
                trust: &trust,
                provisioning: &provisioning,
                device_id: device_self,
                identity: &identity_self,
                roster_epoch: 1,
                peers: &[("peer-b".to_string(), addr)],
            },
        )
        .unwrap();

        // Trust: the store authorizes both its own and the peer's certificate.
        assert!(trust
            .authorize_transport_certificate(&identity_self.certificate_der)
            .is_ok());
        assert!(trust
            .authorize_transport_certificate(&identity_peer.certificate_der)
            .is_ok());

        // Keychain: the shared DEK round-trips.
        let loaded = load_project_key(&keychain, *project.as_bytes()).unwrap();
        assert_eq!(loaded.key_id, dek.key_id);

        // Provisioning: own coordinates + the peer address book.
        assert_eq!(
            provisioning.local(*project.as_bytes()).unwrap(),
            Some(LocalCoordinates { device_id: device_self, roster_epoch: 1 })
        );
        assert_eq!(provisioning.peer_addr("peer-b").unwrap(), Some(addr));
    }

    #[test]
    fn bootstrap_two_daemons_is_symmetric_and_shares_one_dek() {
        let dir = tempfile::tempdir().unwrap();
        let recovery = SigningKey::from_bytes(&[0x51; 32]);
        let project = ProjectId::from_bytes([0x52; 32]);
        let identity_a = DeviceTlsIdentity::generate().unwrap();
        let identity_b = DeviceTlsIdentity::generate().unwrap();

        let keychain_a = MemoryKeychain::default();
        let keychain_b = MemoryKeychain::default();
        let trust_a = open_trust(dir.path(), "trust_a.sqlite3", project, &recovery);
        let trust_b = open_trust(dir.path(), "trust_b.sqlite3", project, &recovery);
        let prov_a = SyncProvisioningStore::open(dir.path().join("prov_a.db")).unwrap();
        let prov_b = SyncProvisioningStore::open(dir.path().join("prov_b.db")).unwrap();

        let addr_a: SocketAddr = "127.0.0.1:5001".parse().unwrap();
        let addr_b: SocketAddr = "127.0.0.1:5002".parse().unwrap();

        let peer_a = BootstrapPeer {
            device_id: [0x53; 32],
            identity: &identity_a,
            epoch: 1,
            sync_peer_id: "daemon-a".to_string(),
            reachable_addr: addr_a,
            keychain: &keychain_a,
            trust: &trust_a,
            provisioning: &prov_a,
        };
        let peer_b = BootstrapPeer {
            device_id: [0x54; 32],
            identity: &identity_b,
            epoch: 2,
            sync_peer_id: "daemon-b".to_string(),
            reachable_addr: addr_b,
            keychain: &keychain_b,
            trust: &trust_b,
            provisioning: &prov_b,
        };

        let dek = bootstrap_two_daemons(project, &recovery, &peer_a, &peer_b).unwrap();

        // Each trust store authorizes both certificates.
        for trust in [&trust_a, &trust_b] {
            assert!(trust.authorize_transport_certificate(&identity_a.certificate_der).is_ok());
            assert!(trust.authorize_transport_certificate(&identity_b.certificate_der).is_ok());
        }

        // Both keychains hold the same DEK the call returned.
        let dek_a = load_project_key(&keychain_a, *project.as_bytes()).unwrap();
        let dek_b = load_project_key(&keychain_b, *project.as_bytes()).unwrap();
        assert_eq!(dek_a.key_id, dek.key_id);
        assert_eq!(dek_b.key_id, dek.key_id);

        // Each daemon's address book points at the *other* one, not itself.
        assert_eq!(prov_a.peer_addr("daemon-b").unwrap(), Some(addr_b));
        assert_eq!(prov_a.peer_addr("daemon-a").unwrap(), None);
        assert_eq!(prov_b.peer_addr("daemon-a").unwrap(), Some(addr_a));
        assert_eq!(prov_b.peer_addr("daemon-b").unwrap(), None);

        // Each records its own local coordinates at its own epoch.
        assert_eq!(prov_a.local(*project.as_bytes()).unwrap().unwrap().roster_epoch, 1);
        assert_eq!(prov_b.local(*project.as_bytes()).unwrap().unwrap().roster_epoch, 2);
    }

    #[test]
    fn rejects_zero_or_equal_epochs() {
        let dir = tempfile::tempdir().unwrap();
        let recovery = SigningKey::from_bytes(&[0x61; 32]);
        let project = ProjectId::from_bytes([0x62; 32]);
        let identity_a = DeviceTlsIdentity::generate().unwrap();
        let identity_b = DeviceTlsIdentity::generate().unwrap();
        let keychain_a = MemoryKeychain::default();
        let keychain_b = MemoryKeychain::default();
        let trust_a = open_trust(dir.path(), "ta.sqlite3", project, &recovery);
        let trust_b = open_trust(dir.path(), "tb.sqlite3", project, &recovery);
        let prov_a = SyncProvisioningStore::open(dir.path().join("pa.db")).unwrap();
        let prov_b = SyncProvisioningStore::open(dir.path().join("pb.db")).unwrap();

        let build = |epoch_a: u64, epoch_b: u64| {
            let a = BootstrapPeer {
                device_id: [0x63; 32],
                identity: &identity_a,
                epoch: epoch_a,
                sync_peer_id: "a".to_string(),
                reachable_addr: "127.0.0.1:1".parse().unwrap(),
                keychain: &keychain_a,
                trust: &trust_a,
                provisioning: &prov_a,
            };
            let b = BootstrapPeer {
                device_id: [0x64; 32],
                identity: &identity_b,
                epoch: epoch_b,
                sync_peer_id: "b".to_string(),
                reachable_addr: "127.0.0.1:2".parse().unwrap(),
                keychain: &keychain_b,
                trust: &trust_b,
                provisioning: &prov_b,
            };
            bootstrap_two_daemons(project, &recovery, &a, &b)
        };

        assert!(matches!(build(0, 2), Err(BootstrapError::InvalidRoster)));
        assert!(matches!(build(1, 1), Err(BootstrapError::InvalidRoster)));
    }
}
