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

/// Feature-flag strings a peer may advertise via `Hello.capabilities`
/// (`proto/peer/v1/peer.proto` Evolution rule 3). Mirrors
/// `swift/PeerProto/Sources/PeerProto/PeerCapabilities.swift` on the Swift
/// side — keep the two lists in sync.
///
/// This is plumbing only (see P3 in `docs/peer-perf-proposal.md`): nothing
/// in this codebase branches on a capability string yet. It exists so P8
/// and later wire changes have a real, already-round-tripped negotiation
/// channel to gate on instead of inventing one from scratch.
pub mod capability {
    /// PtyData broadcast coalescing (P7). Purely a sender-side batching
    /// change with no new wire shape, but advertised so a future receiver
    /// that cares about batch boundaries (e.g. a compressor, P8) can detect
    /// support for it.
    pub const PTYDATA_COALESCE_V1: &str = "ptydata.coalesce.v1";
    /// Attach-time ANSI-preserving raw-byte replay ring (P4).
    pub const REPLAY_RING_V1: &str = "replay.ring.v1";

    /// Every capability this build supports. Single source of truth for
    /// populating outgoing `Hello.capabilities` — callers should use
    /// [`supported_vec`] rather than hand-rolling the list.
    pub const SUPPORTED: &[&str] = &[PTYDATA_COALESCE_V1, REPLAY_RING_V1];

    /// `Hello.capabilities` value for an outgoing handshake message.
    pub fn supported_vec() -> Vec<String> {
        SUPPORTED.iter().map(|s| (*s).to_string()).collect()
    }
}

/// The other side's advertised feature flags, parsed once out of its
/// `Hello.capabilities` and kept around for the life of a connection.
///
/// Unknown strings (a future peer advertising something this build
/// predates) are kept but never interpreted — only [`has`](Self::has) gives
/// them meaning, and no current call site queries anything but the
/// constants in [`capability`]. Memory is bounded by the wire's own
/// [`MAX_FRAME_BYTES`] frame-size cap: even a maximally adversarial
/// capabilities list can't exceed that many bytes, so no separate
/// entry-count limit is applied here.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PeerCapabilities(std::collections::HashSet<String>);

impl PeerCapabilities {
    /// Builds from a raw `Hello.capabilities` list (e.g. `hello.capabilities`
    /// after decoding). Safe for any input: empty (legacy peer — every
    /// `has()` call then returns `false`, matching today's no-capability
    /// behavior exactly), unknown strings, or a very large list.
    pub fn from_hello(capabilities: Vec<String>) -> Self {
        Self(capabilities.into_iter().collect())
    }

    /// Whether the peer that sent this `Hello` advertised `capability`.
    pub fn has(&self, capability: &str) -> bool {
        self.0.contains(capability)
    }
}

#[cfg(test)]
mod tests {
    use super::v1::*;
    use super::{capability, MAX_FRAME_BYTES};
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

    // ---- P3 capability plumbing: adversarial-input safety ----
    // A peer's `Hello.capabilities` is attacker/bug-controlled input (it
    // comes straight off the wire from whatever connects to the socket),
    // so these prove decode + `PeerCapabilities` never panic or corrupt
    // the rest of the envelope, regardless of what's in that field.

    #[test]
    fn capabilities_empty_list_round_trips_to_empty() {
        // The legacy/pre-P3 fallback: an old peer that never populates
        // this field must decode to an empty vec, not a default/error.
        let env = Envelope {
            seq: 1,
            correlation_id: 0,
            payload: Some(envelope::Payload::Hello(Hello {
                protocol_version: "1.0.0".into(),
                peer_id: vec![0x01; 16],
                display_name: "legacy-peer".into(),
                capabilities: vec![],
                app_version: "0.0.0".into(),
            })),
        };
        let bytes = env.encode_to_vec();
        let back = Envelope::decode(bytes.as_slice()).expect("decode");
        match back.payload.unwrap() {
            envelope::Payload::Hello(h) => assert!(h.capabilities.is_empty()),
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn capabilities_unknown_strings_round_trip_safely() {
        // A newer peer may advertise a capability this build predates.
        // Forward-compat requires these to decode intact, not be dropped
        // or cause an error.
        let unknown = vec![
            "future.feature.v99".to_string(),
            "".to_string(), // empty string is a valid (if useless) entry
            "\u{1F980}-unicode-cap".to_string(),
        ];
        let env = Envelope {
            seq: 1,
            correlation_id: 0,
            payload: Some(envelope::Payload::Hello(Hello {
                protocol_version: "1.0.0".into(),
                peer_id: vec![0x02; 16],
                display_name: "future-peer".into(),
                capabilities: unknown.clone(),
                app_version: "9.9.9".into(),
            })),
        };
        let bytes = env.encode_to_vec();
        let back = Envelope::decode(bytes.as_slice()).expect("decode");
        match back.payload.unwrap() {
            envelope::Payload::Hello(h) => assert_eq!(h.capabilities, unknown),
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn capabilities_large_list_round_trips_without_panic() {
        // Thousands of entries: bounded in practice by MAX_FRAME_BYTES,
        // but nothing before that limit should panic or truncate silently.
        let many: Vec<String> = (0..5000).map(|i| format!("cap.{i}.v1")).collect();
        let env = Envelope {
            seq: 1,
            correlation_id: 0,
            payload: Some(envelope::Payload::Hello(Hello {
                protocol_version: "1.0.0".into(),
                peer_id: vec![0x03; 16],
                display_name: "chatty-peer".into(),
                capabilities: many.clone(),
                app_version: "1.2.3".into(),
            })),
        };
        let bytes = env.encode_to_vec();
        assert!(bytes.len() < MAX_FRAME_BYTES as usize);
        let back = Envelope::decode(bytes.as_slice()).expect("decode");
        match back.payload.unwrap() {
            envelope::Payload::Hello(h) => {
                assert_eq!(h.capabilities.len(), 5000);
                assert_eq!(h.capabilities, many);
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn capabilities_invalid_utf8_bytes_fail_decode_gracefully() {
        // Rust's `String` type can't hold invalid UTF-8, so the only way
        // to exercise decode-time handling of malformed wire bytes is to
        // corrupt already-encoded bytes directly, after encoding a
        // structurally-valid message with a same-length placeholder.
        let placeholder = "xxxxxxxx";
        let env = Envelope {
            seq: 1,
            correlation_id: 0,
            payload: Some(envelope::Payload::Hello(Hello {
                protocol_version: "1.0.0".into(),
                peer_id: vec![0xAB; 16],
                display_name: "corrupt-test".into(),
                capabilities: vec![placeholder.to_string()],
                app_version: "0.0.0".into(),
            })),
        };
        let mut bytes = env.encode_to_vec();
        let marker = placeholder.as_bytes();
        let pos = bytes
            .windows(marker.len())
            .position(|w| w == marker)
            .expect("placeholder capability bytes not found in encoded message");
        // 0x80 alone (a continuation byte with no preceding lead byte) is
        // never valid UTF-8 in any position.
        for b in &mut bytes[pos..pos + marker.len()] {
            *b = 0x80;
        }

        let result = Envelope::decode(bytes.as_slice());
        assert!(
            result.is_err(),
            "decoding a Hello.capabilities entry with invalid UTF-8 bytes \
             should return a decode error, not panic or silently corrupt data"
        );
    }

    #[test]
    fn peer_capabilities_has_is_safe_for_any_input() {
        use super::PeerCapabilities;

        let empty = PeerCapabilities::from_hello(vec![]);
        assert!(!empty.has(capability::PTYDATA_COALESCE_V1));

        let known = PeerCapabilities::from_hello(capability::supported_vec());
        assert!(known.has(capability::PTYDATA_COALESCE_V1));
        assert!(known.has(capability::REPLAY_RING_V1));
        assert!(!known.has("totally.unknown.v1"));

        let many: Vec<String> = (0..5000).map(|i| format!("cap.{i}.v1")).collect();
        let large = PeerCapabilities::from_hello(many);
        assert!(large.has("cap.42.v1"));
        assert!(!large.has("cap.99999.v1"));
    }
}
