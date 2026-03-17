use axum::{
    extract::{Path, Query, State},
    http::{header, StatusCode},
    middleware,
    response::{Html, IntoResponse, Json},
    routing::{get, post},
    Router,
};
use serde::Deserialize;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::watch;
use tokio::time::{timeout, Duration};
use tower_http::cors::CorsLayer;

/// Dashboard HTML embedded at compile time so it's always available in the binary,
/// even when the filesystem path cannot be resolved (e.g. deployed app bundle).
const EMBEDDED_DASHBOARD_HTML: &str = include_str!("../../../Resources/dashboard/index.html");

/// App icon embedded at compile time so `/api/brand-icon` always works
/// regardless of where the binary is installed.
const EMBEDDED_BRAND_ICON: &[u8] = include_bytes!("../../../Assets.xcassets/AppIcon.appiconset/128.png");

use crate::agent::AgentSessionManager;
use crate::monitor::{MonitorHandle, SystemSnapshot};
use crate::socket::{SessionStore, TeamStateStore};
use crate::tokens::UsageTracker;
use crate::watcher::WatcherHandle;

pub struct HttpState {
    pub monitor_rx: watch::Receiver<Option<SystemSnapshot>>,
    pub monitor_handle: MonitorHandle,
    pub watcher_handle: WatcherHandle,
    pub sessions: SessionStore,
    pub team_state: TeamStateStore,
    pub usage_tracker: UsageTracker,
    pub agent_manager: Arc<AgentSessionManager>,
    pub dashboard_dir: Option<PathBuf>,
    pub auth_password: Option<String>,
}

pub async fn serve(
    addr: SocketAddr,
    monitor_rx: watch::Receiver<Option<SystemSnapshot>>,
    monitor_handle: MonitorHandle,
    watcher_handle: WatcherHandle,
    sessions: SessionStore,
    team_state: TeamStateStore,
    usage_tracker: UsageTracker,
    agent_manager: Arc<AgentSessionManager>,
    auth_password: Option<String>,
    mut shutdown_rx: watch::Receiver<bool>,
) -> anyhow::Result<()> {
    let dashboard_dir = find_dashboard_dir();

    if auth_password.is_some() {
        tracing::info!("HTTP dashboard authentication enabled");
    }

    let state = Arc::new(HttpState {
        monitor_rx,
        monitor_handle,
        watcher_handle,
        sessions,
        team_state,
        usage_tracker,
        agent_manager,
        dashboard_dir,
        auth_password,
    });

    // Public routes (no auth required)
    let public_routes = Router::new()
        .route("/", get(index_handler))
        .route("/api/health", get(health_handler))
        .route("/api/version", get(version_handler))
        .route("/api/brand-icon", get(brand_icon_handler));

    // Protected routes (auth required when password is set)
    let protected_routes = Router::new()
        .route("/api/sessions", get(sessions_handler))
        .route("/api/team", get(team_handler))
        .route("/api/team/create", post(team_create_handler))
        .route("/api/team/teams", get(team_teams_handler))
        .route("/api/team/tasks", get(team_tasks_handler).post(team_tasks_create_handler))
        .route("/api/team/tasks/{id}/action", post(team_tasks_action_handler))
        .route("/api/team/inbox", get(team_inbox_handler))
        .route("/api/team/instance", get(team_instance_handler))
        .route("/api/monitor", get(monitor_handler))
        .route("/api/watcher", get(watcher_handler))
        .route("/api/watcher/watch", post(watch_handler))
        .route("/api/watcher/unwatch", post(unwatch_handler))
        .route("/api/process/stop", post(process_stop_handler))
        .route("/api/process/resume", post(process_resume_handler))
        .route("/api/usage", get(usage_handler))
        .route("/api/budget/auto-stop", post(budget_auto_stop_handler))
        .route("/api/agents", get(agents_list_handler))
        .route("/api/agents/spawn", post(agents_spawn_handler))
        .route("/api/agents/{id}", get(agents_get_handler))
        .route("/api/agents/{id}/terminate", post(agents_terminate_handler))
        .route("/api/agents/{id}/input", post(agents_input_handler))
        // Task & Message endpoints (F-06 Phase 2)
        .route("/api/tasks", get(tasks_list_handler).post(tasks_create_handler))
        .route("/api/tasks/{id}", get(tasks_get_handler).patch(tasks_update_handler))
        .route("/api/tasks/{id}/assign", post(tasks_assign_handler))
        .route("/api/tasks/{id}/log", get(tasks_log_handler))
        .route("/api/messages", post(messages_send_handler))
        .route("/api/messages/ack", post(messages_ack_handler))
        .route("/api/messages/{agent_id}", get(messages_list_handler))
        .layer(middleware::from_fn_with_state(state.clone(), auth_middleware));

    let app = public_routes
        .merge(protected_routes)
        .layer(
            CorsLayer::new()
                .allow_origin(tower_http::cors::AllowOrigin::predicate(|origin, _| {
                    let host = origin.to_str().unwrap_or("");
                    host.starts_with("http://127.0.0.1")
                        || host.starts_with("http://localhost")
                        || host.starts_with("http://[::1]")
                }))
                .allow_methods([
                    axum::http::Method::GET,
                    axum::http::Method::POST,
                    axum::http::Method::PATCH,
                    axum::http::Method::DELETE,
                ])
                .allow_headers([header::CONTENT_TYPE, header::AUTHORIZATION]),
        )
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("HTTP dashboard listening on http://{}", addr);

    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            let _ = shutdown_rx.changed().await;
            tracing::info!("HTTP server shutting down");
        })
        .await?;
    Ok(())
}

/// Authentication middleware: checks Bearer token or ?token= query parameter.
/// Passes through if no password is configured.
async fn auth_middleware(
    State(state): State<Arc<HttpState>>,
    req: axum::extract::Request,
    next: middleware::Next,
) -> impl IntoResponse {
    let password = match &state.auth_password {
        Some(p) if !p.is_empty() => p,
        _ => return next.run(req).await.into_response(),
    };

    // Check Authorization: Bearer <token>
    if let Some(auth_header) = req.headers().get(header::AUTHORIZATION) {
        if let Ok(value) = auth_header.to_str() {
            if let Some(token) = value.strip_prefix("Bearer ") {
                if constant_time_eq(token.as_bytes(), password.as_bytes()) {
                    return next.run(req).await.into_response();
                }
            }
        }
    }

    // Check ?token=<password> query parameter
    if let Some(query) = req.uri().query() {
        for pair in query.split('&') {
            if let Some(token) = pair.strip_prefix("token=") {
                let decoded = urlencoding_decode(token);
                if constant_time_eq(decoded.as_bytes(), password.as_bytes()) {
                    return next.run(req).await.into_response();
                }
            }
        }
    }

    (StatusCode::UNAUTHORIZED, Json(serde_json::json!({
        "error": "Authentication required. Use Authorization: Bearer <password> header or ?token=<password> query parameter."
    }))).into_response()
}

/// Constant-time byte comparison to prevent timing attacks.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut result: u8 = 0;
    for (x, y) in a.iter().zip(b.iter()) {
        result |= x ^ y;
    }
    result == 0
}

/// Simple percent-decoding for query parameter values.
fn urlencoding_decode(input: &str) -> String {
    let mut result = Vec::with_capacity(input.len());
    let bytes = input.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                result.push(hi << 4 | lo);
                i += 3;
                continue;
            }
        }
        if bytes[i] == b'+' {
            result.push(b' ');
        } else {
            result.push(bytes[i]);
        }
        i += 1;
    }
    String::from_utf8(result).unwrap_or_else(|_| input.to_string())
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

async fn index_handler(State(state): State<Arc<HttpState>>) -> impl IntoResponse {
    // Try filesystem first (allows live-editing during development)
    if let Some(dir) = &state.dashboard_dir {
        let index_path = dir.join("index.html");
        if let Ok(html) = tokio::fs::read_to_string(&index_path).await {
            let injected = html.replace("</body>", &format!("{}\n</body>", HTTP_POLL_SCRIPT));
            return Html(injected);
        }
    }
    // Fall back to compile-time embedded dashboard (always available in binary)
    let injected = EMBEDDED_DASHBOARD_HTML.replace("</body>", &format!("{}\n</body>", HTTP_POLL_SCRIPT));
    Html(injected)
}

static START_TIME: std::sync::LazyLock<std::time::Instant> =
    std::sync::LazyLock::new(std::time::Instant::now);

async fn health_handler() -> impl IntoResponse {
    Json(serde_json::json!({
        "status": "ok",
        "uptime_seconds": START_TIME.elapsed().as_secs(),
    }))
}

async fn version_handler() -> impl IntoResponse {
    Json(serde_json::json!({
        "version": env!("CARGO_PKG_VERSION"),
        "name": env!("CARGO_PKG_NAME"),
        "build_timestamp": option_env!("BUILD_TIMESTAMP").unwrap_or("dev"),
        "git_hash": option_env!("GIT_HASH").unwrap_or("unknown"),
    }))
}

async fn brand_icon_handler() -> impl IntoResponse {
    ([(header::CONTENT_TYPE, "image/png")], EMBEDDED_BRAND_ICON).into_response()
}

/// GET /api/sessions — list terminal sessions from the Swift app
async fn sessions_handler(State(state): State<Arc<HttpState>>) -> impl IntoResponse {
    let sessions = state.sessions.lock().unwrap().clone();
    Json(serde_json::to_value(sessions).unwrap())
}

async fn team_handler(State(state): State<Arc<HttpState>>) -> impl IntoResponse {
    let team_state = refreshed_team_state(&state).await;
    Json(team_state)
}

async fn team_teams_handler(State(state): State<Arc<HttpState>>) -> impl IntoResponse {
    let team_state = refreshed_team_state(&state).await;
    Json(team_state.get("teams").cloned().unwrap_or_else(|| serde_json::json!([])))
}

async fn team_tasks_handler(State(state): State<Arc<HttpState>>) -> impl IntoResponse {
    let team_state = refreshed_team_state(&state).await;
    Json(team_state.get("tasks").cloned().unwrap_or_else(|| serde_json::json!([])))
}

async fn team_inbox_handler(State(state): State<Arc<HttpState>>) -> impl IntoResponse {
    let team_state = refreshed_team_state(&state).await;
    Json(team_state.get("attention").cloned().unwrap_or_else(|| serde_json::json!([])))
}

async fn team_instance_handler(State(state): State<Arc<HttpState>>) -> impl IntoResponse {
    let team_state = refreshed_team_state(&state).await;
    Json(team_state.get("instance").cloned().unwrap_or_else(|| serde_json::json!({})))
}

async fn refreshed_team_state(state: &Arc<HttpState>) -> serde_json::Value {
    if let Some(live) = fetch_live_team_state(state).await {
        *state.team_state.lock().unwrap() = live.clone();
        return live;
    }
    state.team_state.lock().unwrap().clone()
}

async fn fetch_live_team_state(state: &Arc<HttpState>) -> Option<serde_json::Value> {
    let cached = state.team_state.lock().unwrap().clone();
    let socket_path = team_socket_path(state).ok()?;
    let teams = rpc_team_socket(&socket_path, "team.list", serde_json::json!({}))
        .await
        .ok()?
        .as_array()
        .cloned()?;

    let mut tasks = Vec::new();
    let mut attention = Vec::new();
    for team in &teams {
        let team_name = team.get("team_name").and_then(|v| v.as_str())?;
        if let Ok(task_result) = rpc_team_socket(
            &socket_path,
            "team.task.list",
            serde_json::json!({ "team_name": team_name }),
        )
        .await
        {
            if let Some(team_tasks) = task_result.get("tasks").and_then(|v| v.as_array()) {
                for task in team_tasks {
                    let mut task = task.clone();
                    if let Some(obj) = task.as_object_mut() {
                        obj.insert("team_name".to_string(), serde_json::json!(team_name));
                    }
                    tasks.push(task);
                }
            }
        }

        if let Ok(inbox_result) = rpc_team_socket(
            &socket_path,
            "team.inbox",
            serde_json::json!({ "team_name": team_name }),
        )
        .await
        {
            if let Some(team_items) = inbox_result.get("items").and_then(|v| v.as_array()) {
                attention.extend(team_items.iter().cloned());
            }
        }
    }

    let mut instance = cached
        .get("instance")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({}));
    if let Some(obj) = instance.as_object_mut() {
        obj.insert("socket_path".to_string(), serde_json::json!(socket_path));
        obj.insert("team_count".to_string(), serde_json::json!(teams.len()));
    }

    Some(serde_json::json!({
        "teams": teams,
        "tasks": tasks,
        "attention": attention,
        "instance": instance,
    }))
}

fn team_socket_path(state: &HttpState) -> Result<String, String> {
    let team_state = state.team_state.lock().unwrap().clone();
    team_state
        .get("instance")
        .and_then(|v| v.get("socket_path"))
        .and_then(|v| v.as_str())
        .filter(|v| !v.is_empty())
        .map(|v| v.to_string())
        .ok_or_else(|| "team instance socket is unavailable".to_string())
}

async fn rpc_team_socket(
    socket_path: &str,
    method: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value, String> {
    let mut stream = UnixStream::connect(socket_path)
        .await
        .map_err(|e| format!("socket connect failed: {e}"))?;
    let request = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });
    let payload = format!("{}\n", request);
    stream
        .write_all(payload.as_bytes())
        .await
        .map_err(|e| format!("socket write failed: {e}"))?;

    let mut reader = BufReader::new(stream);
    let mut attempts = 0;
    let response_line = loop {
        let mut line = String::new();
        let bytes = timeout(Duration::from_secs(5), reader.read_line(&mut line))
            .await
            .map_err(|_| "socket read timed out".to_string())?
            .map_err(|e| format!("socket read failed: {e}"))?;
        if bytes == 0 {
            return Err("socket closed without a response".to_string());
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            attempts += 1;
            if attempts >= 8 {
                return Err("socket returned only empty lines".to_string());
            }
            continue;
        }
        if !trimmed.starts_with('{') {
            return Err(trimmed.to_string());
        }
        break trimmed.to_string();
    };
    let response: serde_json::Value =
        serde_json::from_str(&response_line).map_err(|e| format!("invalid rpc response: {e}; raw={response_line}"))?;
    if let Some(err) = response.get("error") {
        return Err(err
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or("rpc error")
            .to_string());
    }
    Ok(response
        .get("result")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({})))
}

#[derive(Deserialize)]
struct TeamCreateAgentRequest {
    name: String,
    #[serde(default = "default_team_cli")]
    cli: String,
    #[serde(default = "default_team_model")]
    model: String,
    #[serde(default = "default_team_agent_type")]
    agent_type: String,
    #[serde(default = "default_team_color")]
    color: String,
    #[serde(default)]
    instructions: String,
}

fn default_team_cli() -> String { "claude".to_string() }
fn default_team_model() -> String { "sonnet".to_string() }
fn default_team_agent_type() -> String { "general".to_string() }
fn default_team_color() -> String { "green".to_string() }

#[derive(Deserialize)]
struct TeamCreateRequest {
    team_name: String,
    working_directory: String,
    #[serde(default = "default_leader_mode")]
    leader_mode: String,
    agents: Vec<TeamCreateAgentRequest>,
}

fn default_leader_mode() -> String { "repl".to_string() }

async fn team_create_handler(
    State(state): State<Arc<HttpState>>,
    Json(req): Json<TeamCreateRequest>,
) -> impl IntoResponse {
    let socket_path = match team_socket_path(&state) {
        Ok(path) => path,
        Err(err) => return (StatusCode::SERVICE_UNAVAILABLE, err).into_response(),
    };
    let params = serde_json::json!({
        "team_name": req.team_name,
        "working_directory": req.working_directory,
        "leader_mode": req.leader_mode,
        "leader_session_id": format!("http-dashboard-{}", uuid::Uuid::new_v4()),
        "agents": req.agents.into_iter().map(|agent| serde_json::json!({
            "name": agent.name,
            "cli": agent.cli,
            "model": agent.model,
            "agent_type": agent.agent_type,
            "color": agent.color,
            "instructions": agent.instructions,
        })).collect::<Vec<_>>(),
    });
    match rpc_team_socket(&socket_path, "team.create", params).await {
        Ok(result) => (StatusCode::CREATED, Json(result)).into_response(),
        Err(err) => (StatusCode::BAD_GATEWAY, err).into_response(),
    }
}

#[derive(Deserialize)]
struct TeamTaskCreateRequest {
    team_name: String,
    title: String,
    #[serde(default)]
    assignee: Option<String>,
}

async fn team_tasks_create_handler(
    State(state): State<Arc<HttpState>>,
    Json(req): Json<TeamTaskCreateRequest>,
) -> impl IntoResponse {
    let socket_path = match team_socket_path(&state) {
        Ok(path) => path,
        Err(err) => return (StatusCode::SERVICE_UNAVAILABLE, err).into_response(),
    };
    let params = serde_json::json!({
        "team_name": req.team_name,
        "title": req.title,
        "assignee": req.assignee,
        "priority": 2,
        "created_by": "http-dashboard",
    });
    match rpc_team_socket(&socket_path, "team.task.create", params).await {
        Ok(result) => {
            if let Some(task_id) = result.get("id").and_then(|v| v.as_str()) {
                let leader_text = format!(
                    "New task created: {}\nTask id: {task_id}\nAssignee: {}\nStatus: {}\n",
                    result.get("title").and_then(|v| v.as_str()).unwrap_or(""),
                    result.get("assignee").and_then(|v| v.as_str()).unwrap_or("unassigned"),
                    result.get("status").and_then(|v| v.as_str()).unwrap_or("assigned")
                );
                let _ = rpc_team_socket(
                    &socket_path,
                    "team.leader.send",
                    serde_json::json!({
                        "team_name": req.team_name,
                        "text": leader_text,
                    }),
                ).await;
                if let Some(assignee) = req.assignee.as_deref() {
                    let assignee_text = format!(
                        "New assigned task: {}\nTask id: {task_id}\nStatus: {}\n\nA new task has been assigned to you.\nWhen you begin work, run:\ntm-agent task start {task_id}\n",
                        result.get("title").and_then(|v| v.as_str()).unwrap_or(""),
                        result.get("status").and_then(|v| v.as_str()).unwrap_or("assigned")
                    );
                    let _ = rpc_team_socket(
                        &socket_path,
                        "team.send",
                        serde_json::json!({
                            "team_name": req.team_name,
                            "agent_name": assignee,
                            "text": assignee_text,
                        }),
                    ).await;
                }
            }
            (StatusCode::CREATED, Json(result)).into_response()
        }
        Err(err) => (StatusCode::BAD_GATEWAY, err).into_response(),
    }
}

#[derive(Deserialize)]
struct TeamTaskActionRequest {
    action: String,
    #[serde(default)]
    note: Option<String>,
    #[serde(default)]
    team_name: Option<String>,
}

async fn team_tasks_action_handler(
    State(state): State<Arc<HttpState>>,
    Path(id): Path<String>,
    Json(req): Json<TeamTaskActionRequest>,
) -> impl IntoResponse {
    let socket_path = match team_socket_path(&state) {
        Ok(path) => path,
        Err(err) => return (StatusCode::SERVICE_UNAVAILABLE, err).into_response(),
    };
    if req.action == "start" {
        let mut params = serde_json::json!({
            "team_name": req.team_name,
            "task_id": id,
        });
        if let Some(note) = req.note {
            params["progress_note"] = serde_json::json!(note);
        }
        return match rpc_team_socket(&socket_path, "team.task.start", params).await {
            Ok(result) => {
                let team_name = req.team_name.clone().unwrap_or_default();
                if let Some(task) = result.get("task") {
                    let task_id = task.get("id").and_then(|v| v.as_str()).unwrap_or("");
                    let assignee = task.get("assignee").and_then(|v| v.as_str()).unwrap_or("");
                    let title = task.get("title").and_then(|v| v.as_str()).unwrap_or("");
                    let leader_text = format!(
                        "Task started: {title}\nTask id: {task_id}\nAssignee: {assignee}\nStatus: in_progress\n"
                    );
                    let _ = rpc_team_socket(
                        &socket_path,
                        "team.leader.send",
                        serde_json::json!({
                            "team_name": team_name,
                            "text": leader_text,
                        }),
                    ).await;
                }
                Json(result).into_response()
            }
            Err(err) => (StatusCode::BAD_GATEWAY, err).into_response(),
        };
    }
    let method = match req.action.as_str() {
        "block" => "team.task.block",
        "review" => "team.task.review",
        "done" => "team.task.done",
        "reassign" => "team.task.reassign",
        "unblock" => "team.task.unblock",
        other => return (StatusCode::BAD_REQUEST, format!("unsupported action: {other}")).into_response(),
    };
    let mut params = serde_json::json!({
        "team_name": req.team_name,
        "task_id": id,
    });
    if let Some(note) = req.note {
        match req.action.as_str() {
            "block" => params["blocked_reason"] = serde_json::json!(note),
            "review" => params["review_summary"] = serde_json::json!(note),
            "done" => params["result"] = serde_json::json!(note),
            "reassign" => params["assignee"] = serde_json::json!(note),
            _ => {}
        }
    }
    match rpc_team_socket(&socket_path, method, params).await {
        Ok(result) => Json(result).into_response(),
        Err(err) => (StatusCode::BAD_GATEWAY, err).into_response(),
    }
}

async fn monitor_handler(State(state): State<Arc<HttpState>>) -> impl IntoResponse {
    let snapshot = state.monitor_rx.borrow().clone();
    match snapshot {
        Some(s) => {
            let usage = state.usage_tracker.snapshot();
            let mut value = serde_json::to_value(s).unwrap();
            value["usage_summary"] = serde_json::json!({
                "total_cost_usd": usage.total_cost_usd,
                "active_sessions": usage.sessions.len(),
                "total_input_tokens": usage.total_input_tokens,
                "total_output_tokens": usage.total_output_tokens,
            });
            value["budget_config"] = serde_json::json!({
                "cpu_threshold_percent": state.monitor_handle.cpu_threshold(),
                "memory_threshold_bytes": state.monitor_handle.memory_threshold(),
                "auto_stop": state.monitor_handle.is_auto_stop(),
            });
            Json(value).into_response()
        }
        None => (StatusCode::SERVICE_UNAVAILABLE, "monitor not ready").into_response(),
    }
}

async fn watcher_handler(State(state): State<Arc<HttpState>>) -> impl IntoResponse {
    let snapshot = state.watcher_handle.snapshot();
    Json(serde_json::to_value(snapshot).unwrap())
}

#[derive(Deserialize)]
struct WatchRequest {
    path: String,
}

async fn watch_handler(
    State(state): State<Arc<HttpState>>,
    Json(req): Json<WatchRequest>,
) -> impl IntoResponse {
    state.watcher_handle.watch_path(&req.path);
    Json(serde_json::json!({"status": "ok", "watching": req.path}))
}

async fn unwatch_handler(
    State(state): State<Arc<HttpState>>,
    Json(req): Json<WatchRequest>,
) -> impl IntoResponse {
    state.watcher_handle.unwatch_path(&req.path);
    Json(serde_json::json!({"status": "ok", "unwatched": req.path}))
}

#[derive(Deserialize)]
struct ProcessRequest {
    pid: u32,
}

async fn process_stop_handler(
    State(state): State<Arc<HttpState>>,
    Json(req): Json<ProcessRequest>,
) -> impl IntoResponse {
    let ok = state.monitor_handle.stop_process(req.pid);
    Json(serde_json::json!({"stopped": ok, "pid": req.pid}))
}

async fn process_resume_handler(
    State(state): State<Arc<HttpState>>,
    Json(req): Json<ProcessRequest>,
) -> impl IntoResponse {
    let ok = state.monitor_handle.resume_process(req.pid);
    Json(serde_json::json!({"resumed": ok, "pid": req.pid}))
}

#[derive(Deserialize)]
struct AutoStopRequest {
    enabled: bool,
}

async fn budget_auto_stop_handler(
    State(state): State<Arc<HttpState>>,
    Json(req): Json<AutoStopRequest>,
) -> impl IntoResponse {
    state.monitor_handle.set_auto_stop(req.enabled);
    Json(serde_json::json!({"auto_stop": req.enabled}))
}

async fn usage_handler(State(state): State<Arc<HttpState>>) -> impl IntoResponse {
    let snapshot = state.usage_tracker.snapshot();
    Json(serde_json::to_value(snapshot).unwrap())
}

// --- Agent Session Handlers (F-06) ---

async fn agents_list_handler(State(state): State<Arc<HttpState>>) -> impl IntoResponse {
    let sessions = state.agent_manager.list(false);
    Json(serde_json::to_value(sessions).unwrap())
}

async fn agents_get_handler(
    State(state): State<Arc<HttpState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    match state.agent_manager.get(&id) {
        Some(s) => Json(serde_json::to_value(s).unwrap()).into_response(),
        None => (StatusCode::NOT_FOUND, "session not found").into_response(),
    }
}

#[derive(Deserialize)]
struct SpawnRequest {
    repo_path: String,
    #[serde(default = "default_count")]
    count: usize,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    command: Option<String>,
}

fn default_count() -> usize { 1 }

async fn agents_spawn_handler(
    State(state): State<Arc<HttpState>>,
    Json(req): Json<SpawnRequest>,
) -> impl IntoResponse {
    let params = crate::agent::SpawnParams {
        repo_path: req.repo_path,
        count: req.count,
        name: req.name,
        command: req.command,
    };
    match state.agent_manager.spawn(params, &state.watcher_handle) {
        Ok(sessions) => Json(serde_json::to_value(sessions).unwrap()).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    }
}

#[derive(Deserialize)]
struct TerminateRequest {
    #[serde(default)]
    force: bool,
}

async fn agents_terminate_handler(
    State(state): State<Arc<HttpState>>,
    Path(id): Path<String>,
    body: Option<Json<TerminateRequest>>,
) -> impl IntoResponse {
    let force = body.map(|b| b.force).unwrap_or(false);
    match state.agent_manager.terminate(&id, force, &state.watcher_handle) {
        Ok(_) => Json(serde_json::json!({"status": "ok"})).into_response(),
        Err(e) => (StatusCode::NOT_FOUND, e).into_response(),
    }
}

// --- Agent Input Handler (PTY injection) ---

#[derive(Deserialize)]
struct InputRequest {
    text: String,
}

async fn agents_input_handler(
    State(state): State<Arc<HttpState>>,
    Path(id): Path<String>,
    Json(req): Json<InputRequest>,
) -> impl IntoResponse {
    match state.agent_manager.enqueue_input(&id, &req.text) {
        Ok(_) => StatusCode::OK.into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

// --- Task Handlers (F-06 Phase 2) ---

#[derive(Deserialize)]
struct TaskListQuery {
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    assignee: Option<String>,
}

async fn tasks_list_handler(
    State(state): State<Arc<HttpState>>,
    Query(q): Query<TaskListQuery>,
) -> impl IntoResponse {
    let params = crate::agent::TaskListParams {
        status: q.status,
        assignee: q.assignee,
    };
    let tasks = state.agent_manager.task_list(params);
    Json(serde_json::to_value(tasks).unwrap())
}

#[derive(Deserialize)]
struct TaskCreateRequest {
    title: String,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    priority: Option<i32>,
    #[serde(default)]
    created_by: Option<String>,
    #[serde(default)]
    deps: Option<Vec<String>>,
}

async fn tasks_create_handler(
    State(state): State<Arc<HttpState>>,
    Json(req): Json<TaskCreateRequest>,
) -> impl IntoResponse {
    let params = crate::agent::TaskCreateParams {
        title: req.title,
        description: req.description,
        priority: req.priority,
        created_by: req.created_by,
        deps: req.deps,
    };
    match state.agent_manager.task_create(params) {
        Ok(task) => (StatusCode::CREATED, Json(serde_json::to_value(task).unwrap())).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    }
}

async fn tasks_get_handler(
    State(state): State<Arc<HttpState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    match state.agent_manager.task_get(&id) {
        Ok(task) => Json(serde_json::to_value(task).unwrap()).into_response(),
        Err(e) => (StatusCode::NOT_FOUND, e).into_response(),
    }
}

#[derive(Deserialize)]
struct TaskUpdateRequest {
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    priority: Option<i32>,
    #[serde(default)]
    assignee: Option<String>,
}

async fn tasks_update_handler(
    State(state): State<Arc<HttpState>>,
    Path(id): Path<String>,
    Json(req): Json<TaskUpdateRequest>,
) -> impl IntoResponse {
    let params = crate::agent::TaskUpdateParams {
        id,
        title: req.title,
        description: req.description,
        status: req.status,
        priority: req.priority,
        assignee: req.assignee,
    };
    match state.agent_manager.task_update(params) {
        Ok(task) => Json(serde_json::to_value(task).unwrap()).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

#[derive(Deserialize)]
struct TaskAssignRequest {
    agent_id: String,
}

async fn tasks_assign_handler(
    State(state): State<Arc<HttpState>>,
    Path(id): Path<String>,
    Json(req): Json<TaskAssignRequest>,
) -> impl IntoResponse {
    let params = crate::agent::TaskAssignParams {
        task_id: id,
        agent_id: req.agent_id,
    };
    match state.agent_manager.task_assign(params) {
        Ok(task) => Json(serde_json::to_value(task).unwrap()).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

#[derive(Deserialize)]
struct TaskLogQuery {
    #[serde(default)]
    limit: Option<i64>,
}

async fn tasks_log_handler(
    State(state): State<Arc<HttpState>>,
    Path(id): Path<String>,
    Query(q): Query<TaskLogQuery>,
) -> impl IntoResponse {
    let entries = state.agent_manager.task_log(&id, q.limit);
    Json(serde_json::to_value(entries).unwrap())
}

// --- Message Handlers (F-06 Phase 2) ---

#[derive(Deserialize)]
struct MessageSendRequest {
    #[serde(default)]
    from_agent: Option<String>,
    to_agent: String,
    content: String,
}

async fn messages_send_handler(
    State(state): State<Arc<HttpState>>,
    Json(req): Json<MessageSendRequest>,
) -> impl IntoResponse {
    tracing::info!("POST /api/messages: to={} content_len={}", req.to_agent, req.content.len());
    let params = crate::agent::MessageSendParams {
        from_agent: req.from_agent,
        to_agent: req.to_agent,
        content: req.content,
    };
    match state.agent_manager.message_send(params) {
        Ok(msg) => {
            tracing::info!("message sent: id={}", msg.id);
            (StatusCode::CREATED, Json(serde_json::to_value(msg).unwrap())).into_response()
        }
        Err(e) => {
            tracing::warn!("message send failed: {}", e);
            (StatusCode::BAD_REQUEST, e).into_response()
        }
    }
}

#[derive(Deserialize)]
struct MessageListQuery {
    #[serde(default)]
    unread_only: Option<bool>,
    #[serde(default)]
    limit: Option<i64>,
}

async fn messages_list_handler(
    State(state): State<Arc<HttpState>>,
    Path(agent_id): Path<String>,
    Query(q): Query<MessageListQuery>,
) -> impl IntoResponse {
    let params = crate::agent::MessageListParams {
        agent_id,
        unread_only: q.unread_only,
        limit: q.limit,
    };
    let msgs = state.agent_manager.message_list(params);
    Json(serde_json::to_value(msgs).unwrap())
}

#[derive(Deserialize)]
struct MessageAckRequest {
    message_ids: Vec<i64>,
}

async fn messages_ack_handler(
    State(state): State<Arc<HttpState>>,
    Json(req): Json<MessageAckRequest>,
) -> impl IntoResponse {
    match state.agent_manager.message_ack(&req.message_ids) {
        Ok(n) => Json(serde_json::json!({"acknowledged": n})).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    }
}

fn find_dashboard_dir() -> Option<PathBuf> {
    if let Ok(project_dir) = std::env::var("CMUX_PROJECT_DIR") {
        let path = PathBuf::from(project_dir).join("Resources/dashboard");
        if path.exists() { return Some(path); }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            // Direct sibling: <dir>/Resources/dashboard (dev layout)
            let path = parent.join("Resources/dashboard");
            if path.exists() { return Some(path); }
            // Deployed app bundle: binary is at Contents/Resources/bin/term-meshd,
            // dashboard is at Contents/Resources/dashboard
            if let Some(grandparent) = parent.parent() {
                let path = grandparent.join("dashboard");
                if path.exists() { return Some(path); }
            }
        }
    }
    None
}


const HTTP_POLL_SCRIPT: &str = r#"<script>
// ── HTTP Fetch Polling + Session Picker (injected by term-meshd) ──
(function() {
  const isWKWebView = window.webkit && window.webkit.messageHandlers;
  if (isWKWebView) return;

  const POLL_INTERVAL = 2000;
  const baseUrl = window.location.origin;
  let selectedSession = 'all'; // 'all' or a project_path

  async function poll() {
    try {
      const [monitorRes, watcherRes, sessionsRes, usageRes, teamRes] = await Promise.all([
        fetch(baseUrl + '/api/monitor'),
        fetch(baseUrl + '/api/watcher'),
        fetch(baseUrl + '/api/sessions'),
        fetch(baseUrl + '/api/usage'),
        fetch(baseUrl + '/api/team'),
      ]);
      if (monitorRes.ok) updateMonitor(await monitorRes.json());
      if (watcherRes.ok) updateHeatmap(await watcherRes.json());
      if (sessionsRes.ok) {
        const sessionsData = await sessionsRes.json();
        updateSessionPicker(sessionsData);
        if (window.updateAgentStatus) updateAgentStatus(sessionsData);
      }
      if (usageRes.ok && window.updateUsage) updateUsage(await usageRes.json());
      if (teamRes.ok) {
        const teamData = await teamRes.json();
        if (window.updateTeamAgents) updateTeamAgents(teamData.teams || []);
        if (window.updateTeamTasks) updateTeamTasks(teamData.tasks || []);
        if (window.updateTeamAttention) updateTeamAttention(teamData.attention || []);
        if (window.updateInstanceStatus) updateInstanceStatus(teamData.instance || {});
      }

      // Agents + Tasks + Messages
      fetch(baseUrl + '/api/agents').then(r => r.ok ? r.json() : []).then(d => {
        if (window.updateAgents) updateAgents(d);
        if (window.refreshMsgAgentDropdown) refreshMsgAgentDropdown();
      });
      fetch(baseUrl + '/api/tasks').then(r => r.ok ? r.json() : []).then(d => {
        if (window.updateTasks) updateTasks(d);
      });
      if (window.pollMessages) pollMessages();
    } catch (e) {
      document.getElementById('status').textContent = 'disconnected';
    }
  }

  // ── Session Picker ──
  function updateSessionPicker(sessions) {
    const container = document.getElementById('session-picker');
    if (!container) return;

    // Build select options
    let html = '<select id="session-select" onchange="window._selectSession(this.value)" style="background:rgba(255,255,255,0.94);border:1px solid rgba(148,163,184,0.18);color:#27364b;padding:9px 11px;border-radius:6px;font-size:12px;outline:none;min-width:220px;box-shadow:0 8px 18px rgba(15,23,42,0.06);">';
    html += '<option value="all"' + (selectedSession === 'all' ? ' selected' : '') + '>All Sessions (' + sessions.length + ')</option>';
    for (const s of sessions) {
      const label = s.name + (s.git_branch ? ' [' + s.git_branch + ']' : '');
      const sel = selectedSession === s.project_path ? ' selected' : '';
      html += '<option value="' + s.project_path + '"' + sel + '>' + label + '</option>';
    }
    html += '</select>';

    // Show session details
    if (sessions.length > 0 && selectedSession !== 'all') {
      const s = sessions.find(x => x.project_path === selectedSession);
      if (s) {
        const projName = s.project_path.split('/').pop();
        html += '<span style="margin-left:8px;font-size:11px;color:#64766f;">' + projName + '</span>';
      }
    }

    container.innerHTML = html;
  }

  window._selectSession = function(value) {
    selectedSession = value;
    // Apply filter to heatmap/events
    window._sessionFilter = value === 'all' ? null : value;
    poll(); // Refresh with filter
  };

  window._sessionFilter = null;

  // ── Override updateHeatmap to apply session filter ──
  const _origUpdateHeatmap = window.updateHeatmap;
  window.updateHeatmap = function(data) {
    if (!data) return;
    const filter = window._sessionFilter;
    if (filter) {
      // Filter top_files and recent_events to selected session's project_path
      data = {
        ...data,
        top_files: data.top_files.filter(f => f.path.startsWith(filter + '/')),
        recent_events: data.recent_events.filter(e => e.path.startsWith(filter + '/')),
        // Keep watched_paths as-is for display
      };
    }
    _origUpdateHeatmap(data);
  };

  // ── Watch Path Form ──
  const wpEl = document.getElementById('watched-projects');
  if (wpEl) {
    const origHeatmap = window.updateHeatmap;
    window.updateHeatmap = function(data) {
      origHeatmap(data);
      // Add watch management UI
      const paths = (data.watched_paths || []);
      let html = paths.map(p => {
        const name = p.split('/').pop() || p;
        return '<span class="project-tag" title="' + p + '">' + name +
               '<span class="remove-btn" onclick="unwatchProject(\'' + p + '\')">&times;</span></span>';
      }).join('');
      html += '<div style="margin-top:8px;display:flex;gap:4px;">' +
        '<input id="watch-input" type="text" placeholder="/path/to/project" ' +
        'style="background:#1a1a2e;border:1px solid #0f3460;color:#e0e0e0;padding:4px 8px;border-radius:4px;font-size:11px;flex:1;outline:none;" ' +
        'onkeydown="if(event.key===\'Enter\')addWatch()">' +
        '<button onclick="addWatch()" style="background:#00adb5;border:none;color:#fff;padding:4px 10px;border-radius:4px;font-size:11px;cursor:pointer;">+ Watch</button>' +
        '</div>';
      wpEl.innerHTML = html;
    };
  }

  window.addWatch = async function() {
    const input = document.getElementById('watch-input');
    if (!input) return;
    const path = input.value.trim();
    if (!path) return;
    await fetch(baseUrl + '/api/watcher/watch', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({path}),
    });
    input.value = '';
    poll();
  };

  window.unwatchProject = async function(path) {
    await fetch(baseUrl + '/api/watcher/unwatch', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({path}),
    });
    poll();
  };

  setInterval(poll, POLL_INTERVAL);
  setTimeout(poll, 300);
  document.getElementById('status').textContent = 'http polling';
})();
</script>"#;

