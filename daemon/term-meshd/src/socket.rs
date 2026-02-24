use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::watch;

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

/// Shared context passed to each connection handler.
pub struct Context {
    pub monitor_rx: watch::Receiver<Option<SystemSnapshot>>,
    pub monitor_handle: MonitorHandle,
    pub watcher_handle: WatcherHandle,
    pub sessions: SessionStore,
    pub usage_tracker: UsageTracker,
}

pub fn default_socket_path() -> PathBuf {
    let dir = dirs::runtime_dir()
        .or_else(|| std::env::var("TMPDIR").ok().map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    dir.join("term-meshd.sock")
}

pub async fn serve(
    path: &PathBuf,
    monitor_rx: watch::Receiver<Option<SystemSnapshot>>,
    monitor_handle: MonitorHandle,
    watcher_handle: WatcherHandle,
    sessions: SessionStore,
    usage_tracker: UsageTracker,
) -> anyhow::Result<()> {
    if path.exists() {
        std::fs::remove_file(path)?;
    }

    let listener = UnixListener::bind(path)?;
    tracing::info!("listening on {}", path.display());

    let ctx = Arc::new(Context {
        monitor_rx,
        monitor_handle,
        watcher_handle,
        sessions,
        usage_tracker,
    });

    loop {
        let (stream, _) = listener.accept().await?;
        let ctx = ctx.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_connection(stream, &ctx).await {
                tracing::error!("connection error: {e}");
            }
        });
    }
}

async fn handle_connection(
    stream: tokio::net::UnixStream,
    ctx: &Context,
) -> anyhow::Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();

    while let Some(line) = lines.next_line().await? {
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
                writer.write_all(&buf).await?;
                continue;
            }
        };

        tracing::debug!("req: {} {:?}", req.method, req.params);
        let resp = dispatch(&req, ctx).await;

        let mut buf = serde_json::to_vec(&resp)?;
        buf.push(b'\n');
        writer.write_all(&buf).await?;
    }

    Ok(())
}

async fn dispatch(req: &Request, ctx: &Context) -> Response {
    let result = match req.method.as_str() {
        // --- General ---
        "ping" => Ok(serde_json::json!("pong")),

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

        // --- Worktree (F-01) ---
        "worktree.create" => worktree::create(req.params.clone())
            .map(|v| serde_json::to_value(v).unwrap()),
        "worktree.remove" => worktree::remove(req.params.clone())
            .map(|_| serde_json::json!("ok")),
        "worktree.list" => worktree::list(req.params.clone())
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
