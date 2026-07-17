//! Phase S2a end-to-end check: an encrypted CAS object transfers from a source
//! peer to a destination peer over the Blob lane and reproduces byte-identically
//! — the first "bytes move" milestone. (`docs/design/mesh-project-sync-wiring-plan.md`.)

#[path = "../src/sync/mod.rs"]
mod sync;

use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;

use ed25519_dalek::SigningKey;
use sync::{
    put_plaintext, recv_object, seed_trust_store, send_object, BootstrapDevice, CasError, CasLimits,
    CasStore, DeviceTlsIdentity, KeyId, ObjectDomain, ObjectType, ProjectId, ProjectKey,
    ProjectKeyMaterial, ProjectKeyProvider, SyncConnection, SyncEndpoint, TrustStore,
};
use sync_protocol::{SyncHello, PROJECT_SYNC_CAPABILITY, PROTOCOL_V1};

/// A single fixed project key shared by both CAS stores, reconstructed on each
/// call (ProjectKey is not Clone). This is the shared-project-key assumption the
/// blob transfer relies on.
struct FixedKeyProvider {
    bytes: [u8; 32],
    key_id: KeyId,
}

impl ProjectKeyProvider for FixedKeyProvider {
    fn current_project_key(&self, _project: ProjectId) -> Result<ProjectKeyMaterial, CasError> {
        Ok(ProjectKeyMaterial {
            key_id: self.key_id,
            key: ProjectKey::new(self.bytes),
        })
    }
    fn project_key(&self, _project: ProjectId, _key_id: KeyId) -> Result<ProjectKey, CasError> {
        Ok(ProjectKey::new(self.bytes))
    }
}

fn hello(project: [u8; 32], device: [u8; 32], epoch: u64, nonce: u8) -> SyncHello {
    SyncHello {
        project_id: project,
        device_id: device,
        roster_epoch: epoch,
        selected_version: PROTOCOL_V1,
        version_offers: vec![PROTOCOL_V1],
        capabilities: vec![PROJECT_SYNC_CAPABILITY.into()],
        nonce: [nonce; 32],
    }
}

fn cas(dir: &std::path::Path) -> CasStore {
    let provider = Arc::new(FixedKeyProvider {
        bytes: [0x5c; 32],
        key_id: KeyId([0x11; 16]),
    });
    CasStore::open(dir, CasLimits::default(), provider).unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn encrypted_object_transfers_over_blob_lane_byte_identically() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x41; 32]);
    let project = [0x42; 32];
    let device_a = [0x43; 32];
    let device_b = [0x44; 32];
    let identity_a = DeviceTlsIdentity::generate().unwrap();
    let identity_b = DeviceTlsIdentity::generate().unwrap();
    let project_id = ProjectId::from_bytes(project);

    let trust_a = Arc::new(
        TrustStore::open(
            temporary.path().join("trust_a.sqlite3"),
            project_id,
            recovery.verifying_key().to_bytes(),
        )
        .unwrap(),
    );
    let trust_b = Arc::new(
        TrustStore::open(
            temporary.path().join("trust_b.sqlite3"),
            project_id,
            recovery.verifying_key().to_bytes(),
        )
        .unwrap(),
    );
    let roster = [
        BootstrapDevice {
            device_id: device_a,
            identity: &identity_a,
            epoch: 1,
        },
        BootstrapDevice {
            device_id: device_b,
            identity: &identity_b,
            epoch: 2,
        },
    ];
    seed_trust_store(&trust_a, project_id, &recovery, &roster).unwrap();
    seed_trust_store(&trust_b, project_id, &recovery, &roster).unwrap();

    // Two CAS stores sharing one project key. The source (server side) holds the
    // object; the destination (client side) receives it.
    let cas_source = cas(&temporary.path().join("cas_source"));
    let cas_dest = cas(&temporary.path().join("cas_dest"));
    let domain = ObjectDomain {
        project_id,
        object_type: ObjectType::FILE,
        version: 1,
    };

    // A >4 MiB payload so the transfer spans multiple chunks.
    let plaintext: Vec<u8> = (0..(4 * 1024 * 1024 + 1000))
        .map(|i| (i % 251) as u8)
        .collect();
    let object_id = put_plaintext(
        &cas_source,
        domain,
        &ProjectKey::new([0x5c; 32]),
        KeyId([0x11; 16]),
        &plaintext,
    )
    .unwrap();

    // Bring up the authenticated QUIC connection.
    let server = SyncEndpoint::server(
        SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
        trust_a.clone(),
        &identity_a,
    )
    .unwrap();
    let client = SyncEndpoint::client(
        SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
        trust_b.clone(),
        &identity_b,
    )
    .unwrap();
    let address = server.local_addr().unwrap();
    let (accepted, connected) = tokio::join!(
        server.accept(hello(project, device_a, 2, 1)),
        client.connect(address, hello(project, device_b, 2, 2)),
    );
    let conn_source = SyncConnection::start(accepted.unwrap());
    let mut conn_dest = SyncConnection::start(connected.unwrap());

    // Transfer: source streams chunks while dest stages them.
    let (send_result, recv_result) = tokio::join!(
        send_object(&conn_source, &cas_source, domain, object_id, plaintext.len() as u64),
        recv_object(&mut conn_dest, &cas_dest, domain, object_id, plaintext.len() as u64),
    );
    send_result.expect("send_object");
    recv_result.expect("recv_object");

    // The object reproduces byte-identically in the destination CAS.
    let mut reproduced = Vec::new();
    let copied = cas_dest
        .copy_verified_plaintext(domain, object_id, &mut reproduced)
        .expect("copy_verified_plaintext on dest");
    assert_eq!(copied as usize, plaintext.len());
    assert_eq!(reproduced, plaintext, "transferred object differs from source");
}
