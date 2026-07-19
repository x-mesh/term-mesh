use std::collections::VecDeque;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use quinn::{Endpoint, IdleTimeout, TransportConfig, VarInt};
use sync_protocol::{ProtocolError, SyncHello, MAX_SYNC_HELLO_BYTES};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use super::{DeviceTlsIdentity, TransportPeerSnapshot, TrustError, TrustStore};

const MAX_CONNECTIONS: usize = 32;
const MAX_BIDI_STREAMS: u32 = 16;
const MAX_UNI_STREAMS: u32 = 16;
const STREAM_RECEIVE_WINDOW: u32 = 8 * 1024 * 1024;
const CONNECTION_RECEIVE_WINDOW: u32 = 32 * 1024 * 1024;
const MAX_REPLAY_ENTRIES: usize = 4096;

#[derive(Clone, Copy, PartialEq, Eq)]
struct HelloReplayKey {
    project_id: [u8; 32],
    device_id: [u8; 32],
    roster_epoch: u64,
    nonce: [u8; 32],
}

#[derive(Default)]
struct HelloReplayCache {
    entries: std::sync::Mutex<VecDeque<HelloReplayKey>>,
}

impl HelloReplayCache {
    fn consume(&self, hello: &SyncHello) -> Result<(), TransportError> {
        let key = HelloReplayKey {
            project_id: hello.project_id,
            device_id: hello.device_id,
            roster_epoch: hello.roster_epoch,
            nonce: hello.nonce,
        };
        let mut entries = self.entries.lock().map_err(|_| TransportError::Closed)?;
        entries.retain(|entry| {
            entry.project_id != key.project_id
                || entry.device_id != key.device_id
                || entry.roster_epoch >= key.roster_epoch
        });
        if entries.contains(&key) {
            return Err(TransportError::HelloReplay);
        }
        // Same/current-epoch entries are never evicted: eviction would make an
        // old authenticated nonce replayable. A single device can exhaust this
        // global bound, but fail-closed is preferable to weakening replay safety.
        if entries.len() == MAX_REPLAY_ENTRIES {
            return Err(TransportError::ReplayCacheFull);
        }
        entries.push_back(key);
        Ok(())
    }
}

pub struct AuthenticatedConnection {
    pub connection: quinn::Connection,
    pub peer: TransportPeerSnapshot,
    /// What the peer advertised in its hello. Kept past the handshake because
    /// some wire choices are only safe once the far side has said it
    /// understands them — see `DIRECTORY_MODE_CAPABILITY`.
    pub peer_capabilities: Vec<String>,
    _permit: OwnedSemaphorePermit,
}

pub struct SyncEndpoint {
    endpoint: Endpoint,
    trust: Arc<TrustStore>,
    connections: Arc<Semaphore>,
    replays: Arc<HelloReplayCache>,
}

impl SyncEndpoint {
    #[cfg(test)]
    pub fn server_with_alpn(
        bind: SocketAddr,
        trust: Arc<TrustStore>,
        identity: &DeviceTlsIdentity,
        alpn: Vec<u8>,
    ) -> Result<Self, TransportError> {
        let config = super::transport_auth::server_config_with_alpn(trust.clone(), identity, alpn)?;
        let endpoint = Endpoint::server(config, bind)?;
        Ok(Self {
            endpoint,
            trust,
            connections: Arc::new(Semaphore::new(MAX_CONNECTIONS)),
            replays: Arc::new(HelloReplayCache::default()),
        })
    }

    pub fn server(
        bind: SocketAddr,
        trust: Arc<TrustStore>,
        identity: &DeviceTlsIdentity,
    ) -> Result<Self, TransportError> {
        let config = super::transport_auth::server_config(trust.clone(), identity)?;
        let endpoint = Endpoint::server(config, bind)?;
        Ok(Self {
            endpoint,
            trust,
            connections: Arc::new(Semaphore::new(MAX_CONNECTIONS)),
            replays: Arc::new(HelloReplayCache::default()),
        })
    }

    pub fn client(
        bind: SocketAddr,
        trust: Arc<TrustStore>,
        identity: &DeviceTlsIdentity,
    ) -> Result<Self, TransportError> {
        let mut endpoint = Endpoint::client(bind)?;
        endpoint.set_default_client_config(super::transport_auth::client_config(
            trust.clone(),
            identity,
        )?);
        Ok(Self {
            endpoint,
            trust,
            connections: Arc::new(Semaphore::new(MAX_CONNECTIONS)),
            replays: Arc::new(HelloReplayCache::default()),
        })
    }

    pub fn local_addr(&self) -> Result<SocketAddr, TransportError> {
        self.endpoint.local_addr().map_err(Into::into)
    }

    pub async fn connect(
        &self,
        remote: SocketAddr,
        hello: SyncHello,
    ) -> Result<AuthenticatedConnection, TransportError> {
        let permit = self
            .connections
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| TransportError::Closed)?;
        let connection = self.endpoint.connect(remote, "term-mesh.local")?.await?;
        super::transport_auth::verify_alpn(&connection)?;
        let peer = super::transport_auth::peer_snapshot(&connection, &self.trust)?;
        let (mut send, mut receive) = connection.open_bi().await?;
        let bytes = hello.canonical_bytes()?;
        send.write_all(&bytes).await?;
        send.finish()?;
        let response = receive.read_to_end(MAX_SYNC_HELLO_BYTES).await?;
        let response = SyncHello::decode(&response)?;
        validate_peer_hello(&response, &peer)?;
        self.trust.revalidate_transport_peer(&peer)?;
        self.replays.consume(&response)?;
        Ok(AuthenticatedConnection {
            connection,
            peer,
            peer_capabilities: response.capabilities,
            _permit: permit,
        })
    }

    pub async fn accept(
        &self,
        hello: SyncHello,
    ) -> Result<AuthenticatedConnection, TransportError> {
        let permit = self
            .connections
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| TransportError::Closed)?;
        let incoming = self.endpoint.accept().await.ok_or(TransportError::Closed)?;
        let connection = incoming.await?;
        super::transport_auth::verify_alpn(&connection)?;
        let peer = super::transport_auth::peer_snapshot(&connection, &self.trust)?;
        let (mut send, mut receive) = connection.accept_bi().await?;
        let request = receive.read_to_end(MAX_SYNC_HELLO_BYTES).await?;
        let request = SyncHello::decode(&request)?;
        validate_peer_hello(&request, &peer)?;
        self.trust.revalidate_transport_peer(&peer)?;
        self.replays.consume(&request)?;
        send.write_all(&hello.canonical_bytes()?).await?;
        send.finish()?;
        Ok(AuthenticatedConnection {
            connection,
            peer,
            peer_capabilities: request.capabilities,
            _permit: permit,
        })
    }
}

fn validate_peer_hello(
    hello: &SyncHello,
    peer: &TransportPeerSnapshot,
) -> Result<(), TransportError> {
    hello.validate_negotiation()?;
    if hello.project_id != *peer.project_id.as_bytes()
        || hello.device_id != peer.device_id
        || hello.roster_epoch != peer.roster_epoch
        || hello.nonce == [0; 32]
    {
        return Err(TransportError::HelloBinding);
    }
    Ok(())
}

pub(super) fn bounded_transport_config() -> Result<TransportConfig, TransportError> {
    let mut config = TransportConfig::default();
    config.max_concurrent_bidi_streams(VarInt::from_u32(MAX_BIDI_STREAMS));
    config.max_concurrent_uni_streams(VarInt::from_u32(MAX_UNI_STREAMS));
    config.stream_receive_window(VarInt::from_u32(STREAM_RECEIVE_WINDOW));
    config.receive_window(VarInt::from_u32(CONNECTION_RECEIVE_WINDOW));
    config.send_window(u64::from(CONNECTION_RECEIVE_WINDOW));
    config.max_idle_timeout(Some(
        IdleTimeout::try_from(Duration::from_secs(60))
            .map_err(|error| TransportError::Configuration(error.to_string()))?,
    ));
    config.keep_alive_interval(Some(Duration::from_secs(20)));
    Ok(config)
}

#[derive(Debug)]
pub enum TransportError {
    Io(std::io::Error),
    Tls(quinn::rustls::Error),
    Trust(TrustError),
    Protocol(ProtocolError),
    Connect(quinn::ConnectError),
    Connection(quinn::ConnectionError),
    Write(quinn::WriteError),
    Read(quinn::ReadToEndError),
    ClosedStream(quinn::ClosedStream),
    Configuration(String),
    MissingPeerIdentity,
    AlpnMismatch,
    HelloBinding,
    HelloReplay,
    ReplayCacheFull,
    Closed,
}

impl std::fmt::Display for TransportError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{self:?}")
    }
}
impl std::error::Error for TransportError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn hello(nonce: u8) -> SyncHello {
        SyncHello {
            project_id: [1; 32],
            device_id: [2; 32],
            roster_epoch: 1,
            selected_version: sync_protocol::PROTOCOL_V1,
            version_offers: vec![sync_protocol::PROTOCOL_V1],
            capabilities: vec![sync_protocol::PROJECT_SYNC_CAPABILITY.into()],
            nonce: [nonce; 32],
        }
    }

    fn numbered_hello(number: u64, epoch: u64) -> SyncHello {
        let mut value = hello(0);
        value.roster_epoch = epoch;
        value.nonce[..8].copy_from_slice(&number.to_be_bytes());
        value
    }

    #[test]
    fn replay_consume_is_atomic_and_epoch_scoped() {
        let cache = Arc::new(HelloReplayCache::default());
        let threads = (0..16)
            .map(|_| {
                let cache = cache.clone();
                std::thread::spawn(move || cache.consume(&hello(7)))
            })
            .collect::<Vec<_>>();
        assert_eq!(
            threads
                .into_iter()
                .map(|thread| thread.join().unwrap())
                .filter(Result::is_ok)
                .count(),
            1
        );
        assert!(cache.consume(&hello(8)).is_ok());
        let mut next_epoch = hello(7);
        next_epoch.roster_epoch = 2;
        assert!(cache.consume(&next_epoch).is_ok());
    }

    #[test]
    fn replay_capacity_fails_closed_without_evicting_first_nonce() {
        let cache = HelloReplayCache::default();
        for number in 0..MAX_REPLAY_ENTRIES as u64 {
            assert!(cache.consume(&numbered_hello(number, 1)).is_ok());
        }
        assert!(matches!(
            cache.consume(&numbered_hello(MAX_REPLAY_ENTRIES as u64, 1)),
            Err(TransportError::ReplayCacheFull)
        ));
        assert!(matches!(
            cache.consume(&numbered_hello(0, 1)),
            Err(TransportError::HelloReplay)
        ));

        assert!(cache.consume(&numbered_hello(0, 2)).is_ok());
        assert!(cache.consume(&numbered_hello(1, 2)).is_ok());
    }

    #[test]
    fn concurrent_replay_boundary_accepts_exactly_remaining_capacity() {
        let cache = Arc::new(HelloReplayCache::default());
        let prefill = MAX_REPLAY_ENTRIES - 16;
        for number in 0..prefill as u64 {
            cache.consume(&numbered_hello(number, 1)).unwrap();
        }
        let threads = (prefill as u64..prefill as u64 + 32)
            .map(|number| {
                let cache = cache.clone();
                std::thread::spawn(move || cache.consume(&numbered_hello(number, 1)))
            })
            .collect::<Vec<_>>();
        let results = threads
            .into_iter()
            .map(|thread| thread.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 16);
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, Err(TransportError::ReplayCacheFull)))
                .count(),
            16
        );
        assert_eq!(cache.entries.lock().unwrap().len(), MAX_REPLAY_ENTRIES);
    }

    #[tokio::test]
    async fn connection_semaphore_boundary_and_cancel_release() {
        let semaphore = Arc::new(Semaphore::new(MAX_CONNECTIONS));
        let mut permits = Vec::new();
        for _ in 0..MAX_CONNECTIONS {
            permits.push(semaphore.clone().acquire_owned().await.unwrap());
        }
        assert!(
            tokio::time::timeout(Duration::from_millis(20), semaphore.clone().acquire_owned())
                .await
                .is_err()
        );
        drop(permits.pop());
        assert!(
            tokio::time::timeout(Duration::from_millis(20), semaphore.clone().acquire_owned())
                .await
                .unwrap()
                .is_ok()
        );
    }
}

macro_rules! from_error {
    ($source:ty, $variant:ident) => {
        impl From<$source> for TransportError {
            fn from(value: $source) -> Self {
                Self::$variant(value)
            }
        }
    };
}
from_error!(std::io::Error, Io);
from_error!(quinn::rustls::Error, Tls);
from_error!(TrustError, Trust);
from_error!(ProtocolError, Protocol);
from_error!(quinn::ConnectError, Connect);
from_error!(quinn::ConnectionError, Connection);
from_error!(quinn::WriteError, Write);
from_error!(quinn::ReadToEndError, Read);
from_error!(quinn::ClosedStream, ClosedStream);
