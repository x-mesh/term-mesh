use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::time::{timeout, Duration};
use tokio::sync::watch;

use crate::agent::AgentSessionManager;
use crate::monitor::{MonitorHandle, SystemSnapshot};
use crate::tokens::UsageTracker;
use crate::watcher::WatcherHandle;
use crate::worktree;

/// JSON-RPC 2.0 request (simplified)
#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: Option<serde_json::Value>,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

/// JSON-RPC 2.0 response (simplified)
#[derive(Debug, Serialize)]
pub struct Response {
    pub id: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

#[derive(Debug, Serialize)]
pub struct RpcError {
    pub code: i32,
    pub message: String,
}

/// Terminal session info pushed by the Swift app.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: String,
    pub name: String,
    pub project_path: String,
    #[serde(default)]
    pub git_branch: Option<String>,
    /// Agent notification state: "idle" | "waiting" (has unread notification)
    #[serde(default)]
    pub agent_state: Option<String>,
    /// Notification title (e.g., agent command that completed)
    #[serde(default)]
    pub notification_title: Option<String>,
    /// Timestamp of last notification (ms since epoch)
    #[serde(default)]
    pub notification_ts: Option<u64>,
}

/// Shared session store.
pub type SessionStore = Arc<Mutex<Vec<SessionInfo>>>;
/// Shared team dashboard state pushed by the Swift app.
pub type TeamStateStore = Arc<Mutex<serde_json::Value>>;

/// Shared context passed to each connection handler.
pub struct Context {
    pub monitor_rx: watch::Receiver<Option<SystemSnapshot>>,
    pub monitor_handle: MonitorHandle,
    pub watcher_handle: WatcherHandle,
    pub sessions: SessionStore,
    pub team_state: TeamStateStore,
    pub usage_tracker: UsageTracker,
    pub agent_manager: Arc<AgentSessionManager>,
}

pub fn default_socket_path() -> PathBuf {
    // Honor explicit socket path for tagged/isolated builds
    if let Ok(p) = std::env::var("TERMMESH_DAEMON_UNIX_PATH") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    let dir = dirs::runtime_dir()
        .or_else(|| std::env::var("TMPDIR").ok().map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    dir.join("term-meshd.sock")
}

pub async fn serve(
    path: PathBuf,
    monitor_rx: watch::Receiver<Option<SystemSnapshot>>,
    monitor_handle: MonitorHandle,
    watcher_handle: WatcherHandle,
    sessions: SessionStore,
    team_state: TeamStateStore,
    usage_tracker: UsageTracker,
    agent_manager: Arc<AgentSessionManager>,
    mut shutdown_rx: watch::Receiver<bool>,
) -> anyhow::Result<()> {
    if path.exists() {
        std::fs::remove_file(&path)?;
    }

    let listener = UnixListener::bind(&path)?;
    tracing::info!("listening on {}", path.display());

    let ctx = Arc::new(Context {
        monitor_rx,
        monitor_handle,
        watcher_handle,
        sessions,
        team_state,
        usage_tracker,
        agent_manager,
    });

    loop {
        tokio::select! {
            result = listener.accept() => {
                match result {
                    Ok((stream, _)) => {
                        let ctx = ctx.clone();
                        tokio::spawn(async move {
                            if let Err(e) = handle_connection(stream, &ctx).await {
                                tracing::error!("connection error: {e}");
                            }
                        });
                    }
                    Err(e) => {
                        tracing::error!("accept error: {e}");
                    }
                }
            }
            _ = shutdown_rx.changed() => {
                tracing::info!("socket server shutting down");
                break;
            }
        }
    }

    // Clean up socket file
    if path.exists() {
        if let Err(e) = std::fs::remove_file(&path) {
            tracing::warn!("failed to remove socket file: {e}");
        } else {
            tracing::info!("removed socket file {}", path.display());
        }
    }

    Ok(())
}

async fn handle_connection(
    stream: tokio::net::UnixStream,
    ctx: &Context,
) -> anyhow::Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();

    while let Some(line) = timeout(Duration::from_secs(60), lines.next_line())
        .await
        .map_err(|_| anyhow::anyhow!("read timeout"))??
    {
        let req: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let resp = Response {
                    id: None,
                    result: None,
                    error: Some(RpcError {
                        code: -32700,
                        message: format!("parse error: {e}"),
                    }),
                };
                let mut buf = serde_json::to_vec(&resp)?;
                buf.push(b'\n');
                timeout(Duration::from_secs(5), writer.write_all(&buf))
                    .await
                    .map_err(|_| anyhow::anyhow!("write timeout"))??;
                continue;
            }
        };

        tracing::debug!("req: {} {:?}", req.method, req.params);
        let resp = dispatch(&req, ctx).await;

        let mut buf = serde_json::to_vec(&resp)?;
        buf.push(b'\n');
        timeout(Duration::from_secs(5), writer.write_all(&buf))
            .await
            .map_err(|_| anyhow::anyhow!("write timeout"))??;
    }

    Ok(())
}

async fn dispatch(req: &Request, ctx: &Context) -> Response {
    let result = match req.method.as_str() {
        // --- General ---
        "ping" => Ok(serde_json::json!("pong")),

        "daemon.status" => {
            let uptime_secs = crate::START_TIME
                .get()
                .map(|t| t.elapsed().as_secs())
                .unwrap_or(0);

            let has_snapshot = ctx.monitor_rx.borrow().is_some();
            let watched_count = ctx.watcher_handle.snapshot().watched_paths.len();
            let active_agents = ctx.agent_manager.list(false).len();
            let tracked_pids = ctx.monitor_handle.tracked_pids().len();

            let http_disabled = std::env::var("TERM_MESH_HTTP_DISABLED")
                .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                .unwrap_or(false);
            let http_addr = std::env::var("TERM_MESH_HTTP_ADDR")
                .unwrap_or_else(|_| "127.0.0.1:9876".to_string());

            Ok(serde_json::json!({
                "pid": std::process::id(),
                "uptime_secs": uptime_secs,
                "subsystems": {
                    "socket": { "status": "running" },
                    "http": {
                        "status": if http_disabled { "disabled" } else { "running" },
                        "addr": if http_disabled { None } else { Some(&http_addr) },
                    },
                    "monitor": {
                        "status": if has_snapshot { "running" } else { "starting" },
                        "tracked_pids": tracked_pids,
                    },
                    "watcher": {
                        "status": "running",
                        "watched_paths": watched_count,
                    },
                    "agents": {
                        "status": "running",
                        "active_sessions": active_agents,
                    },
                },
            }))
        }

        // --- Sessions (pushed by Swift app) ---
        "session.sync" => {
            #[derive(Deserialize)]
            struct SyncParams { sessions: Vec<SessionInfo> }
            match serde_json::from_value::<SyncParams>(req.params.clone()) {
                Ok(p) => {
                    let count = p.sessions.len();
                    *ctx.sessions.lock().unwrap() = p.sessions;
                    tracing::debug!("session.sync: {count} sessions");
                    Ok(serde_json::json!({"synced": count}))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "session.list" => {
            let sessions = ctx.sessions.lock().unwrap().clone();
            Ok(serde_json::to_value(sessions).unwrap())
        }
        "team.sync" => {
            #[derive(Deserialize)]
            struct SyncParams {
                #[serde(default)]
                teams: Vec<serde_json::Value>,
                #[serde(default)]
                tasks: Vec<serde_json::Value>,
                #[serde(default)]
                attention: Vec<serde_json::Value>,
                #[serde(default)]
                instance: serde_json::Value,
            }
            match serde_json::from_value::<SyncParams>(req.params.clone()) {
                Ok(p) => {
                    let synced = serde_json::json!({
                        "teams": p.teams,
                        "tasks": p.tasks,
                        "attention": p.attention,
                        "instance": p.instance,
                    });
                    let counts = serde_json::json!({
                        "teams": synced["teams"].as_array().map(|v| v.len()).unwrap_or(0),
                        "tasks": synced["tasks"].as_array().map(|v| v.len()).unwrap_or(0),
                        "attention": synced["attention"].as_array().map(|v| v.len()).unwrap_or(0),
                    });
                    *ctx.team_state.lock().unwrap() = synced;
                    tracing::debug!("team.sync: {:?}", counts);
                    Ok(counts)
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "team.get" => {
            let team_state = ctx.team_state.lock().unwrap().clone();
            Ok(team_state)
        }

        // --- Worktree (F-01) ---
        "worktree.create" => worktree::create(req.params.clone())
            .map(|v| serde_json::to_value(v).unwrap()),
        "worktree.remove" => worktree::remove(req.params.clone())
            .map(|_| serde_json::json!("ok")),
        "worktree.list" => worktree::list(req.params.clone())
            .map(|v| serde_json::to_value(v).unwrap()),
        "worktree.status" => worktree::status(req.params.clone())
            .map(|v| serde_json::to_value(v).unwrap()),
        "worktree.safe_remove" => worktree::safe_remove(req.params.clone())
            .map(|_| serde_json::json!("ok")),
        "worktree.list_branches" => worktree::list_branches(req.params.clone())
            .map(|v| serde_json::to_value(v).unwrap()),

        // --- Resource Monitor (F-03/F-04) ---
        "monitor.snapshot" => {
            let snapshot = ctx.monitor_rx.borrow().clone();
            match snapshot {
                Some(s) => {
                    let usage = ctx.usage_tracker.snapshot();
                    let mut value = serde_json::to_value(s).unwrap();
                    value["usage_summary"] = serde_json::json!({
                        "total_cost_usd": usage.total_cost_usd,
                        "active_sessions": usage.sessions.len(),
                        "total_input_tokens": usage.total_input_tokens,
                        "total_output_tokens": usage.total_output_tokens,
                    });
                    value["budget_config"] = serde_json::json!({
                        "cpu_threshold_percent": ctx.monitor_handle.cpu_threshold(),
                        "memory_threshold_bytes": ctx.monitor_handle.memory_threshold(),
                        "auto_stop": ctx.monitor_handle.is_auto_stop(),
                    });
                    Ok(value)
                }
                None => Ok(serde_json::json!(null)),
            }
        }
        "monitor.track" => {
            #[derive(Deserialize)]
            struct TrackParams { pid: u32 }
            match serde_json::from_value::<TrackParams>(req.params.clone()) {
                Ok(p) => { ctx.monitor_handle.track_pid(p.pid); Ok(serde_json::json!("ok")) }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "monitor.untrack" => {
            #[derive(Deserialize)]
            struct UntrackParams { pid: u32 }
            match serde_json::from_value::<UntrackParams>(req.params.clone()) {
                Ok(p) => { ctx.monitor_handle.untrack_pid(p.pid); Ok(serde_json::json!("ok")) }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "monitor.tracked" => {
            let pids = ctx.monitor_handle.tracked_pids();
            Ok(serde_json::to_value(pids).unwrap())
        }
        "process.stop" => {
            #[derive(Deserialize)]
            struct StopParams { pid: u32 }
            match serde_json::from_value::<StopParams>(req.params.clone()) {
                Ok(p) => {
                    let ok = ctx.monitor_handle.stop_process(p.pid);
                    Ok(serde_json::json!({"stopped": ok, "pid": p.pid}))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "process.resume" => {
            #[derive(Deserialize)]
            struct ResumeParams { pid: u32 }
            match serde_json::from_value::<ResumeParams>(req.params.clone()) {
                Ok(p) => {
                    let ok = ctx.monitor_handle.resume_process(p.pid);
                    Ok(serde_json::json!({"resumed": ok, "pid": p.pid}))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "budget.auto_stop" => {
            #[derive(Deserialize)]
            struct AutoStopParams { enabled: bool }
            match serde_json::from_value::<AutoStopParams>(req.params.clone()) {
                Ok(p) => {
                    ctx.monitor_handle.set_auto_stop(p.enabled);
                    Ok(serde_json::json!({"auto_stop": p.enabled}))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }

        // --- File Watcher (F-05) ---
        "watcher.watch" => {
            #[derive(Deserialize)]
            struct WatchParams { path: String }
            match serde_json::from_value::<WatchParams>(req.params.clone()) {
                Ok(p) => { ctx.watcher_handle.watch_path(&p.path); Ok(serde_json::json!("ok")) }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "watcher.unwatch" => {
            #[derive(Deserialize)]
            struct UnwatchParams { path: String }
            match serde_json::from_value::<UnwatchParams>(req.params.clone()) {
                Ok(p) => { ctx.watcher_handle.unwatch_path(&p.path); Ok(serde_json::json!("ok")) }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "watcher.snapshot" => {
            let snapshot = ctx.watcher_handle.snapshot();
            Ok(serde_json::to_value(snapshot).unwrap())
        }

        // --- Usage Tracker (F-03/F-04) — JSONL-based real API usage ---
        "usage.snapshot" => {
            let snapshot = ctx.usage_tracker.snapshot();
            Ok(serde_json::to_value(snapshot).unwrap())
        }
        "usage.scan" => {
            match ctx.usage_tracker.scan_all() {
                Ok(_) => Ok(serde_json::json!("ok")),
                Err(e) => Err(format!("scan error: {e}")),
            }
        }

        // --- Agent Sessions (F-06) ---
        "agent.spawn" => {
            match serde_json::from_value::<crate::agent::SpawnParams>(req.params.clone()) {
                Ok(p) => match ctx.agent_manager.spawn(p, &ctx.watcher_handle) {
                    Ok(sessions) => Ok(serde_json::to_value(sessions).unwrap()),
                    Err(e) => Err(e),
                },
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "agent.list" => {
            #[derive(Deserialize)]
            struct ListParams {
                #[serde(default)]
                include_terminated: bool,
            }
            let params: ListParams = serde_json::from_value(req.params.clone()).unwrap_or(ListParams { include_terminated: false });
            let sessions = ctx.agent_manager.list(params.include_terminated);
            Ok(serde_json::to_value(sessions).unwrap())
        }
        "agent.get" => {
            #[derive(Deserialize)]
            struct GetParams { id: String }
            match serde_json::from_value::<GetParams>(req.params.clone()) {
                Ok(p) => match ctx.agent_manager.get(&p.id) {
                    Some(s) => Ok(serde_json::to_value(s).unwrap()),
                    None => Err(format!("session not found: {}", p.id)),
                },
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "agent.terminate" => {
            #[derive(Deserialize)]
            struct TerminateParams {
                id: String,
                #[serde(default)]
                force: bool,
            }
            match serde_json::from_value::<TerminateParams>(req.params.clone()) {
                Ok(p) => ctx.agent_manager.terminate(&p.id, p.force, &ctx.watcher_handle)
                    .map(|_| serde_json::json!("ok")),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "agent.bind_panel" => {
            #[derive(Deserialize)]
            struct BindParams { session_id: String, panel_id: String }
            match serde_json::from_value::<BindParams>(req.params.clone()) {
                Ok(p) => ctx.agent_manager.bind_panel(&p.session_id, &p.panel_id)
                    .map(|_| serde_json::json!("ok")),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "agent.unbind_panel" => {
            #[derive(Deserialize)]
            struct UnbindParams { session_id: String }
            match serde_json::from_value::<UnbindParams>(req.params.clone()) {
                Ok(p) => ctx.agent_manager.unbind_panel(&p.session_id)
                    .map(|_| serde_json::json!("ok")),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "agent.add_pid" => {
            #[derive(Deserialize)]
            struct AddPidParams { session_id: String, pid: u32 }
            match serde_json::from_value::<AddPidParams>(req.params.clone()) {
                Ok(p) => ctx.agent_manager.add_pid(&p.session_id, p.pid)
                    .map(|_| serde_json::json!("ok")),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }

        // --- Tasks (F-06 Phase 2) ---
        "task.create" => {
            match serde_json::from_value::<crate::agent::TaskCreateParams>(req.params.clone()) {
                Ok(p) => ctx.agent_manager.task_create(p)
                    .map(|t| serde_json::to_value(t).unwrap()),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "task.get" => {
            #[derive(Deserialize)]
            struct P { id: String }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => ctx.agent_manager.task_get(&p.id)
                    .map(|t| serde_json::to_value(t).unwrap()),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "task.list" => {
            let params: crate::agent::TaskListParams = serde_json::from_value(req.params.clone())
                .unwrap_or(crate::agent::TaskListParams { status: None, assignee: None });
            let tasks = ctx.agent_manager.task_list(params);
            Ok(serde_json::to_value(tasks).unwrap())
        }
        "task.update" => {
            match serde_json::from_value::<crate::agent::TaskUpdateParams>(req.params.clone()) {
                Ok(p) => ctx.agent_manager.task_update(p)
                    .map(|t| serde_json::to_value(t).unwrap()),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "task.assign" => {
            match serde_json::from_value::<crate::agent::TaskAssignParams>(req.params.clone()) {
                Ok(p) => ctx.agent_manager.task_assign(p)
                    .map(|t| serde_json::to_value(t).unwrap()),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "task.log" => {
            #[derive(Deserialize)]
            struct P { task_id: String, #[serde(default)] limit: Option<i64> }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let entries = ctx.agent_manager.task_log(&p.task_id, p.limit);
                    Ok(serde_json::to_value(entries).unwrap())
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }

        // --- Messages (F-06 Phase 2) ---
        "message.send" => {
            match serde_json::from_value::<crate::agent::MessageSendParams>(req.params.clone()) {
                Ok(p) => ctx.agent_manager.message_send(p)
                    .map(|m| serde_json::to_value(m).unwrap()),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "message.list" => {
            match serde_json::from_value::<crate::agent::MessageListParams>(req.params.clone()) {
                Ok(p) => {
                    let msgs = ctx.agent_manager.message_list(p);
                    Ok(serde_json::to_value(msgs).unwrap())
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "message.ack" => {
            match serde_json::from_value::<crate::agent::MessageAckParams>(req.params.clone()) {
                Ok(p) => ctx.agent_manager.message_ack(&p.message_ids)
                    .map(|n| serde_json::json!({"acknowledged": n})),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }

        // --- Pending Input (PTY injection via Swift polling) ---
        "input.enqueue" => {
            #[derive(Deserialize)]
            struct P { session_id: String, text: String }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => ctx.agent_manager.enqueue_input(&p.session_id, &p.text)
                    .map(|_| serde_json::json!("ok")),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "input.poll" => {
            let inputs = ctx.agent_manager.poll_inputs();
            Ok(serde_json::to_value(inputs).unwrap())
        }

        _ => Err(format!("unknown method: {}", req.method)),
    };

    match result {
        Ok(value) => Response {
            id: req.id.clone(),
            result: Some(value),
            error: None,
        },
        Err(msg) => Response {
            id: req.id.clone(),
            result: None,
            error: Some(RpcError {
                code: -32601,
                message: msg,
            }),
        },
    }
}
