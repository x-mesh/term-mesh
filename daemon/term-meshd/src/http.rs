use axum::{
    extract::State,
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
    pub dashboard_dir: Option<PathBuf>,
}

pub async fn serve(
    addr: SocketAddr,
    monitor_rx: watch::Receiver<Option<SystemSnapshot>>,
    monitor_handle: MonitorHandle,
    watcher_handle: WatcherHandle,
    sessions: SessionStore,
    usage_tracker: UsageTracker,
    mut shutdown_rx: watch::Receiver<bool>,
) -> anyhow::Result<()> {
    let dashboard_dir = find_dashboard_dir();

    let state = Arc::new(HttpState {
        monitor_rx,
        monitor_handle,
        watcher_handle,
        sessions,
        usage_tracker,
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
