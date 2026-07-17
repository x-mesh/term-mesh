//! Phase S0 end-to-end check for the mesh sync transport wiring
//! (`docs/design/mesh-project-sync-wiring-plan.md`).
//!
//! Proves the pipe: two independent daemons bootstrap mutual trust with real
//! recovery-key-signed grants (no interactive user-presence), complete the
//! mutual-pinned QUIC handshake, and round-trip lane-tagged messages **both
//! directions** through the `SyncConnection` lane↔QUIC pump — the piece that did
//! not exist before S0. No project data yet (that is S1/S2).

#[path = "../src/sync/mod.rs"]
mod sync;

use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use ed25519_dalek::SigningKey;
use sync::{
    seed_trust_store, BootstrapDevice, DeviceTlsIdentity, ProjectId, StreamLane, SyncConnection,
    SyncEndpoint, TrustStore,
};
use sync_protocol::{SyncHello, PROJECT_SYNC_CAPABILITY, PROTOCOL_V1};

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

async fn recv_one(conn: &mut SyncConnection) -> (StreamLane, Vec<u8>) {
    tokio::time::timeout(Duration::from_secs(5), conn.recv())
        .await
        .expect("recv timed out")
        .expect("connection closed before a message arrived")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn s0_two_daemons_bootstrap_trust_and_round_trip_lane_messages() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x41; 32]);
    let project = [0x42; 32];
    let device_a = [0x43; 32];
    let device_b = [0x44; 32];
    let identity_a = DeviceTlsIdentity::generate().unwrap();
    let identity_b = DeviceTlsIdentity::generate().unwrap();
    let project_id = ProjectId::from_bytes(project);

    // Both daemons open a trust store pinned to the same recovery key, then seed
    // the full roster (device A @ epoch 1, device B @ epoch 2) into each — the
    // D3 bootstrap: real ed25519 grants, recovery key supplied directly.
    let trust_a = Arc::new(
        TrustStore::open(
            temporary.path().join("a.sqlite3"),
            project_id,
            recovery.verifying_key().to_bytes(),
        )
        .unwrap(),
    );
    let trust_b = Arc::new(
        TrustStore::open(
            temporary.path().join("b.sqlite3"),
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

    // Stand up both endpoints and complete the mutual-pinned handshake.
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
    let accepted = accepted.expect("server accept");
    let connected = connected.expect("client connect");
    assert_eq!(accepted.peer.device_id, device_b);
    assert_eq!(connected.peer.device_id, device_a);

    // Wrap each side in the lane↔QUIC pump.
    let mut server_conn = SyncConnection::start(accepted);
    let mut client_conn = SyncConnection::start(connected);
    assert_eq!(server_conn.peer().device_id, device_b);
    assert_eq!(client_conn.peer().device_id, device_a);

    // client → server on the control lane.
    let ping = b"s0-control-ping".to_vec();
    client_conn.send(StreamLane::Control, ping.clone()).await.unwrap();
    let (lane, payload) = recv_one(&mut server_conn).await;
    assert_eq!(lane, StreamLane::Control);
    assert_eq!(payload, ping);

    // server → client on the control lane (both directions through the pump).
    let pong = b"s0-control-pong".to_vec();
    server_conn.send(StreamLane::Control, pong.clone()).await.unwrap();
    let (lane, payload) = recv_one(&mut client_conn).await;
    assert_eq!(lane, StreamLane::Control);
    assert_eq!(payload, pong);

    // A different lane demuxes independently and preserves its tag.
    let op = b"s0-sync-operation-frame".to_vec();
    client_conn.send(StreamLane::SyncOperation, op.clone()).await.unwrap();
    let (lane, payload) = recv_one(&mut server_conn).await;
    assert_eq!(lane, StreamLane::SyncOperation);
    assert_eq!(payload, op);
}
