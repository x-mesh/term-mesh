//! Per-project sync routing coordinates — the non-secret half of what a Sync
//! operation needs to reach a peer. Trust grants live in the [`TrustStore`](super::TrustStore),
//! the DEK and device identity in the keychain; this store holds only this
//! daemon's own device coordinates per project (which rostered device it is, at
//! which epoch) plus a peer address book. `bootstrap-trust` writes it and the
//! sync-context registry + peer resolver read it.
//!
//! Plain rusqlite (not `SecureSqlite`): the data is routing metadata, not a
//! secret, and the store lives in the daemon's 0700 state directory. Integrity
//! rests on those filesystem permissions.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OptionalExtension};

use super::PeerAddressResolver;

const SCHEMA: &str = "\
CREATE TABLE IF NOT EXISTS sync_local(\
 project_id BLOB PRIMARY KEY NOT NULL CHECK(length(project_id)=32),\
 device_id BLOB NOT NULL CHECK(length(device_id)=32),\
 roster_epoch INTEGER NOT NULL CHECK(roster_epoch>=0)\
) STRICT;\
CREATE TABLE IF NOT EXISTS sync_peer_addr(\
 peer_id TEXT PRIMARY KEY NOT NULL CHECK(length(peer_id)>0 AND length(peer_id)<=128),\
 addr TEXT NOT NULL CHECK(length(addr)>0 AND length(addr)<=256)\
) STRICT;";

#[derive(Debug, PartialEq, Eq)]
pub enum ProvisioningError {
    Storage,
    Corrupt,
}

/// This daemon's own coordinates for a project: which rostered device it is and
/// at which epoch. Feeds its `SyncHello` when it dials a peer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalCoordinates {
    pub device_id: [u8; 32],
    pub roster_epoch: u64,
}

/// The per-project routing store. `Mutex<Connection>` because a rusqlite
/// `Connection` is `Send` but not `Sync`, and the daemon shares one store.
pub struct SyncProvisioningStore {
    connection: Mutex<Connection>,
}

impl SyncProvisioningStore {
    pub fn open(path: impl Into<PathBuf>) -> Result<Self, ProvisioningError> {
        let path = path.into();
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent).map_err(|_| ProvisioningError::Storage)?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ =
                        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700));
                }
            }
        }
        let connection = Connection::open(&path).map_err(|_| ProvisioningError::Storage)?;
        connection
            .execute_batch(&format!(
                "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; {SCHEMA}"
            ))
            .map_err(|_| ProvisioningError::Storage)?;
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }

    /// Record (or replace) this daemon's coordinates for `project_id`.
    pub fn set_local(
        &self,
        project_id: [u8; 32],
        coordinates: LocalCoordinates,
    ) -> Result<(), ProvisioningError> {
        self.connection
            .lock()
            .map_err(|_| ProvisioningError::Storage)?
            .execute(
                "INSERT INTO sync_local(project_id,device_id,roster_epoch)VALUES(?1,?2,?3)\
                 ON CONFLICT(project_id)DO UPDATE SET device_id=excluded.device_id,roster_epoch=excluded.roster_epoch",
                params![
                    project_id.as_slice(),
                    coordinates.device_id.as_slice(),
                    coordinates.roster_epoch as i64
                ],
            )
            .map(|_| ())
            .map_err(|_| ProvisioningError::Storage)
    }

    /// This daemon's coordinates for `project_id`, if it has been provisioned.
    pub fn local(
        &self,
        project_id: [u8; 32],
    ) -> Result<Option<LocalCoordinates>, ProvisioningError> {
        let connection = self.connection.lock().map_err(|_| ProvisioningError::Storage)?;
        let row = connection
            .query_row(
                "SELECT device_id,roster_epoch FROM sync_local WHERE project_id=?1",
                params![project_id.as_slice()],
                |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()
            .map_err(|_| ProvisioningError::Storage)?;
        match row {
            None => Ok(None),
            Some((device, epoch)) => {
                let device_id: [u8; 32] =
                    device.try_into().map_err(|_| ProvisioningError::Corrupt)?;
                let roster_epoch = u64::try_from(epoch).map_err(|_| ProvisioningError::Corrupt)?;
                Ok(Some(LocalCoordinates {
                    device_id,
                    roster_epoch,
                }))
            }
        }
    }

    /// Record (or replace) a peer's reachable QUIC address.
    pub fn set_peer_addr(&self, peer_id: &str, addr: SocketAddr) -> Result<(), ProvisioningError> {
        self.connection
            .lock()
            .map_err(|_| ProvisioningError::Storage)?
            .execute(
                "INSERT INTO sync_peer_addr(peer_id,addr)VALUES(?1,?2)\
                 ON CONFLICT(peer_id)DO UPDATE SET addr=excluded.addr",
                params![peer_id, addr.to_string()],
            )
            .map(|_| ())
            .map_err(|_| ProvisioningError::Storage)
    }

    /// A peer's reachable QUIC address, if one has been provisioned. A stored
    /// address that no longer parses is reported as corrupt, not silently None.
    pub fn peer_addr(&self, peer_id: &str) -> Result<Option<SocketAddr>, ProvisioningError> {
        let connection = self.connection.lock().map_err(|_| ProvisioningError::Storage)?;
        let addr = connection
            .query_row(
                "SELECT addr FROM sync_peer_addr WHERE peer_id=?1",
                params![peer_id],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|_| ProvisioningError::Storage)?;
        match addr {
            None => Ok(None),
            Some(addr) => addr.parse().map(Some).map_err(|_| ProvisioningError::Corrupt),
        }
    }
}

/// A [`PeerAddressResolver`] backed by the provisioning store's address book.
pub struct ProvisioningPeerResolver {
    store: Arc<SyncProvisioningStore>,
}

impl ProvisioningPeerResolver {
    pub fn new(store: Arc<SyncProvisioningStore>) -> Self {
        Self { store }
    }
}

impl PeerAddressResolver for ProvisioningPeerResolver {
    fn resolve(&self, peer_id: &str) -> Option<SocketAddr> {
        // A storage/corrupt error resolves to "unknown peer" rather than
        // crashing the runner; the operation then fails with sync_peer_unknown.
        self.store.peer_addr(peer_id).ok().flatten()
    }
}

pub fn default_provisioning_db_path() -> PathBuf {
    if let Some(path) = std::env::var_os("TERMMESH_SYNC_PROVISIONING_DB") {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("term-mesh")
        .join("sync")
        .join("sync_provisioning.db")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_and_peer_round_trip_and_upsert() {
        let dir = tempfile::tempdir().unwrap();
        let store = SyncProvisioningStore::open(dir.path().join("prov.db")).unwrap();

        // Absent until set.
        assert_eq!(store.local([1; 32]).unwrap(), None);
        store
            .set_local(
                [1; 32],
                LocalCoordinates {
                    device_id: [2; 32],
                    roster_epoch: 3,
                },
            )
            .unwrap();
        assert_eq!(
            store.local([1; 32]).unwrap(),
            Some(LocalCoordinates {
                device_id: [2; 32],
                roster_epoch: 3,
            })
        );
        // Upsert replaces.
        store
            .set_local(
                [1; 32],
                LocalCoordinates {
                    device_id: [9; 32],
                    roster_epoch: 7,
                },
            )
            .unwrap();
        assert_eq!(store.local([1; 32]).unwrap().unwrap().roster_epoch, 7);

        let addr: SocketAddr = "127.0.0.1:4433".parse().unwrap();
        assert_eq!(store.peer_addr("peer-b").unwrap(), None);
        store.set_peer_addr("peer-b", addr).unwrap();
        assert_eq!(store.peer_addr("peer-b").unwrap(), Some(addr));

        // The resolver reads the same address book; an unknown peer is None.
        let resolver = ProvisioningPeerResolver::new(Arc::new(store));
        assert_eq!(resolver.resolve("peer-b"), Some(addr));
        assert_eq!(resolver.resolve("peer-unknown"), None);
    }

    #[test]
    fn survives_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("prov.db");
        let addr: SocketAddr = "10.0.0.1:5000".parse().unwrap();
        {
            let store = SyncProvisioningStore::open(&path).unwrap();
            store.set_peer_addr("p", addr).unwrap();
        }
        let store = SyncProvisioningStore::open(&path).unwrap();
        assert_eq!(store.peer_addr("p").unwrap(), Some(addr));
    }
}
