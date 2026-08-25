//! Mobile remote-control listener (`docs/mobile-remote-control.md` §4.4–§7)
//! against a fake app socket: auth modes, route allowlist, RPC mapping, error
//! table, body limits, key policy, request-id dedupe, stale-exposure pruning.

#[path = "../src/app_socket.rs"]
mod app_socket;
#[path = "../src/http_mobile.rs"]
mod http_mobile;
#[path = "../src/remote.rs"]
mod remote;

use http_mobile::{
    gui_key, parse_logins, styled_from_grid, AuthMode, GuiKey, MobileConfig, SAFE_KEYS,
};
use remote::{EnableSpec, KeysPolicy, SharedRegistry, TargetKind};
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream, UnixListener};
use tokio::sync::watch;

const LOGIN: &str = "user@example.com";

// ── fake app socket ─────────────────────────────────────────────────────

/// Scripted reply for one method: `Ok(result)` or `Err((code, message))`.
type Script = Arc<Mutex<HashMap<String, Result<Value, (String, String)>>>>;

struct FakeApp {
    path: PathBuf,
    calls: Arc<Mutex<Vec<(String, Value)>>>,
    script: Script,
}

impl FakeApp {
    fn spawn(dir: &Path) -> Self {
        let path = dir.join("term-mesh-fake.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let calls: Arc<Mutex<Vec<(String, Value)>>> = Arc::new(Mutex::new(Vec::new()));
        let script: Script = Arc::new(Mutex::new(HashMap::new()));
        let (calls_bg, script_bg) = (calls.clone(), script.clone());
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    break;
                };
                let calls = calls_bg.clone();
                let script = script_bg.clone();
                tokio::spawn(async move {
                    let (r, mut w) = stream.into_split();
                    let mut line = String::new();
                    if BufReader::new(r).read_line(&mut line).await.unwrap_or(0) == 0 {
                        return;
                    }
                    let req: Value = serde_json::from_str(line.trim()).unwrap();
                    let method = req["method"].as_str().unwrap().to_string();
                    let params = req["params"].clone();
                    calls.lock().unwrap().push((method.clone(), params));
                    let reply = match script.lock().unwrap().get(&method).cloned() {
                        Some(Ok(result)) => json!({ "id": req["id"], "result": result }),
                        Some(Err((code, message))) => {
                            json!({ "id": req["id"], "error": { "code": code, "message": message } })
                        }
                        None => {
                            json!({ "id": req["id"], "error": { "code": "method_not_found", "message": format!("unscripted {method}") } })
                        }
                    };
                    let _ = w.write_all(format!("{reply}\n").as_bytes()).await;
                });
            }
        });
        Self {
            path,
            calls,
            script,
        }
    }

    fn reply(&self, method: &str, result: Value) {
        self.script
            .lock()
            .unwrap()
            .insert(method.to_string(), Ok(result));
    }

    fn fail(&self, method: &str, code: &str, message: &str) {
        self.script.lock().unwrap().insert(
            method.to_string(),
            Err((code.to_string(), message.to_string())),
        );
    }

    fn calls(&self) -> Vec<(String, Value)> {
        self.calls.lock().unwrap().clone()
    }

    fn path_str(&self) -> String {
        self.path.to_string_lossy().into_owned()
    }
}

// ── listener harness ────────────────────────────────────────────────────

struct Harness {
    addr: SocketAddr,
    registry: SharedRegistry,
    _shutdown: watch::Sender<bool>,
}

async fn start(auth: AuthMode, allowed: &[&str]) -> Harness {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let config = MobileConfig {
        addr,
        auth,
        allowed_logins: allowed.iter().map(|s| s.to_string()).collect(),
    };
    let registry = remote::new_registry();
    let state = http_mobile::new_state(config, registry.clone());
    let (tx, rx) = watch::channel(false);
    tokio::spawn(http_mobile::serve_listener(listener, state, rx));
    Harness {
        addr,
        registry,
        _shutdown: tx,
    }
}

async fn start_tailscale() -> Harness {
    start(AuthMode::Tailscale, &[LOGIN]).await
}

async fn expose(h: &Harness, app: &FakeApp, id: &str, kind: TargetKind, keys: KeysPolicy) {
    let spec = EnableSpec {
        surface_id: id.to_string(),
        kind,
        team_name: (kind != TargetKind::Pane).then(|| "live-team".to_string()),
        agent_name: (kind == TargetKind::Agent).then(|| "worker-1".to_string()),
        app_socket: Some(app.path_str()),
        keys,
        leader_request_token: (kind == TargetKind::Leader).then(|| "tok-leader".to_string()),
        ..EnableSpec::default()
    };
    h.registry
        .lock()
        .await
        .upsert(spec, remote::now_unix())
        .unwrap();
}

struct Reply {
    status: u16,
    headers: HashMap<String, String>,
    body: String,
}

impl Reply {
    fn json(&self) -> Value {
        serde_json::from_str(&self.body).unwrap_or_else(|e| panic!("{e}: {}", self.body))
    }
    fn error_code(&self) -> String {
        self.json()["error"]["code"]
            .as_str()
            .unwrap_or("")
            .to_string()
    }
}

async fn http(
    addr: SocketAddr,
    method: &str,
    path: &str,
    headers: &[(&str, &str)],
    body: Option<&str>,
) -> Reply {
    let mut stream = TcpStream::connect(addr).await.unwrap();
    let mut req = format!("{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n");
    for (k, v) in headers {
        req.push_str(&format!("{k}: {v}\r\n"));
    }
    if let Some(b) = body {
        req.push_str(&format!("Content-Length: {}\r\n", b.len()));
    }
    req.push_str("\r\n");
    if let Some(b) = body {
        req.push_str(b);
    }
    stream.write_all(req.as_bytes()).await.unwrap();
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).await.unwrap();
    let text = String::from_utf8_lossy(&raw).into_owned();
    let (head, body) = text.split_once("\r\n\r\n").unwrap_or((&text, ""));
    let mut lines = head.lines();
    let status: u16 = lines
        .next()
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap()
        .parse()
        .unwrap();
    let headers = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
        .collect();
    Reply {
        status,
        headers,
        body: body.to_string(),
    }
}

fn auth() -> [(&'static str, &'static str); 2] {
    [
        ("Tailscale-User-Login", LOGIN),
        ("Content-Type", "application/json"),
    ]
}

async fn get(h: &Harness, path: &str) -> Reply {
    http(h.addr, "GET", path, &auth(), None).await
}

async fn post(h: &Harness, path: &str, body: Value) -> Reply {
    http(h.addr, "POST", path, &auth(), Some(&body.to_string())).await
}

// ── tests ───────────────────────────────────────────────────────────────

#[tokio::test]
async fn health_reports_mode_and_sets_security_headers() {
    let h = start_tailscale().await;
    let r = get(&h, "/api/health").await;
    assert_eq!(r.status, 200, "{}", r.body);
    let j = r.json();
    assert_eq!(j["ok"], true);
    assert_eq!(j["auth_mode"], "tailscale");
    assert_eq!(r.headers["cache-control"], "no-store");
    assert_eq!(r.headers["referrer-policy"], "no-referrer");
    assert_eq!(r.headers["x-content-type-options"], "nosniff");
    assert!(r.headers["content-security-policy"].contains("frame-ancestors 'none'"));
    assert!(r.headers["content-security-policy"].starts_with("default-src 'none'"));
}

#[tokio::test]
async fn tailscale_mode_requires_an_allowed_login_header() {
    let h = start_tailscale().await;
    let none = http(h.addr, "GET", "/api/health", &[], None).await;
    assert_eq!(none.status, 403);
    assert_eq!(none.error_code(), "login_required");
    assert_eq!(
        none.headers["cache-control"], "no-store",
        "errors carry the headers too"
    );

    let wrong = http(
        h.addr,
        "GET",
        "/api/health",
        &[("Tailscale-User-Login", "stranger@example.com")],
        None,
    )
    .await;
    assert_eq!(wrong.status, 403);
    assert_eq!(wrong.error_code(), "login_not_allowed");

    let mixed_case = http(
        h.addr,
        "GET",
        "/api/health",
        &[("Tailscale-User-Login", " User@Example.COM ")],
        None,
    )
    .await;
    assert_eq!(mixed_case.status, 200, "logins compare case-insensitively");

    let page = http(h.addr, "GET", "/", &[], None).await;
    assert_eq!(page.status, 403, "the page itself is behind auth");
}

#[tokio::test]
async fn empty_allowlist_refuses_everyone() {
    let h = start(AuthMode::Tailscale, &[]).await;
    let r = http(
        h.addr,
        "GET",
        "/api/health",
        &[("Tailscale-User-Login", LOGIN)],
        None,
    )
    .await;
    assert_eq!(r.status, 403);
    assert_eq!(r.error_code(), "login_not_allowed");
}

#[tokio::test]
async fn loopback_mode_passes_without_identity() {
    let h = start(AuthMode::Loopback, &[]).await;
    let r = http(h.addr, "GET", "/api/health", &[], None).await;
    assert_eq!(r.status, 200);
    assert_eq!(r.json()["auth_mode"], "loopback");
    let page = http(h.addr, "GET", "/t/some-surface", &[], None).await;
    assert_eq!(page.status, 200);
    assert!(page.headers["content-type"].starts_with("text/html"));
    assert!(page.body.contains("<html"));
}

#[tokio::test]
async fn dashboard_routes_do_not_exist_here() {
    let h = start_tailscale().await;
    for path in [
        "/api/agents",
        "/api/fleet",
        "/api/team",
        "/api/process/stop",
        "/api/tasks",
        "/api/sessions",
    ] {
        let r = get(&h, path).await;
        assert_eq!(r.status, 404, "{path}");
        assert_eq!(r.error_code(), "no_such_route", "{path}");
    }
    let spawn = post(&h, "/api/agents/spawn", json!({})).await;
    assert_eq!(spawn.status, 404);
    let wrong_method = post(&h, "/api/health", json!({})).await;
    assert_eq!(wrong_method.status, 405);
    let wrong_method = get(&h, "/api/targets/x/text").await;
    assert_eq!(wrong_method.status, 405);
}

#[tokio::test]
async fn targets_lists_live_entries_and_prunes_dead_sockets() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    let h = start_tailscale().await;
    let empty = get(&h, "/api/targets").await;
    assert_eq!(empty.status, 200);
    assert_eq!(empty.json()["targets"], json!([]));

    expose(&h, &app, "pane-1", TargetKind::Pane, KeysPolicy::Safe).await;
    expose(&h, &app, "leader-1", TargetKind::Leader, KeysPolicy::None).await;
    let mut dead = EnableSpec {
        surface_id: "dead-1".into(),
        app_socket: Some(dir.path().join("gone.sock").to_string_lossy().into_owned()),
        ..EnableSpec::default()
    };
    dead.kind = TargetKind::Pane;
    h.registry
        .lock()
        .await
        .upsert(dead, remote::now_unix())
        .unwrap();

    let r = get(&h, "/api/targets").await;
    assert_eq!(r.status, 200, "{}", r.body);
    let targets = r.json()["targets"].as_array().unwrap().clone();
    let ids: Vec<&str> = targets
        .iter()
        .map(|t| t["surface_id"].as_str().unwrap())
        .collect();
    assert_eq!(
        ids,
        vec!["pane-1", "leader-1"],
        "dead socket pruned, order = registration"
    );
    assert_eq!(targets[0]["kind"], "pane");
    assert_eq!(targets[0]["source"], "gui");
    assert_eq!(targets[0]["keys"], "safe");
    assert_eq!(targets[1]["kind"], "leader");
    assert_eq!(targets[1]["team_name"], "live-team");
    assert_eq!(targets[1]["keys"], "none");
    assert_eq!(h.registry.lock().await.len(), 2);
}

#[tokio::test]
async fn screen_routes_pane_and_leader_to_the_right_rpc() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply("surface.read_text", json!({ "text": "pane screen" }));
    app.reply(
        "team.read",
        json!({ "text": "leader screen", "agent_name": "leader" }),
    );
    let h = start_tailscale().await;
    expose(&h, &app, "pane-1", TargetKind::Pane, KeysPolicy::Safe).await;
    expose(&h, &app, "leader-1", TargetKind::Leader, KeysPolicy::Safe).await;

    let r = get(&h, "/api/targets/pane-1/screen").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(r.json()["text"], "pane screen");
    assert_eq!(r.json()["lines"], 200);

    let r = get(&h, "/api/targets/leader-1/screen?lines=1000").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(r.json()["text"], "leader screen");
    assert_eq!(r.json()["kind"], "leader");

    let calls = app.calls();
    assert_eq!(calls.len(), 2);
    assert_eq!(calls[0].0, "surface.read_text");
    assert_eq!(calls[0].1["surface_id"], "pane-1");
    assert_eq!(calls[0].1["lines"], 200);
    assert_eq!(calls[0].1["scrollback"], true);
    assert_eq!(calls[1].0, "team.read");
    assert_eq!(calls[1].1["team_name"], "live-team");
    assert_eq!(calls[1].1["agent_name"], "leader");
    assert_eq!(calls[1].1["lines"], 1000);

    for bad in ["?lines=5", "?lines=1001", "?lines=0", "?lines=abc"] {
        let r = get(&h, &format!("/api/targets/pane-1/screen{bad}")).await;
        assert_eq!(r.status, 400, "{bad}: {}", r.body);
    }
    let unknown = get(&h, "/api/targets/nope/screen").await;
    assert_eq!(unknown.status, 404);
    assert_eq!(unknown.error_code(), "not_exposed");
}

fn grid_fixture() -> Value {
    let style = |id: u64, fg: &str, fg_src: &str, extra: Value| {
        let mut v = json!({
            "id": id, "foreground": fg, "background": "#101114",
            "foreground_source": fg_src, "background_source": "default",
            "bold": false, "faint": false, "italic": false, "underline": false,
            "blink": false, "inverse": false, "invisible": false, "strikethrough": false, "overline": false
        });
        for (k, val) in extra.as_object().cloned().unwrap_or_default() {
            v[k] = val;
        }
        v
    };
    json!({
        "format": "render-grid", "columns": 40, "rows": 4, "scrollback_rows": 1,
        "cursor": { "row": 2, "column": 2, "visible": true, "style": "block", "blinking": false },
        "styles": [
            style(0, "#E6E6E6", "default", json!({})),
            style(1, "#FF0000", "palette", json!({ "foreground_palette_index": 1 })),
            style(2, "#E6E6E6", "default", json!({ "faint": true })),
            style(3, "#E6E6E6", "default", json!({ "inverse": true })),
            style(4, "#E6E6E6", "default", json!({ "invisible": true })),
        ],
        "scrollback_spans": [
            { "row": 0, "column": 0, "style_id": 0, "cell_width": 1, "text": "old line" }
        ],
        "row_spans": [
            { "row": 0, "column": 0, "style_id": 1, "cell_width": 1, "text": "red" },
            { "row": 0, "column": 3, "style_id": 0, "cell_width": 1, "text": " plain" },
            { "row": 1, "column": 0, "style_id": 2, "cell_width": 1, "text": "dim" },
            { "row": 1, "column": 5, "style_id": 3, "cell_width": 1, "text": "inv" },
            { "row": 1, "column": 8, "style_id": 4, "cell_width": 1, "text": "secret" },
            { "row": 2, "column": 0, "style_id": 0, "cell_width": 1, "text": "❯ " }
        ]
    })
}

#[tokio::test]
async fn styled_screen_maps_the_render_grid_into_spans_with_a_cursor() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply(
        "surface.read_screen_grid",
        json!({ "grid": grid_fixture() }),
    );
    let h = start_tailscale().await;
    expose(&h, &app, "pane-1", TargetKind::Pane, KeysPolicy::Safe).await;

    let r = get(&h, "/api/targets/pane-1/screen?lines=50&format=styled").await;
    assert_eq!(r.status, 200, "{}", r.body);
    let j = r.json();
    assert_eq!(j["format"], "styled");
    assert_eq!(j["columns"], 40);
    let rows = j["rows"].as_array().unwrap();
    // 1 scrollback row + active rows up to the cursor; the blank 4th active row is dropped.
    assert_eq!(rows.len(), 4, "{}", r.body);
    assert_eq!(rows[0][0], json!({ "t": "old line" }));
    assert_eq!(rows[1][0], json!({ "t": "red", "fg": "#ff0000" }));
    assert_eq!(rows[1][1], json!({ "t": " plain" }));
    assert_eq!(rows[2][0], json!({ "t": "dim", "d": true }));
    assert_eq!(
        rows[2][1],
        json!({ "t": "  " }),
        "column gap filled with spaces"
    );
    assert_eq!(rows[2][2], json!({ "t": "inv", "inv": true }));
    assert_eq!(
        rows[2][3],
        json!({ "t": "      " }),
        "invisible text renders as spaces"
    );
    assert_eq!(rows[3][0], json!({ "t": "❯ " }));
    assert_eq!(j["cursor"], json!({ "row": 3, "col": 2 }));

    let calls = app.calls();
    assert_eq!(calls[0].0, "surface.read_screen_grid");
    assert_eq!(
        calls[0].1,
        json!({ "surface_id": "pane-1", "scrollback_lines": 50 })
    );
}

#[tokio::test]
async fn styled_falls_back_to_text_when_the_app_lacks_the_rpc() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    // surface.read_screen_grid is unscripted → the fake answers method_not_found.
    app.reply("surface.read_text", json!({ "text": "plain only" }));
    let h = start_tailscale().await;
    expose(&h, &app, "pane-1", TargetKind::Pane, KeysPolicy::Safe).await;
    let r = get(&h, "/api/targets/pane-1/screen?format=styled").await;
    assert_eq!(r.status, 200, "{}", r.body);
    let j = r.json();
    assert_eq!(j["format"], "text");
    assert_eq!(j["styled_unavailable"], true);
    assert_eq!(j["text"], "plain only");
    let methods: Vec<String> = app.calls().into_iter().map(|c| c.0).collect();
    assert_eq!(
        methods,
        vec!["surface.read_screen_grid", "surface.read_text"]
    );
}

#[test]
fn styled_from_grid_trims_blank_rows_and_respects_cursor_visibility() {
    let mut grid = grid_fixture();
    let screen = styled_from_grid(&grid);
    assert_eq!(screen.rows.len(), 4);
    assert_eq!(screen.cursor, Some((3, 2)));

    // A cursor below the last content keeps the blank rows up to it.
    grid["cursor"]["row"] = json!(3);
    let screen = styled_from_grid(&grid);
    assert_eq!(screen.rows.len(), 5);
    assert!(screen.rows[4].is_empty());
    assert_eq!(screen.cursor, Some((4, 2)));

    // Hidden cursor: no cursor, blank tail dropped.
    grid["cursor"]["visible"] = json!(false);
    let screen = styled_from_grid(&grid);
    assert_eq!(screen.cursor, None);
    assert_eq!(screen.rows.len(), 4);

    // Empty frame.
    let empty = styled_from_grid(&json!({}));
    assert!(empty.rows.is_empty());
    assert_eq!(empty.cursor, None);
    assert_eq!(empty.columns, 0);
}

#[tokio::test]
async fn expired_exposure_is_not_served() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply("surface.read_text", json!({ "text": "x" }));
    let h = start_tailscale().await;
    let spec = EnableSpec {
        surface_id: "old".into(),
        kind: TargetKind::Pane,
        app_socket: Some(app.path_str()),
        ttl_secs: Some(remote::MIN_TTL_SECS),
        ..EnableSpec::default()
    };
    // Registered far enough in the past to be expired now.
    h.registry
        .lock()
        .await
        .upsert(spec, remote::now_unix() - remote::MIN_TTL_SECS - 1)
        .unwrap();
    let r = get(&h, "/api/targets/old/screen").await;
    assert_eq!(r.status, 404);
    assert!(app.calls().is_empty(), "no RPC for an expired exposure");
    let list = get(&h, "/api/targets").await;
    assert_eq!(list.json()["targets"], json!([]), "listing prunes it");
}

#[tokio::test]
async fn pane_text_is_typed_once_per_request_id() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply("surface.send_text", json!({ "ok": true }));
    let h = start_tailscale().await;
    expose(&h, &app, "pane-1", TargetKind::Pane, KeysPolicy::Safe).await;

    let first = post(
        &h,
        "/api/targets/pane-1/text",
        json!({ "text": "hello", "request_id": "r-1" }),
    )
    .await;
    assert_eq!(first.status, 200, "{}", first.body);
    assert_eq!(first.json()["delivered"], true);
    assert_eq!(first.json()["deduplicated"], false);

    let retry = post(
        &h,
        "/api/targets/pane-1/text",
        json!({ "text": "hello", "request_id": "r-1" }),
    )
    .await;
    assert_eq!(retry.status, 200);
    assert_eq!(retry.json()["deduplicated"], true);

    let no_id = post(&h, "/api/targets/pane-1/text", json!({ "text": "again" })).await;
    assert_eq!(no_id.status, 200);
    assert_eq!(no_id.json()["deduplicated"], false);

    let calls = app.calls();
    assert_eq!(
        calls.len(),
        2,
        "retry with the same request_id must not type twice"
    );
    assert_eq!(calls[0].0, "surface.send_text");
    assert_eq!(
        calls[0].1,
        json!({ "surface_id": "pane-1", "text": "hello" })
    );
    assert_eq!(calls[1].1["text"], "again");

    let empty = post(&h, "/api/targets/pane-1/text", json!({ "text": "   " })).await;
    assert_eq!(empty.status, 400);
    assert_eq!(empty.error_code(), "empty_text");
    let bad_id = post(
        &h,
        "/api/targets/pane-1/text",
        json!({ "text": "x", "request_id": "a b" }),
    )
    .await;
    assert_eq!(bad_id.status, 400);
    assert_eq!(bad_id.error_code(), "invalid_request_id");
}

#[tokio::test]
async fn leader_text_goes_to_the_durable_board_and_returns_202() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply(
        "team.leader.send",
        json!({
            "request_id": "req-9", "stored": true, "wake_dispatched": true,
            "request_replayed": false, "claimed_by_leader": false, "content_bytes": 5
        }),
    );
    let h = start_tailscale().await;
    expose(&h, &app, "leader-1", TargetKind::Leader, KeysPolicy::Safe).await;

    let r = post(
        &h,
        "/api/targets/leader-1/text",
        json!({ "text": "reply", "request_id": "req-9" }),
    )
    .await;
    assert_eq!(r.status, 202, "{}", r.body);
    let j = r.json();
    assert_eq!(j["request_id"], "req-9");
    assert_eq!(j["stored"], true);
    assert_eq!(j["wake_dispatched"], true);
    assert_eq!(j["request_replayed"], false);
    assert_eq!(j["claimed_by_leader"], false);
    assert!(
        j.get("content_bytes").is_none(),
        "only the documented fields pass through"
    );

    let calls = app.calls();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].0, "team.leader.send");
    assert_eq!(
        calls[0].1,
        json!({ "team_name": "live-team", "text": "reply", "request_id": "req-9" })
    );

    // The durable board owns idempotency for leaders: a retry is forwarded.
    let again = post(
        &h,
        "/api/targets/leader-1/text",
        json!({ "text": "reply", "request_id": "req-9" }),
    )
    .await;
    assert_eq!(again.status, 202);
    assert_eq!(app.calls().len(), 2);
}

#[tokio::test]
async fn requests_exist_only_for_leaders() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply(
        "team.leader.request.list",
        json!({ "team_name": "live-team", "count": 1, "requests": [{ "id": "req-9", "status": "queued" }] }),
    );
    let h = start_tailscale().await;
    expose(&h, &app, "pane-1", TargetKind::Pane, KeysPolicy::Safe).await;
    expose(&h, &app, "leader-1", TargetKind::Leader, KeysPolicy::Safe).await;

    let pane = get(&h, "/api/targets/pane-1/requests").await;
    assert_eq!(pane.status, 409);
    assert_eq!(pane.error_code(), "not_leader");

    let leader = get(&h, "/api/targets/leader-1/requests").await;
    assert_eq!(leader.status, 200, "{}", leader.body);
    assert_eq!(leader.json()["count"], 1);
    assert_eq!(leader.json()["requests"][0]["id"], "req-9");
    assert_eq!(
        app.calls()[0].1,
        json!({ "team_name": "live-team", "leader_request_token": "tok-leader" })
    );
    // The token never leaves the daemon: not in the target listing.
    let listing = get(&h, "/api/targets").await;
    assert!(!listing.body.contains("tok-leader"), "{}", listing.body);
}

#[tokio::test]
async fn keys_follow_policy_and_the_safe_allowlist() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply("surface.send_key", json!({ "ok": true }));
    app.reply("surface.send_text", json!({ "ok": true }));
    let h = start_tailscale().await;
    expose(&h, &app, "locked", TargetKind::Pane, KeysPolicy::None).await;
    expose(&h, &app, "open", TargetKind::Pane, KeysPolicy::Safe).await;

    let locked = post(&h, "/api/targets/locked/key", json!({ "key": "Enter" })).await;
    assert_eq!(locked.status, 403);
    assert_eq!(locked.error_code(), "keys_disabled");

    let forbidden = post(&h, "/api/targets/open/key", json!({ "key": "q" })).await;
    assert_eq!(forbidden.status, 403);
    assert_eq!(forbidden.error_code(), "key_not_allowed");
    let forbidden = post(&h, "/api/targets/open/key", json!({ "key": "C-d" })).await;
    assert_eq!(forbidden.status, 403);
    assert!(app.calls().is_empty(), "refused keys never reach the app");

    for key in ["Enter", "y", "Up", "C-c", "7", "Escape", "Backspace"] {
        let r = post(&h, "/api/targets/open/key", json!({ "key": key })).await;
        assert_eq!(r.status, 200, "{key}: {}", r.body);
        assert_eq!(r.json()["delivered"], true);
    }
    let calls = app.calls();
    assert_eq!(
        calls[0],
        (
            "surface.send_key".into(),
            json!({ "surface_id": "open", "key": "enter" })
        )
    );
    assert_eq!(
        calls[1],
        (
            "surface.send_text".into(),
            json!({ "surface_id": "open", "text": "y" })
        )
    );
    assert_eq!(
        calls[2],
        (
            "surface.send_key".into(),
            json!({ "surface_id": "open", "key": "up" })
        )
    );
    assert_eq!(
        calls[3],
        (
            "surface.send_key".into(),
            json!({ "surface_id": "open", "key": "ctrl-c" })
        )
    );
    assert_eq!(
        calls[4],
        (
            "surface.send_text".into(),
            json!({ "surface_id": "open", "text": "7" })
        )
    );
    assert_eq!(
        calls[5],
        (
            "surface.send_key".into(),
            json!({ "surface_id": "open", "key": "escape" })
        )
    );
    assert_eq!(
        calls[6],
        (
            "surface.send_key".into(),
            json!({ "surface_id": "open", "key": "backspace" })
        )
    );
}

#[test]
fn every_safe_key_has_a_gui_mapping_and_nothing_else_does() {
    for key in SAFE_KEYS {
        assert!(gui_key(key).is_some(), "{key}");
    }
    assert_eq!(gui_key("Enter"), Some(GuiKey::Named("enter")));
    assert_eq!(gui_key("Down"), Some(GuiKey::Named("down")));
    assert_eq!(gui_key("y"), Some(GuiKey::Text("y")));
    assert_eq!(gui_key("enter"), None, "exact match only");
    assert_eq!(gui_key("0"), None);
    assert_eq!(gui_key("C-d"), None);
    assert_eq!(gui_key(""), None);
}

#[tokio::test]
async fn not_found_from_the_app_drops_the_exposure() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.fail("surface.read_text", "not_found", "Surface not found");
    let h = start_tailscale().await;
    expose(&h, &app, "pane-1", TargetKind::Pane, KeysPolicy::Safe).await;

    let r = get(&h, "/api/targets/pane-1/screen").await;
    assert_eq!(r.status, 404, "{}", r.body);
    assert_eq!(r.error_code(), "target_gone");
    assert!(
        h.registry.lock().await.get("pane-1").is_none(),
        "exposure removed"
    );
    let again = get(&h, "/api/targets/pane-1/screen").await;
    assert_eq!(again.error_code(), "not_exposed");
}

#[tokio::test]
async fn other_app_errors_map_to_502_and_a_dead_socket_to_503() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.fail("surface.send_text", "timeout", "surface busy");
    let h = start_tailscale().await;
    expose(&h, &app, "pane-1", TargetKind::Pane, KeysPolicy::Safe).await;
    let r = post(&h, "/api/targets/pane-1/text", json!({ "text": "x" })).await;
    assert_eq!(r.status, 502, "{}", r.body);
    assert_eq!(r.error_code(), "app_rpc_failed");
    assert!(
        h.registry.lock().await.get("pane-1").is_some(),
        "kept: the surface may recover"
    );

    // A socket file whose listener is gone: connect is refused.
    let stale = dir.path().join("stale.sock");
    drop(UnixListener::bind(&stale).unwrap());
    let spec = EnableSpec {
        surface_id: "stale-pane".into(),
        kind: TargetKind::Pane,
        app_socket: Some(stale.to_string_lossy().into_owned()),
        ..EnableSpec::default()
    };
    h.registry
        .lock()
        .await
        .upsert(spec, remote::now_unix())
        .unwrap();
    let r = get(&h, "/api/targets/stale-pane/screen").await;
    assert_eq!(r.status, 503, "{}", r.body);
    assert_eq!(r.error_code(), "app_unavailable");
}

#[tokio::test]
async fn post_bodies_are_bounded_and_must_be_json() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply("surface.send_text", json!({}));
    let h = start_tailscale().await;
    expose(&h, &app, "pane-1", TargetKind::Pane, KeysPolicy::Safe).await;

    let huge = json!({ "text": "x".repeat(http_mobile::MAX_BODY_BYTES + 1) }).to_string();
    let r = http(
        h.addr,
        "POST",
        "/api/targets/pane-1/text",
        &auth(),
        Some(&huge),
    )
    .await;
    assert_eq!(r.status, 413);

    let r = http(
        h.addr,
        "POST",
        "/api/targets/pane-1/text",
        &[
            ("Tailscale-User-Login", LOGIN),
            ("Content-Type", "text/plain"),
        ],
        Some("text=hi"),
    )
    .await;
    assert_eq!(r.status, 415);

    let r = http(
        h.addr,
        "POST",
        "/api/targets/pane-1/text",
        &auth(),
        Some("{not json"),
    )
    .await;
    assert_eq!(r.status, 400);

    let r = post(&h, "/api/targets/pane-1/text", json!({ "nope": 1 })).await;
    assert_eq!(r.status, 422, "missing field");
    assert!(app.calls().is_empty());
}

#[test]
fn login_lists_are_normalized() {
    let parsed = parse_logins(Some(" A@Example.com, ,b@example.com ,"));
    let expected: BTreeSet<String> = ["a@example.com", "b@example.com"]
        .into_iter()
        .map(String::from)
        .collect();
    assert_eq!(parsed, expected);
    assert!(parse_logins(None).is_empty());
}

#[test]
fn config_from_env_defaults_to_tailscale_and_rejects_bad_modes() {
    // Env is process-global; every value here is unique to this test.
    std::env::set_var(remote::ENV_LISTENER_ADDR, "127.0.0.1:9877");
    std::env::remove_var(http_mobile::ENV_AUTH_MODE);
    std::env::set_var(http_mobile::ENV_ALLOWED_LOGINS, "Me@Example.com");
    let cfg = MobileConfig::from_env().unwrap();
    assert_eq!(cfg.auth, AuthMode::Tailscale);
    assert!(cfg.allowed_logins.contains("me@example.com"));
    assert_eq!(cfg.addr.to_string(), "127.0.0.1:9877");

    std::env::set_var(http_mobile::ENV_AUTH_MODE, "Loopback");
    assert_eq!(MobileConfig::from_env().unwrap().auth, AuthMode::Loopback);

    std::env::set_var(http_mobile::ENV_AUTH_MODE, "open");
    assert!(MobileConfig::from_env()
        .unwrap_err()
        .contains("loopback|tailscale"));

    std::env::set_var(http_mobile::ENV_AUTH_MODE, "tailscale");
    std::env::set_var(remote::ENV_LISTENER_ADDR, "0.0.0.0:9877");
    assert!(MobileConfig::from_env().unwrap_err().contains("loopback"));
    std::env::remove_var(remote::ENV_LISTENER_ADDR);
    std::env::remove_var(http_mobile::ENV_AUTH_MODE);
    std::env::remove_var(http_mobile::ENV_ALLOWED_LOGINS);
}

#[tokio::test]
async fn agent_targets_take_turns_and_show_the_transcript() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply(
        "team.agent.transcript",
        json!({
            "team_name": "live-team", "agent_name": "worker-1", "running": true, "thinking": false,
            "in_flight": true, "summary": "working", "total": 2,
            "entries": [
                { "id": "e1", "kind": "said", "speaker": "person", "text": "hello" },
                { "id": "e2", "kind": "answered", "text": "hi there" }
            ]
        }),
    );
    app.reply("team.send", json!({ "delivery_scope": "transport_write" }));
    app.reply("team.interrupt", json!({ "interrupted": true }));
    app.reply("team.read", json!({ "text": "hello\nhi there" }));
    let h = start_tailscale().await;
    expose(&h, &app, "panel-1", TargetKind::Agent, KeysPolicy::Safe).await;

    let listed = targets_by_id_for(&h).await;
    assert_eq!(listed["panel-1"]["kind"], "agent");
    assert_eq!(listed["panel-1"]["agent_name"], "worker-1");

    let t = get(&h, "/api/targets/panel-1/transcript?limit=50").await;
    assert_eq!(t.status, 200, "{}", t.body);
    let j = t.json();
    assert_eq!(j["running"], true);
    assert_eq!(j["entries"][1]["text"], "hi there");
    assert_eq!(app.calls()[0].0, "team.agent.transcript");
    assert_eq!(
        app.calls()[0].1,
        json!({ "team_name": "live-team", "agent_name": "worker-1", "limit": 50 })
    );

    let sent = post(
        &h,
        "/api/targets/panel-1/text",
        json!({ "text": "do it", "request_id": "a-1" }),
    )
    .await;
    assert_eq!(sent.status, 202, "{}", sent.body);
    assert_eq!(sent.json()["kind"], "agent");
    assert_eq!(sent.json()["delivery_scope"], "transport_write");
    assert_eq!(app.calls()[1].0, "team.send");
    assert_eq!(
        app.calls()[1].1,
        json!({ "team_name": "live-team", "agent_name": "worker-1", "text": "do it" })
    );
    let again = post(
        &h,
        "/api/targets/panel-1/text",
        json!({ "text": "do it", "request_id": "a-1" }),
    )
    .await;
    assert_eq!(again.json()["deduplicated"], true);
    assert_eq!(app.calls().len(), 2, "retry must not send a second turn");

    let stop = http(
        h.addr,
        "POST",
        "/api/targets/panel-1/interrupt",
        &auth(),
        Some("{}"),
    )
    .await;
    assert_eq!(stop.status, 200, "{}", stop.body);
    assert_eq!(stop.json()["interrupted"], true);
    assert_eq!(app.calls()[2].0, "team.interrupt");

    let key = post(&h, "/api/targets/panel-1/key", json!({ "key": "Enter" })).await;
    assert_eq!(key.status, 409);
    assert_eq!(key.error_code(), "not_a_terminal");

    let screen = get(&h, "/api/targets/panel-1/screen?format=styled").await;
    assert_eq!(screen.status, 200, "{}", screen.body);
    assert_eq!(screen.json()["format"], "text");
    assert_eq!(screen.json()["text"], "hello\nhi there");
    assert_eq!(app.calls()[3].0, "team.read");

    // Terminal targets have no transcript or interrupt.
    expose(&h, &app, "pane-1", TargetKind::Pane, KeysPolicy::Safe).await;
    let none = get(&h, "/api/targets/pane-1/transcript").await;
    assert_eq!(none.status, 409);
    assert_eq!(none.error_code(), "not_an_agent");
}

#[tokio::test]
async fn terminal_chat_submits_one_turn_while_terminal_mode_only_types() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply("surface.send_turn", json!({ "submitted": true }));
    app.reply("surface.send_text", json!({ "queued": false }));
    let h = start_tailscale().await;
    let mut spec = EnableSpec {
        surface_id: "pane-chat".to_string(),
        kind: TargetKind::Pane,
        chat_capable: true,
        agent_cli: "codex".to_string(),
        session_id: Some("session-1".to_string()),
        app_socket: Some(app.path_str()),
        ..EnableSpec::default()
    };
    h.registry
        .lock()
        .await
        .upsert(spec.clone(), remote::now_unix())
        .unwrap();

    let chat = post(
        &h,
        "/api/targets/pane-chat/text",
        json!({
            "text": "whole turn", "mode": "chat", "request_id": "chat-1"
        }),
    )
    .await;
    assert_eq!(chat.status, 200, "{}", chat.body);
    assert_eq!(app.calls()[0].0, "surface.send_turn");
    assert_eq!(app.calls()[0].1["text"], "whole turn");

    let terminal = post(
        &h,
        "/api/targets/pane-chat/text",
        json!({
            "text": "typed", "mode": "terminal", "request_id": "terminal-1"
        }),
    )
    .await;
    assert_eq!(terminal.status, 200, "{}", terminal.body);
    assert_eq!(app.calls()[1].0, "surface.send_text");

    spec.surface_id = "plain".to_string();
    spec.chat_capable = false;
    spec.session_id = None;
    h.registry
        .lock()
        .await
        .upsert(spec, remote::now_unix())
        .unwrap();
    let unavailable = post(
        &h,
        "/api/targets/plain/text",
        json!({
            "text": "no", "mode": "chat", "request_id": "plain-1"
        }),
    )
    .await;
    assert_eq!(unavailable.status, 409);
    assert_eq!(unavailable.error_code(), "chat_unavailable");
}

#[test]
fn terminal_chat_running_tracks_the_live_surface_roster() {
    let live = json!({ "surfaces": [{ "id": "live-pane" }] });
    assert!(http_mobile::surface_roster_contains(&live, "live-pane"));
    assert!(!http_mobile::surface_roster_contains(&live, "other"));
    assert!(!http_mobile::surface_roster_contains(
        &json!({ "surfaces": [] }),
        "live-pane"
    ));
}

#[tokio::test]
async fn failed_terminal_chat_delivery_does_not_poison_request_dedupe() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.fail("surface.send_turn", "busy", "try again");
    let h = start_tailscale().await;
    let spec = EnableSpec {
        surface_id: "retry-chat".into(),
        kind: TargetKind::Pane,
        chat_capable: true,
        agent_cli: "codex".into(),
        session_id: Some("session-1".into()),
        app_socket: Some(app.path_str()),
        ..EnableSpec::default()
    };
    h.registry
        .lock()
        .await
        .upsert(spec, remote::now_unix())
        .unwrap();
    let body = json!({ "text": "retry me", "mode": "chat", "request_id": "retry-1" });

    let first = post(&h, "/api/targets/retry-chat/text", body.clone()).await;
    assert_eq!(first.status, 502, "{}", first.body);
    app.reply("surface.send_turn", json!({ "submitted": true }));
    let retry = post(&h, "/api/targets/retry-chat/text", body).await;
    assert_eq!(retry.status, 200, "{}", retry.body);
    assert_eq!(retry.json()["deduplicated"], false);
    assert_eq!(
        app.calls()
            .iter()
            .filter(|(m, _)| m == "surface.send_turn")
            .count(),
        2
    );
}

#[test]
fn session_logs_normalize_to_the_mobile_chat_shape() {
    let claude = vec![
        json!({ "type": "user", "uuid": "u1", "message": { "content": "hello" } }),
        json!({ "type": "assistant", "uuid": "a1", "message": { "content": [
            { "type": "text", "text": "hi" },
            { "type": "tool_use", "id": "t1", "name": "Bash", "input": { "command": "pwd" } }
        ] } }),
        json!({ "type": "user", "uuid": "u2", "message": { "content": [
            { "type": "tool_result", "tool_use_id": "t1", "content": "/repo" }
        ] } }),
    ];
    let c = http_mobile::claude_entries(&claude);
    assert_eq!(c[0]["kind"], "said");
    assert_eq!(c[1]["kind"], "answered");
    assert_eq!(c[2]["kind"], "tool");
    assert_eq!(c[2]["result"], "/repo");
    assert_eq!(c[2]["running"], false);

    let codex = vec![
        json!({ "type": "response_item", "payload": { "type": "message", "id": "hidden", "role": "user", "content": [{ "type": "input_text", "text": "# AGENTS.md instructions for /repo" }] } }),
        json!({ "type": "response_item", "payload": { "type": "message", "id": "m1", "role": "user", "content": [{ "type": "input_text", "text": "hello" }] } }),
        json!({ "type": "response_item", "payload": { "type": "custom_tool_call", "id": "x1", "call_id": "call1", "name": "exec", "input": "pwd" } }),
        json!({ "type": "response_item", "payload": { "type": "custom_tool_call_output", "id": "x2", "call_id": "call1", "output": [{ "type": "input_text", "text": "/repo" }] } }),
        json!({ "type": "response_item", "payload": { "type": "message", "id": "m2", "role": "assistant", "content": [{ "type": "output_text", "text": "done" }] } }),
    ];
    let x = http_mobile::codex_entries(&codex);
    assert!(x.iter().all(|entry| entry["id"] != "hidden"));
    assert_eq!(x[0]["kind"], "said");
    assert_eq!(x[1]["kind"], "tool");
    assert_eq!(x[1]["result"], "/repo");
    assert_eq!(x[2]["kind"], "answered");

    let active = vec![
        json!({ "type": "event_msg", "payload": { "type": "task_started" } }),
        json!({ "type": "response_item", "payload": { "type": "message", "role": "assistant", "content": [{ "type": "output_text", "text": "streaming" }] } }),
    ];
    assert_eq!(http_mobile::codex_turn_in_flight(&active), Some(true));
    let complete = vec![
        active[0].clone(),
        json!({ "type": "event_msg", "payload": { "type": "task_complete" } }),
    ];
    assert_eq!(http_mobile::codex_turn_in_flight(&complete), Some(false));

    let secret = vec![json!({ "type": "response_item", "payload": {
        "type": "custom_tool_call", "id": "secret", "call_id": "secret-call",
        "name": "exec", "input": "OPENAI_API_KEY=do-not-show echo ok"
    } })];
    let hidden = http_mobile::codex_entries(&secret);
    assert_eq!(hidden[0]["headline"], "[credential redacted]");
    for raw in [
        "GITHUB_TOKEN=ghp_example",
        "HF_TOKEN=hf_example",
        "AWS_ACCESS_KEY_ID=AKIAEXAMPLE",
        "Authorization: Basic abc",
        "https://example.test/?token=abc",
        "ghp_exampletoken",
        "sk-exampletoken",
    ] {
        assert_eq!(
            http_mobile::redact_session_text(raw),
            "[credential redacted]"
        );
    }
}

#[test]
fn session_tail_reader_appends_without_reparsing_or_losing_partial_lines() {
    use std::io::Write;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.jsonl");
    std::fs::write(&path, b"{\"type\":\"one\"}\n{\"type\":").unwrap();
    let first = http_mobile::tail_json_lines(&path).unwrap();
    assert_eq!(first.len(), 1);
    assert_eq!(first[0]["type"], "one");

    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap();
    write!(file, "\"two\"}}\n{{\"type\":\"three\"}}\n").unwrap();
    let second = http_mobile::tail_json_lines(&path).unwrap();
    assert_eq!(second.len(), 3);
    assert_eq!(second[1]["type"], "two");
    assert_eq!(second[2]["type"], "three");
    let unchanged = http_mobile::tail_json_lines(&path).unwrap();
    assert_eq!(unchanged, second);
}

async fn targets_by_id_for(h: &Harness) -> serde_json::Map<String, Value> {
    let r = get(h, "/api/targets").await;
    let mut out = serde_json::Map::new();
    for t in r.json()["targets"].as_array().unwrap() {
        out.insert(t["surface_id"].as_str().unwrap().to_string(), t.clone());
    }
    out
}
