#[path = "../src/sync/mod.rs"]
mod sync;

use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Instant;

use ed25519_dalek::{Signer, SigningKey};
use sync::{DeviceTlsIdentity, ProjectId, StreamLane, StreamRouter, SyncEndpoint, TrustStore};
use sync_protocol::{
    CanonicalRecord, ControlFields, DeviceGrantPayload, DeviceRevokePayload, RecordKind, SyncHello,
    PROJECT_SYNC_CAPABILITY, PROTOCOL_V1,
};

fn control_fields(
    project_id: [u8; 32],
    device_id: [u8; 32],
    epoch: u64,
    nonce: u8,
    signing_public_key: [u8; 32],
) -> ControlFields {
    ControlFields {
        project_id,
        device_id,
        roster_epoch: epoch,
        nonce: [nonce; 32],
        signing_public_key,
        agreement_public_key: [nonce.wrapping_add(1); 32],
        key_id: [9; 16],
    }
}

fn signed_control(
    recovery: &SigningKey,
    kind: RecordKind,
    fields: &ControlFields,
    payload: Vec<u8>,
) -> CanonicalRecord {
    let mut record = CanonicalRecord {
        kind,
        project_id: fields.project_id,
        device_id: fields.device_id,
        roster_epoch: fields.roster_epoch,
        sequence: fields.roster_epoch,
        payload,
        signature: [0; 64],
    };
    record.signature = recovery
        .sign(&record.signing_preimage().unwrap())
        .to_bytes();
    record
}

fn grant(
    recovery: &SigningKey,
    project_id: [u8; 32],
    device_id: [u8; 32],
    epoch: u64,
    identity: &DeviceTlsIdentity,
) -> CanonicalRecord {
    let signing = SigningKey::from_bytes(&device_id);
    let fields = control_fields(
        project_id,
        device_id,
        epoch,
        epoch as u8,
        signing.verifying_key().to_bytes(),
    );
    signed_control(
        recovery,
        RecordKind::DeviceGrant,
        &fields,
        DeviceGrantPayload {
            fields: fields.clone(),
            ephemeral_public_key: [3; 32],
            wrap_nonce: [4; 24],
            wrapped_dek: [5; 48],
            tls_certificate_hash: identity.certificate_hash(),
        }
        .encode(),
    )
}

fn hello(project_id: [u8; 32], device_id: [u8; 32], epoch: u64, nonce: u8) -> SyncHello {
    SyncHello {
        project_id,
        device_id,
        roster_epoch: epoch,
        selected_version: PROTOCOL_V1,
        version_offers: vec![PROTOCOL_V1],
        capabilities: vec![PROJECT_SYNC_CAPABILITY.into()],
        nonce: [nonce; 32],
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn loopback_quic_requires_mutual_pin_and_revalidates_revocation() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x41; 32]);
    let project = [0x42; 32];
    let device_a = [0x43; 32];
    let device_b = [0x44; 32];
    let identity_a = DeviceTlsIdentity::generate().unwrap();
    let identity_b = DeviceTlsIdentity::generate().unwrap();

    let trust_a = Arc::new(
        TrustStore::open(
            temporary.path().join("a.sqlite3"),
            ProjectId::from_bytes(project),
            recovery.verifying_key().to_bytes(),
        )
        .unwrap(),
    );
    let trust_b = Arc::new(
        TrustStore::open(
            temporary.path().join("b.sqlite3"),
            ProjectId::from_bytes(project),
            recovery.verifying_key().to_bytes(),
        )
        .unwrap(),
    );
    for trust in [&trust_a, &trust_b] {
        trust
            .apply_control_record(&grant(&recovery, project, device_a, 1, &identity_a))
            .unwrap();
        trust
            .apply_control_record(&grant(&recovery, project, device_b, 2, &identity_b))
            .unwrap();
    }

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
    let durable_before = (
        trust_a.test_mutation_fingerprint().unwrap(),
        trust_b.test_mutation_fingerprint().unwrap(),
    );
    let address = server.local_addr().unwrap();
    let (accepted, connected) = tokio::join!(
        server.accept(hello(project, device_a, 2, 1)),
        client.connect(address, hello(project, device_b, 2, 2))
    );
    let accepted = accepted.unwrap();
    let connected = connected.unwrap();
    assert_eq!(accepted.peer.device_id, device_b);
    assert_eq!(connected.peer.device_id, device_a);
    let accepted_peer = accepted.peer;

    let mut streams = Vec::new();
    for _ in 0..16 {
        streams.push(connected.connection.open_uni().await.unwrap());
    }
    assert!(tokio::time::timeout(
        std::time::Duration::from_millis(100),
        connected.connection.open_uni()
    )
    .await
    .is_err());
    drop(streams);

    let mut streams = Vec::new();
    // The authenticated SyncHello consumes one of the 16 peer bidi slots until
    // QUIC acknowledges stream retirement, so 15 additional streams fill it.
    for _ in 0..15 {
        streams.push(connected.connection.open_bi().await.unwrap());
    }
    assert!(tokio::time::timeout(
        std::time::Duration::from_millis(100),
        connected.connection.open_bi()
    )
    .await
    .is_err());
    drop(streams);

    accepted
        .connection
        .close(0_u32.into(), b"stream-limit-complete");
    connected
        .connection
        .close(0_u32.into(), b"stream-limit-complete");
    drop(accepted);
    drop(connected);

    let (fresh_server, fresh_client) = tokio::join!(
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            server.accept(hello(project, device_a, 2, 7))
        ),
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            client.connect(address, hello(project, device_b, 2, 8))
        )
    );
    drop(fresh_server.unwrap().unwrap());
    drop(fresh_client.unwrap().unwrap());
    let (server_replay, client_replay) = tokio::join!(
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            server.accept(hello(project, device_a, 2, 9))
        ),
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            client.connect(address, hello(project, device_b, 2, 8))
        )
    );
    assert!(!matches!(server_replay, Ok(Ok(_))));
    assert!(!matches!(client_replay, Ok(Ok(_))));

    let mut missing_capability = hello(project, device_b, 2, 4);
    missing_capability.capabilities.clear();
    let (server_rejection, client_rejection) = tokio::join!(
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            server.accept(hello(project, device_a, 2, 3))
        ),
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            client.connect(address, missing_capability)
        )
    );
    assert!(!matches!(server_rejection, Ok(Ok(_))));
    assert!(!matches!(client_rejection, Ok(Ok(_))));

    let mut no_common_version = hello(project, device_b, 2, 10);
    no_common_version.selected_version = 2;
    no_common_version.version_offers = vec![2];
    let (server_rejection, client_rejection) = tokio::join!(
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            server.accept(hello(project, device_a, 2, 11))
        ),
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            client.connect(address, no_common_version)
        )
    );
    assert!(!matches!(server_rejection, Ok(Ok(_))));
    assert!(!matches!(client_rejection, Ok(Ok(_))));
    assert_eq!(
        durable_before,
        (
            trust_a.test_mutation_fingerprint().unwrap(),
            trust_b.test_mutation_fingerprint().unwrap(),
        )
    );

    let fields = control_fields(
        project,
        device_b,
        3,
        3,
        SigningKey::from_bytes(&device_b).verifying_key().to_bytes(),
    );
    let revoke = signed_control(
        &recovery,
        RecordKind::DeviceRevoke,
        &fields,
        DeviceRevokePayload {
            fields: fields.clone(),
        }
        .encode(),
    );
    trust_a.apply_control_record(&revoke).unwrap();
    assert!(trust_a.revalidate_transport_peer(&accepted_peer).is_err());

    let (server_rejection, client_rejection) = tokio::join!(
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            server.accept(hello(project, device_a, 3, 5))
        ),
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            client.connect(address, hello(project, device_b, 2, 6))
        )
    );
    assert!(!matches!(server_rejection, Ok(Ok(_))));
    assert!(!matches!(client_rejection, Ok(Ok(_))));
}

async fn assert_handshake_rejected(
    server: &SyncEndpoint,
    client: &SyncEndpoint,
    server_hello: SyncHello,
    client_hello: SyncHello,
) {
    let address = server.local_addr().unwrap();
    let (accepted, connected) = tokio::join!(
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            server.accept(server_hello)
        ),
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            client.connect(address, client_hello)
        )
    );
    assert!(!matches!(accepted, Ok(Ok(_))));
    assert!(!matches!(connected, Ok(Ok(_))));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn independent_wrong_server_wrong_client_and_alpn_pins_fail_closed() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x51; 32]);
    let project = [0x52; 32];
    let device_a = [0x53; 32];
    let device_b = [0x54; 32];
    let identity_a = DeviceTlsIdentity::generate().unwrap();
    let identity_b = DeviceTlsIdentity::generate().unwrap();

    for (case, server_grant_a, client_grant_a, custom_alpn) in [
        ("wrong-server", false, false, false),
        ("wrong-client", true, true, false),
        ("alpn", true, true, true),
    ] {
        let server_trust = Arc::new(
            TrustStore::open(
                temporary.path().join(format!("{case}-server.sqlite3")),
                ProjectId::from_bytes(project),
                recovery.verifying_key().to_bytes(),
            )
            .unwrap(),
        );
        let client_trust = Arc::new(
            TrustStore::open(
                temporary.path().join(format!("{case}-client.sqlite3")),
                ProjectId::from_bytes(project),
                recovery.verifying_key().to_bytes(),
            )
            .unwrap(),
        );
        if server_grant_a {
            server_trust
                .apply_control_record(&grant(&recovery, project, device_a, 1, &identity_a))
                .unwrap();
        } else {
            server_trust
                .apply_control_record(&grant(&recovery, project, device_b, 1, &identity_b))
                .unwrap();
        }
        if client_grant_a {
            client_trust
                .apply_control_record(&grant(&recovery, project, device_a, 1, &identity_a))
                .unwrap();
        } else {
            client_trust
                .apply_control_record(&grant(&recovery, project, device_b, 1, &identity_b))
                .unwrap();
        }
        let epoch = if custom_alpn {
            server_trust
                .apply_control_record(&grant(&recovery, project, device_b, 2, &identity_b))
                .unwrap();
            client_trust
                .apply_control_record(&grant(&recovery, project, device_b, 2, &identity_b))
                .unwrap();
            2
        } else {
            1
        };
        let server = if custom_alpn {
            SyncEndpoint::server_with_alpn(
                SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
                server_trust,
                &identity_a,
                b"not-term-mesh".to_vec(),
            )
            .unwrap()
        } else {
            SyncEndpoint::server(
                SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
                server_trust,
                &identity_a,
            )
            .unwrap()
        };
        let client = SyncEndpoint::client(
            SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
            client_trust,
            &identity_b,
        )
        .unwrap();
        assert_handshake_rejected(
            &server,
            &client,
            hello(project, device_a, epoch, 20),
            hello(project, device_b, epoch, 21),
        )
        .await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn client_side_revocation_independently_rejects_server_certificate() {
    let temporary = tempfile::tempdir().unwrap();
    let recovery = SigningKey::from_bytes(&[0x61; 32]);
    let project = [0x62; 32];
    let device_a = [0x63; 32];
    let device_b = [0x64; 32];
    let identity_a = DeviceTlsIdentity::generate().unwrap();
    let identity_b = DeviceTlsIdentity::generate().unwrap();
    let server_trust = Arc::new(
        TrustStore::open(
            temporary.path().join("server.sqlite3"),
            ProjectId::from_bytes(project),
            recovery.verifying_key().to_bytes(),
        )
        .unwrap(),
    );
    let client_trust = Arc::new(
        TrustStore::open(
            temporary.path().join("client.sqlite3"),
            ProjectId::from_bytes(project),
            recovery.verifying_key().to_bytes(),
        )
        .unwrap(),
    );
    for trust in [&server_trust, &client_trust] {
        trust
            .apply_control_record(&grant(&recovery, project, device_a, 1, &identity_a))
            .unwrap();
        trust
            .apply_control_record(&grant(&recovery, project, device_b, 2, &identity_b))
            .unwrap();
    }
    let fields = control_fields(
        project,
        device_a,
        3,
        31,
        SigningKey::from_bytes(&device_a).verifying_key().to_bytes(),
    );
    client_trust
        .apply_control_record(&signed_control(
            &recovery,
            RecordKind::DeviceRevoke,
            &fields,
            DeviceRevokePayload {
                fields: fields.clone(),
            }
            .encode(),
        ))
        .unwrap();
    let server = SyncEndpoint::server(
        SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
        server_trust,
        &identity_a,
    )
    .unwrap();
    let client = SyncEndpoint::client(
        SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
        client_trust,
        &identity_b,
    )
    .unwrap();
    assert_handshake_rejected(
        &server,
        &client,
        hello(project, device_a, 2, 32),
        hello(project, device_b, 3, 33),
    )
    .await;
}

#[tokio::test]
async fn router_latency_artifact_has_no_wall_clock_gate() {
    let (sender, mut router) = StreamRouter::bounded();
    let started = Instant::now();
    let mut drained = 0usize;
    for _ in 0..128 {
        sender
            .send(StreamLane::Control, vec![1; 1024])
            .await
            .unwrap();
        let frame = router.next().await.unwrap();
        assert_eq!(frame.payload().len(), 1024, "router must forward the full payload");
        drained += 1;
    }
    // Functional assertion: every enqueued frame routed through. The latency
    // artifact below is written for offline analysis only — deliberately NOT
    // gated on wall-clock time (would be flaky under CI load).
    assert_eq!(drained, 128, "all frames must route through the bounded router");
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("target/mesh-sync/t7-quic-latency.json");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(
        path,
        format!(
            "{{\"sample_count\":128,\"payload_bytes\":1024,\"elapsed_micros\":{}}}\n",
            started.elapsed().as_micros()
        ),
    )
    .unwrap();
}
