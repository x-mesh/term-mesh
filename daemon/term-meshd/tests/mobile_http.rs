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
    embedded_page_js, gui_key, parse_logins, styled_from_grid, AuthMode, GuiKey, MobileConfig,
    SAFE_KEYS,
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
    start_with_resolver(auth, allowed, None).await
}

async fn start_with_surface_access(
    auth: AuthMode,
    allowed: &[&str],
    surface_access: http_mobile::SurfaceAccess,
) -> Harness {
    start_inner(auth, allowed, None, Some(surface_access)).await
}

async fn start_with_resolver(
    auth: AuthMode,
    allowed: &[&str],
    session_resolver: Option<http_mobile::SessionResolver>,
) -> Harness {
    start_inner(auth, allowed, session_resolver, None).await
}

async fn start_inner(
    auth: AuthMode,
    allowed: &[&str],
    session_resolver: Option<http_mobile::SessionResolver>,
    surface_access: Option<http_mobile::SurfaceAccess>,
) -> Harness {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let config = MobileConfig {
        addr,
        auth,
        allowed_logins: allowed.iter().map(|s| s.to_string()).collect(),
    };
    let registry = remote::new_registry();
    let state = http_mobile::new_state(config, registry.clone(), session_resolver, surface_access);
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
async fn screen_reads_a_daemon_owned_surface_without_an_app() {
    // A peer host owns its surfaces itself: there is no app socket to ask, so
    // the listener has to read them from this daemon.
    let access: http_mobile::SurfaceAccess =
        std::sync::Arc::new(|method: &str, params: &serde_json::Value| match method {
            "surface.read_text" => {
                assert_eq!(params["surface_id"], "host-pane");
                Some(Ok(json!({ "text": "host screen" })))
            }
            _ => None,
        });
    let h = start_with_surface_access(AuthMode::Tailscale, &[LOGIN], access).await;
    h.registry
        .lock()
        .await
        .upsert(
            EnableSpec {
                surface_id: "host-pane".to_string(),
                kind: TargetKind::Pane,
                app_socket: None,
                keys: KeysPolicy::Safe,
                ..EnableSpec::default()
            },
            remote::now_unix(),
        )
        .unwrap();

    let r = get(&h, "/api/targets/host-pane/screen").await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(r.json()["text"], "host screen");
}

#[tokio::test]
async fn a_daemon_owned_surface_says_so_when_this_build_cannot_read_it() {
    // Without an accessor the listener keeps its old answer rather than
    // reporting a call failure it never made.
    let h = start_tailscale().await;
    h.registry
        .lock()
        .await
        .upsert(
            EnableSpec {
                surface_id: "host-pane".to_string(),
                kind: TargetKind::Pane,
                app_socket: None,
                keys: KeysPolicy::Safe,
                ..EnableSpec::default()
            },
            remote::now_unix(),
        )
        .unwrap();

    let r = get(&h, "/api/targets/host-pane/screen").await;
    assert_eq!(r.status, 409, "{}", r.body);
    assert_eq!(r.json()["error"]["code"], "not_readable");
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
            { "row": 0, "column": 0, "style_id": 0, "cell_width": 8, "text": "old line" }
        ],
        "row_spans": [
            { "row": 0, "column": 0, "style_id": 1, "cell_width": 3, "text": "red" },
            { "row": 0, "column": 3, "style_id": 0, "cell_width": 6, "text": " plain" },
            { "row": 1, "column": 0, "style_id": 2, "cell_width": 3, "text": "dim" },
            { "row": 1, "column": 5, "style_id": 3, "cell_width": 3, "text": "inv" },
            { "row": 1, "column": 8, "style_id": 4, "cell_width": 6, "text": "secret" },
            { "row": 2, "column": 0, "style_id": 0, "cell_width": 2, "text": "❯ " }
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

#[tokio::test]
async fn styled_does_not_fall_back_when_only_the_rpc_message_mentions_method_not_found() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.fail(
        "surface.read_screen_grid",
        "internal_error",
        "dependency said method_not_found",
    );
    app.reply("surface.read_text", json!({ "text": "must not be served" }));
    let h = start_tailscale().await;
    expose(&h, &app, "pane-1", TargetKind::Pane, KeysPolicy::Safe).await;

    let r = get(&h, "/api/targets/pane-1/screen?format=styled").await;
    assert_eq!(r.status, 502, "{}", r.body);
    assert_eq!(r.error_code(), "app_rpc_failed");
    assert_eq!(
        app.calls().len(),
        1,
        "only the typed RPC code may trigger fallback"
    );
}

/// `cell_width` is the whole span's width in cells, not one character's: a
/// Ghostty span "curl" arrives with `cell_width: 4`, a lone "한" with 2. Reading
/// it per character pushed the column past every later gap, so each space the
/// grid left as a gap after the first multi-character span vanished — Korean
/// lines on the phone ran together as "check와darwin빌드가".
#[test]
fn styled_from_grid_keeps_gap_spaces_after_multi_character_spans() {
    let grid = json!({
        "columns": 40, "rows": 1, "scrollback_rows": 0,
        "styles": [],
        "row_spans": [
            { "row": 0, "column": 0, "style_id": 0, "cell_width": 5, "text": "check" },
            { "row": 0, "column": 5, "style_id": 0, "cell_width": 2, "text": "와" },
            { "row": 0, "column": 8, "style_id": 0, "cell_width": 6, "text": "darwin" },
            { "row": 0, "column": 15, "style_id": 0, "cell_width": 2, "text": "빌" },
            { "row": 0, "column": 17, "style_id": 0, "cell_width": 2, "text": "드" }
        ]
    });
    let screen = styled_from_grid(&grid);
    let line: String = screen.rows[0].iter().map(|span| span.t.as_str()).collect();
    assert_eq!(line, "check와 darwin 빌드");
}

#[test]
fn styled_from_grid_counts_one_cell_per_character_when_width_is_missing() {
    let grid = json!({
        "columns": 40, "rows": 1, "scrollback_rows": 0,
        "styles": [],
        "row_spans": [
            { "row": 0, "column": 0, "style_id": 0, "text": "abc" },
            { "row": 0, "column": 4, "style_id": 0, "text": "d" }
        ]
    });
    let screen = styled_from_grid(&grid);
    let line: String = screen.rows[0].iter().map(|span| span.t.as_str()).collect();
    assert_eq!(line, "abc d");
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
async fn terminal_submit_sends_text_and_return_as_one_turn() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.fail("surface.send_turn", "timeout", "app busy");
    let h = start_tailscale().await;
    expose(&h, &app, "pane-1", TargetKind::Pane, KeysPolicy::Safe).await;
    expose(&h, &app, "locked", TargetKind::Pane, KeysPolicy::None).await;

    let locked = post(
        &h,
        "/api/targets/locked/text",
        json!({ "text": "no", "mode": "terminal", "submit": true, "request_id": "s-0" }),
    )
    .await;
    assert_eq!(locked.status, 403);
    assert_eq!(locked.error_code(), "keys_disabled");
    assert!(app.calls().is_empty(), "keys=none must not reach the app");

    let failed = post(
        &h,
        "/api/targets/pane-1/text",
        json!({ "text": "ls", "mode": "terminal", "submit": true, "request_id": "s-1" }),
    )
    .await;
    assert_ne!(failed.status, 200, "{}", failed.body);

    app.reply("surface.send_turn", json!({ "submitted": true }));
    let first = post(
        &h,
        "/api/targets/pane-1/text",
        json!({ "text": "ls", "mode": "terminal", "submit": true, "request_id": "s-1" }),
    )
    .await;
    assert_eq!(first.status, 200, "{}", first.body);
    assert_eq!(first.json()["deduplicated"], false);
    let retry = post(
        &h,
        "/api/targets/pane-1/text",
        json!({ "text": "ls", "mode": "terminal", "submit": true, "request_id": "s-1" }),
    )
    .await;
    assert_eq!(retry.status, 200);
    assert_eq!(retry.json()["deduplicated"], true);

    let calls = app.calls();
    assert_eq!(calls.len(), 2, "a failed turn is retried once, then deduplicated: {calls:?}");
    for (method, params) in &calls {
        assert_eq!(method, "surface.send_turn");
        assert_eq!(params, &json!({ "surface_id": "pane-1", "text": "ls" }));
    }
    assert!(
        calls.iter().all(|(method, _)| method != "surface.send_key"),
        "Return travels inside the turn, never as a second request"
    );
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

#[test]
fn mobile_page_keeps_chat_and_terminal_wired_for_chat_capable_targets() {
    let js = embedded_page_js();
    assert!(
        js.contains("function isChat(t) { return !!t && t.chat_capable && state.mode === 'chat'; }"),
        "native agents must not be permanently locked to Chat"
    );
    assert!(
        js.contains("el.viewSwitch.hidden = !has || !t.chat_capable;"),
        "every chat-capable target must expose Chat and Terminal"
    );
    assert!(
        js.contains("Promise.all([refreshScreen(), refreshChat(), refreshRequests()])"),
        "both data sources must stay warm so switching views cannot show an empty pane"
    );
    assert!(
        !js.contains("el.viewSwitch.hidden = !has || isAgent(t) || !t.chat_capable;"),
        "the old native-agent terminal suppression must not return"
    );
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

    spec.surface_id = "locked-chat".to_string();
    spec.keys = KeysPolicy::None;
    h.registry
        .lock()
        .await
        .upsert(spec.clone(), remote::now_unix())
        .unwrap();
    let locked_turn = post(
        &h,
        "/api/targets/locked-chat/text",
        json!({ "text": "no", "mode": "chat", "request_id": "locked-1" }),
    )
    .await;
    assert_eq!(locked_turn.status, 403);
    assert_eq!(locked_turn.error_code(), "keys_disabled");
    let locked_terminal = post(
        &h,
        "/api/targets/locked-chat/text",
        json!({ "text": "no", "mode": "terminal", "request_id": "locked-2" }),
    )
    .await;
    assert_eq!(locked_terminal.status, 403);
    assert_eq!(locked_terminal.error_code(), "keys_disabled");
    let locked_interrupt = post(&h, "/api/targets/locked-chat/interrupt", json!({})).await;
    assert_eq!(locked_interrupt.status, 403);
    assert_eq!(locked_interrupt.error_code(), "keys_disabled");
    assert_eq!(app.calls().len(), 2, "blocked input must not reach the app");

    spec.surface_id = "plain".to_string();
    spec.keys = KeysPolicy::Safe;
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
    let ansi_split_private_key = vec![
        json!({ "type": "response_item", "payload": { "type": "message", "id": "a1", "role": "assistant", "content": [{ "type": "output_text", "text": "-----BE\u{1b}[31mGIN PRIVATE KEY-----" }] } }),
        json!({ "type": "response_item", "payload": { "type": "message", "id": "a2", "role": "assistant", "content": [{ "type": "output_text", "text": "YWJjZGVm" }] } }),
        json!({ "type": "response_item", "payload": { "type": "message", "id": "a3", "role": "assistant", "content": [{ "type": "output_text", "text": "-----END PRIVATE KEY-----" }] } }),
        json!({ "type": "response_item", "payload": { "type": "message", "id": "safe-ansi", "role": "assistant", "content": [{ "type": "output_text", "text": "after" }] } }),
    ];
    let ansi_hidden = http_mobile::codex_entries(&ansi_split_private_key);
    assert_eq!(ansi_hidden.len(), 1);
    assert_eq!(ansi_hidden[0]["id"], "safe-ansi");
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
    assert_eq!(
        http_mobile::redact_session_text(
            "before\n-----BEGIN PRIVATE KEY-----\nYWJjZGVm\n-----END PRIVATE KEY-----\nafter"
        ),
        "before\n[credential redacted]\n[credential redacted]\n[credential redacted]\nafter"
    );
    for wrapped in [
        "`sk-exampletoken`",
        "(sk-exampletoken)",
        "[sk-exampletoken]",
    ] {
        assert_eq!(
            http_mobile::redact_session_text(wrapped),
            "[credential redacted]"
        );
    }
    assert_eq!(
        http_mobile::redact_session_text("\u{1b}[31msk-exampletoken\u{1b}[0m"),
        "[credential redacted]"
    );
    assert_eq!(
        http_mobile::redact_session_text("\u{1b}]0;title\u{7}sk-exampletoken"),
        "[credential redacted]"
    );
    assert_eq!(
        http_mobile::redact_session_text("\u{1b}[sk-exampletoken"),
        "[credential redacted]"
    );
    for malformed in [
        "\u{1b}]unterminated AKIAEXAMPLE",
        "\u{1b}[unterminated API_KEY=secret",
    ] {
        assert_eq!(
            http_mobile::redact_session_text(malformed),
            "[credential redacted]"
        );
    }
    let malformed_escape_block = vec![
        json!({ "type": "response_item", "payload": { "type": "message", "id": "bad1", "role": "assistant", "content": [{ "type": "output_text", "text": "\u{1b}]unterminated -----BEGIN PRIVATE KEY-----" }] } }),
        json!({ "type": "response_item", "payload": { "type": "message", "id": "bad2", "role": "assistant", "content": [{ "type": "output_text", "text": "YWJjZGVm" }] } }),
        json!({ "type": "response_item", "payload": { "type": "message", "id": "bad3", "role": "assistant", "content": [{ "type": "output_text", "text": "-----END PRIVATE KEY-----" }] } }),
        json!({ "type": "response_item", "payload": { "type": "message", "id": "safe-malformed", "role": "assistant", "content": [{ "type": "output_text", "text": "after" }] } }),
    ];
    let malformed_hidden = http_mobile::codex_entries(&malformed_escape_block);
    assert_eq!(malformed_hidden.len(), 1);
    assert_eq!(malformed_hidden[0]["id"], "safe-malformed");
    assert_eq!(
        http_mobile::redact_session_text(
            "-----BEGIN PGP PRIVATE KEY BLOCK-----\nbody\n-----END PGP PRIVATE KEY BLOCK-----"
        ),
        "[credential redacted]\n[credential redacted]\n[credential redacted]"
    );
    assert_eq!(
        http_mobile::redact_session_text(
            "-----BEGIN PRIVATE KEY-----YWJj-----END PRIVATE KEY-----\nafter"
        ),
        "[credential redacted]\nafter"
    );
    assert_eq!(
        http_mobile::redact_session_text(
            "-----BEGIN PRIVATE KEY-----\npartial body\nafter without end"
        ),
        "[credential redacted]\n[credential redacted]\n[credential redacted]"
    );
    for ordinary in ["task-runner", "risk-aware", "disk-space"] {
        assert_eq!(http_mobile::redact_session_text(ordinary), ordinary);
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

#[test]
fn session_tail_reader_keeps_private_key_state_across_the_initial_tail_window() {
    use std::io::Write;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("private-key-window.jsonl");
    let mut file = std::fs::File::create(&path).unwrap();
    writeln!(file, "{{\"type\":\"response_item\",\"payload\":{{\"type\":\"message\",\"id\":\"begin\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"-----BEGIN PRIVATE KEY-----\"}}]}}}}").unwrap();
    let key_padding = "x".repeat(9 * 1024 * 1024);
    writeln!(file, "{{\"padding\":\"{key_padding}\"}}").unwrap();
    writeln!(file, "{{\"type\":\"response_item\",\"payload\":{{\"type\":\"message\",\"id\":\"body\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"YWJjZGVm\"}}]}}}}").unwrap();
    writeln!(file, "{{\"type\":\"response_item\",\"payload\":{{\"type\":\"message\",\"id\":\"end\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"-----END PRIVATE KEY-----\"}}]}}}}").unwrap();
    writeln!(file, "{{\"type\":\"response_item\",\"payload\":{{\"type\":\"message\",\"id\":\"safe\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"after\"}}]}}}}").unwrap();

    let lines = http_mobile::tail_json_lines(&path).unwrap();
    let visible = http_mobile::codex_entries(&lines);
    assert_eq!(visible.len(), 1);
    assert_eq!(visible[0]["id"], "safe");
}

async fn targets_by_id_for(h: &Harness) -> serde_json::Map<String, Value> {
    let r = get(h, "/api/targets").await;
    let mut out = serde_json::Map::new();
    for t in r.json()["targets"].as_array().unwrap() {
        out.insert(t["surface_id"].as_str().unwrap().to_string(), t.clone());
    }
    out
}

/// The regression the resolver exists for.
///
/// A terminal pane running a hand-started CLI is exposed by the app's mobile
/// button, which cannot know the session id — the CLI hands that only to its
/// own children. The record therefore says `chat_capable: false`, and the page
/// hides the whole Chat/Terminal switch on exactly that value. With the daemon
/// answering instead, the same record offers Chat again.
#[tokio::test]
async fn a_pane_running_a_cli_is_chat_capable_even_when_the_record_is_not() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());

    // Exposed exactly as the app's button does it: a plain pane, no session.
    let spec = EnableSpec {
        surface_id: "panel-1".into(),
        kind: TargetKind::Pane,
        app_socket: Some(app.path_str()),
        ..EnableSpec::default()
    };

    let without = start_tailscale().await;
    without
        .registry
        .lock()
        .await
        .upsert(spec.clone(), remote::now_unix())
        .unwrap();
    let target = get(&without, "/api/targets").await.json()["targets"][0].clone();
    assert_eq!(
        target["chat_capable"], false,
        "precondition: the record itself cannot claim chat"
    );

    let resolver: http_mobile::SessionResolver =
        Arc::new(|surface_id: &str| match surface_id {
            "panel-1" => Some(http_mobile::PaneSession {
                cli: "claude".into(),
                session_id: Some("sess-abc".into()),
            }),
            _ => None,
        });
    let with = start_with_resolver(AuthMode::Tailscale, &[LOGIN], Some(resolver)).await;
    with.registry
        .lock()
        .await
        .upsert(spec, remote::now_unix())
        .unwrap();
    let target = get(&with, "/api/targets").await.json()["targets"][0].clone();
    assert_eq!(
        target["chat_capable"], true,
        "the daemon knows this pane's session, so the switch must come back"
    );
    assert_eq!(
        target["agent_cli"], "claude",
        "the page picks its transcript reader from this"
    );
}

/// A pane the resolver knows nothing about stays a screen mirror. Claiming
/// chat there would open an empty conversation in place of the terminal.
#[tokio::test]
async fn an_unresolvable_pane_stays_terminal_only() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    let resolver: http_mobile::SessionResolver = Arc::new(|_: &str| None);
    let h = start_with_resolver(AuthMode::Tailscale, &[LOGIN], Some(resolver)).await;
    h.registry
        .lock()
        .await
        .upsert(
            EnableSpec {
                surface_id: "panel-2".into(),
                kind: TargetKind::Pane,
                app_socket: Some(app.path_str()),
                ..EnableSpec::default()
            },
            remote::now_unix(),
        )
        .unwrap();

    let target = get(&h, "/api/targets").await.json()["targets"][0].clone();
    assert_eq!(target["chat_capable"], false);
}

/// A CLI that has started but not replied yet has no session file, so the
/// resolver knows the pane runs it and nothing more. The switch must already
/// be on the page, because the first turn is sent from Chat itself.
#[tokio::test]
async fn a_pane_whose_cli_has_no_session_yet_still_offers_chat() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply("surface.list", json!({ "surfaces": [] }));
    app.reply("surface.send_turn", json!({ "submitted": true }));
    let resolver: http_mobile::SessionResolver = Arc::new(|_: &str| {
        Some(http_mobile::PaneSession {
            cli: "claude".into(),
            session_id: None,
        })
    });
    let h = start_with_resolver(AuthMode::Tailscale, &[LOGIN], Some(resolver)).await;
    h.registry
        .lock()
        .await
        .upsert(
            EnableSpec {
                surface_id: "panel-5".into(),
                kind: TargetKind::Pane,
                app_socket: Some(app.path_str()),
                ..EnableSpec::default()
            },
            remote::now_unix(),
        )
        .unwrap();

    let target = get(&h, "/api/targets").await.json()["targets"][0].clone();
    assert_eq!(target["chat_capable"], true);
    assert_eq!(target["agent_cli"], "claude");

    let transcript = get(&h, "/api/targets/panel-5/transcript").await;
    assert_eq!(transcript.status, 409, "{}", transcript.body);
    assert_eq!(
        transcript.json()["error"]["code"],
        "session_unavailable",
        "the page retries on this code instead of showing an error"
    );

    let chat = post(
        &h,
        "/api/targets/panel-5/text",
        json!({ "text": "first turn", "mode": "chat", "request_id": "first-1" }),
    )
    .await;
    assert_eq!(chat.status, 200, "{}", chat.body);
}

/// The other half of `a_pane_running_a_cli_is_chat_capable_even_when_the_record
/// _is_not`: the page reads `chat_capable` off `/api/targets`, which the
/// resolver answers, and then posts its turn to `/text`. Gating that POST on
/// the raw record instead left the Chat tab and its live transcript on screen
/// while every turn came back `chat_unavailable`.
#[tokio::test]
async fn a_resolved_pane_accepts_a_chat_turn() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply("surface.send_turn", json!({ "submitted": true }));
    let resolver: http_mobile::SessionResolver =
        Arc::new(|surface_id: &str| match surface_id {
            "panel-3" => Some(http_mobile::PaneSession {
                cli: "claude".into(),
                session_id: Some("sess-xyz".into()),
            }),
            _ => None,
        });
    let h = start_with_resolver(AuthMode::Tailscale, &[LOGIN], Some(resolver)).await;
    h.registry
        .lock()
        .await
        .upsert(
            EnableSpec {
                surface_id: "panel-3".into(),
                kind: TargetKind::Pane,
                app_socket: Some(app.path_str()),
                ..EnableSpec::default()
            },
            remote::now_unix(),
        )
        .unwrap();

    let target = get(&h, "/api/targets").await.json()["targets"][0].clone();
    assert_eq!(
        target["chat_capable"], true,
        "precondition: the page is offered Chat for this pane"
    );

    let chat = post(
        &h,
        "/api/targets/panel-3/text",
        json!({ "text": "whole turn", "mode": "chat", "request_id": "resolved-1" }),
    )
    .await;
    assert_eq!(chat.status, 200, "{}", chat.body);
    assert_eq!(app.calls()[0].0, "surface.send_turn");
    assert_eq!(app.calls()[0].1["text"], "whole turn");
}

/// A third half of the same regression, this time for `/interrupt`: gating it
/// on the raw `entry.chat_capable` instead of `state.chat_capable(&entry)`
/// left the Interrupt button `/api/targets` had just told the page to show
/// coming back `not_an_agent` for every terminal-backed chat. The resolved
/// pane is not a native agent, so the stop must still reach it as a C-c key.
#[tokio::test]
async fn a_resolved_pane_forwards_interrupt_as_ctrl_c() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply("surface.send_key", json!({ "interrupted": true }));
    let resolver: http_mobile::SessionResolver = Arc::new(|surface_id: &str| match surface_id {
        "panel-4" => Some(http_mobile::PaneSession {
            cli: "claude".into(),
            session_id: Some("sess-int".into()),
        }),
        _ => None,
    });
    let h = start_with_resolver(AuthMode::Tailscale, &[LOGIN], Some(resolver)).await;
    h.registry
        .lock()
        .await
        .upsert(
            EnableSpec {
                surface_id: "panel-4".into(),
                kind: TargetKind::Pane,
                app_socket: Some(app.path_str()),
                ..EnableSpec::default()
            },
            remote::now_unix(),
        )
        .unwrap();

    let target = get(&h, "/api/targets").await.json()["targets"][0].clone();
    assert_eq!(
        target["chat_capable"], true,
        "precondition: the page is offered Chat (and Interrupt) for this pane"
    );

    let stop = post(&h, "/api/targets/panel-4/interrupt", json!({})).await;
    assert_eq!(stop.status, 200, "{}", stop.body);
    assert_eq!(stop.json()["interrupted"], true);
    assert_eq!(
        app.calls()[0],
        (
            "surface.send_key".to_string(),
            json!({ "surface_id": "panel-4", "key": "ctrl-c" })
        ),
        "a resolved pane is not a native agent, so the stop is a key, not team.interrupt"
    );
}

#[tokio::test]
async fn listener_serving_reports_whether_the_bind_held() {
    let taken = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let config = MobileConfig {
        addr: taken.local_addr().unwrap(),
        auth: AuthMode::Loopback,
        allowed_logins: BTreeSet::new(),
    };
    let (_tx, rx) = watch::channel(false);
    assert!(http_mobile::serve(config, remote::new_registry(), None, None, rx)
        .await
        .is_err());
    assert!(!remote::listener_serving());

    let config = MobileConfig {
        addr: "127.0.0.1:0".parse().unwrap(),
        auth: AuthMode::Loopback,
        allowed_logins: BTreeSet::new(),
    };
    let (tx, rx) = watch::channel(false);
    let task = tokio::spawn(http_mobile::serve(config, remote::new_registry(), None, None, rx));
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    while !remote::listener_serving() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "listener never reported serving"
        );
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    tx.send(true).unwrap();
    task.await.unwrap().unwrap();
    assert!(!remote::listener_serving());
}

#[test]
fn command_catalog_reads_project_user_and_namespaced_plugin_metadata() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let project = temp.path().join("project");
    let plugin = temp.path().join("plugin");
    for dir in [
        home.join(".claude/commands"),
        project.join(".claude/commands/frontend"),
        project.join(".claude/skills/deploy"),
        plugin.join("skills/review"),
        home.join(".claude/plugins"),
    ] {
        std::fs::create_dir_all(dir).unwrap();
    }
    std::fs::create_dir_all(project.join(".git")).unwrap();
    std::fs::write(
        home.join(".claude/commands/build.md"),
        "---\ndescription: User build\n---\nPRIVATE BODY",
    )
    .unwrap();
    std::fs::write(
        project.join(".claude/commands/build.md"),
        "---\ndescription: 'Project build'\nargument-hint: [target]\n---\nPRIVATE BODY",
    )
    .unwrap();
    std::fs::write(
        project.join(".claude/commands/frontend/component.md"),
        "---\ndescription: Component\n---",
    )
    .unwrap();
    std::fs::write(
        project.join(".claude/skills/deploy/SKILL.md"),
        "---\nname: ship\ndescription: >\n  Deploy the app\n  to staging\n---\nPRIVATE BODY",
    )
    .unwrap();
    std::fs::write(
        plugin.join("skills/review/SKILL.md"),
        "---\nname: quality:review\ndescription: Review code\n---",
    )
    .unwrap();
    let (mut items, warning) =
        http_mobile::mobile_command_catalog("claude", &project, &home, false).unwrap();
    let (plugins, plugin_warning) = http_mobile::mobile_claude_plugin_items(&json!([
        {"id":"quality@market","installPath":plugin,"enabled":true,"projectEnabled":true},
        {"id":"disabled@market","installPath":plugin,"enabled":false}
    ]));
    assert!(plugin_warning.is_none());
    items.extend(plugins);
    assert!(warning.is_none());
    let find = |name: &str| items.iter().find(|item| item.invocation == name).unwrap();
    assert_eq!(find("/build").description, "Project build");
    assert_eq!(find("/build").argument_hint, "[target]");
    assert_eq!(find("/build").source, "project");
    assert_eq!(find("/frontend:component").kind, "command");
    assert_eq!(find("/ship").description, "Deploy the app to staging");
    assert_eq!(find("/quality:review").source, "plugin");
    assert!(!serde_json::to_string(&items)
        .unwrap()
        .contains("PRIVATE BODY"));
    assert!(!serde_json::to_string(&items)
        .unwrap()
        .contains(temp.path().to_str().unwrap()));
}

#[test]
fn claude_catalog_hides_non_invocable_entries() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let project = temp.path().join("project");
    for dir in [
        project.join(".claude/skills/rc"),
        project.join(".claude/skills/hidden"),
        home.join(".claude/skills/.system/helper"),
    ] {
        std::fs::create_dir_all(dir).unwrap();
    }
    std::fs::create_dir_all(project.join(".git")).unwrap();
    std::fs::write(
        project.join(".claude/skills/rc/SKILL.md"),
        "---\nname: rc\ndescription: Mobile control\n---",
    )
    .unwrap();
    std::fs::write(
        project.join(".claude/skills/hidden/SKILL.md"),
        "---\nname: hidden\nuser-invocable: false\n---",
    )
    .unwrap();
    std::fs::write(
        home.join(".claude/skills/.system/helper/SKILL.md"),
        "---\nname: helper\n---",
    )
    .unwrap();
    let (items, _) = http_mobile::mobile_command_catalog("claude", &project, &home, false).unwrap();
    assert!(items
        .iter()
        .any(|item| item.invocation == "/rc" && item.kind == "skill"));
    assert!(items.iter().any(|item| item.invocation == "/helper"));
    assert!(!items.iter().any(|item| item.invocation == "/hidden"));
    assert!(items.iter().any(|item| item.invocation == "/model"));
}

#[test]
fn native_catalog_disables_terminal_commands_but_keeps_skills_selectable() {
    let temp = tempfile::tempdir().unwrap();
    let skills = temp.path().join(".claude/skills/rc");
    std::fs::create_dir_all(&skills).unwrap();
    std::fs::write(skills.join("SKILL.md"), "---\nname: rc\n---").unwrap();
    let (items, _) =
        http_mobile::mobile_command_catalog("claude", temp.path(), temp.path(), true).unwrap();
    assert!(
        items
            .iter()
            .find(|item| item.invocation == "/rc")
            .unwrap()
            .selectable
    );
    let model = items
        .iter()
        .find(|item| item.invocation == "/model")
        .unwrap();
    assert!(!model.selectable);
    assert!(!model.reason.is_empty());
}

#[test]
fn command_catalog_handles_symlink_cycles_and_bad_metadata_visibly() {
    let temp = tempfile::tempdir().unwrap();
    let skills = temp.path().join(".claude/skills");
    std::fs::create_dir_all(skills.join("broken")).unwrap();
    std::os::unix::fs::symlink(&skills, skills.join("cycle")).unwrap();
    std::fs::write(skills.join("broken/SKILL.md"), [0xff, 0xfe]).unwrap();
    let (items, warning) =
        http_mobile::mobile_command_catalog("claude", temp.path(), temp.path(), false).unwrap();
    assert!(warning.is_some());
    assert!(!items.iter().any(|item| item.kind == "skill"));
}

#[tokio::test]
async fn command_endpoint_requires_auth_live_exposure_and_a_cli_session() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    let h = start_tailscale().await;
    let unauthorized = http(h.addr, "GET", "/api/targets/pane-1/commands", &[], None).await;
    assert_eq!(unauthorized.status, 403);
    assert_eq!(get(&h, "/api/targets/missing/commands").await.status, 404);
    expose(&h, &app, "pane-1", TargetKind::Pane, KeysPolicy::Safe).await;
    let shell = get(&h, "/api/targets/pane-1/commands").await;
    assert_eq!(shell.status, 409);
    assert_eq!(shell.error_code(), "commands_unavailable");
}

#[test]
fn runtime_codex_skill_list_honors_enabled_state_and_preserves_namespaces() {
    let result = json!({"data":[{"cwd":"/project","errors":[],"skills":[
        {"name":"rc","description":"Mobile control","enabled":true,"scope":"repo","pluginId":null},
        {"name":"xm:build","description":"Build","enabled":true,"scope":"user","pluginId":"xm@market"},
        {"name":"disabled","enabled":false,"scope":"user"}
    ]}]});
    let (items, warning) = http_mobile::mobile_codex_skill_items(&result).unwrap();
    assert!(warning.is_none());
    assert_eq!(items.len(), 2);
    assert_eq!(items[0].invocation, "$rc");
    assert_eq!(items[0].source, "project");
    assert_eq!(items[1].invocation, "$xm:build");
    assert_eq!(items[1].source, "plugin");
    assert!(!serde_json::to_string(&items).unwrap().contains("/project"));
    assert!(http_mobile::mobile_codex_skill_items(&json!({})).is_err());
}

#[tokio::test]
async fn native_remote_catalog_does_not_read_the_local_skill_installation() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    let h = start_tailscale().await;
    expose(&h, &app, "agent-1", TargetKind::Agent, KeysPolicy::Safe).await;
    app.reply(
        "team.status",
        json!({"agents":[{"name":"worker-1","host":"ssh:peer"}]}),
    );
    let r = get(&h, "/api/targets/agent-1/commands").await;
    assert_eq!(r.status, 409);
    assert_eq!(r.error_code(), "remote_commands_unavailable");
}

#[tokio::test]
#[ignore = "requires an installed Codex CLI"]
async fn command_endpoint_reads_the_installed_codex_skill_runtime() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("project");
    let skill = project.join(".agents/skills/mobile-catalog-fixture");
    std::fs::create_dir_all(&skill).unwrap();
    std::fs::create_dir_all(project.join(".git")).unwrap();
    std::fs::write(
        skill.join("SKILL.md"),
        "---\nname: mobile-catalog-fixture\ndescription: Catalog test\n---\nTest fixture",
    )
    .unwrap();
    let app = FakeApp::spawn(dir.path());
    let h = start_tailscale().await;
    h.registry
        .lock()
        .await
        .upsert(
            EnableSpec {
                surface_id: "codex-1".into(),
                kind: TargetKind::Pane,
                app_socket: Some(app.path_str()),
                cwd: project.to_string_lossy().into_owned(),
                agent_cli: "codex".into(),
                chat_capable: true,
                session_id: Some("fixture-session".into()),
                ..EnableSpec::default()
            },
            remote::now_unix(),
        )
        .unwrap();
    let r = get(&h, "/api/targets/codex-1/commands").await;
    assert_eq!(r.status, 200, "{}", r.body);
    let data = r.json();
    let items = data["items"].as_array().unwrap();
    assert!(items
        .iter()
        .any(|item| item["invocation"] == "$mobile-catalog-fixture"));
    assert!(!items
        .iter()
        .any(|item| item["invocation"] == "/mobile-catalog-fixture"));
    assert!(!r.body.contains("installPath"));
    assert!(!r.body.contains(project.to_str().unwrap()));
}


#[test]
fn claude_local_commands_become_notices_instead_of_turns() {
    let rows = vec![
        json!({ "type": "system", "subtype": "local_command", "uuid": "s1",
            "content": "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>sonnet</command-args>" }),
        json!({ "type": "system", "subtype": "local_command", "uuid": "s2",
            "content": "<local-command-stdout>Set model to Sonnet 5.5</local-command-stdout>" }),
        json!({ "type": "user", "uuid": "u1", "message": { "content":
            "<local-command-caveat>Caveat: generated by local commands</local-command-caveat>" } }),
        json!({ "type": "user", "uuid": "u2", "message": { "content":
            "<local-command-stdout>Model 'bogus' not found</local-command-stdout>" } }),
    ];
    let entries = http_mobile::claude_entries(&rows);
    let shown: Vec<(&str, &str)> = entries
        .iter()
        .map(|e| (e["kind"].as_str().unwrap(), e["text"].as_str().unwrap()))
        .collect();
    assert_eq!(
        shown,
        vec![
            ("notice", "/model sonnet"),
            ("notice", "Set model to Sonnet 5.5"),
            ("notice", "Model 'bogus' not found"),
        ]
    );
}

#[test]
fn only_a_terminal_catalog_offers_the_model_picker() {
    let temp = tempfile::tempdir().unwrap();
    for (native, action) in [(false, Some("pick_model")), (true, None)] {
        let (items, _) =
            http_mobile::mobile_command_catalog("codex", temp.path(), temp.path(), native).unwrap();
        let model = items.iter().find(|item| item.invocation == "/model").unwrap();
        assert_eq!(model.action, action, "native={native}");
    }
    let action_of = |cli: &str, invocation: &str| {
        let (items, _) = http_mobile::mobile_command_catalog(cli, temp.path(), temp.path(), false).unwrap();
        items.into_iter().find(|item| item.invocation == invocation).unwrap().action
    };
    assert_eq!(action_of("claude", "/effort"), Some("pick_effort"));
    assert_eq!(action_of("claude", "/permissions"), Some("terminal"));
    assert_eq!(action_of("claude", "/compact"), None);
    assert_eq!(action_of("codex", "/status"), Some("terminal"));
    assert_eq!(action_of("codex", "/compact"), None);
}

#[tokio::test]
async fn a_custom_claude_id_goes_inline_and_never_into_a_draft() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply("surface.send_turn", json!({ "submitted": true }));
    app.reply("surface.read_text", json!({ "text": "❯ Try \"write a test\"\n  Opus 5.5 high" }));
    let resolver: http_mobile::SessionResolver = Arc::new(|_: &str| {
        Some(http_mobile::PaneSession {
            cli: "claude".into(),
            session_id: None,
        })
    });
    let h = start_with_resolver(AuthMode::Tailscale, &[LOGIN], Some(resolver)).await;
    h.registry
        .lock()
        .await
        .upsert(
            EnableSpec {
                surface_id: "panel-7".into(),
                kind: TargetKind::Pane,
                app_socket: Some(app.path_str()),
                ..EnableSpec::default()
            },
            remote::now_unix(),
        )
        .unwrap();
    let turns = |app: &FakeApp| -> Vec<Value> {
        app.calls()
            .into_iter()
            .filter(|(method, _)| method == "surface.send_turn")
            .map(|(_, params)| params)
            .collect()
    };

    let prompt = post(
        &h,
        "/api/targets/panel-7/model",
        json!({ "model": "opus please", "custom": true }),
    )
    .await;
    assert_eq!(prompt.status, 400, "{}", prompt.body);
    assert!(turns(&app).is_empty(), "a rejected id must type nothing");

    let switched = post(
        &h,
        "/api/targets/panel-7/model",
        json!({ "model": "claude-opus-4-1", "custom": true }),
    )
    .await;
    assert_eq!(switched.status, 200, "{}", switched.body);
    assert_eq!(turns(&app).len(), 1);
    assert_eq!(turns(&app)[0]["text"], "/model claude-opus-4-1");

    app.reply("surface.read_text", json!({ "text": "❯ fix the parser\n  Opus 5.5 high" }));
    let draft = post(
        &h,
        "/api/targets/panel-7/model",
        json!({ "model": "sonnet", "custom": true }),
    )
    .await;
    assert_eq!(draft.status, 409, "{}", draft.body);
    assert_eq!(draft.json()["error"]["code"], "composer_not_empty");
    assert_eq!(turns(&app).len(), 1, "a draft must not get /model appended to it");
}

#[tokio::test]
async fn a_model_change_holds_the_pane_and_releases_it_when_the_menu_never_opens() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply("surface.send_turn", json!({ "submitted": true }));
    app.reply("surface.send_key", json!({ "ok": true }));
    app.reply(
        "surface.read_text",
        json!({ "text": "› Ask Codex to do anything\n  Jev Auto medium" }),
    );
    let resolver: http_mobile::SessionResolver = Arc::new(|_: &str| {
        Some(http_mobile::PaneSession {
            cli: "codex".into(),
            session_id: None,
        })
    });
    let h = Arc::new(start_with_resolver(AuthMode::Tailscale, &[LOGIN], Some(resolver)).await);
    h.registry
        .lock()
        .await
        .upsert(
            EnableSpec {
                surface_id: "panel-8".into(),
                kind: TargetKind::Pane,
                app_socket: Some(app.path_str()),
                ..EnableSpec::default()
            },
            remote::now_unix(),
        )
        .unwrap();

    let driving = {
        let h = h.clone();
        tokio::spawn(async move {
            post(&h, "/api/targets/panel-8/model", json!({ "model": "GLM 5" })).await
        })
    };
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let typed = post(
        &h,
        "/api/targets/panel-8/text",
        json!({ "text": "hello", "mode": "chat", "request_id": "during-1" }),
    )
    .await;
    assert_eq!(typed.status, 409, "{}", typed.body);
    assert_eq!(typed.json()["error"]["code"], "model_change_in_flight");

    let driven = driving.await.unwrap();
    assert_eq!(driven.status, 409, "{}", driven.body);
    assert_eq!(driven.json()["error"]["code"], "screen_unrecognized");

    let after = post(
        &h,
        "/api/targets/panel-8/text",
        json!({ "text": "hello", "mode": "chat", "request_id": "after-1" }),
    )
    .await;
    assert_eq!(after.status, 200, "the lock is released once the change ends: {}", after.body);
}

#[tokio::test]
async fn the_model_picker_refuses_native_agents() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    let h = start(AuthMode::Tailscale, &[LOGIN]).await;
    expose(&h, &app, "agent-1", TargetKind::Agent, KeysPolicy::Safe).await;
    let reply = post(&h, "/api/targets/agent-1/model", json!({ "model": "opus" })).await;
    assert_eq!(reply.status, 409, "{}", reply.body);
    assert_eq!(reply.json()["error"]["code"], "model_unavailable");
}

const CODEX_APPROVAL_SCREEN: &str = "• Running touch c.txt
  Would you like to run the following command?
  Reason: needs write access
  $ touch c.txt
› 1. Yes, proceed (y)
  2. No, and tell Codex what to do differently (esc)
  Press enter to confirm or esc to cancel";

#[tokio::test]
async fn an_approval_question_is_read_and_answered_only_while_it_is_the_same_one() {
    let dir = tempfile::tempdir().unwrap();
    let app = FakeApp::spawn(dir.path());
    app.reply("surface.send_text", json!({ "ok": true }));
    app.reply("surface.read_text", json!({ "text": CODEX_APPROVAL_SCREEN }));
    let resolver: http_mobile::SessionResolver = Arc::new(|_: &str| {
        Some(http_mobile::PaneSession {
            cli: "codex".into(),
            session_id: None,
        })
    });
    let h = Arc::new(start_with_resolver(AuthMode::Tailscale, &[LOGIN], Some(resolver)).await);
    h.registry
        .lock()
        .await
        .upsert(
            EnableSpec {
                surface_id: "panel-9".into(),
                kind: TargetKind::Pane,
                app_socket: Some(app.path_str()),
                ..EnableSpec::default()
            },
            remote::now_unix(),
        )
        .unwrap();

    let read = get(&h, "/api/targets/panel-9/prompt").await;
    assert_eq!(read.status, 200, "{}", read.body);
    let prompt = read.json()["prompt"].clone();
    assert_eq!(prompt["question"], "Would you like to run the following command?");
    assert_eq!(prompt["options"].as_array().unwrap().len(), 2);
    let fingerprint = prompt["fingerprint"].as_str().unwrap().to_string();

    let stale = post(
        &h,
        "/api/targets/panel-9/prompt",
        json!({ "fingerprint": "not-this-one", "index": 1 }),
    )
    .await;
    assert_eq!(stale.status, 409, "{}", stale.body);
    assert_eq!(stale.json()["error"]["code"], "prompt_gone");
    let typed = |app: &FakeApp| {
        app.calls()
            .into_iter()
            .filter(|(m, _)| m == "surface.send_text")
            .count()
    };
    assert_eq!(typed(&app), 0, "a stale answer must type nothing");

    let answering = {
        let h = h.clone();
        let fingerprint = fingerprint.clone();
        tokio::spawn(async move {
            post(
                &h,
                "/api/targets/panel-9/prompt",
                json!({ "fingerprint": fingerprint, "index": 1 }),
            )
            .await
        })
    };
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    app.reply("surface.read_text", json!({ "text": "✔ You approved codex\n› Ask Codex to do anything" }));
    let answered = answering.await.unwrap();
    assert_eq!(answered.status, 200, "{}", answered.body);
    let digits: Vec<_> = app
        .calls()
        .into_iter()
        .filter(|(m, _)| m == "surface.send_text")
        .map(|(_, p)| p["text"].clone())
        .collect();
    assert_eq!(digits, vec![json!("1")]);

    let idle = get(&h, "/api/targets/panel-9/prompt").await;
    assert_eq!(idle.json()["prompt"], Value::Null);
}

#[test]
fn a_long_command_file_cut_inside_a_character_still_lists() {
    let temp = tempfile::tempdir().unwrap();
    let commands = temp.path().join(".claude/commands");
    std::fs::create_dir_all(&commands).unwrap();
    let mut body = String::from("---\ndescription: 팀 dispatch\n---\n");
    while body.len() < 16 * 1024 + 8 {
        body.push('한');
    }
    std::fs::write(commands.join("tm.md"), &body).unwrap();
    std::fs::write(commands.join("zz-after.md"), "---\ndescription: later\n---\n").unwrap();
    let (items, warning) =
        http_mobile::mobile_command_catalog("claude", temp.path(), temp.path(), false).unwrap();
    assert_eq!(warning, None);
    let tm = items.iter().find(|item| item.invocation == "/tm").expect("long file listed");
    assert_eq!(tm.description, "팀 dispatch");
    assert!(items.iter().any(|item| item.invocation == "/zz-after"), "later files still scanned");
}

#[test]
fn a_claude_turn_is_open_from_its_prompt_to_its_turn_duration() {
    let prompt = json!({ "type": "user", "message": { "content": "list files" } });
    let tool_use = json!({ "type": "assistant", "message": { "content": [{ "type": "tool_use", "id": "t1", "name": "Bash" }], "stop_reason": "tool_use" } });
    let tool_result = json!({ "type": "user", "message": { "content": [{ "type": "tool_result", "tool_use_id": "t1", "content": "a.txt" }] } });
    let answer = json!({ "type": "assistant", "message": { "content": [{ "type": "text", "text": "done" }], "stop_reason": "end_turn" } });
    let hooks = json!({ "type": "system", "subtype": "stop_hook_summary" });
    let ended = json!({ "type": "system", "subtype": "turn_duration", "durationMs": 7876 });
    let model = json!({ "type": "user", "message": { "content": "<command-name>/model</command-name>" } });
    let meta = json!({ "type": "user", "isMeta": true, "message": { "content": "Caveat" } });
    let interrupted = json!({ "type": "user", "message": { "content": [{ "type": "text", "text": "[Request interrupted by user]" }] } });

    let open = |rows: &[&Value]| http_mobile::claude_turn_in_flight(&rows.iter().map(|r| (*r).clone()).collect::<Vec<_>>());
    assert_eq!(open(&[&prompt]), Some(true));
    assert_eq!(open(&[&prompt, &tool_use, &tool_result]), Some(true), "a finished tool mid-turn is still the turn");
    assert_eq!(open(&[&prompt, &tool_use, &tool_result, &answer]), Some(true), "an answer before turn_duration is still the turn");
    assert_eq!(open(&[&prompt, &answer, &hooks, &ended]), Some(false));
    assert_eq!(open(&[&prompt, &answer, &hooks, &ended, &model, &meta]), Some(false), "local commands open no turn");
    assert_eq!(open(&[&prompt, &interrupted]), Some(false));
    assert_eq!(open(&[&tool_use]), None);
}

