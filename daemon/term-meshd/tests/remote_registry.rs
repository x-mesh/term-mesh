//! Mobile remote-control exposure registry (`docs/mobile-remote-control.md`
//! §4.1): register / refresh / remove / TTL expiry / stale prune / validation.

#[path = "../src/remote.rs"]
mod remote;

use remote::{
    app_socket_alive, parse_loopback_addr, target_url, EnableSpec, KeysPolicy, Registry,
    TargetKind, DEFAULT_TTL_SECS, MAX_TTL_SECS, MIN_TTL_SECS,
};

fn pane_spec(id: &str) -> EnableSpec {
    EnableSpec {
        surface_id: id.to_string(),
        kind: TargetKind::Pane,
        app_socket: Some("/tmp/term-mesh-test.sock".to_string()),
        ..EnableSpec::default()
    }
}

#[test]
fn upsert_registers_pane_with_default_ttl_and_owner() {
    let mut reg = Registry::new();
    let entry = reg
        .upsert(pane_spec("11111111-2222-3333-4444-555555555555"), 1_000)
        .unwrap();
    assert_eq!(entry.kind, TargetKind::Pane);
    assert_eq!(entry.keys, KeysPolicy::Safe);
    assert_eq!(entry.owner, "local");
    assert_eq!(entry.created_at, 1_000);
    assert_eq!(entry.expires_at, 1_000 + DEFAULT_TTL_SECS);
    assert_eq!(reg.len(), 1);
    assert_eq!(
        reg.get("11111111-2222-3333-4444-555555555555"),
        Some(&entry)
    );
}

#[test]
fn reregistering_replaces_entry_and_restarts_ttl() {
    let mut reg = Registry::new();
    let first = reg.upsert(pane_spec("surf-a"), 100).unwrap();
    let mut again = pane_spec("surf-a");
    again.keys = KeysPolicy::None;
    again.ttl_secs = Some(3_600);
    again.title = "claude".into();
    let second = reg.upsert(again, 500).unwrap();
    assert_eq!(reg.len(), 1, "same surface must not duplicate");
    assert_ne!(first, second);
    assert_eq!(second.keys, KeysPolicy::None);
    assert_eq!(second.title, "claude");
    assert_eq!(second.created_at, 500);
    assert_eq!(second.expires_at, 500 + 3_600);
}

#[test]
fn remove_reports_whether_anything_was_there() {
    let mut reg = Registry::new();
    reg.upsert(pane_spec("surf-a"), 1).unwrap();
    assert!(reg.remove("surf-a"));
    assert!(!reg.remove("surf-a"));
    assert!(reg.is_empty());
}

#[test]
fn expired_entry_reads_as_absent_before_prune() {
    let mut reg = Registry::new();
    let mut spec = pane_spec("surf-a");
    spec.ttl_secs = Some(MIN_TTL_SECS);
    reg.upsert(spec, 1_000).unwrap();
    assert!(reg.get_live("surf-a", 1_000 + MIN_TTL_SECS - 1).is_some());
    assert!(reg.get_live("surf-a", 1_000 + MIN_TTL_SECS).is_none());
    // Still stored until prune runs.
    assert!(reg.get("surf-a").is_some());
}

#[test]
fn prune_drops_expired_and_dead_entries_and_reports_them() {
    let mut reg = Registry::new();
    let mut expired = pane_spec("expired");
    expired.ttl_secs = Some(MIN_TTL_SECS);
    reg.upsert(expired, 0).unwrap();
    reg.upsert(pane_spec("dead"), 0).unwrap();
    let mut live = pane_spec("live");
    live.app_socket = Some("/tmp/live.sock".into());
    reg.upsert(live, 0).unwrap();

    let pruned = reg.prune(MIN_TTL_SECS, |entry| entry.surface_id != "dead");
    assert_eq!(pruned, vec!["dead".to_string(), "expired".to_string()]);
    let ids: Vec<String> = reg.list().into_iter().map(|e| e.surface_id).collect();
    assert_eq!(ids, vec!["live".to_string()]);
}

#[test]
fn list_is_in_registration_order_even_within_one_second() {
    let mut reg = Registry::new();
    reg.upsert(pane_spec("z-first"), 20).unwrap();
    reg.upsert(pane_spec("a-second"), 20).unwrap();
    reg.upsert(pane_spec("m-third"), 20).unwrap();
    let ids: Vec<String> = reg.list().into_iter().map(|e| e.surface_id).collect();
    assert_eq!(ids, vec!["z-first", "a-second", "m-third"]);

    // Re-registering moves the entry to the end; removing forgets its slot.
    reg.upsert(pane_spec("z-first"), 21).unwrap();
    let ids: Vec<String> = reg.list().into_iter().map(|e| e.surface_id).collect();
    assert_eq!(ids, vec!["a-second", "m-third", "z-first"]);
    assert!(reg.remove("m-third"));
    let ids: Vec<String> = reg.list().into_iter().map(|e| e.surface_id).collect();
    assert_eq!(ids, vec!["a-second", "z-first"]);
}

#[test]
fn app_socket_liveness_checks_the_path_type() {
    let dir = tempfile::tempdir().unwrap();
    let sock_path = dir.path().join("app.sock");
    let _listener = std::os::unix::net::UnixListener::bind(&sock_path).unwrap();
    let plain = dir.path().join("not-a-socket");
    std::fs::write(&plain, b"x").unwrap();

    let mut reg = Registry::new();
    let mut live = pane_spec("live");
    live.app_socket = Some(sock_path.to_string_lossy().into_owned());
    let live = reg.upsert(live, 0).unwrap();
    let mut file = pane_spec("file");
    file.app_socket = Some(plain.to_string_lossy().into_owned());
    let file = reg.upsert(file, 0).unwrap();
    let mut missing = pane_spec("missing");
    missing.app_socket = Some(dir.path().join("gone.sock").to_string_lossy().into_owned());
    let missing = reg.upsert(missing, 0).unwrap();
    let mut daemon_owned = pane_spec("daemon");
    daemon_owned.app_socket = None;
    let daemon_owned = reg.upsert(daemon_owned, 0).unwrap();

    assert!(app_socket_alive(&live));
    assert!(!app_socket_alive(&file));
    assert!(!app_socket_alive(&missing));
    assert!(
        app_socket_alive(&daemon_owned),
        "daemon-owned entries are the listener's concern"
    );

    let pruned = reg.prune(1, app_socket_alive);
    assert_eq!(pruned, vec!["file".to_string(), "missing".to_string()]);
}

#[test]
fn validation_rejects_what_the_listener_cannot_serve() {
    let mut reg = Registry::new();

    let mut empty = pane_spec("");
    empty.surface_id = "   ".into();
    assert!(reg
        .upsert(empty, 0)
        .unwrap_err()
        .contains("surface_id is required"));

    let mut long = pane_spec("");
    long.surface_id = "x".repeat(remote::MAX_SURFACE_ID_BYTES + 1);
    assert!(reg.upsert(long, 0).unwrap_err().contains("too long"));

    let mut bad_chars = pane_spec("");
    bad_chars.surface_id = "../etc".into();
    assert!(reg
        .upsert(bad_chars, 0)
        .unwrap_err()
        .contains("alphanumeric"));

    let mut leader = pane_spec("surf-leader");
    leader.kind = TargetKind::Leader;
    assert!(reg
        .upsert(leader.clone(), 0)
        .unwrap_err()
        .contains("team_name"));
    leader.team_name = Some("live-team".into());
    let entry = reg.upsert(leader, 0).unwrap();
    assert_eq!(entry.kind, TargetKind::Leader);
    assert_eq!(entry.team_name.as_deref(), Some("live-team"));

    let mut relative = pane_spec("surf-rel");
    relative.app_socket = Some("relative.sock".into());
    assert!(reg.upsert(relative, 0).unwrap_err().contains("absolute"));

    assert!(reg.is_empty() || reg.len() == 1);
}

#[test]
fn leader_request_token_is_kept_but_never_serialized() {
    let mut reg = Registry::new();
    let mut leader = pane_spec("surf-leader");
    leader.kind = TargetKind::Leader;
    leader.team_name = Some("live-team".into());
    leader.leader_request_token = Some(" tok-123 ".into());
    let entry = reg.upsert(leader, 0).unwrap();
    assert_eq!(entry.leader_request_token.as_deref(), Some("tok-123"));
    let json = serde_json::to_string(&entry).unwrap();
    assert!(!json.contains("tok-123"), "{json}");
    assert!(!json.contains("leader_request_token"), "{json}");
}

#[test]
fn ttl_is_clamped_not_rejected() {
    let mut reg = Registry::new();
    let mut tiny = pane_spec("tiny");
    tiny.ttl_secs = Some(1);
    assert_eq!(reg.upsert(tiny, 0).unwrap().expires_at, MIN_TTL_SECS);
    let mut huge = pane_spec("huge");
    huge.ttl_secs = Some(u64::MAX);
    assert_eq!(reg.upsert(huge, 0).unwrap().expires_at, MAX_TTL_SECS);
}

#[test]
fn enable_spec_deserializes_with_defaults() {
    let spec: EnableSpec = serde_json::from_value(serde_json::json!({
        "surface_id": "surf-json",
        "app_socket": "/tmp/app.sock"
    }))
    .unwrap();
    assert_eq!(spec.kind, TargetKind::Pane);
    assert_eq!(spec.keys, KeysPolicy::Safe);
    assert_eq!(spec.ttl_secs, None);

    let leader: EnableSpec = serde_json::from_value(serde_json::json!({
        "surface_id": "surf-leader",
        "kind": "leader",
        "team_name": "live-team",
        "keys": "none",
        "ttl_secs": 120
    }))
    .unwrap();
    assert_eq!(leader.kind, TargetKind::Leader);
    assert_eq!(leader.keys, KeysPolicy::None);
    assert_eq!(leader.ttl_secs, Some(120));
}

#[test]
fn listener_addr_accepts_only_loopback() {
    assert_eq!(
        parse_loopback_addr("127.0.0.1:9877").unwrap().to_string(),
        "127.0.0.1:9877"
    );
    assert!(parse_loopback_addr("[::1]:9877").is_ok());
    let err = parse_loopback_addr("0.0.0.0:9877").unwrap_err();
    assert!(err.contains("loopback"), "{err}");
    assert!(parse_loopback_addr("192.168.0.2:9877").is_err());
    assert!(parse_loopback_addr("not-an-addr").is_err());

    let addr = parse_loopback_addr("127.0.0.1:9877").unwrap();
    assert_eq!(
        target_url(&addr, "surf-a"),
        "http://127.0.0.1:9877/t/surf-a"
    );
}
