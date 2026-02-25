use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{Html, IntoResponse, Json},
    routing::{get, post},
    Router,
};
use serde::Deserialize;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::watch;
use tower_http::cors::CorsLayer;

use crate::agent::AgentSessionManager;
use crate::monitor::{MonitorHandle, SystemSnapshot};
use crate::socket::SessionStore;
use crate::tokens::UsageTracker;
use crate::watcher::WatcherHandle;

pub struct HttpState {
    pub monitor_rx: watch::Receiver<Option<SystemSnapshot>>,
    #[allow(dead_code)]
    pub monitor_handle: MonitorHandle,
    pub watcher_handle: WatcherHandle,
    pub sessions: SessionStore,
    pub usage_tracker: UsageTracker,
    pub agent_manager: Arc<AgentSessionManager>,
    pub dashboard_dir: Option<PathBuf>,
}

pub async fn serve(
    addr: SocketAddr,
    monitor_rx: watch::Receiver<Option<SystemSnapshot>>,
    monitor_handle: MonitorHandle,
    watcher_handle: WatcherHandle,
    sessions: SessionStore,
    usage_tracker: UsageTracker,
    agent_manager: Arc<AgentSessionManager>,
    mut shutdown_rx: watch::Receiver<bool>,
) -> anyhow::Result<()> {
    let dashboard_dir = find_dashboard_dir();

    let state = Arc::new(HttpState {
        monitor_rx,
        monitor_handle,
        watcher_handle,
        sessions,
        usage_tracker,
        agent_manager,
        dashboard_dir,
    });

    let app = Router::new()
        .route("/", get(index_handler))
        .route("/api/sessions", get(sessions_handler))
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
        .layer(CorsLayer::permissive())
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

async fn index_handler(State(state): State<Arc<HttpState>>) -> impl IntoResponse {
    if let Some(dir) = &state.dashboard_dir {
        let index_path = dir.join("index.html");
        if let Ok(html) = tokio::fs::read_to_string(&index_path).await {
            let injected = html.replace("</body>", &format!("{}\n</body>", HTTP_POLL_SCRIPT));
            return Html(injected);
        }
    }
    Html(FALLBACK_HTML.to_string())
}

/// GET /api/sessions — list terminal sessions from the Swift app
async fn sessions_handler(State(state): State<Arc<HttpState>>) -> impl IntoResponse {
    let sessions = state.sessions.lock().unwrap().clone();
    Json(serde_json::to_value(sessions).unwrap())
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
            let path = parent.join("Resources/dashboard");
            if path.exists() { return Some(path); }
        }
    }
    let dev_path = PathBuf::from("/Users/jinwoo/work/cmux-term-mesh/Resources/dashboard");
    if dev_path.exists() { return Some(dev_path); }
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
      const [monitorRes, watcherRes, sessionsRes, usageRes] = await Promise.all([
        fetch(baseUrl + '/api/monitor'),
        fetch(baseUrl + '/api/watcher'),
        fetch(baseUrl + '/api/sessions'),
        fetch(baseUrl + '/api/usage'),
      ]);
      if (monitorRes.ok) updateMonitor(await monitorRes.json());
      if (watcherRes.ok) updateHeatmap(await watcherRes.json());
      if (sessionsRes.ok) {
        const sessionsData = await sessionsRes.json();
        updateSessionPicker(sessionsData);
        if (window.updateAgentStatus) updateAgentStatus(sessionsData);
      }
      if (usageRes.ok && window.updateUsage) updateUsage(await usageRes.json());

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
    let html = '<select id="session-select" onchange="window._selectSession(this.value)" style="background:#1a1a2e;border:1px solid #0f3460;color:#e0e0e0;padding:4px 8px;border-radius:4px;font-size:12px;outline:none;min-width:200px;">';
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
        html += '<span style="margin-left:8px;font-size:11px;color:#888;">' + projName + '</span>';
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

const FALLBACK_HTML: &str = r#"<!DOCTYPE html>
<html><head><title>term-mesh Dashboard</title></head>
<body style="background:#1a1a2e;color:#e0e0e0;font-family:sans-serif;padding:40px;text-align:center">
<h1 style="color:#00adb5">term-mesh Dashboard</h1>
<p>Dashboard HTML not found.</p>
<p>API: <a href="/api/sessions" style="color:#00adb5">/api/sessions</a>
 | <a href="/api/monitor" style="color:#00adb5">/api/monitor</a>
 | <a href="/api/watcher" style="color:#00adb5">/api/watcher</a></p>
</body></html>"#;
