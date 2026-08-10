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
/// side — keep the two lists in sync. "In sync" means the constants mirror;
/// each side's advertised `supported` list adds an entry only once that side
/// actually implements the behavior. [`SURFACE_AGENT_V1`] is the live
/// example: this build (daemon) advertises it, while the Swift viewer keeps
/// it out of `PeerCapability.supported` until it can render agent surfaces,
/// and the Rust CLI strips it from its client Hello
/// (`term-mesh-cli::peer::client_capabilities`) because it renders raw
/// bytes to a terminal. A client Hello built straight from
/// [`supported_vec`] would claim renderer behavior the daemon happens to
/// implement as a HOST — filter out what the client half cannot keep.
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
    /// The host applies `WorkspaceControl` (split/close/tab/divider) and
    /// pushes `WorkspaceLayoutChanged` to every connection. Daemon hosts
    /// gained this after shipping without it, so a client that wants to
    /// grey out pane controls against an older daemon can key off this.
    pub const WORKSPACE_CONTROL_V1: &str = "workspace.control.v1";
    /// The host supports workspace-level lifecycle RPCs:
    /// `CreateWorkspaceRequest`/`Response`, `RenameWorkspaceRequest`,
    /// `DeleteWorkspaceRequest`, and the `WorkspaceRemoved` push (see
    /// `proto/peer/v1/peer.proto`'s "Workspace lifecycle" section). A
    /// client should not send these payloads to a peer that hasn't
    /// advertised this — older daemons silently drop them via the
    /// Ready-state unhandled-payload path instead of acting on them.
    pub const WORKSPACE_LIFECYCLE_V1: &str = "workspace.lifecycle.v1";
    /// Complete workspace-roster snapshots pushed after a client subscribes.
    pub const WORKSPACE_LIST_SUBSCRIBE_V1: &str = "workspace.list.subscribe.v1";
    /// The host can deterministically create or reuse a daemon-owned PTY
    /// surface from an explicit `EnsureSurfaceRequest` specification.
    pub const SURFACE_ENSURE_V1: &str = "surface.ensure.v1";
    /// The host can terminate one exact ensured surface and remove its
    /// runtime, persistence, and layout state.
    pub const SURFACE_TERMINATE_V1: &str = "surface.terminate.v1";
    /// Daemon-owned agent surfaces (`SurfaceInfo.surface_type == "agent"`):
    /// non-PTY `tm-agent-bridge` children whose byte stream is NDJSON
    /// events, not a terminal grid. Advertised by BOTH sides — a HOST
    /// advertises that it can create and attach agent-kind ensured
    /// surfaces; a CLIENT advertises that it can render them (AgentPanel).
    /// To a client that did not advertise this, a host lists agent
    /// surfaces as `attachable = false` and rejects attach attempts, so
    /// older viewers degrade for free through the existing `attachable`
    /// filter.
    pub const SURFACE_AGENT_V1: &str = "surface.agent.v1";
    /// The host pushes `HostStats` (load, memory, disk and network rates)
    /// for the machine it runs on. Advertised by the client, since the
    /// client is what decides whether it wants the traffic — a host sends
    /// these only to connections that asked.
    pub const HOST_STATS_V1: &str = "host.stats.v1";
    /// The peer understands the typed `GridSnapshot` message (`ansi` form)
    /// on a fresh attach. Advertised by the CLIENT — like `host.stats.v1`,
    /// the client is what decides whether it can consume the typed form. A
    /// host that sees it sends the fresh-attach screen as a `GridSnapshot`
    /// envelope; otherwise the same bytes ride an ordinary `PtyData`, so
    /// every older client keeps working unchanged. The typed form is what
    /// lets a client clear stale local scrollback (`ESC[3J`) and reset its
    /// wire-gap baseline to `GridSnapshot.byte_seq` — neither is safe to
    /// infer from an untyped byte stream.
    pub const GRID_SNAPSHOT_V1: &str = "grid.snapshot.v1";
    /// Authenticated host-reported directories containing bundled CLIs.
    pub const HOST_CLI_BIN_DIRS_V1: &str = "host.cli-bin-dirs.v1";

    /// The host answers `ListTeams` with the agent teams it is running.
    /// A team is not visible in the layout tree — knowing which machine
    /// holds a project's leader needs a team-level read, and this is it.
    /// Advertised by the HOST, since only a host with a team manager can
    /// answer; a client asks a host that did not advertise it nothing.
    pub const TEAM_ROSTER_V1: &str = "team.roster.v1";

    /// The host runs allow-listed `team.*` methods on behalf of a client.
    /// Advertised by the HOST. Unlike the roster this CHANGES things, so the
    /// allow-list — not the capability — is what bounds it. Kept in lockstep
    /// with the Swift host's `PeerTeamCall` allow-list.
    pub const TEAM_CALL_V1: &str = "team.call.v1";
    /// Project-bound remote leader bootstrap with scoped, expiring grants.
    /// Kept separate so it cannot widen `team.call.v1`'s lifecycle boundary.
    pub const TEAM_LEADER_V1: &str = "team.leader.v1";

    /// Every capability this build supports. Single source of truth for
    /// populating outgoing `Hello.capabilities` — callers should use
    /// [`supported_vec`] rather than hand-rolling the list.
    pub const SUPPORTED: &[&str] = &[
        PTYDATA_COALESCE_V1,
        REPLAY_RING_V1,
        WORKSPACE_CONTROL_V1,
        WORKSPACE_LIFECYCLE_V1,
        WORKSPACE_LIST_SUBSCRIBE_V1,
        SURFACE_ENSURE_V1,
        SURFACE_TERMINATE_V1,
        SURFACE_AGENT_V1,
        HOST_STATS_V1,
        GRID_SNAPSHOT_V1,
        HOST_CLI_BIN_DIRS_V1,
        TEAM_ROSTER_V1,
        TEAM_CALL_V1,
        TEAM_LEADER_V1,
    ];

    /// `Hello.capabilities` value for an outgoing handshake message.
    pub fn supported_vec() -> Vec<String> {
        SUPPORTED.iter().map(|s| (*s).to_string()).collect()
    }
}

/// Security limits and pure validators for `team.leader.v1`.
///
/// These values and validation order mirror Swift's `PeerTeamLeader`.
pub mod team_leader {
    use super::{TeamLeaderBootstrapRequest, TeamLeaderGrant, TeamLeaderPlacement, TeamLeaderRole};
    use std::collections::HashSet;

    pub const MAX_PROJECT_ID_BYTES: usize = 128;
    pub const MAX_TEAM_UUID_BYTES: usize = 128;
    pub const REQUEST_ID_BYTES: usize = 16;
    pub const GRANT_ID_BYTES: usize = 32;
    pub const MAX_BOOTSTRAP_PAYLOAD_BYTES: usize = 512;

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum ValidationError {
        PayloadTooLarge,
        InvalidProject,
        InvalidPlacement,
        InvalidRequestId,
        ReplayedRequest,
        UnknownGrant,
        ForgedProject,
        ForgedTeam,
        InvalidRole,
        ExpiredGrant,
    }

    pub fn validate_bootstrap(
        request: &TeamLeaderBootstrapRequest,
        encoded_bytes: Option<usize>,
    ) -> Result<(), ValidationError> {
        if encoded_bytes.is_some_and(|size| size > MAX_BOOTSTRAP_PAYLOAD_BYTES) {
            return Err(ValidationError::PayloadTooLarge);
        }
        if !safe_identifier(&request.project_id, MAX_PROJECT_ID_BYTES) {
            return Err(ValidationError::InvalidProject);
        }
        if request.leader_placement != TeamLeaderPlacement::Local as i32
            && request.leader_placement != TeamLeaderPlacement::Peer as i32
        {
            return Err(ValidationError::InvalidPlacement);
        }
        if request.request_id.len() != REQUEST_ID_BYTES {
            return Err(ValidationError::InvalidRequestId);
        }
        Ok(())
    }

    pub fn validate_grant(
        presented: &TeamLeaderGrant,
        registered: Option<&TeamLeaderGrant>,
        registered_valid_until_unix_seconds: Option<u64>,
        expected_project_id: &str,
        expected_team_uuid: &str,
        now_unix_seconds: u64,
    ) -> Result<(), ValidationError> {
        let Some(registered) = registered.filter(|grant| {
            presented.grant_id.len() == GRANT_ID_BYTES && grant.grant_id == presented.grant_id
        }) else {
            return Err(ValidationError::UnknownGrant);
        };
        if presented.project_id != registered.project_id
            || presented.project_id != expected_project_id
        {
            return Err(ValidationError::ForgedProject);
        }
        if presented.team_uuid != registered.team_uuid
            || presented.team_uuid != expected_team_uuid
            || !safe_identifier(&presented.team_uuid, MAX_TEAM_UUID_BYTES)
        {
            return Err(ValidationError::ForgedTeam);
        }
        if presented.role != TeamLeaderRole::Leader as i32
            || registered.role != TeamLeaderRole::Leader as i32
        {
            return Err(ValidationError::InvalidRole);
        }
        // Keep the issued wire expiry immutable for tamper detection. The
        // authoritative server may renew a separate lease deadline without
        // needing to mutate the long-running leader process environment.
        let valid_until =
            registered_valid_until_unix_seconds.unwrap_or(registered.expires_at_unix_secs);
        if presented.expires_at_unix_secs != registered.expires_at_unix_secs
            || valid_until <= now_unix_seconds
        {
            return Err(ValidationError::ExpiredGrant);
        }
        Ok(())
    }

    fn safe_identifier(value: &str, max_bytes: usize) -> bool {
        let bytes = value.as_bytes();
        !bytes.is_empty()
            && bytes.len() <= max_bytes
            && bytes.iter().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b':' | b'_')
            })
    }

    #[derive(Debug, Default)]
    pub struct ReplayGuard {
        consumed: HashSet<Vec<u8>>,
    }

    impl ReplayGuard {
        pub fn consume(&mut self, request_id: &[u8]) -> Result<(), ValidationError> {
            if request_id.len() != REQUEST_ID_BYTES {
                return Err(ValidationError::InvalidRequestId);
            }
            if !self.consumed.insert(request_id.to_vec()) {
                return Err(ValidationError::ReplayedRequest);
            }
            Ok(())
        }
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
mod team_leader_tests {
    use super::team_leader::{
        validate_bootstrap, validate_grant, ReplayGuard, ValidationError, GRANT_ID_BYTES,
        MAX_BOOTSTRAP_PAYLOAD_BYTES, REQUEST_ID_BYTES,
    };
    use super::{TeamLeaderBootstrapRequest, TeamLeaderGrant, TeamLeaderPlacement, TeamLeaderRole};

    fn request() -> TeamLeaderBootstrapRequest {
        TeamLeaderBootstrapRequest {
            project_id: "name:demo".into(),
            leader_placement: TeamLeaderPlacement::Peer as i32,
            request_id: vec![1; REQUEST_ID_BYTES],
        }
    }

    fn grant() -> TeamLeaderGrant {
        TeamLeaderGrant {
            grant_id: vec![2; GRANT_ID_BYTES],
            project_id: "name:demo".into(),
            team_uuid: "team-uuid".into(),
            role: TeamLeaderRole::Leader as i32,
            expires_at_unix_secs: 100,
        }
    }

    #[test]
    fn bootstrap_rejects_oversize_invalid_placement_and_executable_injection() {
        assert_eq!(validate_bootstrap(&request(), Some(64)), Ok(()));
        assert_eq!(
            validate_bootstrap(&request(), Some(MAX_BOOTSTRAP_PAYLOAD_BYTES + 1)),
            Err(ValidationError::PayloadTooLarge)
        );

        let mut invalid = request();
        invalid.leader_placement = TeamLeaderPlacement::Unspecified as i32;
        assert_eq!(
            validate_bootstrap(&invalid, None),
            Err(ValidationError::InvalidPlacement)
        );

        for injected in [
            "/tmp/project",
            "name:demo\ncommand=/bin/sh",
            "name:demo --cli codex",
            "name:demo$HOME",
            "name:demo env=TOKEN",
        ] {
            let mut invalid = request();
            invalid.project_id = injected.into();
            assert_eq!(
                validate_bootstrap(&invalid, None),
                Err(ValidationError::InvalidProject),
                "accepted executable-field injection: {injected}"
            );
        }
    }

    #[test]
    fn grant_rejects_forged_project_team_role_and_expiry() {
        let registered = grant();
        assert_eq!(
            validate_grant(
                &registered,
                Some(&registered),
                None,
                "name:demo",
                "team-uuid",
                99
            ),
            Ok(())
        );

        let mut forged = registered.clone();
        forged.project_id = "name:other".into();
        assert_eq!(
            validate_grant(
                &forged,
                Some(&registered),
                None,
                "name:demo",
                "team-uuid",
                99
            ),
            Err(ValidationError::ForgedProject)
        );

        let mut forged = registered.clone();
        forged.team_uuid = "other-team".into();
        assert_eq!(
            validate_grant(
                &forged,
                Some(&registered),
                None,
                "name:demo",
                "team-uuid",
                99
            ),
            Err(ValidationError::ForgedTeam)
        );

        let mut wrong_role = registered.clone();
        wrong_role.role = TeamLeaderRole::Unspecified as i32;
        assert_eq!(
            validate_grant(
                &wrong_role,
                Some(&registered),
                None,
                "name:demo",
                "team-uuid",
                99
            ),
            Err(ValidationError::InvalidRole)
        );
        assert_eq!(
            validate_grant(
                &registered,
                Some(&registered),
                None,
                "name:demo",
                "team-uuid",
                100
            ),
            Err(ValidationError::ExpiredGrant)
        );
        assert_eq!(
            validate_grant(&registered, None, None, "name:demo", "team-uuid", 99),
            Err(ValidationError::UnknownGrant)
        );

        let mut renewed = registered.clone();
        renewed.expires_at_unix_secs = 110;
        assert_eq!(
            validate_grant(
                &registered,
                Some(&registered),
                Some(renewed.expires_at_unix_secs),
                "name:demo",
                "team-uuid",
                105
            ),
            Ok(())
        );
    }

    #[test]
    fn request_replay_is_rejected() {
        let mut replay = ReplayGuard::default();
        let request_id = vec![7; REQUEST_ID_BYTES];
        assert_eq!(replay.consume(&request_id), Ok(()));
        assert_eq!(
            replay.consume(&request_id),
            Err(ValidationError::ReplayedRequest)
        );
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
                cli_bin_dirs: vec![],
                session_host_socket: String::new(),
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
                cli_bin_dirs: vec![],
                session_host_socket: String::new(),
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
                cli_bin_dirs: vec![],
                session_host_socket: String::new(),
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
                cli_bin_dirs: vec![],
                session_host_socket: String::new(),
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
                cli_bin_dirs: vec![],
                session_host_socket: String::new(),
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
        assert!(known.has(capability::SURFACE_AGENT_V1));
        assert!(!known.has("totally.unknown.v1"));

        let many: Vec<String> = (0..5000).map(|i| format!("cap.{i}.v1")).collect();
        let large = PeerCapabilities::from_hello(many);
        assert!(large.has("cap.42.v1"));
        assert!(!large.has("cap.99999.v1"));
    }

    #[test]
    fn supported_capabilities_advertise_surface_agent_v1() {
        // The literal string is the wire contract shared with the Swift
        // side — a typo in the constant would silently break gating on
        // both ends, so pin it here.
        assert_eq!(capability::SURFACE_AGENT_V1, "surface.agent.v1");
        assert!(capability::SUPPORTED.contains(&capability::SURFACE_AGENT_V1));
        assert_eq!(capability::supported_vec().len(), capability::SUPPORTED.len());

        let unique: std::collections::HashSet<&str> =
            capability::SUPPORTED.iter().copied().collect();
        assert_eq!(
            unique.len(),
            capability::SUPPORTED.len(),
            "SUPPORTED contains a duplicate capability string"
        );
    }

    #[test]
    fn ensure_surface_request_and_response_round_trip() {
        let request_id = vec![0x11; 16];
        let request = Envelope {
            seq: 7,
            correlation_id: 0,
            payload: Some(envelope::Payload::EnsureSurfaceRequest(
                EnsureSurfaceRequest {
                    request_id: request_id.clone(),
                    key: "runner-smoke".into(),
                    cwd: "/app/runner".into(),
                    executable: "/bin/sh".into(),
                    args: vec!["-lc".into(), "exec cargo test".into()],
                    restart_policy: EnsureSurfaceRestartPolicy::OnDaemonRestart as i32,
                    // Empty means "terminal" — the pre-`kind` wire default.
                    kind: String::new(),
                },
            )),
        };
        let decoded = Envelope::decode(request.encode_to_vec().as_slice()).expect("decode");
        match decoded.payload.unwrap() {
            envelope::Payload::EnsureSurfaceRequest(value) => {
                assert_eq!(value.request_id, request_id);
                assert_eq!(value.key, "runner-smoke");
                assert_eq!(value.cwd, "/app/runner");
                assert_eq!(
                    value.restart_policy,
                    EnsureSurfaceRestartPolicy::OnDaemonRestart as i32
                );
            }
            _ => panic!("wrong variant"),
        }

        let response = Envelope {
            seq: 8,
            correlation_id: 7,
            payload: Some(envelope::Payload::EnsureSurfaceResponse(
                EnsureSurfaceResponse {
                    request_id: vec![0x11; 16],
                    result: EnsureSurfaceResult::Created as i32,
                    surface_id: vec![0x22; 16],
                    instance_id: vec![0x33; 16],
                    generation: 1,
                    pid: 4242,
                    spec_hash: vec![0x44; 32],
                    error: None,
                },
            )),
        };
        let decoded = Envelope::decode(response.encode_to_vec().as_slice()).expect("decode");
        match decoded.payload.unwrap() {
            envelope::Payload::EnsureSurfaceResponse(value) => {
                assert_eq!(value.result, EnsureSurfaceResult::Created as i32);
                assert_eq!(value.surface_id, vec![0x22; 16]);
                assert_eq!(value.instance_id, vec![0x33; 16]);
                assert_eq!(value.generation, 1);
                assert_eq!(value.pid, 4242);
                assert!(value.error.is_none());
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn ensure_surface_failure_taxonomy_round_trips() {
        let response = EnsureSurfaceResponse {
            request_id: vec![0x55; 16],
            result: EnsureSurfaceResult::Failed as i32,
            error: Some(EnsureSurfaceError {
                code: EnsureSurfaceErrorCode::DuplicateRequestId as i32,
                stage: "validate".into(),
                safe_context: "request_id already consumed".into(),
                exit_code: 0,
                ..Default::default()
            }),
            ..Default::default()
        };
        let decoded =
            EnsureSurfaceResponse::decode(response.encode_to_vec().as_slice()).expect("decode");
        assert_eq!(decoded.result, EnsureSurfaceResult::Failed as i32);
        assert_eq!(
            decoded.error.unwrap().code,
            EnsureSurfaceErrorCode::DuplicateRequestId as i32
        );
    }

    #[test]
    fn ensure_surface_non_executable_response_round_trips() {
        let response = EnsureSurfaceResponse {
            request_id: vec![0x71; 16],
            result: EnsureSurfaceResult::Failed as i32,
            error: Some(EnsureSurfaceError {
                code: EnsureSurfaceErrorCode::CommandPermissionDenied as i32,
                stage: "exec".into(),
                safe_context: "executable is not runnable".into(),
                os_error: 13,
                ..Default::default()
            }),
            ..Default::default()
        };
        let decoded =
            EnsureSurfaceResponse::decode(response.encode_to_vec().as_slice()).expect("decode");
        let error = decoded.error.expect("structured error");
        assert_eq!(
            error.code,
            EnsureSurfaceErrorCode::CommandPermissionDenied as i32
        );
        assert_eq!(error.stage, "exec");
        assert_eq!(error.os_error, 13);
    }

    #[test]
    fn ensure_surface_signaled_response_round_trips() {
        let response = EnsureSurfaceResponse {
            request_id: vec![0x72; 16],
            result: EnsureSurfaceResult::Failed as i32,
            error: Some(EnsureSurfaceError {
                code: EnsureSurfaceErrorCode::CommandSignaled as i32,
                stage: "startup".into(),
                safe_context: "command terminated during startup".into(),
                signal: 15,
                ..Default::default()
            }),
            ..Default::default()
        };
        let decoded =
            EnsureSurfaceResponse::decode(response.encode_to_vec().as_slice()).expect("decode");
        let error = decoded.error.expect("structured error");
        assert_eq!(error.code, EnsureSurfaceErrorCode::CommandSignaled as i32);
        assert_eq!(error.signal, 15);
        assert_eq!(error.exit_code, 0);
    }

    #[test]
    fn ensure_surface_exec_errno_response_round_trips() {
        let response = EnsureSurfaceResponse {
            request_id: vec![0x73; 16],
            result: EnsureSurfaceResult::Failed as i32,
            error: Some(EnsureSurfaceError {
                code: EnsureSurfaceErrorCode::CommandExecError as i32,
                stage: "exec".into(),
                safe_context: "exec failed".into(),
                os_error: 8,
                ..Default::default()
            }),
            ..Default::default()
        };
        let decoded =
            EnsureSurfaceResponse::decode(response.encode_to_vec().as_slice()).expect("decode");
        let error = decoded.error.expect("structured error");
        assert_eq!(error.code, EnsureSurfaceErrorCode::CommandExecError as i32);
        assert_eq!(error.os_error, 8);
        assert_eq!(error.signal, 0);
    }

    #[test]
    fn ensure_surface_exec_handshake_timeout_response_round_trips() {
        let response = EnsureSurfaceResponse {
            request_id: vec![0x74; 16],
            result: EnsureSurfaceResult::Failed as i32,
            error: Some(EnsureSurfaceError {
                code: EnsureSurfaceErrorCode::ExecHandshakeTimeout as i32,
                stage: "exec_handshake".into(),
                safe_context: "exec readiness deadline exceeded".into(),
                ..Default::default()
            }),
            ..Default::default()
        };
        let decoded =
            EnsureSurfaceResponse::decode(response.encode_to_vec().as_slice()).expect("decode");
        let error = decoded.error.expect("structured error");
        assert_eq!(
            error.code,
            EnsureSurfaceErrorCode::ExecHandshakeTimeout as i32
        );
        assert_eq!(error.stage, "exec_handshake");
    }

    #[test]
    fn ensure_surface_oversized_request_is_visible_to_framing() {
        let envelope = Envelope {
            seq: 1,
            correlation_id: 0,
            payload: Some(envelope::Payload::EnsureSurfaceRequest(
                EnsureSurfaceRequest {
                    request_id: vec![0x66; 16],
                    key: "oversized".into(),
                    cwd: "/app/runner".into(),
                    executable: "/bin/sh".into(),
                    args: vec!["x".repeat(MAX_FRAME_BYTES as usize)],
                    restart_policy: EnsureSurfaceRestartPolicy::Never as i32,
                    kind: String::new(),
                },
            )),
        };
        assert!(envelope.encoded_len() > MAX_FRAME_BYTES as usize);
    }

    #[test]
    fn terminate_surface_contract_round_trips() {
        let request = Envelope {
            seq: 9,
            correlation_id: 0,
            payload: Some(envelope::Payload::TerminateSurfaceRequest(
                TerminateSurfaceRequest {
                    request_id: vec![0x81; 16],
                    surface_id: vec![0x82; 16],
                },
            )),
        };
        let decoded = Envelope::decode(request.encode_to_vec().as_slice()).expect("decode request");
        assert!(matches!(
            decoded.payload,
            Some(envelope::Payload::TerminateSurfaceRequest(value))
                if value.request_id == vec![0x81; 16] && value.surface_id == vec![0x82; 16]
        ));

        for result in [
            TerminateSurfaceResult::Terminated,
            TerminateSurfaceResult::NotFound,
            TerminateSurfaceResult::Failed,
        ] {
            let response = TerminateSurfaceResponse {
                request_id: vec![0x81; 16],
                result: result as i32,
                surface_id: vec![0x82; 16],
                error: (result == TerminateSurfaceResult::Failed).then(|| TerminateSurfaceError {
                    code: TerminateSurfaceErrorCode::Internal as i32,
                    stage: "terminate".into(),
                    safe_context: "surface termination failed".into(),
                }),
            };
            let decoded = TerminateSurfaceResponse::decode(response.encode_to_vec().as_slice())
                .expect("decode response");
            assert_eq!(decoded.result, result as i32);
            assert_eq!(decoded.surface_id, vec![0x82; 16]);
        }
    }
}
