use serde::Deserialize;
use sync_protocol::{
    negotiate_version, validate_mesh_ref, CanonicalRecord, ControlFields, DeviceGrantPayload,
    DeviceRevokePayload, ProtocolError, RecordKind, RotationPayload, SyncHello, MAX_PAYLOAD_BYTES,
    MAX_VERSION_OFFERS, PROJECT_SYNC_CAPABILITY, PROTOCOL_V1,
};

#[test]
fn maximum_record_fits_single_oplog_batch_and_plus_one_is_rejected() {
    use sync_protocol::*;
    let record = CanonicalRecord {
        kind: RecordKind::Oplog,
        project_id: [1; 32],
        device_id: [2; 32],
        roster_epoch: 1,
        sequence: 1,
        payload: vec![3; MAX_RECORD_PAYLOAD_BYTES],
        signature: [4; 64],
    };
    let encoded = record.canonical_bytes().unwrap();
    let frame = WireFrame {
        binding: WireBinding {
            project_id: [1; 32],
            roster_epoch: 1,
            operation_id: [5; 16],
        },
        body: WireBody::OplogBatch(OplogBatch {
            records: vec![encoded.clone()],
        }),
    };
    let wire = frame.canonical_bytes().unwrap();
    assert_eq!(wire.len(), MAX_WIRE_BYTES);
    assert_eq!(WireFrame::decode(&wire).unwrap(), frame);
    assert_eq!(CanonicalRecord::decode(&encoded).unwrap(), record);
    let oversized = CanonicalRecord {
        payload: vec![0; MAX_RECORD_PAYLOAD_BYTES + 1],
        ..record
    };
    assert!(oversized.checked_encoded_len().is_err());
    assert!(oversized.canonical_bytes().is_err());
}

#[test]
fn project_sync_wire_variants_are_canonical_and_binding_preserving() {
    use sync_protocol::*;
    let binding = WireBinding {
        project_id: [0x31; 32],
        roster_epoch: 17,
        operation_id: [0x42; 16],
    };
    let frontier = vec![
        FrontierEntry {
            device_id: [1; 32],
            sequence: 4,
        },
        FrontierEntry {
            device_id: [2; 32],
            sequence: 8,
        },
    ];
    let bodies = vec![
        WireBody::StreamPreface(StreamPreface {
            lane: 3,
            declared_length: Some(99),
        }),
        WireBody::ReconcileOffer(ReconcileOffer {
            manifest_root: [3; 32],
            frontier: frontier.clone(),
            retained_floor: frontier.clone(),
        }),
        WireBody::ManifestNodeRequest(ManifestNodeRequest {
            hashes: vec![[1; 32], [2; 32]],
        }),
        WireBody::ManifestNodeBatch(ManifestNodeBatch {
            nodes: vec![b"node".to_vec()],
        }),
        WireBody::MissingObject(MissingObject {
            hashes: vec![[1; 32]],
            resume_ranges: vec![ChunkRange {
                start: 0,
                end_exclusive: 2,
            }],
        }),
        WireBody::BlobChunk(BlobChunk {
            object_id: [4; 32],
            chunk_index: 2,
            plaintext_length: 7,
            envelope: vec![5; 23],
        }),
        WireBody::OplogRangeRequest(OplogRangeRequest {
            device_id: [6; 32],
            start: 1,
            end_exclusive: 3,
        }),
        WireBody::OplogBatch(OplogBatch {
            records: vec![b"record".to_vec()],
        }),
        WireBody::BatchAck(BatchAck {
            batch_hash: [7; 32],
            durable_sequence: 9,
        }),
        WireBody::FullResyncRequired(FullResyncRequired {
            manifest_root: [8; 32],
            retained_floor: frontier.clone(),
        }),
        WireBody::Baseline(Baseline {
            manifest_root: [9; 32],
            frontier,
        }),
    ];
    for body in bodies {
        let frame = WireFrame { binding, body };
        let bytes = frame.canonical_bytes().unwrap();
        assert_eq!(WireFrame::decode(&bytes).unwrap(), frame);
        let mut trailing = bytes;
        trailing.push(0);
        assert!(WireFrame::decode(&trailing).is_err());
    }
}

#[test]
fn project_sync_wire_limits_fail_closed() {
    use sync_protocol::*;
    let binding = WireBinding {
        project_id: [1; 32],
        roster_epoch: 1,
        operation_id: [2; 16],
    };
    let unsorted = WireFrame {
        binding,
        body: WireBody::ManifestNodeRequest(ManifestNodeRequest {
            hashes: vec![[2; 32], [1; 32]],
        }),
    };
    assert!(unsorted.canonical_bytes().is_err());
    let oversized = WireFrame {
        binding,
        body: WireBody::BlobChunk(BlobChunk {
            object_id: [3; 32],
            chunk_index: 0,
            plaintext_length: 1,
            envelope: vec![0; MAX_BLOB_ENVELOPE_BYTES + 1],
        }),
    };
    assert!(oversized.canonical_bytes().is_err());
    let too_many = WireFrame {
        binding,
        body: WireBody::OplogBatch(OplogBatch {
            records: vec![Vec::new(); MAX_BATCH_RECORDS + 1],
        }),
    };
    assert!(too_many.canonical_bytes().is_err());

    let bad_lane = WireFrame {
        binding,
        body: WireBody::StreamPreface(StreamPreface {
            lane: 4,
            declared_length: None,
        }),
    };
    assert!(bad_lane.canonical_bytes().is_err());
    let boundary = WireFrame {
        binding,
        body: WireBody::ManifestNodeBatch(ManifestNodeBatch {
            nodes: vec![vec![0; MAX_MANIFEST_PAGE_BYTES - 6]],
        }),
    };
    assert_eq!(
        WireFrame::decode(&boundary.canonical_bytes().unwrap()).unwrap(),
        boundary
    );
    let boundary_plus_one = WireFrame {
        binding,
        body: WireBody::ManifestNodeBatch(ManifestNodeBatch {
            nodes: vec![vec![0; MAX_MANIFEST_PAGE_BYTES - 5]],
        }),
    };
    assert!(boundary_plus_one.canonical_bytes().is_err());
}

#[test]
fn control_payload_vectors_are_fixed_and_round_trip() {
    let fields = ControlFields {
        project_id: [0x11; 32],
        device_id: [0x22; 32],
        roster_epoch: 0x0102_0304_0506_0708,
        nonce: [0x33; 32],
        signing_public_key: [0x44; 32],
        agreement_public_key: [0x55; 32],
        key_id: [0x66; 16],
    };
    let grant = DeviceGrantPayload {
        fields: fields.clone(),
        ephemeral_public_key: [0x77; 32],
        wrap_nonce: [0x88; 24],
        wrapped_dek: [0x99; 48],
        tls_certificate_hash: [0xab; 32],
    };
    let grant_bytes = grant.encode();
    assert_eq!(&grant_bytes[..8], b"TMCT\0\x01\x01\0");
    assert_eq!(grant_bytes.len(), DeviceGrantPayload::ENCODED_BYTES);
    assert_eq!(DeviceGrantPayload::decode(&grant_bytes).unwrap(), grant);

    let revoke = DeviceRevokePayload {
        fields: fields.clone(),
    };
    let revoke_bytes = revoke.encode();
    assert_eq!(&revoke_bytes[..8], b"TMCT\0\x01\x02\0");
    assert_eq!(DeviceRevokePayload::decode(&revoke_bytes).unwrap(), revoke);

    let rotation = RotationPayload {
        fields,
        dek_commitment: [0xaa; 32],
    };
    let rotation_bytes = rotation.encode();
    assert_eq!(&rotation_bytes[..8], b"TMCT\0\x01\x08\0");
    assert_eq!(RotationPayload::decode(&rotation_bytes).unwrap(), rotation);

    let mut noncanonical = rotation_bytes;
    noncanonical[7] = 1;
    assert_eq!(
        RotationPayload::decode(&noncanonical),
        Err(ProtocolError::InvalidControlPayload(
            "wrong payload kind or reserved byte"
        ))
    );
}

#[test]
fn sync_hello_is_canonical_bounded_and_downgrade_safe() {
    let hello = SyncHello {
        project_id: [1; 32],
        device_id: [2; 32],
        roster_epoch: 3,
        selected_version: PROTOCOL_V1,
        version_offers: vec![PROTOCOL_V1],
        capabilities: vec![PROJECT_SYNC_CAPABILITY.into()],
        nonce: [4; 32],
    };
    let bytes = hello.canonical_bytes().unwrap();
    assert_eq!(SyncHello::decode(&bytes).unwrap(), hello);
    assert_eq!(hello.validate_negotiation(), Ok(PROTOCOL_V1));

    let mut trailing = bytes.clone();
    trailing.push(0);
    assert!(SyncHello::decode(&trailing).is_err());
    let mut downgrade = hello.clone();
    downgrade.selected_version = 0;
    assert!(matches!(
        downgrade.validate_negotiation(),
        Err(ProtocolError::Downgrade { .. })
    ));
    let mut missing = hello;
    missing.capabilities.clear();
    assert_eq!(
        missing.validate_negotiation(),
        Err(ProtocolError::MissingCapability)
    );

    let mut duplicate_offer = missing.clone();
    duplicate_offer.version_offers = vec![PROTOCOL_V1, PROTOCOL_V1];
    assert!(duplicate_offer.canonical_bytes().is_err());
    let mut unsorted_capabilities = missing;
    unsorted_capabilities.capabilities = vec!["z.v1".into(), "a.v1".into()];
    assert!(unsorted_capabilities.canonical_bytes().is_err());
}

#[derive(Deserialize)]
struct Fixture {
    project_id_hex: String,
    device_id_hex: String,
    roster_epoch: u64,
    sequence: u64,
    payload_hex: String,
    signature_hex: String,
    canonical_hex: String,
    domain_hash_hex: String,
    signing_preimage_hex: String,
}

fn fixture() -> (Fixture, CanonicalRecord) {
    let fixture: Fixture = serde_json::from_str(include_str!("fixtures/v1.json")).unwrap();
    let record = CanonicalRecord {
        kind: RecordKind::Oplog,
        project_id: decode_array(&fixture.project_id_hex),
        device_id: decode_array(&fixture.device_id_hex),
        roster_epoch: fixture.roster_epoch,
        sequence: fixture.sequence,
        payload: decode_hex(&fixture.payload_hex),
        signature: decode_array(&fixture.signature_hex),
    };
    (fixture, record)
}

#[test]
fn v1_fixture_is_stable_and_round_trips() {
    let (fixture, record) = fixture();
    let bytes = record.canonical_bytes().unwrap();
    let hash = record.domain_hash().unwrap();
    assert_eq!(encode_hex(&bytes), fixture.canonical_hex);
    assert_eq!(encode_hex(&hash), fixture.domain_hash_hex);
    assert_eq!(
        encode_hex(&record.signing_preimage().unwrap()),
        fixture.signing_preimage_hex
    );
    assert_eq!(CanonicalRecord::decode(&bytes).unwrap(), record);
    assert_eq!(record.canonical_bytes().unwrap(), bytes);
    assert_eq!(record.domain_hash().unwrap(), hash);

    let mut differently_signed = record.clone();
    differently_signed.signature = [0xff; 64];
    assert_eq!(
        differently_signed.signing_preimage().unwrap(),
        record.signing_preimage().unwrap()
    );
    assert_ne!(differently_signed.domain_hash().unwrap(), hash);
}

#[test]
fn malformed_noncanonical_and_truncated_inputs_are_rejected() {
    let (_, record) = fixture();
    let canonical = record.canonical_bytes().unwrap();

    let mut malformed = canonical.clone();
    malformed[0] = b'X';
    assert_eq!(
        CanonicalRecord::decode(&malformed),
        Err(ProtocolError::BadMagic)
    );

    let mut noncanonical = canonical.clone();
    noncanonical[7] = 1;
    assert_eq!(
        CanonicalRecord::decode(&noncanonical),
        Err(ProtocolError::NonCanonical("reserved byte is non-zero"))
    );

    let mut trailing = canonical.clone();
    trailing.push(0);
    assert_eq!(
        CanonicalRecord::decode(&trailing),
        Err(ProtocolError::NonCanonical("trailing bytes"))
    );

    let truncated = &canonical[..canonical.len() - 1];
    assert!(matches!(
        CanonicalRecord::decode(truncated),
        Err(ProtocolError::Truncated { .. })
    ));
}

#[test]
fn oversized_inputs_are_rejected_before_payload_allocation() {
    let (_, mut record) = fixture();
    record.payload = vec![0; MAX_PAYLOAD_BYTES + 1];
    assert_eq!(
        record.canonical_bytes(),
        Err(ProtocolError::PayloadTooLarge {
            actual: MAX_PAYLOAD_BYTES + 1,
            maximum: MAX_PAYLOAD_BYTES,
        })
    );

    let oversized_wire = vec![0; 4 + 2 + 1 + 1 + 32 + 32 + 8 + 8 + 4 + 64 + MAX_PAYLOAD_BYTES + 1];
    assert_eq!(
        CanonicalRecord::decode(&oversized_wire),
        Err(ProtocolError::RecordTooLarge {
            actual: oversized_wire.len(),
            maximum: oversized_wire.len() - 1,
        })
    );

    let offers = vec![PROTOCOL_V1; MAX_VERSION_OFFERS + 1];
    assert_eq!(
        negotiate_version(&offers, PROTOCOL_V1),
        Err(ProtocolError::TooManyVersionOffers {
            actual: MAX_VERSION_OFFERS + 1,
            maximum: MAX_VERSION_OFFERS,
        })
    );
}

#[test]
fn downgrade_and_unsupported_peers_fail_closed() {
    assert_eq!(
        negotiate_version(&[PROTOCOL_V1], PROTOCOL_V1),
        Ok(PROTOCOL_V1)
    );
    assert_eq!(
        negotiate_version(&[PROTOCOL_V1], 0),
        Err(ProtocolError::Downgrade {
            selected: 0,
            required: PROTOCOL_V1,
        })
    );
    assert_eq!(
        negotiate_version(&[2], 2),
        Err(ProtocolError::NoCommonVersion)
    );
}

#[test]
fn git_refs_are_confined_to_the_peer_namespace() {
    for reference in ["refs/mesh/peer-a/main", "refs/mesh/peer-a/heads/feature-a"] {
        assert_eq!(validate_mesh_ref("peer-a", reference), Ok(()));
    }
    for reference in [
        "refs/heads/main",
        "HEAD",
        "refs/mesh/peer-b/main",
        "refs/mesh/peer-a/../main",
        "refs/mesh/peer-a/",
        "refs/mesh/peer-a/main..next",
        "refs/mesh/peer-a/main@{1}",
        "refs/mesh/peer-a/main branch",
        "refs/mesh/peer-a/main\u{001f}",
        "refs/mesh/peer-a/main~1",
        "refs/mesh/peer-a/main^",
        "refs/mesh/peer-a/main:next",
        "refs/mesh/peer-a/main?",
        "refs/mesh/peer-a/main*",
        "refs/mesh/peer-a/main[0]",
        "refs/mesh/peer-a/main\\next",
        "refs/mesh/peer-a/main.",
        "refs/mesh/peer-a/.hidden/main",
        "refs/mesh/peer-a/main.lock",
        "refs/mesh/peer-a/heads/main.lock/child",
        "refs/mesh/peer-a/heads//main",
    ] {
        assert_eq!(
            validate_mesh_ref("peer-a", reference),
            Err(ProtocolError::GitNamespaceViolation)
        );
    }
}

fn decode_hex(value: &str) -> Vec<u8> {
    assert_eq!(value.len() % 2, 0);
    (0..value.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&value[index..index + 2], 16).unwrap())
        .collect()
}

fn decode_array<const N: usize>(value: &str) -> [u8; N] {
    decode_hex(value)
        .try_into()
        .ok()
        .expect("fixture has exact length")
}

fn encode_hex(value: &[u8]) -> String {
    value.iter().map(|byte| format!("{byte:02x}")).collect()
}
