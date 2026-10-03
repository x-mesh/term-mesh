//! Mobile remote-control listener (`docs/mobile-remote-control.md` §4.4–§7).
//!
//! A loopback-only HTTP server, separate from the dashboard in `http.rs`, that
//! exposes registered surfaces (`crate::remote`) to a phone through Tailscale
//! Serve. It owns no state beyond the registry and a short request-id
//! deduplication window; reads and writes are proxied to the app Unix socket
//! that owns each surface.
//!
//! Depends only on `crate::remote`, `crate::app_socket` and its own
//! `mobile_model` submodule so `tests/mobile_http.rs` can include them with
//! `#[path]`.

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

#[path = "cli_path.rs"]
pub(crate) mod cli_path;
#[path = "mobile_model.rs"]
mod mobile_model;
use mobile_model::{DriveError, PaneDriver};

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

#[cfg(test)]
pub(crate) fn embedded_page_js() -> &'static str {
    PAGE_JS
}

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

/// The CLI session a pane is running.
pub struct PaneSession {
    pub cli: String,
    /// None while the CLI is running but has written nothing a transcript
    /// can be read from: a fresh session only appears after its first reply.
    pub session_id: Option<String>,
}

/// Finds the session behind a surface whose exposure record carries none.
///
/// A CLI exports its session id only to its own children, so `/rc on` — which
/// the CLI runs as a child — reads it straight from the environment, while the
/// app that owns the pane cannot see it and cannot put it in the record. The
/// app's mobile button therefore registered terminal panes with no session,
/// the page saw `chat_capable: false`, and the Chat/Terminal switch vanished
/// for exactly the panes people run a CLI in by hand.
///
/// Injected rather than imported: this module stays on `crate::remote` and
/// `crate::app_socket` alone so `tests/mobile_http.rs` can `#[path]` the three
/// together, and the trackers behind this reach the rest of the daemon.
pub type SessionResolver = Arc<dyn Fn(&str) -> Option<PaneSession> + Send + Sync>;

pub struct MobileState {
    pub config: MobileConfig,
    pub registry: SharedRegistry,
    /// None in tests and wherever the daemon cannot correlate panes, which
    /// leaves the record's own answer standing.
    session_resolver: Option<SessionResolver>,
    /// Request ids are reserved while delivery is in flight and become
    /// deduplicable only after the app acknowledges the write.
    dedupe: Mutex<HashMap<String, (Instant, DedupeState)>>,
    /// Surfaces whose model popup is being driven. Any other write would land
    /// in the popup instead of the composer.
    model_busy: Mutex<BTreeSet<String>>,
}

struct ModelLock<'a> {
    state: &'a MobileState,
    surface_id: String,
}

impl Drop for ModelLock<'_> {
    fn drop(&mut self) {
        self.state.model_busy.lock().unwrap().remove(&self.surface_id);
    }
}

impl MobileState {
    fn lock_model(&self, surface_id: &str) -> Result<ModelLock<'_>, ApiError> {
        if !self.model_busy.lock().unwrap().insert(surface_id.to_string()) {
            return Err(model_busy_error());
        }
        Ok(ModelLock {
            state: self,
            surface_id: surface_id.to_string(),
        })
    }

    fn refuse_while_model_busy(&self, surface_id: &str) -> Result<(), ApiError> {
        if self.model_busy.lock().unwrap().contains(surface_id) {
            return Err(model_busy_error());
        }
        Ok(())
    }

    /// The session this entry can show a transcript for, from the record when
    /// the exposing client knew it and from the daemon's own pane correlation
    /// when it did not.
    fn resolved_session(&self, entry: &Entry) -> Option<PaneSession> {
        if let (Some(session_id), false) =
            (entry.session_id.as_deref(), entry.agent_cli.is_empty())
        {
            return Some(PaneSession {
                cli: entry.agent_cli.clone(),
                session_id: Some(session_id.to_string()),
            });
        }
        self.session_resolver.as_ref()?(&entry.surface_id)
    }

    /// Whether the phone should offer Chat beside Terminal.
    ///
    /// Only ever adds: an agent target is a chat by construction, and a record
    /// that already claims the capability keeps it. What changes is the pane
    /// running a hand-started CLI, which can now say so.
    fn chat_capable(&self, entry: &Entry) -> bool {
        entry.chat_capable || self.resolved_session(entry).is_some()
    }
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

pub fn new_state(
    config: MobileConfig,
    registry: SharedRegistry,
    session_resolver: Option<SessionResolver>,
) -> SharedState {
    Arc::new(MobileState {
        config,
        registry,
        session_resolver,
        dedupe: Mutex::new(HashMap::new()),
        model_busy: Mutex::new(BTreeSet::new()),
    })
}

/// Start the listener from the environment. Refuses to bind anything that is
/// not loopback (the config parser already rejects it).
pub async fn serve(
    config: MobileConfig,
    registry: SharedRegistry,
    session_resolver: Option<SessionResolver>,
    shutdown_rx: watch::Receiver<bool>,
) -> anyhow::Result<()> {
    let listener = TcpListener::bind(config.addr).await?;
    let _serving = crate::remote::ListenerServing::begin();
    serve_listener(
        listener,
        new_state(config, registry, session_resolver),
        shutdown_rx,
    )
    .await
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
        .route("/api/targets/{surface_id}/commands", get(commands_handler))
        .route("/api/targets/{surface_id}/models", get(models_handler))
        .route("/api/targets/{surface_id}/model", post(model_handler))
        .route(
            "/api/targets/{surface_id}/effort",
            get(effort_handler).post(effort_set_handler),
        )
        .route(
            "/api/targets/{surface_id}/prompt",
            get(prompt_handler).post(prompt_answer_handler),
        )
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
    rpc_code: Option<String>,
}

impl ApiError {
    fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
            rpc_code: None,
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
            RpcFailure::Rpc { code, message } => Self {
                status: StatusCode::BAD_GATEWAY,
                code: "app_rpc_failed",
                message: format!("{code}: {message}"),
                rpc_code: Some(code),
            },
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
        // A tagged Debug app runs beside the installed one with an identical
        // page; the tag is how a viewer tells which app they reached.
        "tag": std::env::var("TERMMESH_TAG").ok().filter(|tag| !tag.is_empty()),
    }))
    .into_response()
}

/// One target as the page sees it.
///
/// `chat_capable` and `agent_cli` are answered by `state`, not read straight
/// off the record: a pane the app exposed carries neither, because the CLI
/// running in it hands its session id only to its own children. The page hides
/// the whole Chat/Terminal switch on a false here, so leaving the record to
/// answer alone is what made that switch disappear.
fn target_json(state: &MobileState, entry: &Entry) -> Value {
    let session = state.resolved_session(entry);
    let cli = if entry.agent_cli.is_empty() {
        session.as_ref().map(|s| s.cli.clone()).unwrap_or_default()
    } else {
        entry.agent_cli.clone()
    };
    json!({
        "surface_id": entry.surface_id,
        "kind": entry.kind,
        "chat_capable": entry.chat_capable || session.is_some(),
        "team_name": entry.team_name,
        "agent_name": entry.agent_name,
        "agent_cli": cli,
        "title": entry.title,
        "cwd": entry.cwd,
        "source": if entry.app_socket.is_some() { "gui" } else { "headless" },
        "keys": entry.keys,
        "owner": entry.owner,
        "created_at": entry.created_at,
        "expires_at": entry.expires_at,
    })
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct MobileCommand {
    pub name: String,
    pub invocation: String,
    pub kind: &'static str,
    pub description: String,
    pub source: &'static str,
    pub argument_hint: String,
    pub selectable: bool,
    pub reason: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action: Option<&'static str>,
}

const COMMAND_SCAN_LIMIT: usize = 4096;
const COMMAND_METADATA_BYTES: u64 = 16 * 1024;

fn command_metadata(path: &FsPath) -> std::io::Result<HashMap<String, String>> {
    let mut bytes = Vec::new();
    File::open(path)?
        .take(COMMAND_METADATA_BYTES)
        .read_to_end(&mut bytes)?;
    // The cap can split a multi-byte character in a longer file, which used
    // to fail the whole scan root and drop every command after it. Only a
    // character cut at the end is dropped; bytes that are not UTF-8 anywhere
    // else still fail, so a broken file stays visible as a warning.
    let text = match std::str::from_utf8(&bytes) {
        Ok(text) => text,
        Err(error) if error.error_len().is_none() => {
            std::str::from_utf8(&bytes[..error.valid_up_to()]).unwrap_or_default()
        }
        Err(error) => {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, error))
        }
    };
    let mut values = HashMap::new();
    let mut lines = text.lines();
    if lines.next().map(str::trim) != Some("---") {
        return Ok(values);
    }
    let mut multiline: Option<String> = None;
    for line in lines {
        if line.trim() == "---" {
            break;
        }
        if line.starts_with(' ') || line.starts_with('\t') {
            if let Some(key) = &multiline {
                let value = values.entry(key.clone()).or_insert_with(String::new);
                if !value.is_empty() {
                    value.push(' ');
                }
                value.push_str(line.trim());
            }
            continue;
        }
        multiline = None;
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        if !matches!(
            key,
            "name" | "description" | "argument-hint" | "user-invocable"
        ) {
            continue;
        }
        let value = value.trim();
        if matches!(value, ">" | "|" | ">-" | "|-") {
            multiline = Some(key.to_string());
            values.insert(key.to_string(), String::new());
        } else {
            let value = if value.starts_with('"') {
                serde_json::from_str::<String>(value).map_err(std::io::Error::other)?
            } else if value.len() >= 2 && value.starts_with('\'') && value.ends_with('\'') {
                value[1..value.len() - 1].replace("''", "'")
            } else {
                value.to_string()
            };
            values.insert(key.to_string(), value);
        }
    }
    for (key, value) in &mut values {
        let limit = if key == "description" { 600 } else { 160 };
        *value = value.chars().take(limit).collect();
    }
    Ok(values)
}

fn command_name_valid(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 160
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b':' | b'.'))
}

fn scan_mobile_commands(
    root: &FsPath,
    cli: &str,
    kind: &'static str,
    source: &'static str,
    namespace: &str,
    budget: &mut usize,
    items: &mut HashMap<String, MobileCommand>,
) -> std::io::Result<()> {
    let mut stack = vec![(root.to_path_buf(), namespace.to_string(), 0usize)];
    let mut visited = BTreeSet::new();
    while let Some((dir, prefix, depth)) = stack.pop() {
        if *budget == 0 {
            return Err(std::io::Error::other("command scan limit reached"));
        }
        *budget -= 1;
        let canonical = match fs::canonicalize(&dir) {
            Ok(path) => path,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e),
        };
        if !visited.insert(canonical) {
            continue;
        }
        let skill = dir.join("SKILL.md");
        if kind == "skill" && skill.is_file() {
            let meta = command_metadata(&skill)?;
            if meta.get("user-invocable").is_some_and(|v| v == "false") {
                continue;
            }
            let fallback = dir.file_name().and_then(|n| n.to_str()).unwrap_or("");
            let name = meta.get("name").map(String::as_str).unwrap_or(fallback);
            let name = if prefix.is_empty() || name.starts_with(&format!("{prefix}:")) {
                name.to_string()
            } else {
                format!("{prefix}:{name}")
            };
            if command_name_valid(&name) {
                let invocation = format!("{}{name}", if cli == "codex" { '$' } else { '/' });
                items.entry(invocation.clone()).or_insert(MobileCommand {
                    name,
                    invocation,
                    kind,
                    source,
                    description: meta.get("description").cloned().unwrap_or_default(),
                    argument_hint: meta.get("argument-hint").cloned().unwrap_or_default(),
                    selectable: true,
                    action: None,
                    reason: String::new(),
                });
            }
            continue;
        }
        let mut entries = fs::read_dir(&dir)?
            .take(*budget + 1)
            .collect::<Result<Vec<_>, _>>()?;
        if entries.len() > *budget {
            return Err(std::io::Error::other("command scan limit reached"));
        }
        entries.sort_by_key(|e| e.file_name());
        for entry in entries.into_iter().rev() {
            if *budget == 0 {
                return Err(std::io::Error::other("command scan limit reached"));
            }
            *budget -= 1;
            let path = entry.path();
            let filename = entry.file_name().to_string_lossy().into_owned();
            if filename.starts_with('.') && filename != ".system" {
                continue;
            }
            if path.is_dir() && depth < 5 {
                let next = if kind == "command" {
                    if prefix.is_empty() {
                        filename
                    } else {
                        format!("{prefix}:{filename}")
                    }
                } else {
                    prefix.clone()
                };
                stack.push((path, next, depth + 1));
            } else if kind == "command" && path.extension().is_some_and(|ext| ext == "md") {
                let stem = path.file_stem().and_then(|v| v.to_str()).unwrap_or("");
                let name = if prefix.is_empty() {
                    stem.to_string()
                } else {
                    format!("{prefix}:{stem}")
                };
                if !command_name_valid(&name) {
                    continue;
                }
                let meta = command_metadata(&path)?;
                let invocation = format!("/{name}");
                items.entry(invocation.clone()).or_insert(MobileCommand {
                    name,
                    invocation,
                    kind,
                    source,
                    description: meta.get("description").cloned().unwrap_or_default(),
                    argument_hint: meta.get("argument-hint").cloned().unwrap_or_default(),
                    selectable: true,
                    action: None,
                    reason: String::new(),
                });
            }
        }
    }
    Ok(())
}

/// What the page does with a built-in command instead of typing it: open a
/// picker the daemon drives, or send it and switch to the terminal, because
/// the command answers with a menu or screen output Chat never sees (Codex
/// logs no slash-command output at all).
fn builtin_action(cli: &str, invocation: &str) -> Option<&'static str> {
    match (cli, invocation) {
        (_, "/model") => Some("pick_model"),
        ("claude", "/effort") => Some("pick_effort"),
        (
            "claude",
            "/permissions" | "/mcp" | "/resume" | "/config" | "/plugin" | "/rewind" | "/status"
            | "/help" | "/skills",
        ) => Some("terminal"),
        ("codex", "/compact" | "/init") => None,
        ("codex", _) => Some("terminal"),
        _ => None,
    }
}

pub(crate) fn mobile_command_catalog(
    cli: &str,
    cwd: &FsPath,
    home: &FsPath,
    native: bool,
) -> Result<(Vec<MobileCommand>, Option<String>), ApiError> {
    let mut items = HashMap::new();
    let mut budget = COMMAND_SCAN_LIMIT;
    let mut incomplete = false;
    let mut roots = Vec::new();
    if !matches!(cli, "claude" | "codex") {
        return Err(ApiError::conflict(
            "commands_unavailable",
            "this CLI has no command catalog",
        ));
    }
    if cli == "claude" {
        if cwd.is_absolute() {
            for ancestor in cwd.ancestors() {
                roots.push((ancestor.join(".claude/skills"), "skill", "project"));
                roots.push((ancestor.join(".claude/commands"), "command", "project"));
                if ancestor.join(".git").exists() || ancestor == home {
                    break;
                }
            }
        }
        roots.push((home.join(".claude/skills"), "skill", "user"));
        roots.push((home.join(".claude/commands"), "command", "user"));
    }
    for (root, kind, source) in roots {
        if scan_mobile_commands(&root, cli, kind, source, "", &mut budget, &mut items).is_err() {
            incomplete = true;
        }
    }
    let common = [
        ("/model", "모델 선택"),
        ("/compact", "대화 요약으로 컨텍스트 정리"),
        ("/review", "코드 변경 검토"),
        ("/skills", "스킬 목록 보기"),
        ("/permissions", "실행 권한 설정"),
        ("/mcp", "MCP 연결 보기"),
        ("/init", "프로젝트 지침 생성"),
        ("/plan", "계획 모드 사용"),
        ("/resume", "이전 대화 이어가기"),
    ];
    let extra: &[(&str, &str)] = if cli == "claude" {
        &[
            ("/help", "사용할 수 있는 명령 보기"),
            ("/cost", "토큰 사용량과 비용 보기"),
            ("/clear", "대화 초기화"),
            ("/context", "컨텍스트 사용량 보기"),
            ("/effort", "추론 강도 선택"),
            ("/plugin", "플러그인 관리"),
            ("/status", "현재 상태 보기"),
            ("/config", "설정 보기"),
            ("/rewind", "이전 대화 지점으로 돌아가기"),
        ]
    } else {
        &[
            ("/status", "세션 상태와 사용량 보기"),
            ("/new", "새 대화 시작"),
            ("/diff", "파일 변경 보기"),
            ("/fork", "현재 대화 분기"),
            ("/mention", "파일을 컨텍스트에 추가"),
            ("/apps", "앱 연결 보기"),
        ]
    };
    for (invocation, description) in common.iter().chain(extra.iter()) {
        items
            .entry(invocation.to_string())
            .or_insert(MobileCommand {
                name: invocation.trim_start_matches('/').to_string(),
                invocation: invocation.to_string(),
                kind: "command",
                source: "builtin",
                description: description.to_string(),
                argument_hint: String::new(),
                selectable: !native,
                action: if native { None } else { builtin_action(cli, invocation) },
                reason: if native {
                    "터미널 CLI에서 사용하는 명령입니다.".to_string()
                } else {
                    String::new()
                },
            });
    }
    let mut items: Vec<_> = items.into_values().collect();
    items.sort_by(|a, b| a.invocation.cmp(&b.invocation));
    Ok((
        items,
        incomplete.then(|| {
            "일부 명령·스킬을 읽지 못했습니다. 목록을 다시 열어 재시도하세요.".to_string()
        }),
    ))
}

async fn commands_handler(
    State(state): State<SharedState>,
    Path(surface_id): Path<String>,
) -> ApiResult {
    let entry = live_entry(&state, &surface_id).await?;
    if !state.chat_capable(&entry) {
        return Err(ApiError::conflict(
            "commands_unavailable",
            "this pane has no supported CLI session",
        ));
    }
    let mut cli = state
        .resolved_session(&entry)
        .map(|s| s.cli)
        .unwrap_or_else(|| entry.agent_cli.clone());
    let mut cwd = PathBuf::from(&entry.cwd);
    if entry.kind == TargetKind::Agent {
        let roster = app_call(
            &state,
            &entry,
            "team.status",
            json!({"team_name":entry.team_name}),
        )
        .await?;
        let agent = roster
            .get("agents")
            .and_then(Value::as_array)
            .and_then(|agents| {
                agents.iter().find(|agent| {
                    agent.get("name").and_then(Value::as_str) == entry.agent_name.as_deref()
                })
            })
            .ok_or_else(|| {
                ApiError::conflict(
                    "commands_unavailable",
                    "agent command environment is unavailable",
                )
            })?;
        if agent.get("host").is_some_and(|host| !host.is_null()) {
            return Err(ApiError::conflict(
                "remote_commands_unavailable",
                "원격 에이전트의 명령·스킬 목록은 아직 조회할 수 없습니다.",
            ));
        }
        if let Some(value) = agent.get("working_directory").and_then(Value::as_str) {
            cwd = PathBuf::from(value);
        }
        if let Some(value) = agent.get("cli").and_then(Value::as_str) {
            cli = value.to_string();
        }
    }
    let home = home_dir()?;
    let native = entry.kind != TargetKind::Pane;
    let catalog_cli = cli.clone();
    let catalog_cwd = cwd.clone();
    let (mut items, mut warning) = tokio::task::spawn_blocking(move || {
        mobile_command_catalog(&catalog_cli, &catalog_cwd, &home, native)
    })
    .await
    .map_err(|_| ApiError::conflict("commands_unavailable", "command catalog failed"))??;
    if cli == "codex" {
        let result = codex_mobile_skills(&cwd).await?;
        let (skills, skill_warning) = mobile_codex_skill_items(&result)?;
        items.retain(|item| item.kind != "skill");
        items.extend(skills);
        warning = skill_warning;
    } else {
        let output = tokio::time::timeout(
            Duration::from_secs(8),
            tokio::process::Command::new("claude")
                .env("PATH", spawn_path())
                .args(["plugin", "list", "--json"])
                .current_dir(&cwd)
                .kill_on_drop(true)
                .output(),
        )
        .await;
        match output {
            Ok(Ok(output)) if output.status.success() && output.stdout.len() <= 1024 * 1024 => {
                if let Ok(plugins) = serde_json::from_slice::<Value>(&output.stdout) {
                    let (plugins, plugin_warning) =
                        tokio::task::spawn_blocking(move || mobile_claude_plugin_items(&plugins))
                            .await
                            .map_err(|_| {
                                ApiError::conflict("commands_unavailable", "plugin catalog failed")
                            })?;
                    items.extend(plugins);
                    if plugin_warning.is_some() {
                        warning = plugin_warning;
                    }
                } else {
                    warning = Some(
                        "플러그인 목록을 읽지 못했습니다. 목록을 다시 열어 재시도하세요."
                            .to_string(),
                    );
                }
            }
            _ => {
                warning = Some(
                    "플러그인 목록을 조회하지 못했습니다. 목록을 다시 열어 재시도하세요."
                        .to_string(),
                )
            }
        }
    }
    items.sort_by(|a, b| a.invocation.cmp(&b.invocation));
    items.dedup_by(|a, b| a.invocation == b.invocation);
    Ok(Json(json!({"surface_id":surface_id,"items":items,"warning":warning})).into_response())
}

/// An app-launched daemon inherits a PATH without the user's bin dirs, so a
/// bare `claude`/`codex` reached only the bundled wrapper, which then could not
/// find the real CLI either: the catalog always warned that plugins failed.
fn spawn_path() -> String {
    cli_path::compose_agent_path("", &std::env::var("PATH").unwrap_or_default())
}

// ── model picker ────────────────────────────────────────────────────────

const MODEL_SCREEN_LINES: u32 = 80;

fn model_busy_error() -> ApiError {
    ApiError::conflict(
        "model_change_in_flight",
        "모델을 바꾸는 중입니다. 잠시 후 다시 시도하세요.",
    )
}

fn drive_error(error: DriveError) -> ApiError {
    ApiError::conflict(error.code(), error.message())
}

struct AppDriver<'a> {
    state: &'a MobileState,
    entry: &'a Entry,
    /// The app error behind the last `DriveError::Io`, kept so a dead app
    /// still answers 503 `app_unavailable` instead of a generic conflict.
    failure: Mutex<Option<ApiError>>,
}

impl<'a> AppDriver<'a> {
    fn new(state: &'a MobileState, entry: &'a Entry) -> Self {
        Self {
            state,
            entry,
            failure: Mutex::new(None),
        }
    }

    async fn call(&self, method: &str, params: Value) -> Result<Value, DriveError> {
        match app_call(self.state, self.entry, method, params).await {
            Ok(value) => Ok(value),
            Err(error) => {
                let message = error.message.clone();
                *self.failure.lock().unwrap() = Some(error);
                Err(DriveError::Io(message))
            }
        }
    }

    fn api_error(&self, error: DriveError) -> ApiError {
        match (&error, self.failure.lock().unwrap().take()) {
            (DriveError::Io(_), Some(failure)) => failure,
            _ => drive_error(error),
        }
    }
}

impl PaneDriver for AppDriver<'_> {
    async fn read_screen(&self) -> Result<String, DriveError> {
        let result = self
            .call(
                "surface.read_text",
                json!({ "surface_id": self.entry.surface_id, "lines": MODEL_SCREEN_LINES, "scrollback": true }),
            )
            .await?;
        Ok(result
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string())
    }

    async fn send_key(&self, key: &'static str) -> Result<(), DriveError> {
        self.call(
            "surface.send_key",
            json!({ "surface_id": self.entry.surface_id, "key": key }),
        )
        .await
        .map(drop)
    }

    async fn send_text(&self, text: &str) -> Result<(), DriveError> {
        self.call(
            "surface.send_text",
            json!({ "surface_id": self.entry.surface_id, "text": text }),
        )
        .await
        .map(drop)
    }

    async fn send_turn(&self, text: &str) -> Result<(), DriveError> {
        self.call(
            "surface.send_turn",
            json!({ "surface_id": self.entry.surface_id, "text": text }),
        )
        .await
        .map(drop)
    }

    async fn pause(&self, duration: Duration) {
        tokio::time::sleep(duration).await;
    }
}

/// A terminal pane running Claude or Codex, with its session filled in the
/// same way `transcript_handler` does. Native agent panes take turns, not
/// keys, so their popup cannot be driven.
async fn model_target(state: &MobileState, surface_id: &str) -> Result<Entry, ApiError> {
    cli_pane(state, surface_id, "model_unavailable").await
}

async fn cli_pane(
    state: &MobileState,
    surface_id: &str,
    unavailable: &'static str,
) -> Result<Entry, ApiError> {
    let mut entry = live_entry(state, surface_id).await?;
    if entry.kind != TargetKind::Pane {
        return Err(ApiError::conflict(
            unavailable,
            "터미널 pane에서만 지원합니다.",
        ));
    }
    if entry.keys == KeysPolicy::None {
        return Err(ApiError::forbidden(
            "keys_disabled",
            "terminal input is disabled with keys=none",
        ));
    }
    if entry.session_id.is_none() || entry.agent_cli.is_empty() {
        if let Some(session) = state.resolved_session(&entry) {
            entry.session_id = session.session_id.or(entry.session_id.take());
            entry.agent_cli = session.cli;
        }
    }
    if !matches!(entry.agent_cli.as_str(), "claude" | "codex") {
        return Err(ApiError::conflict(
            unavailable,
            "this pane has no Claude or Codex session",
        ));
    }
    Ok(entry)
}

async fn claude_pane(state: &MobileState, surface_id: &str) -> Result<Entry, ApiError> {
    let entry = cli_pane(state, surface_id, "effort_unavailable").await?;
    if entry.agent_cli != "claude" {
        return Err(ApiError::conflict(
            "effort_unavailable",
            "Codex sets reasoning effort in its model picker",
        ));
    }
    Ok(entry)
}

async fn effort_handler(
    State(state): State<SharedState>,
    Path(surface_id): Path<String>,
) -> ApiResult {
    let entry = claude_pane(&state, &surface_id).await?;
    let _lock = state.lock_model(&entry.surface_id)?;
    let driver = AppDriver::new(&state, &entry);
    let slider = mobile_model::read_effort(&driver)
        .await
        .map_err(|error| driver.api_error(error))?;
    Ok(Json(json!({
        "surface_id": entry.surface_id,
        "levels": slider.levels,
        "current": slider.current,
    }))
    .into_response())
}

#[derive(Deserialize)]
struct EffortBody {
    level: String,
    #[serde(default)]
    save_default: bool,
}

async fn effort_set_handler(
    State(state): State<SharedState>,
    Path(surface_id): Path<String>,
    axum::Extension(caller): axum::Extension<Caller>,
    Json(body): Json<EffortBody>,
) -> ApiResult {
    let entry = claude_pane(&state, &surface_id).await?;
    let _lock = state.lock_model(&entry.surface_id)?;
    tracing::info!(
        "mobile: effort {} by {} to {}",
        body.level,
        caller.0,
        entry.surface_id
    );
    let driver = AppDriver::new(&state, &entry);
    let change = mobile_model::set_effort(&driver, body.level.trim(), body.save_default)
        .await
        .map_err(|error| driver.api_error(error))?;
    Ok(Json(json!({
        "surface_id": entry.surface_id,
        "message": change.message,
        "session_only": change.session_only,
    }))
    .into_response())
}

fn prompt_tui(entry: &Entry) -> &'static mobile_model::PromptTui {
    if entry.agent_cli == "codex" {
        &mobile_model::CODEX_PROMPT
    } else {
        &mobile_model::CLAUDE_PROMPT
    }
}

/// The approval question a terminal CLI is waiting on, if any. Chat cannot
/// show it: it lives only on the terminal screen.
async fn prompt_handler(
    State(state): State<SharedState>,
    Path(surface_id): Path<String>,
) -> ApiResult {
    let entry = cli_pane(&state, &surface_id, "prompt_unavailable").await?;
    let driver = AppDriver::new(&state, &entry);
    let screen = driver
        .read_screen()
        .await
        .map_err(|error| driver.api_error(error))?;
    let tui = prompt_tui(&entry);
    let prompt = mobile_model::approval_prompt(tui, &screen);
    let preview = if prompt.is_some() {
        Vec::new()
    } else {
        mobile_model::screen_preview(tui, &screen)
    };
    Ok(Json(json!({ "surface_id": entry.surface_id, "prompt": prompt, "preview": preview }))
        .into_response())
}

#[derive(Deserialize)]
struct PromptAnswer {
    fingerprint: String,
    index: usize,
}

async fn prompt_answer_handler(
    State(state): State<SharedState>,
    Path(surface_id): Path<String>,
    axum::Extension(caller): axum::Extension<Caller>,
    Json(body): Json<PromptAnswer>,
) -> ApiResult {
    let entry = cli_pane(&state, &surface_id, "prompt_unavailable").await?;
    let _lock = state.lock_model(&entry.surface_id)?;
    tracing::info!(
        "mobile: prompt option {} by {} to {}",
        body.index,
        caller.0,
        entry.surface_id
    );
    let driver = AppDriver::new(&state, &entry);
    mobile_model::answer_prompt(&driver, prompt_tui(&entry), &body.fingerprint, body.index)
        .await
        .map_err(|error| driver.api_error(error))?;
    Ok(Json(json!({ "surface_id": entry.surface_id, "answered": body.index })).into_response())
}

fn model_tui(entry: &Entry) -> &'static mobile_model::Tui {
    if entry.agent_cli == "codex" {
        &mobile_model::CODEX
    } else {
        &mobile_model::CLAUDE
    }
}

async fn models_handler(
    State(state): State<SharedState>,
    Path(surface_id): Path<String>,
) -> ApiResult {
    let entry = model_target(&state, &surface_id).await?;
    let _lock = state.lock_model(&entry.surface_id)?;
    let driver = AppDriver::new(&state, &entry);
    let models = mobile_model::list_models(&driver, model_tui(&entry))
        .await
        .map_err(|error| driver.api_error(error))?;
    let current = models
        .iter()
        .find(|model| model.current)
        .map(|model| model.label.clone());
    Ok(Json(json!({
        "surface_id": entry.surface_id,
        "cli": entry.agent_cli,
        "current_model": current,
        "custom": entry.agent_cli == "claude",
        "models": models,
    }))
    .into_response())
}

#[derive(Deserialize)]
struct ModelBody {
    model: String,
    #[serde(default)]
    save_default: bool,
    /// Claude only: an id the popup does not list, sent as `/model <id>`.
    #[serde(default)]
    custom: bool,
}

async fn model_handler(
    State(state): State<SharedState>,
    Path(surface_id): Path<String>,
    axum::Extension(caller): axum::Extension<Caller>,
    Json(body): Json<ModelBody>,
) -> ApiResult {
    let model = body.model.trim().to_string();
    if model.is_empty() || model.chars().count() > 128 {
        return Err(ApiError::bad_request("invalid_model", "model is required"));
    }
    let entry = model_target(&state, &surface_id).await?;
    let _lock = state.lock_model(&entry.surface_id)?;
    tracing::info!(
        "mobile: model {model} by {} to {}",
        caller.0,
        entry.surface_id
    );
    let tui = model_tui(&entry);
    let driver = AppDriver::new(&state, &entry);
    if body.custom {
        // Typed into the composer as a turn: anything but a bare id would
        // reach the model as a prompt. Claude saves an inline pick as the
        // default for new sessions.
        if entry.agent_cli != "claude" {
            return Err(ApiError::bad_request(
                "invalid_model",
                "only Claude takes a model id that is not in its list",
            ));
        }
        if !mobile_model::valid_model_id(&model) {
            return Err(ApiError::bad_request(
                "invalid_model",
                "model must be a single id such as claude-opus-4-1",
            ));
        }
        let screen = driver
            .read_screen()
            .await
            .map_err(|error| driver.api_error(error))?;
        mobile_model::check_ready(tui, &screen).map_err(drive_error)?;
        driver
            .send_turn(&format!("/model {model}"))
            .await
            .map_err(|error| driver.api_error(error))?;
        return Ok(Json(json!({
            "surface_id": entry.surface_id,
            "cli": entry.agent_cli,
            "delivered": true,
            "message": Value::Null,
            "session_only": false,
        }))
        .into_response());
    }
    let change = mobile_model::select_model(&driver, tui, &model, body.save_default)
        .await
        .map_err(|error| driver.api_error(error))?;
    Ok(Json(json!({
        "surface_id": entry.surface_id,
        "cli": entry.agent_cli,
        "delivered": true,
        "message": change.message,
        "session_only": change.session_only,
    }))
    .into_response())
}

pub(crate) fn mobile_claude_plugin_items(plugins: &Value) -> (Vec<MobileCommand>, Option<String>) {
    let mut items = HashMap::new();
    let mut budget = COMMAND_SCAN_LIMIT;
    let mut incomplete = false;
    if let Some(plugins) = plugins.as_array() {
        for plugin in plugins {
            if plugin.get("enabled").and_then(Value::as_bool) != Some(true)
                || plugin.get("projectEnabled").and_then(Value::as_bool) == Some(false)
            {
                continue;
            }
            let Some(id) = plugin.get("id").and_then(Value::as_str) else {
                incomplete = true;
                continue;
            };
            let Some(path) = plugin.get("installPath").and_then(Value::as_str) else {
                incomplete = true;
                continue;
            };
            let namespace = id.split('@').next().unwrap_or(id);
            let root = FsPath::new(path);
            let skills = if root.join("SKILL.md").is_file() {
                root.to_path_buf()
            } else {
                root.join("skills")
            };
            if scan_mobile_commands(
                &skills,
                "claude",
                "skill",
                "plugin",
                namespace,
                &mut budget,
                &mut items,
            )
            .is_err()
            {
                incomplete = true;
            }
            if scan_mobile_commands(
                &root.join("commands"),
                "claude",
                "command",
                "plugin",
                namespace,
                &mut budget,
                &mut items,
            )
            .is_err()
            {
                incomplete = true;
            }
        }
    } else {
        incomplete = true;
    }
    (
        items.into_values().collect(),
        incomplete.then(|| "일부 플러그인의 명령·스킬을 읽지 못했습니다.".to_string()),
    )
}

pub(crate) fn mobile_codex_skill_items(
    result: &Value,
) -> Result<(Vec<MobileCommand>, Option<String>), ApiError> {
    let data = result
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            ApiError::conflict("commands_unavailable", "Codex returned no skill catalog")
        })?;
    let mut items = Vec::new();
    let mut incomplete = false;
    for group in data {
        if group
            .get("errors")
            .and_then(Value::as_array)
            .is_some_and(|errors| !errors.is_empty())
        {
            incomplete = true;
        }
        let Some(skills) = group.get("skills").and_then(Value::as_array) else {
            incomplete = true;
            continue;
        };
        for skill in skills.iter().take(COMMAND_SCAN_LIMIT) {
            if skill.get("enabled").and_then(Value::as_bool) != Some(true) {
                continue;
            }
            let Some(name) = skill.get("name").and_then(Value::as_str) else {
                incomplete = true;
                continue;
            };
            if !command_name_valid(name) {
                incomplete = true;
                continue;
            }
            let scope = skill.get("scope").and_then(Value::as_str).unwrap_or("");
            let source = if skill.get("pluginId").is_some_and(|id| !id.is_null()) {
                "plugin"
            } else if scope == "repo" {
                "project"
            } else if scope == "system" {
                "builtin"
            } else {
                "user"
            };
            items.push(MobileCommand {
                name: name.to_string(),
                invocation: format!("${name}"),
                kind: "skill",
                source,
                description: skill
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .chars()
                    .take(600)
                    .collect(),
                argument_hint: String::new(),
                selectable: true,
                action: None,
                reason: String::new(),
            });
        }
        if skills.len() > COMMAND_SCAN_LIMIT {
            incomplete = true;
        }
    }
    Ok((
        items,
        incomplete
            .then(|| "일부 스킬을 읽지 못했습니다. 목록을 다시 열어 재시도하세요.".to_string()),
    ))
}

async fn codex_mobile_skills(cwd: &FsPath) -> Result<Value, ApiError> {
    use std::process::Stdio;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let mut child = tokio::process::Command::new("codex")
        .env("PATH", spawn_path())
        .arg("app-server")
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| {
            ApiError::conflict(
                "commands_unavailable",
                "Codex의 스킬 목록을 조회할 수 없습니다.",
            )
        })?;
    let result = tokio::time::timeout(Duration::from_secs(8), async {
        let mut input = child.stdin.take().ok_or_else(|| ApiError::conflict("commands_unavailable", "Codex input unavailable"))?;
        let output = child.stdout.take().ok_or_else(|| ApiError::conflict("commands_unavailable", "Codex output unavailable"))?;
        let mut output = BufReader::new(output);
        for request in [
            json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"term-mesh-mobile-catalog","version":"1.0"}}}),
            json!({"method":"initialized"}),
            json!({"id":2,"method":"skills/list","params":{"cwds":[cwd]}}),
        ] {
            let mut line = request.to_string(); line.push('\n');
            input.write_all(line.as_bytes()).await
                .map_err(|_| ApiError::conflict("commands_unavailable", "Codex catalog request failed"))?;
        }
        for _ in 0..128 {
            let mut line = String::new();
            if output.read_line(&mut line).await.map_err(|_| ApiError::conflict("commands_unavailable", "Codex catalog read failed"))? == 0 || line.len() > 2 * 1024 * 1024 { break; }
            let reply: Value = serde_json::from_str(&line)
                .map_err(|_| ApiError::conflict("commands_unavailable", "Codex catalog response is invalid"))?;
            if reply.get("error").is_some() { return Err(ApiError::conflict("commands_unavailable", "Codex의 스킬 목록을 조회하지 못했습니다.")); }
            if reply.get("id").and_then(Value::as_u64) == Some(2) {
                return reply.get("result").cloned().ok_or_else(|| ApiError::conflict("commands_unavailable", "Codex catalog response is empty"));
            }
        }
        Err(ApiError::conflict("commands_unavailable", "Codex catalog response is incomplete"))
    }).await;
    let _ = child.kill().await;
    let _ = child.wait().await;
    result.map_err(|_| {
        ApiError::conflict(
            "commands_unavailable",
            "스킬 목록 조회 시간이 초과되었습니다. 다시 시도하세요.",
        )
    })?
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

fn without_terminal_controls(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut chars = value.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' {
            match chars.next() {
                Some('[') => {
                    for next in chars.by_ref() {
                        if ('\u{40}'..='\u{7e}').contains(&next) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    let mut escape = false;
                    for next in chars.by_ref() {
                        if next == '\u{7}' || (escape && next == '\\') {
                            break;
                        }
                        escape = next == '\u{1b}';
                    }
                }
                Some(_) | None => {}
            }
        } else if !ch.is_control() {
            result.push(ch);
        }
    }
    result
}

fn without_control_bytes(value: &str) -> String {
    value.chars().filter(|ch| !ch.is_control()).collect()
}

fn has_private_key_delimiter(value: &str, boundary: &str) -> bool {
    let prefix = format!("-----{boundary} ");
    value.match_indices(&prefix).any(|(start, _)| {
        let label_start = start + prefix.len();
        value[label_start..]
            .find("-----")
            .is_some_and(|end| value[label_start..label_start + end].contains("PRIVATE KEY"))
    })
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
        "EYJ",
    ];
    fn has_secret_key_prefix(value: &str) -> bool {
        value.match_indices("SK-").any(|(index, _)| {
            index == 0
                || value[..index]
                    .chars()
                    .next_back()
                    .is_some_and(|ch| !ch.is_ascii_alphanumeric())
        })
    }

    let mut redacted = Vec::new();
    let mut private_key_block = false;
    for line in value.lines() {
        let upper = without_terminal_controls(line).to_ascii_uppercase();
        let raw_upper = without_control_bytes(line).to_ascii_uppercase();
        let begins_private_key = has_private_key_delimiter(&upper, "BEGIN")
            || has_private_key_delimiter(&raw_upper, "BEGIN");
        let ends_private_key = has_private_key_delimiter(&upper, "END")
            || has_private_key_delimiter(&raw_upper, "END");
        if begins_private_key {
            redacted.push("[credential redacted]".to_string());
            private_key_block = !ends_private_key;
            continue;
        }
        if private_key_block {
            if ends_private_key {
                private_key_block = false;
            }
            redacted.push("[credential redacted]".to_string());
            continue;
        }
        if MARKERS
            .iter()
            .any(|marker| upper.contains(marker) || raw_upper.contains(marker))
            || has_secret_key_prefix(&upper)
            || has_secret_key_prefix(&raw_upper)
        {
            redacted.push("[credential redacted]".to_string());
        } else {
            redacted.push(line.to_string());
        }
    }
    redacted.join("\n")
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

fn is_local_command_text(text: &str) -> bool {
    let text = text.trim_start();
    text.starts_with("<command-name>")
        || text.starts_with("<local-command-stdout>")
        || text.starts_with("<local-command-stderr>")
        || text.starts_with("<local-command-caveat>")
}

fn tag_body<'a>(text: &'a str, tag: &str) -> Option<&'a str> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = text.find(&open)? + open.len();
    let end = text[start..].find(&close)? + start;
    Some(text[start..end].trim())
}

/// A slash command the CLI ran itself (`/model`, `/effort`, …) is logged as
/// tagged text, not a turn: show the command and its output as a notice so a
/// raw tag never reaches the page and the session does not read as waiting
/// for a reply.
fn local_command_notice(text: &str) -> Option<String> {
    if text.trim_start().starts_with("<local-command-caveat>") {
        return None;
    }
    let shown = if let Some(name) = tag_body(text, "command-name") {
        let args = tag_body(text, "command-args").unwrap_or("");
        if args.is_empty() {
            name.to_string()
        } else {
            format!("{name} {args}")
        }
    } else {
        tag_body(text, "local-command-stdout")
            .or_else(|| tag_body(text, "local-command-stderr"))?
            .to_string()
    };
    (!shown.is_empty()).then(|| bounded_text(&shown))
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

/// Remove private-key blocks inside the bounded retained window. An unmatched
/// END means the window started inside a block; an unmatched BEGIN means it
/// ended inside one. Both edges fail closed without scanning the whole file.
fn without_private_key_rows(lines: &[Value]) -> Vec<&Value> {
    fn delimiter_in_value(value: &Value, boundary: &str) -> bool {
        match value {
            Value::String(text) => {
                let raw_upper = without_control_bytes(text).to_ascii_uppercase();
                has_private_key_delimiter(&raw_upper, boundary)
                    || has_private_key_delimiter(
                        &without_terminal_controls(text).to_ascii_uppercase(),
                        boundary,
                    )
            }
            Value::Array(items) => items.iter().any(|item| delimiter_in_value(item, boundary)),
            Value::Object(fields) => fields
                .values()
                .any(|item| delimiter_in_value(item, boundary)),
            _ => false,
        }
    }
    let mut redacted = vec![false; lines.len()];
    let mut block_start: Option<usize> = None;
    for (index, value) in lines.iter().enumerate() {
        let begins = delimiter_in_value(value, "BEGIN");
        let ends = delimiter_in_value(value, "END");
        if begins && block_start.is_none() {
            block_start = Some(index);
        }
        if ends {
            let start = block_start.take().unwrap_or(0);
            redacted[start..=index].fill(true);
        }
    }
    if let Some(start) = block_start {
        redacted[start..].fill(true);
    }
    lines
        .iter()
        .zip(redacted)
        .filter_map(|(row, hidden)| (!hidden).then_some(row))
        .collect()
}

pub(crate) fn claude_entries(lines: &[Value]) -> Vec<Value> {
    let mut entries = Vec::new();
    let mut tools: HashMap<String, usize> = HashMap::new();
    for row in without_private_key_rows(lines) {
        let kind = row.get("type").and_then(Value::as_str).unwrap_or("");
        let id = row.get("uuid").and_then(Value::as_str).unwrap_or("");
        let message = row.get("message").unwrap_or(&Value::Null);
        let content = message.get("content").unwrap_or(&Value::Null);
        if kind == "system" && row.get("subtype").and_then(Value::as_str) == Some("local_command") {
            let text = row.get("content").and_then(Value::as_str).unwrap_or("");
            if let Some(text) = local_command_notice(text) {
                entries.push(json!({ "id": id, "kind": "notice", "text": text }));
            }
            continue;
        }
        if kind == "user" {
            let text = content_text(content, &["text"]);
            if is_local_command_text(&text) {
                if let Some(text) = local_command_notice(&text) {
                    entries.push(json!({ "id": id, "kind": "notice", "text": text }));
                }
                continue;
            }
            if let Some(text) = user_visible_text(text) {
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
    for row in without_private_key_rows(lines) {
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

fn entries_in_flight(entries: &[Value]) -> bool {
    entries.last().is_some_and(|entry| {
        entry.get("kind").and_then(Value::as_str) == Some("said")
            || (entry.get("kind").and_then(Value::as_str) == Some("tool")
                && entry.get("running").and_then(Value::as_bool) == Some(true))
    })
}

/// Whether Claude's log has a turn open: a prompt after the last turn end.
///
/// Claude writes `system/turn_duration` when a turn ends and nothing when one
/// is cancelled before it answers, so an open turn is only trusted while the
/// log is still being written (see `CLAUDE_OPEN_TURN_STALE`).
pub(crate) fn claude_turn_in_flight(lines: &[Value]) -> Option<bool> {
    lines.iter().rev().find_map(|row| {
        match row.get("type").and_then(Value::as_str) {
            Some("system") => (row.get("subtype").and_then(Value::as_str)
                == Some("turn_duration"))
            .then_some(false),
            Some("user") => {
                if row.get("isMeta").and_then(Value::as_bool) == Some(true) {
                    return None;
                }
                let content = row.pointer("/message/content").unwrap_or(&Value::Null);
                if content
                    .as_array()
                    .is_some_and(|blocks| blocks.iter().any(|b| b.get("type").and_then(Value::as_str) == Some("tool_result")))
                {
                    return None;
                }
                let text = content_text(content, &["text"]);
                let text = text.trim_start();
                if text.starts_with(CLAUDE_INTERRUPTED) {
                    Some(false)
                } else if text.is_empty() || is_local_command_text(text) {
                    None
                } else {
                    Some(true)
                }
            }
            _ => None,
        }
    })
}

const CLAUDE_INTERRUPTED: &str = "[Request interrupted";
/// A turn writes tool calls, results and messages as it goes; an open turn
/// with a log silent this long was most likely cancelled. The screen (its
/// spinner, or an approval question) still marks a quiet turn as running.
const CLAUDE_OPEN_TURN_STALE: Duration = Duration::from_secs(30);

fn log_is_fresh(path: &FsPath, within: Duration) -> bool {
    fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age <= within)
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
        claude_turn_in_flight(&lines).map(|open| open && log_is_fresh(&path, CLAUDE_OPEN_TURN_STALE))
    }
    .unwrap_or_else(|| entries_in_flight(&entries));
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
    let targets: Vec<Value> = reg.list().iter().map(|e| target_json(&state, e)).collect();
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
            let chars = text.chars().count();
            // Without a width, count one cell per character.
            let width = span
                .get("cell_width")
                .and_then(Value::as_u64)
                .map_or(chars, |w| w as usize)
                .max(1);
            let style_id = span.get("style_id").and_then(Value::as_u64).unwrap_or(0) as usize;
            let style = styles.get(style_id).unwrap_or(&default_style);
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
            // `cell_width` is the span's total width, so the next free column
            // is its start plus that width — not width per character.
            col = column + width;
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
            Err(err) if err.rpc_code.as_deref() == Some("method_not_found") => {
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
    /// Terminal mode only types unless the page asks to submit; then the text
    /// and its Return travel as one `surface.send_turn`, so a separate Enter
    /// cannot race the paste it belongs to.
    #[serde(default)]
    submit: bool,
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
    state.refuse_while_model_busy(&entry.surface_id)?;
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
            if entry.keys == KeysPolicy::None {
                return Err(ApiError::forbidden(
                    "keys_disabled",
                    "terminal input is disabled with keys=none",
                ));
            }
            // Same capability answer the page was given by `target_json` and
            // that `transcript_handler` reads by: a pane exposed with `/rc on`
            // carries `chat_capable: false` on the record, and only the
            // resolved session says the CLI is there. Reading the raw field
            // here let the page show a Chat tab and a live transcript it could
            // not send a turn into.
            if chat_mode && !state.chat_capable(&entry) {
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
            let delivery = if chat_mode || body.submit {
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
    let mut entry = live_entry(&state, &surface_id).await?;
    if !state.chat_capable(&entry) {
        return Err(ApiError::conflict(
            "not_an_agent",
            "this target has no structured conversation; use /screen",
        ));
    }
    // Read the session back onto the entry so the blocking reader below needs
    // to know nothing about where it came from. A record that already carried
    // one is left exactly as it was.
    if entry.session_id.is_none() || entry.agent_cli.is_empty() {
        if let Some(session) = state.resolved_session(&entry) {
            entry.session_id = session.session_id.or(entry.session_id.take());
            entry.agent_cli = session.cli;
        }
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
        let mut value =
            tokio::task::spawn_blocking(move || session_transcript(&session_entry, limit as usize))
                .await
                .map_err(|e| {
                    ApiError::conflict("session_unavailable", format!("session reader failed: {e}"))
                })??;
        // The log reads idle between a finished tool and the next step; the
        // CLI's own working line on screen is the ground truth. A failed read
        // leaves the log's answer standing.
        if running && value.get("in_flight").and_then(Value::as_bool) == Some(false) {
            let driver = AppDriver::new(&state, &entry);
            if let Ok(screen) = driver.read_screen().await {
                // An approval question halts both the log and the spinner
                // while it waits for a person; it is still the same turn.
                if mobile_model::screen_busy(model_tui(&entry), &screen)
                    || mobile_model::approval_prompt(prompt_tui(&entry), &screen).is_some()
                {
                    value["in_flight"] = Value::Bool(true);
                }
            }
        }
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
    // Same capability answer `/api/targets` and `/text` already use: a
    // terminal-backed pane running a hand-started CLI carries
    // `chat_capable: false` on the raw record, and only the resolved session
    // knows better. Reading the raw field here left the page's Interrupt
    // button, which `/api/targets` had just told it to show, come back
    // `not_an_agent` on every terminal-backed chat.
    if !state.chat_capable(&entry) {
        return Err(ApiError::conflict(
            "not_an_agent",
            "interrupt exists only for native agent targets; send the C-c key instead",
        ));
    }
    if entry.kind == TargetKind::Pane && entry.keys == KeysPolicy::None {
        return Err(ApiError::forbidden(
            "keys_disabled",
            "terminal-backed chat interrupt is disabled with keys=none",
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
    state.refuse_while_model_busy(&entry.surface_id)?;
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
