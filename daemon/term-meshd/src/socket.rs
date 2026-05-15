use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, RwLock};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::watch;
use tokio::time::{timeout, Duration};

use crate::agent::AgentSessionManager;
use crate::headless::HeadlessManager;
use crate::monitor::{Anomaly, MonitorHandle, SystemSnapshot};
use crate::pane_tracker::PaneTracker;
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
pub type SessionStore = Arc<RwLock<Vec<SessionInfo>>>;
/// Shared team dashboard state pushed by the Swift app.
pub type TeamStateStore = Arc<RwLock<serde_json::Value>>;

/// Event emitted by the daemon when significant state transitions occur.
/// Subscribers receive these via `events.subscribe` streaming RPC.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DaemonEvent {
    TaskStatus {
        team: String,
        agent: String,
        task_id: String,
        status: String,
        prev_status: String,
        ts_ms: u64,
    },
    Reply {
        team: String,
        agent: String,
        task_id: String,
        header: String,
        ts_ms: u64,
    },
    HeartbeatStale {
        team: String,
        agent: String,
        last_heartbeat_ts: String,
        age_seconds: u64,
    },
    /// Phase 2.5: 1-second coalesced per-team cumulative token usage. Emitted
    /// only when at least one agent's counters changed since the previous
    /// tick. Wire kind is `agent_usage_tick`.
    AgentUsageTick {
        team_uuid: String,
        team_name: String,
        agents: Vec<crate::headless::UsageTickAgent>,
        ts_ms: u64,
    },
}

/// Broadcast channel sender. All `events.subscribe` connections subscribe from this.
/// Capacity 256: slow consumers get `Lagged` errors and lose old events, which is fine.
pub type EventSender = tokio::sync::broadcast::Sender<DaemonEvent>;

/// Shared context passed to each connection handler.
pub struct Context {
    pub monitor_rx: watch::Receiver<Option<SystemSnapshot>>,
    pub monitor_handle: MonitorHandle,
    pub watcher_handle: WatcherHandle,
    pub sessions: SessionStore,
    pub team_state: TeamStateStore,
    pub usage_tracker: UsageTracker,
    pub agent_manager: Arc<AgentSessionManager>,
    pub headless: Arc<tokio::sync::Mutex<HeadlessManager>>,
    pub pane_tracker: PaneTracker,
    pub event_tx: EventSender,
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
    headless: Arc<tokio::sync::Mutex<HeadlessManager>>,
    mut shutdown_rx: watch::Receiver<bool>,
) -> anyhow::Result<()> {
    if path.exists() {
        std::fs::remove_file(&path)?;
    }

    let listener = bind_with_tight_umask(&path)?;
    harden_socket_permissions(&path);
    tracing::info!("listening on {}", path.display());

    let owner_uid = current_uid();
    let (event_tx, _) = tokio::sync::broadcast::channel(256);
    let pane_tracker = PaneTracker::new().start();
    let ctx = Arc::new(Context {
        monitor_rx,
        monitor_handle,
        watcher_handle,
        sessions,
        team_state,
        usage_tracker,
        agent_manager,
        headless,
        pane_tracker,
        event_tx,
    });
    let heartbeat_task = tokio::spawn(run_heartbeat_staleness_watcher(
        ctx.clone(),
        shutdown_rx.clone(),
    ));
    // Phase 2.5: 1s coalesce → emit `agent_usage_tick` broadcasts (headless path).
    let usage_broadcast_task =
        tokio::spawn(run_usage_tick_broadcaster(ctx.clone(), shutdown_rx.clone()));
    // Phase 2.5-B: 1s JSONL-watcher → emit `agent_usage_tick` for pane-mode claude agents.
    let jsonl_usage_broadcast_task = tokio::spawn(run_jsonl_usage_tick_broadcaster(
        ctx.clone(),
        shutdown_rx.clone(),
    ));
    // Phase 2.5-C: 2s SQLite-poller → emit `agent_usage_tick` for pane-mode codex agents.
    let codex_usage_broadcast_task = tokio::spawn(run_codex_usage_tick_broadcaster(
        ctx.clone(),
        shutdown_rx.clone(),
    ));
    // Phase 2.5: 30s disk flush for dirty usage counters.
    let usage_flush_task = tokio::spawn(run_usage_disk_flusher(ctx.clone(), shutdown_rx.clone()));

    loop {
        tokio::select! {
            result = listener.accept() => {
                match result {
                    Ok((stream, _)) => {
                        if !peer_uid_matches(&stream, owner_uid) {
                            tracing::warn!("rejecting connection from foreign uid (only uid {owner_uid} may attach)");
                            drop(stream);
                            continue;
                        }
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
    heartbeat_task.abort();
    usage_broadcast_task.abort();
    jsonl_usage_broadcast_task.abort();
    codex_usage_broadcast_task.abort();
    usage_flush_task.abort();

    // Phase 2.5: final usage flush before exit (best-effort).
    {
        let mgr = ctx.headless.clone();
        let _ = tokio::task::spawn_blocking(move || {
            // We cannot `.lock().await` synchronously here; reuse the runtime's
            // current_thread executor via blocking_lock.
            let guard = mgr.blocking_lock();
            let flushed = guard.flush_dirty_usage();
            if flushed > 0 {
                tracing::info!("shutdown: flushed {flushed} usage record(s)");
            }
        })
        .await;
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

async fn handle_connection(stream: tokio::net::UnixStream, ctx: &Context) -> anyhow::Result<()> {
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

        // Streaming handlers hold the writer for their lifetime and must
        // exit handle_connection entirely — they cannot share the loop.
        if req.method == "events.subscribe" {
            return stream_subscribe_events(req, writer, ctx).await;
        }

        let resp = dispatch(&req, ctx).await;

        let mut buf = serde_json::to_vec(&resp)?;
        buf.push(b'\n');
        timeout(Duration::from_secs(5), writer.write_all(&buf))
            .await
            .map_err(|_| anyhow::anyhow!("write timeout"))??;
    }

    Ok(())
}

/// Streaming handler for `events.subscribe`. Takes ownership of the writer and
/// streams JSONL events until the timeout expires or the client disconnects.
/// Streaming handler for `events.subscribe`. Takes ownership of the writer and
/// streams JSONL events until the timeout expires or the client disconnects.
///
/// W-2: real task_status and reply events via broadcast channel + keepalive every 30 s.
async fn stream_subscribe_events(
    req: Request,
    mut writer: tokio::net::unix::OwnedWriteHalf,
    ctx: &Context,
) -> anyhow::Result<()> {
    #[derive(serde::Deserialize, Default)]
    struct SubscribeParams {
        #[serde(default)]
        kinds: Option<Vec<String>>,
        #[serde(default)]
        timeout: Option<u64>,
        #[serde(default)]
        leader_session_id: Option<String>,
    }
    let p: SubscribeParams = serde_json::from_value(req.params.clone()).unwrap_or_default();
    let timeout_secs = p.timeout.unwrap_or(0);
    let filter_kinds: std::collections::HashSet<String> = p
        .kinds
        .unwrap_or_else(|| {
            vec![
                "task_status".into(),
                "reply".into(),
                "heartbeat_stale".into(),
                "agent_usage_tick".into(),
            ]
        })
        .into_iter()
        .collect();
    let leader_session_id = p.leader_session_id;

    // Subscribe before sending the ack so we don't miss events that fire
    // immediately after the client receives the ack.
    let mut event_rx = ctx.event_tx.subscribe();

    // Send initial subscription ack.
    let ack = serde_json::json!({
        "id": req.id,
        "result": {
            "status": "subscribed",
            "filter": filter_kinds.iter().collect::<Vec<_>>(),
            "leader_session_id": leader_session_id,
        },
        "error": null,
    });
    let mut buf = serde_json::to_vec(&ack)?;
    buf.push(b'\n');
    timeout(Duration::from_secs(5), writer.write_all(&buf))
        .await
        .map_err(|_| anyhow::anyhow!("ack write timeout"))??;

    let deadline = if timeout_secs > 0 {
        Some(tokio::time::Instant::now() + Duration::from_secs(timeout_secs))
    } else {
        None
    };

    // Keepalive every 30 s. Always sent regardless of filter for connection health.
    let mut ping_interval = tokio::time::interval(Duration::from_secs(30));
    ping_interval.tick().await; // consume immediate first tick

    loop {
        let ts_ms = || {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as u64
        };

        // Three-way select: deadline | keepalive ping | real event.
        let line: Option<Vec<u8>> = if let Some(dl) = deadline {
            tokio::select! {
                _ = tokio::time::sleep_until(dl) => break,
                _ = ping_interval.tick() => {
                    Some(serde_json::to_vec(&serde_json::json!({"kind":"keepalive","ts_ms":ts_ms()}))?)
                }
                recv = event_rx.recv() => {
                    match recv {
                        Ok(ev) => filter_and_serialize(&ev, &filter_kinds, leader_session_id.as_deref()),
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!("events.subscribe: lagged by {n} events");
                            None
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    }
                }
            }
        } else {
            tokio::select! {
                _ = ping_interval.tick() => {
                    Some(serde_json::to_vec(&serde_json::json!({"kind":"keepalive","ts_ms":ts_ms()}))?)
                }
                recv = event_rx.recv() => {
                    match recv {
                        Ok(ev) => filter_and_serialize(&ev, &filter_kinds, leader_session_id.as_deref()),
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!("events.subscribe: lagged by {n} events");
                            None
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    }
                }
            }
        };

        if let Some(mut payload) = line {
            payload.push(b'\n');
            if timeout(Duration::from_secs(5), writer.write_all(&payload))
                .await
                .is_err()
            {
                break; // client disconnected or write timed out
            }
        }
    }

    Ok(())
}

/// Serialize `ev` to JSONL bytes if its kind is in `filter_kinds` and (when
/// `leader_session_id` is set) matches the event's team/agent scope. Returns
/// `None` if the event should be suppressed for this subscriber.
fn filter_and_serialize(
    ev: &DaemonEvent,
    filter_kinds: &std::collections::HashSet<String>,
    _leader_session_id: Option<&str>,
) -> Option<Vec<u8>> {
    let kind = match ev {
        DaemonEvent::TaskStatus { .. } => "task_status",
        DaemonEvent::Reply { .. } => "reply",
        DaemonEvent::HeartbeatStale { .. } => "heartbeat_stale",
        DaemonEvent::AgentUsageTick { .. } => "agent_usage_tick",
    };
    if !filter_kinds.is_empty() && !filter_kinds.contains(kind) {
        return None;
    }
    // leader_session_id filtering is intentionally relaxed in W-2: any subscriber
    // without a leader_session_id filter receives all events (generous default).
    // Per-leader scoping can be tightened in a follow-up without protocol changes.
    serde_json::to_vec(ev).ok()
}

/// Phase 2.5: every 1s, ask the headless manager which agents have a dirty
/// usage counter and emit `agent_usage_tick` for each team that has at least
/// one. Coalesces all stream-json increments observed in the past second.
async fn run_usage_tick_broadcaster(ctx: Arc<Context>, mut shutdown_rx: watch::Receiver<bool>) {
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    interval.tick().await; // consume immediate first tick

    loop {
        tokio::select! {
            _ = interval.tick() => {
                let teams = {
                    let mgr = ctx.headless.lock().await;
                    mgr.collect_usage_tick()
                };
                if teams.is_empty() {
                    continue;
                }
                let ts_ms = current_time_ms();
                for t in teams {
                    let _ = ctx.event_tx.send(DaemonEvent::AgentUsageTick {
                        team_uuid: t.team_uuid,
                        team_name: t.team_name,
                        agents: t.agents,
                        ts_ms,
                    });
                }
            }
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    break;
                }
            }
        }
    }
}

/// Phase 2.5-B: every 1s, match JSONL-tracked cumulative token stats to pane-mode
/// claude agents via `working_directory == project_path`. Emits `agent_usage_tick`
/// for any team that has at least one claude agent whose counters changed since the
/// previous tick.  Pane-mode agents share the team cwd so all receive the same
/// aggregate (R4 v2-deferred: per-agent attribution is deferred).
/// Reserved agent name used to attribute usage-tick data to a team's leader
/// pane. The leader is not a member of the `agents` array, so it is broadcast
/// under this sentinel name; the Swift sidebar renders it as a dedicated row.
const LEADER_USAGE_NAME: &str = "__leader__";

async fn run_jsonl_usage_tick_broadcaster(
    ctx: Arc<Context>,
    mut shutdown_rx: watch::Receiver<bool>,
) {
    // (team_name, agent_name) → last-emitted (input, output, cache_read, cache_write)
    let mut last_emitted: HashMap<(String, String), (u64, u64, u64, u64)> = HashMap::new();
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    interval.tick().await; // skip the immediate first tick

    loop {
        tokio::select! {
            _ = interval.tick() => {
                let pane_map = ctx.pane_tracker.snapshot();
                let claude_panes: Vec<(String, String, i64, u32)> = pane_map
                    .iter()
                    .filter(|(_, info)| info.cli == "claude")
                    .map(|(id, info)| {
                        (id.clone(), info.cwd.clone(), info.proc_start_unix, info.pid)
                    })
                    .collect();
                if claude_panes.is_empty() {
                    continue;
                }
                let by_panel = ctx.usage_tracker.snapshot_by_panel(&claude_panes);
                if by_panel.is_empty() {
                    continue;
                }
                let team_state = ctx.team_state.read().unwrap().clone();
                let Some(teams) = team_state.get("teams").and_then(|v| v.as_array()) else {
                    continue;
                };
                let ts_ms = current_time_ms();
                for team in teams {
                    let team_name = team
                        .get("team_name")
                        .or_else(|| team.get("name"))
                        .and_then(|v| v.as_str())
                        .unwrap_or_default();
                    if team_name.is_empty() {
                        continue;
                    }
                    // For pane-mode teams the team_uuid is not stored separately;
                    // reuse team_name as the uuid (matches existing Swift handler contract).
                    let team_uuid = team
                        .get("team_uuid")
                        .and_then(|v| v.as_str())
                        .unwrap_or(team_name);
                    let Some(agents) = team.get("agents").and_then(|v| v.as_array()) else {
                        continue;
                    };
                    let mut tick_agents = Vec::new();
                    for agent in agents {
                        let cli = agent
                            .get("cli")
                            .and_then(|v| v.as_str())
                            .unwrap_or_default();
                        if cli != "claude" {
                            continue;
                        }
                        // Pane-mode only: headless agents lack panel_id.
                        let panel_id = match agent.get("panel_id").and_then(|v| v.as_str()) {
                            Some(id) if !id.is_empty() => id,
                            _ => continue,
                        };
                        // Skip until pane_tracker has confirmed this panel AND
                        // start-time correlation has matched it to a session.
                        let Some(&(in_tok, out_tok, cr_tok, cw_tok)) = by_panel.get(panel_id) else {
                            continue;
                        };
                        let agent_name = agent
                            .get("name")
                            .or_else(|| agent.get("agent_name"))
                            .and_then(|v| v.as_str())
                            .unwrap_or_default();
                        if agent_name.is_empty() {
                            continue;
                        }
                        let key = (team_name.to_string(), agent_name.to_string());
                        let last = last_emitted.get(&key).copied().unwrap_or_default();
                        if (in_tok, out_tok, cr_tok, cw_tok) == last {
                            continue;
                        }
                        last_emitted.insert(key, (in_tok, out_tok, cr_tok, cw_tok));
                        tick_agents.push(crate::headless::UsageTickAgent {
                            name: agent_name.to_string(),
                            input_tokens: in_tok,
                            output_tokens: out_tok,
                            cache_read_input_tokens: cr_tok,
                            cache_creation_input_tokens: cw_tok,
                        });
                    }
                    // Leader pane: runs its own claude session but is not part of
                    // the `agents` array. Attribute its usage under the reserved
                    // LEADER_USAGE_NAME sentinel so the sidebar can show a leader row.
                    if team.get("leader_cli").and_then(|v| v.as_str()) == Some("claude") {
                        if let Some(leader_panel) = team
                            .get("leader_panel_id")
                            .and_then(|v| v.as_str())
                            .filter(|id| !id.is_empty())
                        {
                            if let Some(&(in_tok, out_tok, cr_tok, cw_tok)) =
                                by_panel.get(leader_panel)
                            {
                                let key = (team_name.to_string(), LEADER_USAGE_NAME.to_string());
                                let last = last_emitted.get(&key).copied().unwrap_or_default();
                                if (in_tok, out_tok, cr_tok, cw_tok) != last {
                                    last_emitted.insert(key, (in_tok, out_tok, cr_tok, cw_tok));
                                    tick_agents.push(crate::headless::UsageTickAgent {
                                        name: LEADER_USAGE_NAME.to_string(),
                                        input_tokens: in_tok,
                                        output_tokens: out_tok,
                                        cache_read_input_tokens: cr_tok,
                                        cache_creation_input_tokens: cw_tok,
                                    });
                                }
                            }
                        }
                    }
                    if !tick_agents.is_empty() {
                        let _ = ctx.event_tx.send(DaemonEvent::AgentUsageTick {
                            team_uuid: team_uuid.to_string(),
                            team_name: team_name.to_string(),
                            agents: tick_agents,
                            ts_ms,
                        });
                    }
                }
            }
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    break;
                }
            }
        }
    }
}

/// Phase 2.5-C: every 2s, query ~/.codex/state_5.sqlite for pane-mode codex agents.
/// Codex does not split input/output tokens; total is reported as output_tokens.
/// Disabled silently if the DB file does not exist (codex not installed).
async fn run_codex_usage_tick_broadcaster(
    ctx: Arc<Context>,
    mut shutdown_rx: watch::Receiver<bool>,
) {
    let Some(tracker) = crate::codex_tokens::CodexUsageTracker::new() else {
        tracing::info!("codex.token.watch: ~/.codex/sessions not found, broadcaster disabled");
        return;
    };
    tracing::info!("codex.token.watch: started polling ~/.codex/sessions rollout JSONL");

    // (team_name, agent_name) → last-emitted (input, output, cache_read, cache_write)
    let mut last_emitted: HashMap<(String, String), (u64, u64, u64, u64)> = HashMap::new();
    let mut interval = tokio::time::interval(Duration::from_secs(2));
    interval.tick().await; // skip immediate first tick

    loop {
        tokio::select! {
            _ = interval.tick() => {
                let pane_map = ctx.pane_tracker.snapshot();
                let codex_panes: Vec<(String, String, i64, u32)> = pane_map
                    .iter()
                    .filter(|(_, info)| info.cli == "codex")
                    .map(|(id, info)| {
                        (id.clone(), info.cwd.clone(), info.proc_start_unix, info.pid)
                    })
                    .collect();
                if codex_panes.is_empty() {
                    continue;
                }
                let by_panel = match tracker.snapshot_by_panel(&codex_panes) {
                    Ok(m) => m,
                    Err(e) => {
                        tracing::debug!("codex.token.parse.skip reason=scan_error: {e}");
                        continue;
                    }
                };
                if by_panel.is_empty() {
                    continue;
                }
                let team_state = ctx.team_state.read().unwrap().clone();
                let Some(teams) = team_state.get("teams").and_then(|v| v.as_array()) else {
                    continue;
                };
                let ts_ms = current_time_ms();
                for team in teams {
                    let team_name = team
                        .get("team_name")
                        .or_else(|| team.get("name"))
                        .and_then(|v| v.as_str())
                        .unwrap_or_default();
                    if team_name.is_empty() {
                        continue;
                    }
                    let team_uuid = team
                        .get("team_uuid")
                        .and_then(|v| v.as_str())
                        .unwrap_or(team_name);
                    let Some(agents) = team.get("agents").and_then(|v| v.as_array()) else {
                        continue;
                    };
                    let mut tick_agents = Vec::new();
                    for agent in agents {
                        let cli = agent
                            .get("cli")
                            .and_then(|v| v.as_str())
                            .unwrap_or_default();
                        if cli != "codex" {
                            continue;
                        }
                        // Pane-mode only: headless codex agents handled separately.
                        let panel_id = match agent.get("panel_id").and_then(|v| v.as_str()) {
                            Some(id) if !id.is_empty() => id,
                            _ => continue,
                        };
                        // Skip until pane_tracker has confirmed this panel AND
                        // start-time correlation has matched it to a Codex session.
                        let Some(&(in_tok, out_tok, cr_tok, cw_tok)) = by_panel.get(panel_id)
                        else {
                            continue;
                        };
                        let agent_name = agent
                            .get("name")
                            .or_else(|| agent.get("agent_name"))
                            .and_then(|v| v.as_str())
                            .unwrap_or_default();
                        if agent_name.is_empty() {
                            continue;
                        }
                        let key = (team_name.to_string(), agent_name.to_string());
                        let last = last_emitted.get(&key).copied().unwrap_or_default();
                        if (in_tok, out_tok, cr_tok, cw_tok) == last {
                            continue;
                        }
                        last_emitted.insert(key, (in_tok, out_tok, cr_tok, cw_tok));
                        tracing::debug!(
                            "codex.token.update agent={agent_name} panel={panel_id} \
                             in={in_tok} out={out_tok} cache_read={cr_tok}"
                        );
                        // Rollout JSONL splits usage: input / output(+reasoning) /
                        // cached_input → cache_read. Codex has no cache-write.
                        tick_agents.push(crate::headless::UsageTickAgent {
                            name: agent_name.to_string(),
                            input_tokens: in_tok,
                            output_tokens: out_tok,
                            cache_read_input_tokens: cr_tok,
                            cache_creation_input_tokens: cw_tok,
                        });
                    }
                    if !tick_agents.is_empty() {
                        let _ = ctx.event_tx.send(DaemonEvent::AgentUsageTick {
                            team_uuid: team_uuid.to_string(),
                            team_name: team_name.to_string(),
                            agents: tick_agents,
                            ts_ms,
                        });
                    }
                }
            }
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    break;
                }
            }
        }
    }
}

/// Phase 2.5: every 30s, flush dirty usage counters to `agent.json` on disk.
/// Disk I/O runs on `spawn_blocking` so the socket runtime is not stalled.
async fn run_usage_disk_flusher(ctx: Arc<Context>, mut shutdown_rx: watch::Receiver<bool>) {
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    interval.tick().await; // skip immediate tick

    loop {
        tokio::select! {
            _ = interval.tick() => {
                let mgr = ctx.headless.clone();
                let _ = tokio::task::spawn_blocking(move || {
                    let guard = mgr.blocking_lock();
                    let flushed = guard.flush_dirty_usage();
                    if flushed > 0 {
                        tracing::debug!("usage flush: persisted {flushed} record(s)");
                    }
                })
                .await;
            }
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    break;
                }
            }
        }
    }
}

async fn run_heartbeat_staleness_watcher(
    ctx: Arc<Context>,
    mut shutdown_rx: watch::Receiver<bool>,
) {
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    interval.tick().await; // consume immediate first tick
    let mut notified = HashSet::new();

    loop {
        tokio::select! {
            _ = interval.tick() => {
                let now_ms = current_time_ms();
                let events = {
                    let team_state = ctx.team_state.read().unwrap();
                    collect_heartbeat_stale_events(&team_state, &mut notified, now_ms)
                };
                for ev in events {
                    let _ = ctx.event_tx.send(ev);
                }
            }
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    break;
                }
            }
        }
    }
}

fn collect_heartbeat_stale_events(
    team_state: &serde_json::Value,
    notified: &mut HashSet<String>,
    now_ms: u64,
) -> Vec<DaemonEvent> {
    const STALE_AFTER_SECONDS: u64 = 60;
    let mut active_keys = HashSet::new();
    let mut events = Vec::new();

    let Some(teams) = team_state
        .get("teams")
        .and_then(serde_json::Value::as_array)
    else {
        notified.clear();
        return events;
    };

    for team in teams {
        let team_name = team
            .get("team_name")
            .or_else(|| team.get("name"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default();
        if team_name.is_empty() {
            continue;
        }
        let Some(agents) = team.get("agents").and_then(serde_json::Value::as_array) else {
            continue;
        };

        for agent in agents {
            let agent_name = agent
                .get("name")
                .or_else(|| agent.get("agent_name"))
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default();
            if agent_name.is_empty() {
                continue;
            }

            let key = format!("{team_name}\0{agent_name}");
            active_keys.insert(key.clone());

            let Some(age_seconds) = json_u64(agent.get("heartbeat_age_seconds")) else {
                notified.remove(&key);
                continue;
            };

            if age_seconds < STALE_AFTER_SECONDS {
                notified.remove(&key);
                continue;
            }

            if notified.insert(key) {
                let last_heartbeat_ts = agent
                    .get("last_heartbeat_at")
                    .or_else(|| agent.get("last_heartbeat_ts"))
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_string)
                    .unwrap_or_else(|| {
                        iso8601_from_unix_secs(now_ms.saturating_sub(age_seconds * 1000) / 1000)
                    });
                events.push(DaemonEvent::HeartbeatStale {
                    team: team_name.to_string(),
                    agent: agent_name.to_string(),
                    last_heartbeat_ts,
                    age_seconds,
                });
            }
        }
    }

    notified.retain(|key| active_keys.contains(key));
    events
}

fn json_u64(value: Option<&serde_json::Value>) -> Option<u64> {
    match value? {
        serde_json::Value::Number(n) => n
            .as_u64()
            .or_else(|| n.as_i64().and_then(|v| v.try_into().ok())),
        serde_json::Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

fn current_time_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn iso8601_from_unix_secs(secs: u64) -> String {
    // Simple ISO 8601 UTC formatter without adding a chrono dependency.
    let s = secs % 60;
    let m = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let days = secs / 86400;
    let jd = days as i64 + 2440588; // 1970-01-01 = JD 2440588
    let p = jd + 68569;
    let q = 4 * p / 146097;
    let r = p - (146097 * q + 3) / 4;
    let s2 = 4000 * (r + 1) / 1461001;
    let r2 = r - 1461 * s2 / 4 + 31;
    let month = 80 * r2 / 2447;
    let day = r2 - 2447 * month / 80;
    let month2 = month + 2 - 12 * (month / 11);
    let year = 100 * (q - 49) + s2 + month / 11;
    format!("{year:04}-{month2:02}-{day:02}T{h:02}:{m:02}:{s:02}Z")
}

async fn dispatch(req: &Request, ctx: &Context) -> Response {
    let result = match req.method.as_str() {
        // --- General ---
        "ping" => Ok(serde_json::json!({"status": "pong"})),

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
            struct SyncParams {
                sessions: Vec<SessionInfo>,
            }
            match serde_json::from_value::<SyncParams>(req.params.clone()) {
                Ok(p) => {
                    let count = p.sessions.len();
                    *ctx.sessions.write().unwrap() = p.sessions;
                    tracing::debug!("session.sync: {count} sessions");
                    Ok(serde_json::json!({"synced": count}))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "session.list" => {
            let sessions = ctx.sessions.read().unwrap().clone();
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
                    *ctx.team_state.write().unwrap() = synced;
                    tracing::debug!("team.sync: {:?}", counts);
                    Ok(counts)
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "team.get" => {
            let team_state = ctx.team_state.read().unwrap().clone();
            Ok(team_state)
        }

        // --- Worktree (F-01) ---
        // Wrapped in spawn_blocking: these call git via Command::output() (blocking I/O)
        // and must not run on the async tokio runtime thread.
        "worktree.create" => {
            let params = req.params.clone();
            tokio::task::spawn_blocking(move || {
                worktree::create(params).map(|v| serde_json::to_value(v).unwrap())
            })
            .await
            .unwrap_or_else(|e| Err(e.to_string()))
        }
        "worktree.remove" => {
            let params = req.params.clone();
            tokio::task::spawn_blocking(move || {
                worktree::remove(params).map(|_| serde_json::json!({"status": "ok"}))
            })
            .await
            .unwrap_or_else(|e| Err(e.to_string()))
        }
        "worktree.list" => {
            let params = req.params.clone();
            tokio::task::spawn_blocking(move || {
                worktree::list(params).map(|v| serde_json::to_value(v).unwrap())
            })
            .await
            .unwrap_or_else(|e| Err(e.to_string()))
        }
        "worktree.status" => {
            let params = req.params.clone();
            tokio::task::spawn_blocking(move || {
                worktree::status(params).map(|v| serde_json::to_value(v).unwrap())
            })
            .await
            .unwrap_or_else(|e| Err(e.to_string()))
        }
        "worktree.safe_remove" => {
            let params = req.params.clone();
            tokio::task::spawn_blocking(move || {
                worktree::safe_remove(params).map(|_| serde_json::json!({"status": "ok"}))
            })
            .await
            .unwrap_or_else(|e| Err(e.to_string()))
        }
        "worktree.list_branches" => {
            let params = req.params.clone();
            tokio::task::spawn_blocking(move || {
                worktree::list_branches(params).map(|v| serde_json::to_value(v).unwrap())
            })
            .await
            .unwrap_or_else(|e| Err(e.to_string()))
        }

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
                    // Inject agent anomalies computed from task/session state.
                    let extra_anomalies = compute_agent_anomalies(&ctx.agent_manager);
                    if !extra_anomalies.is_empty() {
                        let existing = value["anomalies"].as_array().cloned().unwrap_or_default();
                        let mut all = existing;
                        all.extend(
                            extra_anomalies
                                .into_iter()
                                .map(|a| serde_json::to_value(a).unwrap()),
                        );
                        value["anomalies"] = serde_json::json!(all);
                    }
                    Ok(value)
                }
                None => Ok(serde_json::json!({})),
            }
        }
        "monitor.track" => {
            #[derive(Deserialize)]
            struct TrackParams {
                pid: u32,
            }
            match serde_json::from_value::<TrackParams>(req.params.clone()) {
                Ok(p) => {
                    ctx.monitor_handle.track_pid(p.pid);
                    Ok(serde_json::json!({"status": "ok"}))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "monitor.untrack" => {
            #[derive(Deserialize)]
            struct UntrackParams {
                pid: u32,
            }
            match serde_json::from_value::<UntrackParams>(req.params.clone()) {
                Ok(p) => {
                    ctx.monitor_handle.untrack_pid(p.pid);
                    Ok(serde_json::json!({"status": "ok"}))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "monitor.tracked" => {
            let pids = ctx.monitor_handle.tracked_pids();
            Ok(serde_json::to_value(pids).unwrap())
        }
        "process.stop" => {
            #[derive(Deserialize)]
            struct StopParams {
                pid: u32,
            }
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
            struct ResumeParams {
                pid: u32,
            }
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
            struct AutoStopParams {
                enabled: bool,
            }
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
            struct WatchParams {
                path: String,
            }
            match serde_json::from_value::<WatchParams>(req.params.clone()) {
                Ok(p) => {
                    ctx.watcher_handle.watch_path(&p.path);
                    Ok(serde_json::json!({"status": "ok"}))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "watcher.unwatch" => {
            #[derive(Deserialize)]
            struct UnwatchParams {
                path: String,
            }
            match serde_json::from_value::<UnwatchParams>(req.params.clone()) {
                Ok(p) => {
                    ctx.watcher_handle.unwatch_path(&p.path);
                    Ok(serde_json::json!({"status": "ok"}))
                }
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
        "usage.scan" => match ctx.usage_tracker.scan_all() {
            Ok(_) => Ok(serde_json::json!({"status": "ok"})),
            Err(e) => Err(format!("scan error: {e}")),
        },

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
            let params: ListParams =
                serde_json::from_value(req.params.clone()).unwrap_or(ListParams {
                    include_terminated: false,
                });
            let sessions = ctx.agent_manager.list(params.include_terminated);
            Ok(serde_json::to_value(sessions).unwrap())
        }
        "agent.get" => {
            #[derive(Deserialize)]
            struct GetParams {
                id: String,
            }
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
                Ok(p) => {
                    let agent_manager = ctx.agent_manager.clone();
                    let watcher_handle = ctx.watcher_handle.clone();
                    match tokio::task::spawn_blocking(move || {
                        agent_manager.terminate(&p.id, p.force, &watcher_handle)
                    })
                    .await
                    {
                        Ok(Ok(())) => Ok(serde_json::json!({"status": "ok"})),
                        Ok(Err(e)) => Err(e),
                        Err(e) => Err(format!("agent terminate task failed: {e}")),
                    }
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "agent.bind_panel" => {
            #[derive(Deserialize)]
            struct BindParams {
                session_id: String,
                panel_id: String,
            }
            match serde_json::from_value::<BindParams>(req.params.clone()) {
                Ok(p) => ctx
                    .agent_manager
                    .bind_panel(&p.session_id, &p.panel_id)
                    .map(|_| serde_json::json!({"status": "ok"})),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "agent.unbind_panel" => {
            #[derive(Deserialize)]
            struct UnbindParams {
                session_id: String,
            }
            match serde_json::from_value::<UnbindParams>(req.params.clone()) {
                Ok(p) => ctx
                    .agent_manager
                    .unbind_panel(&p.session_id)
                    .map(|_| serde_json::json!({"status": "ok"})),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "agent.add_pid" => {
            #[derive(Deserialize)]
            struct AddPidParams {
                session_id: String,
                pid: u32,
            }
            match serde_json::from_value::<AddPidParams>(req.params.clone()) {
                Ok(p) => ctx
                    .agent_manager
                    .add_pid(&p.session_id, p.pid)
                    .map(|_| serde_json::json!({"status": "ok"})),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }

        // --- Tasks (F-06 Phase 2) ---
        "task.create" => {
            match serde_json::from_value::<crate::agent::TaskCreateParams>(req.params.clone()) {
                Ok(p) => ctx
                    .agent_manager
                    .task_create(p)
                    .map(|t| serde_json::to_value(t).unwrap()),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "task.get" => {
            #[derive(Deserialize)]
            struct P {
                id: String,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => ctx
                    .agent_manager
                    .task_get(&p.id)
                    .map(|t| serde_json::to_value(t).unwrap()),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "task.list" => {
            let params: crate::agent::TaskListParams = serde_json::from_value(req.params.clone())
                .unwrap_or(crate::agent::TaskListParams {
                    status: None,
                    assignee: None,
                });
            let tasks = ctx.agent_manager.task_list(params);
            Ok(serde_json::to_value(tasks).unwrap())
        }
        "task.update" => {
            match serde_json::from_value::<crate::agent::TaskUpdateParams>(req.params.clone()) {
                Ok(p) => {
                    // Snapshot old status before the update so we can include
                    // it in the broadcast event for subscribers.
                    let prev_status = if p.status.is_some() {
                        ctx.agent_manager
                            .task_get(&p.id)
                            .ok()
                            .map(|t| t.status.as_str().to_string())
                            .unwrap_or_default()
                    } else {
                        String::new()
                    };
                    ctx.agent_manager.task_update(p).map(|t| {
                        // Emit only when status actually changed.
                        if !prev_status.is_empty() && prev_status != t.status.as_str() {
                            let ev = DaemonEvent::TaskStatus {
                                team: String::new(),
                                agent: t.assignee.clone().unwrap_or_default(),
                                task_id: t.id.clone(),
                                status: t.status.as_str().to_string(),
                                prev_status,
                                ts_ms: std::time::SystemTime::now()
                                    .duration_since(std::time::UNIX_EPOCH)
                                    .unwrap_or_default()
                                    .as_millis() as u64,
                            };
                            // Err means no subscribers — fine to ignore.
                            let _ = ctx.event_tx.send(ev);
                        }
                        serde_json::to_value(t).unwrap()
                    })
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "task.assign" => {
            match serde_json::from_value::<crate::agent::TaskAssignParams>(req.params.clone()) {
                Ok(p) => ctx
                    .agent_manager
                    .task_assign(p)
                    .map(|t| serde_json::to_value(t).unwrap()),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "task.log" => {
            #[derive(Deserialize)]
            struct P {
                task_id: String,
                #[serde(default)]
                limit: Option<i64>,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let entries = ctx.agent_manager.task_log(&p.task_id, p.limit);
                    Ok(serde_json::to_value(entries).unwrap())
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }

        // --- Auto-Fix Budget ---
        "task.fix_attempt" => {
            #[derive(Deserialize)]
            struct P {
                task_id: String,
                agent_name: String,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => ctx
                    .agent_manager
                    .task_fix_attempt(&p.task_id, &p.agent_name)
                    .map(|r| serde_json::to_value(r).unwrap()),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }

        // --- Messages (F-06 Phase 2) ---
        "message.send" => {
            match serde_json::from_value::<crate::agent::MessageSendParams>(req.params.clone()) {
                Ok(p) => {
                    let from = p.from_agent.clone().unwrap_or_default();
                    let content_preview = p.content.chars().take(200).collect::<String>();
                    ctx.agent_manager.message_send(p).map(|m| {
                        let ev = DaemonEvent::Reply {
                            team: String::new(),
                            agent: from,
                            task_id: String::new(),
                            header: content_preview,
                            ts_ms: std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .unwrap_or_default()
                                .as_millis() as u64,
                        };
                        let _ = ctx.event_tx.send(ev);
                        serde_json::to_value(m).unwrap()
                    })
                }
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
                Ok(p) => ctx
                    .agent_manager
                    .message_ack(&p.message_ids)
                    .map(|n| serde_json::json!({"acknowledged": n})),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }

        // --- Pending Input (PTY injection via Swift polling) ---
        "input.enqueue" => {
            #[derive(Deserialize)]
            struct P {
                session_id: String,
                text: String,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => ctx
                    .agent_manager
                    .enqueue_input(&p.session_id, &p.text)
                    .map(|_| serde_json::json!({"status": "ok"})),
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "input.poll" => {
            let inputs = ctx.agent_manager.poll_inputs();
            Ok(serde_json::to_value(inputs).unwrap())
        }

        // --- Headless Agents ---
        "headless.spawn" => {
            match serde_json::from_value::<crate::headless::SpawnParams>(req.params.clone()) {
                Ok(p) => {
                    let mut mgr = ctx.headless.lock().await;
                    match mgr.spawn_agent(p).await {
                        Ok(info) => Ok(serde_json::to_value(info).unwrap()),
                        Err(e) => Err(e),
                    }
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "headless.send" => {
            #[derive(Deserialize)]
            struct P {
                agent_id: String,
                text: String,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let mut mgr = ctx.headless.lock().await;
                    mgr.send_message(&p.agent_id, &p.text)
                        .await
                        .map(|_| serde_json::json!({"status": "ok"}))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "headless.read" => {
            #[derive(Deserialize)]
            struct P {
                agent_id: String,
                #[serde(default = "default_lines")]
                lines: usize,
            }
            fn default_lines() -> usize {
                50
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let mgr = ctx.headless.lock().await;
                    mgr.read_output(&p.agent_id, p.lines)
                        .await
                        .map(|lines| serde_json::json!({ "lines": lines, "count": lines.len() }))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "headless.terminate" => {
            #[derive(Deserialize)]
            struct P {
                agent_id: String,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let mut mgr = ctx.headless.lock().await;
                    mgr.terminate(&p.agent_id)
                        .await
                        .map(|_| serde_json::json!({"status": "ok"}))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "headless.status" => {
            #[derive(Deserialize)]
            struct P {
                agent_id: String,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let mgr = ctx.headless.lock().await;
                    mgr.status(&p.agent_id)
                        .await
                        .map(|info| serde_json::to_value(info).unwrap())
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "headless.list" => {
            #[derive(Deserialize)]
            struct P {
                #[serde(default)]
                team_name: Option<String>,
            }
            let params: P =
                serde_json::from_value(req.params.clone()).unwrap_or(P { team_name: None });
            let mgr = ctx.headless.lock().await;
            let agents = mgr.list(params.team_name.as_deref()).await;
            Ok(serde_json::to_value(agents).unwrap())
        }
        "headless.create_team" => {
            match serde_json::from_value::<crate::headless::TeamCreateParams>(req.params.clone()) {
                Ok(p) => {
                    let mut mgr = ctx.headless.lock().await;
                    match mgr.create_team(p).await {
                        Ok(team) => Ok(serde_json::to_value(team).unwrap()),
                        Err(e) => Err(e),
                    }
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "headless.destroy_team" => {
            #[derive(Deserialize)]
            struct P {
                team_name: String,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let mut mgr = ctx.headless.lock().await;
                    mgr.destroy_team(&p.team_name).await.map(|res| {
                        serde_json::json!({
                            "status": "ok",
                            "team_uuid": res.team_uuid,
                            "archived_path": res.archived_path,
                        })
                    })
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "headless.list_resumable" => {
            #[derive(Deserialize)]
            struct P {
                #[serde(default)]
                git_root: Option<String>,
                #[serde(default = "default_limit")]
                limit: usize,
            }
            fn default_limit() -> usize {
                50
            }
            let params: P = serde_json::from_value(req.params.clone()).unwrap_or(P {
                git_root: None,
                limit: 50,
            });
            let limit = params.limit.min(200);
            let mgr = ctx.headless.lock().await;
            let res = mgr.list_resumable(params.git_root.as_deref(), limit);
            if let Some(err) = res.fatal_error.as_ref() {
                Err(err.clone())
            } else {
                Ok(serde_json::to_value(res).unwrap())
            }
        }
        "headless.resume_team" => {
            match serde_json::from_value::<crate::headless::ResumeTeamParams>(req.params.clone()) {
                Ok(p) => {
                    let mut mgr = ctx.headless.lock().await;
                    mgr.resume_team(p)
                        .await
                        .map(|r| serde_json::to_value(r).unwrap())
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "team.archive_pane" => {
            // pane-mode counterpart of headless `destroy_team`'s archive step.
            // Called by the Swift app from `TeamOrchestrator.destroyTeam` so a
            // pane-mode team shows up in `list_resumable` with `mode: "pane"`.
            match serde_json::from_value::<crate::headless::ArchivePaneParams>(req.params.clone()) {
                Ok(p) => {
                    let mut mgr = ctx.headless.lock().await;
                    mgr.archive_pane_team(p)
                        .map(|r| serde_json::to_value(r).unwrap())
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "team.resume_pane" => {
            // pane-mode resume: returns metadata + session IDs so the Swift app
            // can recreate the workspace and spawn each CLI with `--resume <sid>`.
            // Does NOT spawn anything — the daemon owns headless subprocesses,
            // the app owns pane lifecycles.
            match serde_json::from_value::<crate::headless::ResumePaneParams>(req.params.clone()) {
                Ok(p) => {
                    let mgr = ctx.headless.lock().await;
                    mgr.resume_pane(p)
                        .map(|r| serde_json::to_value(r).unwrap())
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "team.delete_archive" => {
            // On-demand archive removal from the resume picker. Works for both
            // pane-mode and headless archives — both live in the same directory.
            match serde_json::from_value::<crate::headless::DeleteArchiveParams>(req.params.clone()) {
                Ok(p) => {
                    let mgr = ctx.headless.lock().await;
                    mgr.delete_archive(p)
                        .map(|r| serde_json::to_value(r).unwrap())
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "headless.set_idle_park_minutes" => {
            #[derive(Deserialize)]
            struct P {
                minutes: u32,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let mut mgr = ctx.headless.lock().await;
                    mgr.set_idle_park_minutes(p.minutes).map(|_| {
                        serde_json::json!({
                            "minutes": p.minutes,
                            "active": p.minutes > 0,
                        })
                    })
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "headless.park_agent" => {
            #[derive(Deserialize)]
            struct P {
                team_name: String,
                agent_name: String,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let mut mgr = ctx.headless.lock().await;
                    mgr.park_agent(&p.team_name, &p.agent_name)
                        .await
                        .map(|r| serde_json::to_value(r).unwrap())
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "headless.unpark_agent" => {
            #[derive(Deserialize)]
            struct P {
                team_name: String,
                agent_name: String,
                #[serde(default)]
                app_socket_path: Option<String>,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let mut mgr = ctx.headless.lock().await;
                    mgr.unpark_agent(&p.team_name, &p.agent_name, p.app_socket_path.as_deref())
                        .await
                        .map(|info| {
                            let mut v = serde_json::to_value(info).unwrap();
                            if let Some(obj) = v.as_object_mut() {
                                obj.insert("unparked".into(), serde_json::Value::Bool(true));
                            }
                            v
                        })
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "headless.list_teams" => {
            let mgr = ctx.headless.lock().await;
            let teams = mgr.list_teams();
            Ok(serde_json::to_value(teams).unwrap())
        }
        "headless.add_agent" => {
            #[derive(Deserialize)]
            struct P {
                team_name: String,
                name: String,
                #[serde(default = "default_cli")]
                cli: String,
                #[serde(default = "default_model")]
                model: String,
                #[serde(default)]
                cli_path: Option<String>,
                #[serde(default)]
                app_socket_path: Option<String>,
                #[serde(default)]
                instructions: Option<String>,
            }
            fn default_cli() -> String {
                "claude".into()
            }
            fn default_model() -> String {
                "sonnet".into()
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let spec = crate::headless::AgentSpec {
                        name: p.name,
                        cli: p.cli,
                        model: p.model,
                        cli_path: p.cli_path,
                        instructions: p.instructions,
                        agent_type: None,
                        color: None,
                    };
                    let mut mgr = ctx.headless.lock().await;
                    match mgr
                        .add_agent(&p.team_name, spec, p.app_socket_path.as_deref())
                        .await
                    {
                        Ok(info) => Ok(serde_json::to_value(info).unwrap()),
                        Err(e) => Err(e),
                    }
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "headless.resolve" => {
            #[derive(Deserialize)]
            struct P {
                team_name: String,
                agent_name: String,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let mgr = ctx.headless.lock().await;
                    match mgr.resolve_agent_id(&p.team_name, &p.agent_name) {
                        Some(id) => Ok(serde_json::json!({ "agent_id": id, "headless": true })),
                        None => Ok(serde_json::json!({ "agent_id": null, "headless": false })),
                    }
                }
                Err(e) => Err(format!("invalid params: {e}")),
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

// ── Socket hardening helpers ──────────────────────────────────────────────────

#[cfg(unix)]
fn current_uid() -> u32 {
    unsafe { libc::getuid() }
}

#[cfg(not(unix))]
fn current_uid() -> u32 {
    0
}

/// Bind with umask(0o077) so the socket file is created at 0600 immediately,
/// eliminating the bind→chmod TOCTOU window.
#[cfg(unix)]
fn bind_with_tight_umask(path: &std::path::Path) -> std::io::Result<UnixListener> {
    let prev = unsafe { libc::umask(0o077) };
    let result = UnixListener::bind(path);
    unsafe { libc::umask(prev) };
    result
}

#[cfg(not(unix))]
fn bind_with_tight_umask(path: &std::path::Path) -> std::io::Result<UnixListener> {
    UnixListener::bind(path)
}

#[cfg(unix)]
fn harden_socket_permissions(path: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    if let Ok(metadata) = std::fs::metadata(path) {
        let mut perms = metadata.permissions();
        perms.set_mode(0o600);
        let _ = std::fs::set_permissions(path, perms);
    }
}

#[cfg(not(unix))]
fn harden_socket_permissions(_path: &std::path::Path) {}

/// Compare connected peer's effective uid against `expected_uid`.
/// Returns `true` only when positively confirmed; fails closed on any error.
#[cfg(target_os = "macos")]
fn peer_uid_matches(stream: &tokio::net::UnixStream, expected_uid: u32) -> bool {
    use std::os::fd::AsRawFd;

    #[repr(C)]
    struct Xucred {
        cr_version: libc::c_uint,
        cr_uid: libc::uid_t,
        cr_ngroups: libc::c_short,
        cr_groups: [libc::gid_t; 16],
    }
    const LOCAL_PEERCRED: libc::c_int = 0x001;
    const SOL_LOCAL: libc::c_int = 0;

    let fd = stream.as_raw_fd();
    let mut cred = std::mem::MaybeUninit::<Xucred>::zeroed();
    let mut len = std::mem::size_of::<Xucred>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            fd,
            SOL_LOCAL,
            LOCAL_PEERCRED,
            cred.as_mut_ptr() as *mut libc::c_void,
            &mut len,
        )
    };
    if rc != 0 {
        return false;
    }
    let cred = unsafe { cred.assume_init() };
    cred.cr_uid == expected_uid
}

#[cfg(target_os = "linux")]
fn peer_uid_matches(stream: &tokio::net::UnixStream, expected_uid: u32) -> bool {
    use std::os::fd::AsRawFd;

    let fd = stream.as_raw_fd();
    let mut cred = std::mem::MaybeUninit::<libc::ucred>::zeroed();
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            cred.as_mut_ptr() as *mut libc::c_void,
            &mut len,
        )
    };
    if rc != 0 {
        return false;
    }
    let cred = unsafe { cred.assume_init() };
    cred.uid == expected_uid
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn peer_uid_matches(_stream: &tokio::net::UnixStream, _expected_uid: u32) -> bool {
    false
}

// ─────────────────────────────────────────────────────────────────────────────

/// Compute no_heartbeat and repeated_failure anomalies from daemon task state.
///
/// - no_heartbeat: in_progress tasks whose `updated_at_ms` is older than 5 minutes.
/// - repeated_failure: tasks where fix_count >= 3.
fn compute_agent_anomalies(agent_manager: &AgentSessionManager) -> Vec<Anomaly> {
    let params = crate::agent::TaskListParams {
        status: None,
        assignee: None,
    };
    let tasks = agent_manager.task_list(params);
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    let five_min_ms: u64 = 5 * 60 * 1000;

    let mut anomalies = Vec::new();
    let detected_at = {
        let secs = now_ms / 1000;
        let s = secs % 60;
        let m = (secs / 60) % 60;
        let h = (secs / 3600) % 24;
        let days = secs / 86400;
        let jd = days as i64 + 2440588;
        let p = jd + 68569;
        let q = 4 * p / 146097;
        let r = p - (146097 * q + 3) / 4;
        let s2 = 4000 * (r + 1) / 1461001;
        let r2 = r - 1461 * s2 / 4 + 31;
        let month = 80 * r2 / 2447;
        let day = r2 - 2447 * month / 80;
        let month2 = month + 2 - 12 * (month / 11);
        let year = 100 * (q - 49) + s2 + month / 11;
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
            year, month2, day, h, m, s
        )
    };

    for task in &tasks {
        // no_heartbeat: task is in_progress and hasn't been updated in 5+ minutes
        if matches!(task.status, crate::agent::TaskStatus::InProgress)
            && now_ms.saturating_sub(task.updated_at_ms) >= five_min_ms
        {
            let idle_mins = now_ms.saturating_sub(task.updated_at_ms) / 60_000;
            let agent_id = task.assignee.clone().unwrap_or_else(|| task.id.clone());
            anomalies.push(Anomaly {
                agent_id,
                kind: "no_heartbeat".into(),
                message: format!(
                    "Task '{}' (id={}) has been in_progress with no update for {}m",
                    task.title, task.id, idle_mins
                ),
                severity: if idle_mins >= 10 {
                    "critical".into()
                } else {
                    "warning".into()
                },
                detected_at: detected_at.clone(),
            });
        }

        // repeated_failure: fix_count >= 3
        if task.fix_count >= 3 {
            let agent_id = task.assignee.clone().unwrap_or_else(|| task.id.clone());
            anomalies.push(Anomaly {
                agent_id,
                kind: "repeated_failure".into(),
                message: format!(
                    "Task '{}' (id={}) has had {} fix attempts",
                    task.title, task.id, task.fix_count
                ),
                severity: if task.fix_count >= 5 {
                    "critical".into()
                } else {
                    "warning".into()
                },
                detected_at: detected_at.clone(),
            });
        }
    }

    anomalies
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn heartbeat_stale_event_emits_once_until_recovered() {
        let mut notified = HashSet::new();
        let state = json!({
            "teams": [{
                "team_name": "team-a",
                "agents": [{
                    "name": "agent-a",
                    "heartbeat_age_seconds": 65
                }]
            }]
        });

        let events = collect_heartbeat_stale_events(&state, &mut notified, 1_700_000_065_000);
        assert_eq!(events.len(), 1);
        match &events[0] {
            DaemonEvent::HeartbeatStale {
                team,
                agent,
                last_heartbeat_ts,
                age_seconds,
            } => {
                assert_eq!(team, "team-a");
                assert_eq!(agent, "agent-a");
                assert_eq!(last_heartbeat_ts, "2023-11-14T22:13:20Z");
                assert_eq!(*age_seconds, 65);
            }
            other => panic!("unexpected event: {other:?}"),
        }

        let duplicate = collect_heartbeat_stale_events(&state, &mut notified, 1_700_000_095_000);
        assert!(duplicate.is_empty());

        let recovered = json!({
            "teams": [{
                "team_name": "team-a",
                "agents": [{
                    "name": "agent-a",
                    "heartbeat_age_seconds": 2
                }]
            }]
        });
        assert!(
            collect_heartbeat_stale_events(&recovered, &mut notified, 1_700_000_097_000).is_empty()
        );

        let stale_again = collect_heartbeat_stale_events(&state, &mut notified, 1_700_000_125_000);
        assert_eq!(stale_again.len(), 1);
    }

    #[test]
    fn heartbeat_stale_event_prefers_payload_timestamp() {
        let mut notified = HashSet::new();
        let state = json!({
            "teams": [{
                "team_name": "team-a",
                "agents": [{
                    "name": "agent-a",
                    "heartbeat_age_seconds": 60,
                    "last_heartbeat_at": "2026-05-10T16:00:00Z"
                }]
            }]
        });

        let events = collect_heartbeat_stale_events(&state, &mut notified, 1_700_000_060_000);
        match &events[0] {
            DaemonEvent::HeartbeatStale {
                last_heartbeat_ts, ..
            } => assert_eq!(last_heartbeat_ts, "2026-05-10T16:00:00Z"),
            other => panic!("unexpected event: {other:?}"),
        }
    }
}
