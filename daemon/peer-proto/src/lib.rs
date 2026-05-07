//! Rust bindings for the term-mesh peer federation protocol.
//!
//! Generated from `proto/peer/v1/peer.proto` at build time via `protox` + `prost-build`.
//! See `docs/peer-federation-protocol.md` for the design and `proto/peer/v1/README.md`
//! for contribution rules.

pub mod v1 {
    include!(concat!(env!("OUT_DIR"), "/termmesh.peer.v1.rs"));
}

pub use v1::*;

/// Length-prefix format for wire framing: little-endian u32 prefix followed by
/// a Protobuf-encoded [`Envelope`]. The prefix MUST NOT exceed [`MAX_FRAME_BYTES`].
pub const MAX_FRAME_BYTES: u32 = 16 * 1024 * 1024;

#[cfg(test)]
mod tests {
    use super::v1::*;
    use prost::Message;

    #[test]
    fn envelope_roundtrip_hello() {
        let env = Envelope {
            seq: 1,
            correlation_id: 0,
            payload: Some(envelope::Payload::Hello(Hello {
                protocol_version: "1.0.0".into(),
                peer_id: vec![0xAB; 16],
                display_name: "MacBook Pro".into(),
                capabilities: vec!["grid-snapshot-v1".into()],
                app_version: "0.98.2".into(),
            })),
        };

        let bytes = env.encode_to_vec();
        assert!(!bytes.is_empty());

        let decoded = Envelope::decode(bytes.as_slice()).expect("decode");
        assert_eq!(decoded.seq, 1);
        let payload = decoded.payload.expect("payload");
        match payload {
            envelope::Payload::Hello(h) => {
                assert_eq!(h.protocol_version, "1.0.0");
                assert_eq!(h.display_name, "MacBook Pro");
                assert_eq!(h.peer_id.len(), 16);
                assert_eq!(h.capabilities, vec!["grid-snapshot-v1"]);
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn envelope_roundtrip_pty_data() {
        let env = Envelope {
            seq: 42,
            correlation_id: 0,
            payload: Some(envelope::Payload::PtyData(PtyData {
                surface_id: vec![0xCD; 16],
                byte_seq: 12345,
                payload: b"hello world\r\n".to_vec(),
            })),
        };
        let bytes = env.encode_to_vec();
        let back = Envelope::decode(bytes.as_slice()).unwrap();
        match back.payload.unwrap() {
            envelope::Payload::PtyData(p) => {
                assert_eq!(p.byte_seq, 12345);
                assert_eq!(p.payload, b"hello world\r\n");
            }
            _ => panic!(),
        }
    }

    #[test]
    fn attach_mode_enum_defaults_to_unspecified() {
        let a = AttachSurface::default();
        assert_eq!(a.mode, AttachMode::Unspecified as i32);
    }

    #[test]
    fn unknown_future_field_does_not_break_decode() {
        // Craft an Envelope with a small Pong payload, then append an unknown field tag.
        let mut base = Envelope {
            seq: 5,
            correlation_id: 0,
            payload: Some(envelope::Payload::Pong(Pong { nonce: 7 })),
        }
        .encode_to_vec();
        // Unknown tag 999, wire type 0 (varint), value 1.
        base.extend_from_slice(&[0xf8, 0x3e, 0x01]);
        let back = Envelope::decode(base.as_slice()).expect("forward-compat decode");
        match back.payload.unwrap() {
            envelope::Payload::Pong(p) => assert_eq!(p.nonce, 7),
            _ => panic!(),
        }
    }
}
