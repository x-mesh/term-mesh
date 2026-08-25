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
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap};
use std::net::SocketAddr;
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
    "Enter", "Escape", "Tab", "Up", "Down", "Left", "Right", "y", "n", "1", "2", "3", "4", "5",
    "6", "7", "8", "9", "C-c",
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
    /// `request_id` → first-seen instant for pane text sends.
    dedupe: Mutex<HashMap<String, Instant>>,
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
        "team_name": entry.team_name,
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
    let result = match entry.kind {
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
            if let Some(id) = &request_id {
                if state.remember_request(&entry.surface_id, id) {
                    return Ok(Json(json!({
                        "surface_id": entry.surface_id,
                        "kind": "pane",
                        "delivered": true,
                        "deduplicated": true,
                        "request_id": id,
                    }))
                    .into_response());
                }
            }
            app_call(
                &state,
                &entry,
                "surface.send_text",
                json!({ "surface_id": entry.surface_id, "text": body.text }),
            )
            .await?;
            Ok(Json(json!({
                "surface_id": entry.surface_id,
                "kind": "pane",
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
    fn remember_request(&self, surface_id: &str, request_id: &str) -> bool {
        let key = format!("{surface_id}\u{0}{request_id}");
        let now = Instant::now();
        let mut seen = self.dedupe.lock().unwrap();
        seen.retain(|_, first| now.duration_since(*first) < DEDUPE_WINDOW);
        if seen.contains_key(&key) {
            return true;
        }
        seen.insert(key, now);
        false
    }
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
