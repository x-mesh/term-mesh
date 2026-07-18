//! `ProvisioningSyncContextProvider` — the [`SyncContextProvider`] the daemon
//! wires behind `NetworkSyncRunner` (the core of P0). Where the runner's tests
//! hand it a fixed context, this resolves each operation's per-project
//! [`SyncContext`] from what `bootstrap-trust` actually wrote:
//!
//! - the daemon's own device coordinates from the [`SyncProvisioningStore`]
//!   (`sync_local`) — which device it is, at which epoch;
//! - its TLS identity + the project DEK from the keychain;
//! - the per-project trust store, CAS, and apply store from the standard project
//!   directory (`<sync state>/projects/<hex>/…`, see [`super::default_project_dir`]).
//!
//! A project that was never bootstrapped for sync has no `sync_local` row, so
//! `context_for` returns `sync_project_not_provisioned` rather than a context —
//! the operation then fails cleanly instead of dialing with an empty trust set.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use super::{
    load_device_tls_identity, ApplyStore, CasLimits, CasStore, KeychainBackend,
    KeychainProjectKeyProvider, ProjectId, SyncContext, SyncContextProvider, SyncProvisioningStore,
    TrustStore,
};

/// Resolves per-project [`SyncContext`]s from the provisioning store + keychain +
/// the on-disk per-project stores. `state_root` is the sync state directory the
/// project dirs hang under (injected so tests use a temp dir instead of the
/// process-wide default).
pub struct ProvisioningSyncContextProvider {
    keychain: Arc<dyn KeychainBackend>,
    provisioning: Arc<SyncProvisioningStore>,
    state_root: PathBuf,
}

impl ProvisioningSyncContextProvider {
    pub fn new(
        keychain: Arc<dyn KeychainBackend>,
        provisioning: Arc<SyncProvisioningStore>,
        state_root: impl Into<PathBuf>,
    ) -> Self {
        Self {
            keychain,
            provisioning,
            state_root: state_root.into(),
        }
    }

    fn project_dir(&self, project_id: ProjectId) -> PathBuf {
        self.state_root
            .join("projects")
            .join(hex::encode(project_id.as_bytes()))
    }
}

impl SyncContextProvider for ProvisioningSyncContextProvider {
    fn context_for(&self, project_id: &str) -> Result<Arc<SyncContext>, String> {
        let bytes = decode_project_id(project_id)?;
        let project = ProjectId::from_bytes(bytes);

        // Which device this daemon is for the project, at which epoch. No row →
        // the project was never provisioned for sync.
        let local = self
            .provisioning
            .local(bytes)
            .map_err(|_| "sync_provisioning_unavailable".to_string())?
            .ok_or_else(|| "sync_project_not_provisioned".to_string())?;

        let identity = load_device_tls_identity(&*self.keychain, bytes, local.device_id)
            .map_err(|_| "sync_identity_unavailable".to_string())?;

        let dir = self.project_dir(project);
        let trust = TrustStore::open_existing(dir.join("trust.sqlite3"), project)
            .map_err(|_| "sync_trust_unavailable".to_string())?;
        // The `SyncHello` advertises the roster's CURRENT epoch (both peers must
        // agree on the same roster version) — the trust store's latest applied
        // grant, NOT this device's own grant epoch (which may be earlier when it
        // was rostered before a later peer).
        let roster_epoch = trust
            .epoch()
            .map_err(|_| "sync_trust_unavailable".to_string())?;
        let keys = Arc::new(KeychainProjectKeyProvider::new(self.keychain.clone()));
        let cas = CasStore::open(dir.join("cas"), CasLimits::default(), keys)
            .map_err(|_| "sync_cas_unavailable".to_string())?;
        let apply_store = ApplyStore::open(dir.join("apply.db"))
            .map_err(|_| "sync_apply_store_unavailable".to_string())?;

        Ok(Arc::new(SyncContext {
            identity,
            trust: Arc::new(trust),
            device_id: local.device_id,
            project_id: bytes,
            roster_epoch,
            cas: Arc::new(cas),
            apply_store: Arc::new(Mutex::new(apply_store)),
        }))
    }
}

fn decode_project_id(value: &str) -> Result<[u8; 32], String> {
    let decoded = hex::decode(value).map_err(|_| "sync_invalid_project_id".to_string())?;
    decoded
        .try_into()
        .map_err(|_| "sync_invalid_project_id".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::{
        ensure_device_identity, generate_project_key, run_bootstrap_trust, BootstrapDevice,
        DaemonBootstrapPaths, KeychainError, KeychainItem, LocalCoordinates,
    };
    use ed25519_dalek::SigningKey;
    use std::collections::HashMap;
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

    #[test]
    fn context_for_builds_after_bootstrap_and_errors_when_unprovisioned() {
        let dir = tempfile::tempdir().unwrap();
        let state_root = dir.path().join("state");
        let recovery = SigningKey::from_bytes(&[0x81; 32]);
        let project = ProjectId::from_bytes([0x82; 32]);
        let keychain: Arc<dyn KeychainBackend> = Arc::new(MemoryKeychain::default());
        let device = [0x83; 32];

        // Identity phase, then apply phase into the standard project dir under
        // `state_root` so the provider (same root) reopens exactly these stores.
        let local_hash = ensure_device_identity(&*keychain, project, device)
            .unwrap()
            .certificate_hash();
        let paths = DaemonBootstrapPaths {
            trust_db: state_root
                .join("projects")
                .join(hex::encode(project.as_bytes()))
                .join("trust.sqlite3"),
            provisioning_db: state_root.join("prov.db"),
        };
        let dek = generate_project_key().unwrap();
        let roster = [
            BootstrapDevice { device_id: device, certificate_hash: local_hash, epoch: 1 },
            BootstrapDevice { device_id: [0x84; 32], certificate_hash: [0xcd; 32], epoch: 2 },
        ];
        run_bootstrap_trust(
            &*keychain,
            &paths,
            project,
            &recovery,
            &dek,
            LocalCoordinates { device_id: device, roster_epoch: 1 },
            &roster,
            &[],
        )
        .unwrap();

        let provisioning = Arc::new(SyncProvisioningStore::open(&paths.provisioning_db).unwrap());
        let provider =
            ProvisioningSyncContextProvider::new(keychain.clone(), provisioning, &state_root);

        let ctx = provider.context_for(&project.to_string()).unwrap();
        assert_eq!(ctx.device_id, device);
        // The current roster epoch (latest grant = the peer at 2), not this
        // device's own grant epoch (1).
        assert_eq!(ctx.roster_epoch, 2);
        assert_eq!(ctx.project_id, *project.as_bytes());
        assert_eq!(ctx.identity.certificate_hash(), local_hash);

        // A project that was never bootstrapped has no local row → not provisioned.
        let other = ProjectId::from_bytes([0x99; 32]);
        assert!(provider.context_for(&other.to_string()).is_err());
    }
}
