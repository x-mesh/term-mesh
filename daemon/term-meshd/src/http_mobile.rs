//! Mobile remote-control listener (`docs/mobile-remote-control.md` §4.4–§7).
//!
//! A loopback-only HTTP server, separate from the dashboard in `http.rs`, that
//! exposes registered surfaces (`crate::remote`) to a phone through Tailscale
//! Serve. It owns no state beyond the registry and a short request-id
//! deduplication window; reads and writes are proxied to the app Unix socket
//! that owns each surface.
//!
//! Depends only on `crate::remote` and `crate::app_socket` so
//! `tests/mobile_http.rs` can include all three with `#[path]`.

use axum::{
    body::Body,
    extract::{ConnectInfo, DefaultBodyLimit, Path, Query, State},
    http::{header, HeaderValue, Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap, VecDeque};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::net::SocketAddr;
use std::os::unix::fs::MetadataExt;
use std::path::{Path as FsPath, PathBuf};
use std::sync::OnceLock;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::net::TcpListener;
use tokio::sync::watch;

use crate::app_socket::{self, RpcFailure};
use crate::remote::{self, Entry, KeysPolicy, SharedRegistry, TargetKind};

pub const ENV_AUTH_MODE: &str = "TERM_MESH_MOBILE_AUTH";
pub const ENV_ALLOWED_LOGINS: &str = "TERM_MESH_MOBILE_ALLOWED_LOGINS";
/// Header Tailscale Serve adds to requests from tailnet users (KB 1312).
/// Absent for tagged devices and Funnel traffic, so absence means "deny".
pub const TAILSCALE_LOGIN_HEADER: &str = "tailscale-user-login";
/// POST body cap. Text for a pane never legitimately approaches this.
pub const MAX_BODY_BYTES: usize = 64 * 1024;
/// How long a pane `request_id` is remembered to swallow client retries.
pub const DEDUPE_WINDOW: Duration = Duration::from_secs(10 * 60);
pub const DEFAULT_SCREEN_LINES: u32 = 200;
pub const MIN_SCREEN_LINES: u32 = 20;
pub const MAX_SCREEN_LINES: u32 = 1000;

/// Keys the page may send when the entry's policy is `safe`.
pub const SAFE_KEYS: &[&str] = &[
    "Enter",
    "Escape",
    "Tab",
    "Backspace",
    "Up",
    "Down",
    "Left",
    "Right",
    "y",
    "n",
    "1",
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9",
    "C-c",
];

const PAGE_HTML: &str = include_str!("../../../Resources/mobile/index.html");
const PAGE_JS: &str = include_str!("../../../Resources/mobile/app.js");
const PAGE_CSS: &str = include_str!("../../../Resources/mobile/app.css");

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthMode {
    /// Development only: any loopback peer passes. Logged loudly at startup.
    Loopback,
    /// Default: `Tailscale-User-Login` must name an allowed tailnet login.
    Tailscale,
}

impl AuthMode {
    pub fn as_str(self) -> &'static str {
        match self {
            AuthMode::Loopback => "loopback",
            AuthMode::Tailscale => "tailscale",
        }
    }
}

#[derive(Debug, Clone)]
pub struct MobileConfig {
    pub addr: SocketAddr,
    pub auth: AuthMode,
    /// Lower-cased tailnet logins. Empty means nobody passes in `tailscale` mode.
    pub allowed_logins: BTreeSet<String>,
}

impl MobileConfig {
    /// Read the listener configuration from the environment. Errors are fatal
    /// for the listener (it does not start) and are logged by the caller.
    pub fn from_env() -> Result<Self, String> {
        let addr = remote::listener_addr()?;
        let auth = match std::env::var(ENV_AUTH_MODE)
            .ok()
            .map(|v| v.trim().to_ascii_lowercase())
            .filter(|v| !v.is_empty())
            .as_deref()
        {
            None | Some("tailscale") => AuthMode::Tailscale,
            Some("loopback") => AuthMode::Loopback,
            Some(other) => {
                return Err(format!(
                    "{ENV_AUTH_MODE}={other:?} is not one of loopback|tailscale"
                ))
            }
        };
        let allowed_logins = parse_logins(std::env::var(ENV_ALLOWED_LOGINS).ok().as_deref());
        Ok(Self {
            addr,
            auth,
            allowed_logins,
        })
    }
}

pub fn parse_logins(raw: Option<&str>) -> BTreeSet<String> {
    raw.unwrap_or("")
        .split(',')
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| !s.is_empty())
        .collect()
}

pub struct MobileState {
    pub config: MobileConfig,
    pub registry: SharedRegistry,
    /// Request ids are reserved while delivery is in flight and become
    /// deduplicable only after the app acknowledges the write.
    dedupe: Mutex<HashMap<String, (Instant, DedupeState)>>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum DedupeState {
    Pending,
    Delivered,
}

enum DedupeAdmission {
    New,
    Delivered,
    Pending,
}

pub type SharedState = Arc<MobileState>;

pub fn new_state(config: MobileConfig, registry: SharedRegistry) -> SharedState {
    Arc::new(MobileState {
        config,
        registry,
        dedupe: Mutex::new(HashMap::new()),
    })
}

/// Start the listener from the environment. Refuses to bind anything that is
/// not loopback (the config parser already rejects it).
pub async fn serve(
    config: MobileConfig,
    registry: SharedRegistry,
    shutdown_rx: watch::Receiver<bool>,
) -> anyhow::Result<()> {
    let listener = TcpListener::bind(config.addr).await?;
    serve_listener(listener, new_state(config, registry), shutdown_rx).await
}

/// Serve on an already-bound listener (tests bind `127.0.0.1:0`).
pub async fn serve_listener(
    listener: TcpListener,
    state: SharedState,
    mut shutdown_rx: watch::Receiver<bool>,
) -> anyhow::Result<()> {
    let addr = listener.local_addr()?;
    match state.config.auth {
        AuthMode::Loopback => tracing::warn!(
            "mobile listener on http://{addr} with {ENV_AUTH_MODE}=loopback: every loopback client passes (development only)"
        ),
        AuthMode::Tailscale => tracing::info!(
            "mobile listener on http://{addr} (auth=tailscale, {} allowed login(s))",
            state.config.allowed_logins.len()
        ),
    }
    if state.config.auth == AuthMode::Tailscale && state.config.allowed_logins.is_empty() {
        tracing::warn!(
            "mobile listener: {ENV_ALLOWED_LOGINS} is empty, every request will be refused"
        );
    }
    axum::serve(
        listener,
        router(state).into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async move {
        let _ = shutdown_rx.changed().await;
        tracing::info!("mobile listener shutting down");
    })
    .await?;
    Ok(())
}

pub fn router(state: SharedState) -> Router {
    Router::new()
        .route("/", get(page_handler))
        .route("/t/{surface_id}", get(page_handler))
        .route("/app.js", get(js_handler))
        .route("/app.css", get(css_handler))
        .route("/api/health", get(health_handler))
        .route("/api/targets", get(targets_handler))
        .route("/api/targets/{surface_id}/screen", get(screen_handler))
        .route("/api/targets/{surface_id}/requests", get(requests_handler))
        .route(
            "/api/targets/{surface_id}/transcript",
            get(transcript_handler),
        )
        .route(
            "/api/targets/{surface_id}/interrupt",
            post(interrupt_handler),
        )
        .route("/api/targets/{surface_id}/text", post(text_handler))
        .route("/api/targets/{surface_id}/key", post(key_handler))
        .fallback(not_found_handler)
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            auth_middleware,
        ))
        .layer(middleware::from_fn(security_headers))
        .with_state(state)
}

// ── auth ────────────────────────────────────────────────────────────────

/// Who the caller is, as far as the listener can tell. Only used for logs.
#[derive(Clone, Debug)]
struct Caller(String);

async fn auth_middleware(
    State(state): State<SharedState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    mut req: Request<Body>,
    next: Next,
) -> Response {
    if !peer.ip().is_loopback() {
        // Cannot happen with a loopback bind; kept as the invariant's last line.
        return ApiError::forbidden("not_loopback", "only loopback peers are accepted")
            .into_response();
    }
    let caller = match state.config.auth {
        AuthMode::Loopback => Caller(format!("loopback:{}", peer.ip())),
        AuthMode::Tailscale => {
            let login = req
                .headers()
                .get(TAILSCALE_LOGIN_HEADER)
                .and_then(|v| v.to_str().ok())
                .map(|v| v.trim().to_ascii_lowercase())
                .filter(|v| !v.is_empty());
            match login {
                None => {
                    return ApiError::forbidden(
                        "login_required",
                        "no Tailscale identity on this request; reach the listener through `tailscale serve`",
                    )
                    .into_response()
                }
                Some(login) if state.config.allowed_logins.contains(&login) => Caller(login),
                Some(_) => {
                    return ApiError::forbidden("login_not_allowed", "this tailnet login is not allowed")
                        .into_response()
                }
            }
        }
    };
    req.extensions_mut().insert(caller);
    next.run(req).await
}

async fn security_headers(req: Request<Body>, next: Next) -> Response {
    let mut res = next.run(req).await;
    let h = res.headers_mut();
    h.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    h.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    h.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    h.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(
            "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
        ),
    );
    res
}

// ── errors ──────────────────────────────────────────────────────────────

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
}

impl ApiError {
    fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
        }
    }
    fn bad_request(code: &'static str, message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, code, message)
    }
    fn forbidden(code: &'static str, message: impl Into<String>) -> Self {
        Self::new(StatusCode::FORBIDDEN, code, message)
    }
    fn not_found(code: &'static str, message: impl Into<String>) -> Self {
        Self::new(StatusCode::NOT_FOUND, code, message)
    }
    fn conflict(code: &'static str, message: impl Into<String>) -> Self {
        Self::new(StatusCode::CONFLICT, code, message)
    }

    /// Map an app-socket failure to the error table in the design doc:
    /// connect failure 503, app-side `not_found` 404, anything else 502.
    fn from_rpc(failure: RpcFailure) -> Self {
        match failure {
            RpcFailure::Unavailable(m) => {
                Self::new(StatusCode::SERVICE_UNAVAILABLE, "app_unavailable", m)
            }
            RpcFailure::Rpc { code, message } if code == "not_found" => {
                Self::not_found("target_gone", message)
            }
            RpcFailure::Rpc { code, message } => Self::new(
                StatusCode::BAD_GATEWAY,
                "app_rpc_failed",
                format!("{code}: {message}"),
            ),
            RpcFailure::Transport(m) => Self::new(StatusCode::BAD_GATEWAY, "app_rpc_failed", m),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(json!({ "error": { "code": self.code, "message": self.message } })),
        )
            .into_response()
    }
}

type ApiResult = Result<Response, ApiError>;

// ── static page ─────────────────────────────────────────────────────────

async fn page_handler() -> Response {
    (
        [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
        PAGE_HTML,
    )
        .into_response()
}

async fn js_handler() -> Response {
    (
        [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
        PAGE_JS,
    )
        .into_response()
}

async fn css_handler() -> Response {
    (
        [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
        PAGE_CSS,
    )
        .into_response()
}

async fn not_found_handler() -> Response {
    ApiError::not_found("no_such_route", "not found").into_response()
}

// ── API ─────────────────────────────────────────────────────────────────

async fn health_handler(State(state): State<SharedState>) -> Response {
    Json(json!({
        "ok": true,
        "auth_mode": state.config.auth.as_str(),
        "version": env!("CARGO_PKG_VERSION"),
        "listener": state.config.addr.to_string(),
    }))
    .into_response()
}

fn target_json(entry: &Entry) -> Value {
    json!({
        "surface_id": entry.surface_id,
        "kind": entry.kind,
        "chat_capable": entry.chat_capable,
        "team_name": entry.team_name,
        "agent_name": entry.agent_name,
        "agent_cli": entry.agent_cli,
        "title": entry.title,
        "cwd": entry.cwd,
        "source": if entry.app_socket.is_some() { "gui" } else { "headless" },
        "keys": entry.keys,
        "owner": entry.owner,
        "created_at": entry.created_at,
        "expires_at": entry.expires_at,
    })
}

const SESSION_SCAN_LINES: usize = 5_000;
const SESSION_SCAN_BYTES: u64 = 8 * 1024 * 1024;
const SESSION_TEXT_LIMIT: usize = 16 * 1024;
const SESSION_HEADLINE_LIMIT: usize = 500;

#[derive(Clone, Copy, PartialEq, Eq)]
struct FileIdentity {
    device: u64,
    inode: u64,
}

#[derive(Default)]
struct SessionTailState {
    identity: Option<FileIdentity>,
    offset: u64,
    carry: Vec<u8>,
    lines: VecDeque<Value>,
}

fn bounded_text(value: &str) -> String {
    let redacted = redact_session_text(value);
    if redacted.len() <= SESSION_TEXT_LIMIT {
        return redacted;
    }
    let mut end = SESSION_TEXT_LIMIT;
    while !redacted.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n… truncated", &redacted[..end])
}

fn bounded_headline(value: &str) -> String {
    let redacted = redact_session_text(value);
    let compact = redacted.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= SESSION_HEADLINE_LIMIT {
        return compact;
    }
    compact
        .chars()
        .take(SESSION_HEADLINE_LIMIT)
        .collect::<String>()
        + "…"
}

pub(crate) fn redact_session_text(value: &str) -> String {
    const MARKERS: &[&str] = &[
        "API_KEY",
        "_KEY",
        "TOKEN",
        "SECRET",
        "PASSWORD",
        "PRIVATE_KEY",
        "AUTHORIZATION",
        "BEARER ",
        "COOKIE",
        "CREDENTIAL",
        "GHP_",
        "GSK_",
        "GLPAT-",
        "NVAPI-",
        "AKIA",
        "XOXB-",
        "HF_",
        "SK-",
        "EYJ",
    ];
    value
        .lines()
        .map(|line| {
            let upper = line.to_ascii_uppercase();
            if MARKERS.iter().any(|marker| upper.contains(marker)) {
                "[credential redacted]".to_string()
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub(crate) fn tail_json_lines(path: &FsPath) -> Result<Vec<Value>, ApiError> {
    static CACHE: OnceLock<Mutex<HashMap<PathBuf, SessionTailState>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut file = File::open(path).map_err(|e| {
        ApiError::conflict(
            "session_unavailable",
            format!("cannot open session log: {e}"),
        )
    })?;
    let metadata = file.metadata().map_err(|e| {
        ApiError::conflict(
            "session_unavailable",
            format!("cannot stat session log: {e}"),
        )
    })?;
    let identity = FileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    };
    let len = metadata.len();
    let mut states = cache.lock().unwrap();
    let state = states.entry(path.to_path_buf()).or_default();
    let reset = state.identity != Some(identity) || len < state.offset;
    if reset {
        *state = SessionTailState {
            identity: Some(identity),
            ..SessionTailState::default()
        };
    }
    if len == state.offset {
        return Ok(state.lines.iter().cloned().collect());
    }
    let start = if state.offset == 0 {
        len.saturating_sub(SESSION_SCAN_BYTES)
    } else {
        state.offset
    };
    file.seek(SeekFrom::Start(start)).map_err(|e| {
        ApiError::conflict(
            "session_unavailable",
            format!("cannot seek session log: {e}"),
        )
    })?;
    let mut bytes = Vec::with_capacity((len - start) as usize);
    file.read_to_end(&mut bytes).map_err(|e| {
        ApiError::conflict(
            "session_unavailable",
            format!("cannot read session log: {e}"),
        )
    })?;
    if state.offset == 0 && start > 0 {
        if let Some(newline) = bytes.iter().position(|b| *b == b'\n') {
            bytes.drain(..=newline);
        } else {
            bytes.clear();
        }
    }
    let mut buffer = std::mem::take(&mut state.carry);
    buffer.extend_from_slice(&bytes);
    let mut consumed = 0;
    for (index, byte) in buffer.iter().enumerate() {
        if *byte != b'\n' {
            continue;
        }
        if let Ok(line) = std::str::from_utf8(&buffer[consumed..index]) {
            if let Ok(value) = serde_json::from_str::<Value>(line) {
                if state.lines.len() == SESSION_SCAN_LINES {
                    state.lines.pop_front();
                }
                state.lines.push_back(value);
            }
        }
        consumed = index + 1;
    }
    state.carry = buffer[consumed..].to_vec();
    state.offset = file.stream_position().unwrap_or(len);
    Ok(state.lines.iter().cloned().collect())
}

fn home_dir() -> Result<PathBuf, ApiError> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| ApiError::conflict("session_unavailable", "HOME is not set"))
}

fn claude_session_path(entry: &Entry, session_id: &str) -> Result<PathBuf, ApiError> {
    let encoded = entry.cwd.replace('/', "-");
    Ok(home_dir()?
        .join(".claude/projects")
        .join(encoded)
        .join(format!("{session_id}.jsonl")))
}

fn codex_session_path(session_id: &str) -> Result<PathBuf, ApiError> {
    static CACHE: OnceLock<Mutex<HashMap<String, PathBuf>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(path) = cache.lock().unwrap().get(session_id).cloned() {
        if path.is_file() {
            return Ok(path);
        }
    }
    let root = home_dir()?.join(".codex/sessions");
    let mut stack = vec![root];
    while let Some(dir) = stack.pop() {
        let Ok(items) = fs::read_dir(dir) else {
            continue;
        };
        for item in items.flatten() {
            let path = item.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().and_then(|v| v.to_str()) == Some("jsonl")
                && path
                    .file_name()
                    .and_then(|v| v.to_str())
                    .is_some_and(|n| n.contains(session_id))
            {
                cache
                    .lock()
                    .unwrap()
                    .insert(session_id.to_string(), path.clone());
                return Ok(path);
            }
        }
    }
    Err(ApiError::conflict(
        "session_unavailable",
        "Codex session log was not found",
    ))
}

fn content_text(content: &Value, kinds: &[&str]) -> String {
    match content {
        Value::String(text) => bounded_text(text),
        Value::Array(blocks) => bounded_text(
            &blocks
                .iter()
                .filter(|block| {
                    block
                        .get("type")
                        .and_then(Value::as_str)
                        .is_some_and(|kind| kinds.contains(&kind))
                })
                .filter_map(|block| block.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n"),
        ),
        _ => String::new(),
    }
}

fn user_visible_text(text: String) -> Option<String> {
    let trimmed = text.trim();
    if trimmed.is_empty()
        || trimmed.starts_with("# AGENTS.md instructions")
        || trimmed.starts_with("<skill>")
        || trimmed.starts_with("<environment_context>")
        || trimmed.starts_with("You are a team agent named \"")
    {
        return None;
    }
    Some(text)
}

pub(crate) fn claude_entries(lines: &[Value]) -> Vec<Value> {
    let mut entries = Vec::new();
    let mut tools: HashMap<String, usize> = HashMap::new();
    for row in lines {
        let kind = row.get("type").and_then(Value::as_str).unwrap_or("");
        let id = row.get("uuid").and_then(Value::as_str).unwrap_or("");
        let message = row.get("message").unwrap_or(&Value::Null);
        let content = message.get("content").unwrap_or(&Value::Null);
        if kind == "user" {
            if let Some(text) = user_visible_text(content_text(content, &["text"])) {
                entries
                    .push(json!({ "id": id, "kind": "said", "speaker": "person", "text": text }));
            }
            if let Some(blocks) = content.as_array() {
                for block in blocks {
                    if block.get("type").and_then(Value::as_str) != Some("tool_result") {
                        continue;
                    }
                    let Some(tool_id) = block.get("tool_use_id").and_then(Value::as_str) else {
                        continue;
                    };
                    if let Some(index) = tools.get(tool_id).copied() {
                        entries[index]["result"] = Value::String(content_text(
                            block.get("content").unwrap_or(&Value::Null),
                            &["text"],
                        ));
                        entries[index]["running"] = Value::Bool(false);
                        entries[index]["failed"] = Value::Bool(
                            block
                                .get("is_error")
                                .and_then(Value::as_bool)
                                .unwrap_or(false),
                        );
                    }
                }
            }
        } else if kind == "assistant" {
            if let Some(blocks) = content.as_array() {
                for (index, block) in blocks.iter().enumerate() {
                    match block.get("type").and_then(Value::as_str) {
                        Some("text") => {
                            if let Some(text) = block
                                .get("text")
                                .and_then(Value::as_str)
                                .filter(|t| !t.trim().is_empty())
                            {
                                entries.push(json!({ "id": format!("{id}:{index}"), "kind": "answered", "text": bounded_text(text) }));
                            }
                        }
                        Some("tool_use") => {
                            let tool_id = block.get("id").and_then(Value::as_str).unwrap_or(id);
                            let name = block.get("name").and_then(Value::as_str).unwrap_or("tool");
                            let headline = block
                                .get("input")
                                .and_then(|v| serde_json::to_string(v).ok())
                                .unwrap_or_default();
                            tools.insert(tool_id.to_string(), entries.len());
                            entries.push(json!({ "id": tool_id, "kind": "tool", "name": name, "headline": bounded_headline(&headline), "result": "", "running": true, "failed": false }));
                        }
                        _ => {}
                    }
                }
            }
        }
    }
    entries
}

pub(crate) fn codex_entries(lines: &[Value]) -> Vec<Value> {
    let mut entries = Vec::new();
    let mut tools: HashMap<String, usize> = HashMap::new();
    for row in lines {
        if row.get("type").and_then(Value::as_str) != Some("response_item") {
            continue;
        }
        let payload = row.get("payload").unwrap_or(&Value::Null);
        let kind = payload.get("type").and_then(Value::as_str).unwrap_or("");
        let id = payload
            .get("id")
            .and_then(Value::as_str)
            .or_else(|| payload.get("call_id").and_then(Value::as_str))
            .unwrap_or("event");
        if kind == "message" {
            let role = payload.get("role").and_then(Value::as_str).unwrap_or("");
            let text = content_text(
                payload.get("content").unwrap_or(&Value::Null),
                &["input_text", "output_text"],
            );
            if role == "user" {
                if let Some(text) = user_visible_text(text) {
                    entries.push(
                        json!({ "id": id, "kind": "said", "speaker": "person", "text": text }),
                    );
                }
            } else if role == "assistant" {
                if text.trim().is_empty() {
                    continue;
                }
                entries.push(json!({ "id": id, "kind": "answered", "text": text }));
            }
        } else if kind == "custom_tool_call" || kind == "function_call" {
            let call_id = payload.get("call_id").and_then(Value::as_str).unwrap_or(id);
            let name = payload
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("tool");
            let headline = payload
                .get("input")
                .or_else(|| payload.get("arguments"))
                .and_then(|v| {
                    if let Some(s) = v.as_str() {
                        Some(s.to_string())
                    } else {
                        serde_json::to_string(v).ok()
                    }
                })
                .unwrap_or_default();
            tools.insert(call_id.to_string(), entries.len());
            entries.push(json!({ "id": call_id, "kind": "tool", "name": name, "headline": bounded_headline(&headline), "result": "", "running": true, "failed": false }));
        } else if kind == "custom_tool_call_output" || kind == "function_call_output" {
            let call_id = payload.get("call_id").and_then(Value::as_str).unwrap_or(id);
            if let Some(index) = tools.get(call_id).copied() {
                let output = payload
                    .get("output")
                    .map(|v| content_text(v, &["input_text", "output_text"]))
                    .unwrap_or_default();
                entries[index]["result"] = Value::String(output);
                entries[index]["running"] = Value::Bool(false);
            }
        }
    }
    entries
}

pub(crate) fn codex_turn_in_flight(lines: &[Value]) -> Option<bool> {
    lines.iter().rev().find_map(|row| {
        if row.get("type").and_then(Value::as_str) != Some("event_msg") {
            return None;
        }
        match row
            .get("payload")
            .and_then(|payload| payload.get("type"))
            .and_then(Value::as_str)
        {
            Some("task_started") => Some(true),
            Some("task_complete") | Some("turn_aborted") => Some(false),
            _ => None,
        }
    })
}

fn session_transcript(entry: &Entry, limit: usize) -> Result<Value, ApiError> {
    let session_id = entry.session_id.as_deref().ok_or_else(|| {
        ApiError::conflict(
            "session_unavailable",
            "the CLI session id is not available yet",
        )
    })?;
    let path = match entry.agent_cli.as_str() {
        "claude" => claude_session_path(entry, session_id)?,
        "codex" => codex_session_path(session_id)?,
        _ => {
            return Err(ApiError::conflict(
                "chat_unavailable",
                "chat supports Claude and Codex sessions",
            ))
        }
    };
    let lines = tail_json_lines(&path)?;
    let mut entries = match entry.agent_cli.as_str() {
        "claude" => claude_entries(&lines),
        "codex" => codex_entries(&lines),
        _ => Vec::new(),
    };
    if entries.len() > limit {
        entries = entries.split_off(entries.len() - limit);
    }
    let in_flight = if entry.agent_cli == "codex" {
        codex_turn_in_flight(&lines)
    } else {
        None
    }
    .unwrap_or_else(|| {
        entries.last().is_some_and(|entry| {
            entry.get("kind").and_then(Value::as_str) == Some("said")
                || (entry.get("kind").and_then(Value::as_str) == Some("tool")
                    && entry.get("running").and_then(Value::as_bool) == Some(true))
        })
    });
    Ok(json!({
        "running": true,
        "thinking": false,
        "in_flight": in_flight,
        "summary": format!("{} · terminal", entry.agent_cli),
        "total": entries.len(),
        "entries": entries,
    }))
}

pub(crate) fn surface_roster_contains(result: &Value, surface_id: &str) -> bool {
    result
        .get("surfaces")
        .and_then(Value::as_array)
        .is_some_and(|items| {
            items
                .iter()
                .any(|item| item.get("id").and_then(Value::as_str) == Some(surface_id))
        })
}

async fn targets_handler(State(state): State<SharedState>) -> Response {
    let now = remote::now_unix();
    let mut reg = state.registry.lock().await;
    let pruned = reg.prune(now, remote::app_socket_alive);
    if !pruned.is_empty() {
        tracing::info!("mobile: pruned {} stale exposure(s)", pruned.len());
    }
    let targets: Vec<Value> = reg.list().iter().map(target_json).collect();
    Json(json!({ "targets": targets, "now": now })).into_response()
}

/// Look up a live entry or fail with 404. Expired entries are 404 too.
async fn live_entry(state: &MobileState, surface_id: &str) -> Result<Entry, ApiError> {
    let now = remote::now_unix();
    let reg = state.registry.lock().await;
    reg.get_live(surface_id, now)
        .cloned()
        .ok_or_else(|| ApiError::not_found("not_exposed", "surface is not exposed"))
}

/// A GUI entry needs its app socket; a daemon-owned entry has none and is not
/// served by this phase (Phase 3 adds the in-process path).
fn app_socket_of(entry: &Entry) -> Result<&str, ApiError> {
    entry.app_socket.as_deref().ok_or_else(|| {
        ApiError::conflict(
            "not_readable",
            "daemon-owned surfaces are not served by this listener yet",
        )
    })
}

/// Run one app RPC for an entry. A `not_found` from the app means the surface
/// (or its team) is gone: drop the exposure so it stops being listed.
async fn app_call(
    state: &MobileState,
    entry: &Entry,
    method: &str,
    params: Value,
) -> Result<Value, ApiError> {
    let socket = app_socket_of(entry)?;
    match app_socket::call(socket, method, params).await {
        Ok(v) => Ok(v),
        Err(failure) => {
            if failure.code() == Some("not_found") {
                let mut reg = state.registry.lock().await;
                reg.remove(&entry.surface_id);
                tracing::info!(
                    "mobile: dropped exposure {} after app reported not_found on {method}",
                    entry.surface_id
                );
            }
            Err(ApiError::from_rpc(failure))
        }
    }
}

#[derive(Deserialize)]
struct ScreenQuery {
    #[serde(default)]
    lines: Option<u32>,
    /// `styled` asks for per-cell colors and attributes (needs an app with
    /// `surface.read_screen_grid`); anything else returns plain text.
    #[serde(default)]
    format: Option<String>,
}

/// One run of cells sharing a style. Colors are `null` (terminal default),
/// a 0–255 palette index, or `#rrggbb`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StyledSpan {
    pub t: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fg: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bg: Option<Value>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub b: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub d: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub i: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub u: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub inv: bool,
}

/// What the page draws: rows of styled spans (scrollback first, then the
/// active area), the cursor cell, and the pane width.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct StyledScreen {
    pub rows: Vec<Vec<StyledSpan>>,
    pub cursor: Option<(usize, usize)>,
    pub columns: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct GridStyle {
    fg: Option<Value>,
    bg: Option<Value>,
    b: bool,
    d: bool,
    i: bool,
    u: bool,
    inv: bool,
    invisible: bool,
}

fn grid_color(style: &Value, key: &str) -> Option<Value> {
    // Ghostty resolves every color to RGB; `*_source` says whether it is
    // the terminal default, which the page renders with its own theme.
    if style.get(&format!("{key}_source")).and_then(Value::as_str) == Some("default") {
        return None;
    }
    style
        .get(key)
        .and_then(Value::as_str)
        .map(|c| json!(c.to_ascii_lowercase()))
}

fn grid_styles(grid: &Value) -> Vec<GridStyle> {
    let Some(list) = grid.get("styles").and_then(Value::as_array) else {
        return Vec::new();
    };
    let flag = |style: &Value, key: &str| style.get(key).and_then(Value::as_bool).unwrap_or(false);
    let mut table: Vec<GridStyle> = Vec::new();
    for style in list {
        let id = style
            .get("id")
            .and_then(Value::as_u64)
            .map(|v| v as usize)
            .unwrap_or(table.len());
        if table.len() <= id {
            table.resize(id + 1, GridStyle::default());
        }
        table[id] = GridStyle {
            fg: grid_color(style, "foreground"),
            bg: grid_color(style, "background"),
            b: flag(style, "bold"),
            d: flag(style, "faint"),
            i: flag(style, "italic"),
            u: flag(style, "underline"),
            inv: flag(style, "inverse"),
            invisible: flag(style, "invisible"),
        };
    }
    table
}

fn push_span(row: &mut Vec<StyledSpan>, next: StyledSpan) {
    match row.last_mut() {
        Some(prev)
            if prev.fg == next.fg
                && prev.bg == next.bg
                && prev.b == next.b
                && prev.d == next.d
                && prev.i == next.i
                && prev.u == next.u
                && prev.inv == next.inv =>
        {
            prev.t.push_str(&next.t)
        }
        _ => row.push(next),
    }
}

/// Place one span list (`row_spans` or `scrollback_spans`) into `rows`,
/// offsetting row numbers by `row_offset` and filling column gaps with
/// default-style spaces so text stays column-aligned.
fn place_spans(
    rows: &mut [Vec<StyledSpan>],
    spans: &Value,
    row_offset: usize,
    styles: &[GridStyle],
) {
    let Some(list) = spans.as_array() else {
        return;
    };
    let mut by_row: HashMap<usize, Vec<(usize, &Value)>> = HashMap::new();
    for span in list {
        let row = span.get("row").and_then(Value::as_u64).unwrap_or(0) as usize + row_offset;
        let column = span.get("column").and_then(Value::as_u64).unwrap_or(0) as usize;
        if row < rows.len() {
            by_row.entry(row).or_default().push((column, span));
        }
    }
    let default_style = GridStyle::default();
    for (row, mut entries) in by_row {
        entries.sort_by_key(|(column, _)| *column);
        let target = &mut rows[row];
        let mut col = 0usize;
        for (column, span) in entries {
            if column > col {
                push_span(
                    target,
                    StyledSpan {
                        t: " ".repeat(column - col),
                        fg: None,
                        bg: None,
                        b: false,
                        d: false,
                        i: false,
                        u: false,
                        inv: false,
                    },
                );
                col = column;
            }
            let text = span.get("text").and_then(Value::as_str).unwrap_or("");
            let width = span
                .get("cell_width")
                .and_then(Value::as_u64)
                .unwrap_or(1)
                .max(1) as usize;
            let style_id = span.get("style_id").and_then(Value::as_u64).unwrap_or(0) as usize;
            let style = styles.get(style_id).unwrap_or(&default_style);
            let chars = text.chars().count();
            let shown = if style.invisible {
                " ".repeat(chars)
            } else {
                text.to_string()
            };
            push_span(
                target,
                StyledSpan {
                    t: shown,
                    fg: style.fg.clone(),
                    bg: style.bg.clone(),
                    b: style.b,
                    d: style.d,
                    i: style.i,
                    u: style.u,
                    inv: style.inv,
                },
            );
            col += chars * width;
        }
    }
}

/// Turn a render-grid frame (`surface.read_screen_grid`) into styled rows.
/// Scrollback rows come first, then the active area; blank rows below both
/// the last content and the cursor are dropped so a tall pane does not
/// render as a wall of empty lines.
pub fn styled_from_grid(grid: &Value) -> StyledScreen {
    let columns = grid.get("columns").and_then(Value::as_u64).unwrap_or(0);
    let active_rows = grid.get("rows").and_then(Value::as_u64).unwrap_or(0) as usize;
    let scrollback_rows = grid
        .get("scrollback_rows")
        .and_then(Value::as_u64)
        .unwrap_or(0) as usize;
    let styles = grid_styles(grid);
    let mut rows: Vec<Vec<StyledSpan>> = vec![Vec::new(); scrollback_rows + active_rows];
    if let Some(spans) = grid.get("scrollback_spans") {
        place_spans(&mut rows, spans, 0, &styles);
    }
    if let Some(spans) = grid.get("row_spans") {
        place_spans(&mut rows, spans, scrollback_rows, &styles);
    }
    let cursor = grid.get("cursor").and_then(|c| {
        let visible = c.get("visible").and_then(Value::as_bool).unwrap_or(false);
        let row = c.get("row").and_then(Value::as_u64)? as usize + scrollback_rows;
        let col = c.get("column").and_then(Value::as_u64)? as usize;
        (visible && row < rows.len()).then_some((row, col))
    });
    let last_content = rows.iter().rposition(|r| {
        r.iter()
            .any(|s| !s.t.trim().is_empty() || s.bg.is_some() || s.inv)
    });
    let keep = match (last_content, cursor) {
        (Some(l), Some((c, _))) => l.max(c) + 1,
        (Some(l), None) => l + 1,
        (None, Some((c, _))) => c + 1,
        (None, None) => 0,
    };
    rows.truncate(keep);
    StyledScreen {
        rows,
        cursor,
        columns,
    }
}

async fn screen_handler(
    State(state): State<SharedState>,
    Path(surface_id): Path<String>,
    Query(q): Query<ScreenQuery>,
) -> ApiResult {
    let lines = match q.lines {
        None => DEFAULT_SCREEN_LINES,
        Some(n) if (MIN_SCREEN_LINES..=MAX_SCREEN_LINES).contains(&n) => n,
        Some(_) => {
            return Err(ApiError::bad_request(
                "invalid_lines",
                format!("lines must be between {MIN_SCREEN_LINES} and {MAX_SCREEN_LINES}"),
            ))
        }
    };
    let entry = live_entry(&state, &surface_id).await?;
    if entry.kind == TargetKind::Agent {
        // A native pane has no grid; `team.read` returns its transcript text.
        let result = app_call(
            &state,
            &entry,
            "team.read",
            json!({ "team_name": entry.team_name, "agent_name": entry.agent_name, "lines": lines }),
        )
        .await?;
        let text = result.get("text").and_then(Value::as_str).unwrap_or("");
        return Ok(Json(json!({
            "surface_id": entry.surface_id,
            "kind": entry.kind,
            "lines": lines,
            "format": "text",
            "text": text,
            "captured_at": remote::now_unix(),
        }))
        .into_response());
    }
    let styled = q.format.as_deref() == Some("styled");
    // An app that predates `surface.read_screen_grid` answers method_not_found;
    // fall through to the plain read and say so in `format` so the page can
    // tell the two apart.
    let styled_result = if styled {
        match app_call(
            &state,
            &entry,
            "surface.read_screen_grid",
            json!({ "surface_id": entry.surface_id, "scrollback_lines": lines }),
        )
        .await
        {
            Ok(result) => Some(result),
            Err(err)
                if err.code == "app_rpc_failed" && err.message.contains("method_not_found") =>
            {
                tracing::info!(
                    "mobile: app has no surface.read_screen_grid, serving plain text for {}",
                    entry.surface_id
                );
                None
            }
            Err(err) => return Err(err),
        }
    } else {
        None
    };
    if let Some(result) = styled_result {
        // Both kinds are GUI surfaces here; the leader's durable board only
        // matters for writes.
        let empty = json!({});
        let screen = styled_from_grid(result.get("grid").unwrap_or(&empty));
        return Ok(Json(json!({
            "surface_id": entry.surface_id,
            "kind": entry.kind,
            "lines": lines,
            "format": "styled",
            "columns": screen.columns,
            "rows": screen.rows,
            "cursor": screen.cursor.map(|(row, col)| json!({ "row": row, "col": col })),
            "captured_at": remote::now_unix(),
        }))
        .into_response());
    }
    let result = match entry.kind {
        // Handled above; kept explicit so a new kind cannot fall through.
        TargetKind::Agent => {
            return Err(ApiError::conflict(
                "not_a_terminal",
                "native agent panes have no screen",
            ))
        }
        TargetKind::Leader => {
            app_call(
                &state,
                &entry,
                "team.read",
                json!({
                    "team_name": entry.team_name,
                    "agent_name": "leader",
                    "lines": lines,
                }),
            )
            .await?
        }
        TargetKind::Pane => {
            app_call(
                &state,
                &entry,
                "surface.read_text",
                json!({
                    "surface_id": entry.surface_id,
                    "lines": lines,
                    "scrollback": true,
                }),
            )
            .await?
        }
    };
    let text = result.get("text").and_then(Value::as_str).unwrap_or("");
    Ok(Json(json!({
        "surface_id": entry.surface_id,
        "kind": entry.kind,
        "lines": lines,
        "format": "text",
        "styled_unavailable": styled,
        "text": text,
        "captured_at": remote::now_unix(),
    }))
    .into_response())
}

async fn requests_handler(
    State(state): State<SharedState>,
    Path(surface_id): Path<String>,
) -> ApiResult {
    let entry = live_entry(&state, &surface_id).await?;
    if entry.kind != TargetKind::Leader {
        return Err(ApiError::conflict(
            "not_leader",
            "durable requests exist only for leader targets",
        ));
    }
    // The app gates the board behind the leader pane's capability token;
    // `tm-agent remote on --leader` captured it from the pane environment.
    let mut params = json!({ "team_name": entry.team_name });
    if let Some(token) = &entry.leader_request_token {
        params["leader_request_token"] = json!(token);
    }
    let result = app_call(&state, &entry, "team.leader.request.list", params).await?;
    Ok(Json(json!({
        "surface_id": entry.surface_id,
        "team_name": entry.team_name,
        "count": result.get("count").cloned().unwrap_or(Value::Null),
        "requests": result.get("requests").cloned().unwrap_or_else(|| json!([])),
    }))
    .into_response())
}

#[derive(Deserialize)]
struct TextBody {
    text: String,
    #[serde(default)]
    request_id: Option<String>,
    #[serde(default)]
    mode: Option<String>,
}

async fn text_handler(
    State(state): State<SharedState>,
    Path(surface_id): Path<String>,
    axum::Extension(caller): axum::Extension<Caller>,
    Json(body): Json<TextBody>,
) -> ApiResult {
    if body.text.trim().is_empty() {
        return Err(ApiError::bad_request(
            "empty_text",
            "text must not be empty",
        ));
    }
    let request_id = body
        .request_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    if let Some(id) = request_id.as_deref() {
        if id.len() > 128
            || !id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err(ApiError::bad_request(
                "invalid_request_id",
                "request_id must be alphanumeric, '-' or '_' (max 128)",
            ));
        }
    }
    let entry = live_entry(&state, &surface_id).await?;
    tracing::info!(
        "mobile: text by {} to {} ({:?}, {} bytes)",
        caller.0,
        entry.surface_id,
        entry.kind,
        body.text.len()
    );
    match entry.kind {
        TargetKind::Agent => {
            if let Some(id) = &request_id {
                match state.reserve_request(&entry.surface_id, id) {
                    DedupeAdmission::New => {}
                    DedupeAdmission::Delivered => {
                        return Ok(Json(json!({
                            "surface_id": entry.surface_id, "kind": "agent",
                            "delivered": true, "deduplicated": true, "request_id": id,
                        }))
                        .into_response())
                    }
                    DedupeAdmission::Pending => {
                        return Err(ApiError::conflict(
                            "request_in_flight",
                            "a request with this id is still being delivered",
                        ))
                    }
                }
            }
            let result = app_call(
                &state,
                &entry,
                "team.send",
                json!({ "team_name": entry.team_name, "agent_name": entry.agent_name, "text": body.text }),
            )
            .await;
            let result = match result {
                Ok(result) => result,
                Err(error) => {
                    if let Some(id) = request_id.as_deref() {
                        state.forget_request(&entry.surface_id, id);
                    }
                    return Err(error);
                }
            };
            if let Some(id) = request_id.as_deref() {
                state.commit_request(&entry.surface_id, id);
            }
            Ok((
                StatusCode::ACCEPTED,
                Json(json!({
                    "surface_id": entry.surface_id,
                    "kind": "agent",
                    "delivered": true,
                    "deduplicated": false,
                    "request_id": request_id,
                    "delivery_scope": result.get("delivery_scope").cloned().unwrap_or(Value::Null),
                })),
            )
                .into_response())
        }
        TargetKind::Leader => {
            let mut params = json!({ "team_name": entry.team_name, "text": body.text });
            if let Some(id) = &request_id {
                params["request_id"] = json!(id);
            }
            let result = app_call(&state, &entry, "team.leader.send", params).await?;
            let pick = |k: &str| result.get(k).cloned().unwrap_or(Value::Null);
            Ok((
                StatusCode::ACCEPTED,
                Json(json!({
                    "surface_id": entry.surface_id,
                    "kind": "leader",
                    "request_id": pick("request_id"),
                    "stored": pick("stored"),
                    "wake_dispatched": pick("wake_dispatched"),
                    "request_replayed": pick("request_replayed"),
                    "claimed_by_leader": pick("claimed_by_leader"),
                })),
            )
                .into_response())
        }
        TargetKind::Pane => {
            let chat_mode = body.mode.as_deref() == Some("chat");
            if chat_mode && !entry.chat_capable {
                return Err(ApiError::conflict(
                    "chat_unavailable",
                    "this terminal has no supported CLI session",
                ));
            }
            if let Some(id) = &request_id {
                match state.reserve_request(&entry.surface_id, id) {
                    DedupeAdmission::New => {}
                    DedupeAdmission::Delivered => {
                        return Ok(Json(json!({
                            "surface_id": entry.surface_id, "kind": "pane",
                            "delivered": true, "deduplicated": true, "request_id": id,
                        }))
                        .into_response())
                    }
                    DedupeAdmission::Pending => {
                        return Err(ApiError::conflict(
                            "request_in_flight",
                            "a request with this id is still being delivered",
                        ))
                    }
                }
            }
            let delivery = if chat_mode {
                app_call(
                    &state,
                    &entry,
                    "surface.send_turn",
                    json!({ "surface_id": entry.surface_id, "text": body.text }),
                )
                .await
            } else {
                app_call(
                    &state,
                    &entry,
                    "surface.send_text",
                    json!({ "surface_id": entry.surface_id, "text": body.text }),
                )
                .await
            };
            if let Err(error) = delivery {
                if let Some(id) = request_id.as_deref() {
                    state.forget_request(&entry.surface_id, id);
                }
                return Err(error);
            }
            if let Some(id) = request_id.as_deref() {
                state.commit_request(&entry.surface_id, id);
            }
            Ok(Json(json!({
                "surface_id": entry.surface_id,
                "kind": "pane",
                "mode": if chat_mode { "chat" } else { "terminal" },
                "delivered": true,
                "deduplicated": false,
                "request_id": request_id,
            }))
            .into_response())
        }
    }
}

impl MobileState {
    /// Returns true when this `request_id` was already delivered inside the
    /// dedupe window (so the caller must not type it again).
    fn reserve_request(&self, surface_id: &str, request_id: &str) -> DedupeAdmission {
        let key = format!("{surface_id}\u{0}{request_id}");
        let now = Instant::now();
        let mut seen = self.dedupe.lock().unwrap();
        seen.retain(|_, (first, _)| now.duration_since(*first) < DEDUPE_WINDOW);
        if let Some((_, state)) = seen.get(&key) {
            return match state {
                DedupeState::Delivered => DedupeAdmission::Delivered,
                DedupeState::Pending => DedupeAdmission::Pending,
            };
        }
        seen.insert(key, (now, DedupeState::Pending));
        DedupeAdmission::New
    }

    fn commit_request(&self, surface_id: &str, request_id: &str) {
        let key = format!("{surface_id}\u{0}{request_id}");
        if let Some((_, state)) = self.dedupe.lock().unwrap().get_mut(&key) {
            *state = DedupeState::Delivered;
        }
    }

    fn forget_request(&self, surface_id: &str, request_id: &str) {
        let key = format!("{surface_id}\u{0}{request_id}");
        self.dedupe.lock().unwrap().remove(&key);
    }
}

#[derive(Deserialize)]
struct TranscriptQuery {
    #[serde(default)]
    limit: Option<u32>,
}

/// Structured conversation for a native agent or a terminal-backed Claude /
/// Codex session. The local pane stays a terminal; only this view is chat.
async fn transcript_handler(
    State(state): State<SharedState>,
    Path(surface_id): Path<String>,
    Query(q): Query<TranscriptQuery>,
) -> ApiResult {
    let entry = live_entry(&state, &surface_id).await?;
    if !entry.chat_capable {
        return Err(ApiError::conflict(
            "not_an_agent",
            "this target has no structured conversation; use /screen",
        ));
    }
    let limit = q.limit.unwrap_or(200).clamp(1, 2000);
    let (result, terminal_running) = if entry.kind == TargetKind::Agent {
        let value = app_call(
            &state,
            &entry,
            "team.agent.transcript",
            json!({ "team_name": entry.team_name, "agent_name": entry.agent_name, "limit": limit }),
        )
        .await?;
        (value, None)
    } else {
        let surfaces = app_call(
            &state,
            &entry,
            "surface.list",
            json!({ "surface_id": entry.surface_id }),
        )
        .await?;
        let running = surface_roster_contains(&surfaces, &entry.surface_id);
        let session_entry = entry.clone();
        let value =
            tokio::task::spawn_blocking(move || session_transcript(&session_entry, limit as usize))
                .await
                .map_err(|e| {
                    ApiError::conflict("session_unavailable", format!("session reader failed: {e}"))
                })??;
        (value, Some(running))
    };
    let pick = |k: &str| result.get(k).cloned().unwrap_or(Value::Null);
    Ok(Json(json!({
        "surface_id": entry.surface_id,
        "kind": "agent",
        "terminal_backed": entry.kind == TargetKind::Pane,
        "team_name": entry.team_name,
        "agent_name": entry.agent_name,
        "running": terminal_running.map(Value::Bool).unwrap_or_else(|| pick("running")),
        "thinking": pick("thinking"),
        "in_flight": pick("in_flight"),
        "summary": pick("summary"),
        "total": pick("total"),
        "entries": result.get("entries").cloned().unwrap_or_else(|| json!([])),
        "captured_at": remote::now_unix(),
    }))
    .into_response())
}

/// `kind=agent`: stop the agent's current turn (`team.interrupt`).
async fn interrupt_handler(
    State(state): State<SharedState>,
    Path(surface_id): Path<String>,
    axum::Extension(caller): axum::Extension<Caller>,
) -> ApiResult {
    let entry = live_entry(&state, &surface_id).await?;
    if !entry.chat_capable {
        return Err(ApiError::conflict(
            "not_an_agent",
            "interrupt exists only for native agent targets; send the C-c key instead",
        ));
    }
    tracing::info!("mobile: interrupt by {} to {}", caller.0, entry.surface_id);
    let result = if entry.kind == TargetKind::Agent {
        app_call(
            &state,
            &entry,
            "team.interrupt",
            json!({ "team_name": entry.team_name, "agent_name": entry.agent_name }),
        )
        .await?
    } else {
        app_call(
            &state,
            &entry,
            "surface.send_key",
            json!({ "surface_id": entry.surface_id, "key": "ctrl-c" }),
        )
        .await?
    };
    Ok(Json(json!({
        "surface_id": entry.surface_id,
        "interrupted": result.get("interrupted").cloned().unwrap_or(json!(true)),
    }))
    .into_response())
}

/// How a safe key reaches a GUI surface: a named key the app understands
/// (`surface.send_key`) or literal bytes typed as text (`surface.send_text`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuiKey {
    Named(&'static str),
    Text(&'static str),
}

/// Exact-match mapping for the safe allowlist. Every non-printable key is a
/// named key event (`surface.send_key`) so Ghostty encodes it for the
/// keyboard protocol the pane negotiated; raw CSI bytes through the text
/// path reach a plain shell but not a kitty-protocol TUI such as Claude Code.
pub fn gui_key(key: &str) -> Option<GuiKey> {
    Some(match key {
        "Enter" => GuiKey::Named("enter"),
        "Escape" => GuiKey::Named("escape"),
        "Tab" => GuiKey::Named("tab"),
        "Backspace" => GuiKey::Named("backspace"),
        "C-c" => GuiKey::Named("ctrl-c"),
        "Up" => GuiKey::Named("up"),
        "Down" => GuiKey::Named("down"),
        "Right" => GuiKey::Named("right"),
        "Left" => GuiKey::Named("left"),
        "y" => GuiKey::Text("y"),
        "n" => GuiKey::Text("n"),
        "1" => GuiKey::Text("1"),
        "2" => GuiKey::Text("2"),
        "3" => GuiKey::Text("3"),
        "4" => GuiKey::Text("4"),
        "5" => GuiKey::Text("5"),
        "6" => GuiKey::Text("6"),
        "7" => GuiKey::Text("7"),
        "8" => GuiKey::Text("8"),
        "9" => GuiKey::Text("9"),
        _ => return None,
    })
}

#[derive(Deserialize)]
struct KeyBody {
    key: String,
}

async fn key_handler(
    State(state): State<SharedState>,
    Path(surface_id): Path<String>,
    axum::Extension(caller): axum::Extension<Caller>,
    Json(body): Json<KeyBody>,
) -> ApiResult {
    let key = body.key.trim();
    let entry = live_entry(&state, &surface_id).await?;
    if entry.kind == TargetKind::Agent {
        return Err(ApiError::conflict(
            "not_a_terminal",
            "native agent panes take turns, not keys; use /text or /interrupt",
        ));
    }
    if entry.keys == KeysPolicy::None {
        return Err(ApiError::forbidden(
            "keys_disabled",
            "this target was exposed with keys=none",
        ));
    }
    let Some(mapped) = gui_key(key) else {
        return Err(ApiError::forbidden(
            "key_not_allowed",
            format!("key is not in the safe allowlist: {}", SAFE_KEYS.join(" ")),
        ));
    };
    tracing::info!("mobile: key {key} by {} to {}", caller.0, entry.surface_id);
    match mapped {
        GuiKey::Named(name) => {
            app_call(
                &state,
                &entry,
                "surface.send_key",
                json!({ "surface_id": entry.surface_id, "key": name }),
            )
            .await?;
        }
        GuiKey::Text(text) => {
            app_call(
                &state,
                &entry,
                "surface.send_text",
                json!({ "surface_id": entry.surface_id, "text": text }),
            )
            .await?;
        }
    }
    Ok(Json(json!({
        "surface_id": entry.surface_id,
        "key": key,
        "delivered": true,
    }))
    .into_response())
}
