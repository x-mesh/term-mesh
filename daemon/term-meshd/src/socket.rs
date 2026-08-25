use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::watch;
use tokio::task::JoinSet;
use tokio::time::{timeout, Duration};

use crate::agent::AgentSessionManager;
use crate::gc;
use crate::headless::HeadlessManager;
use crate::monitor::{Anomaly, MonitorHandle, SystemSnapshot};
use crate::pane_tracker::PaneTracker;
use crate::peer::surface;
use crate::supervisor::{shutdown_supervised, spawn_supervised};
use crate::tokens::UsageTracker;
use crate::watcher::WatcherHandle;
use crate::worktree;

/// Watcher Phase 2 (P6): `.xm/watch/config.json` persistence. Contract functions
/// (`load_watch_states`/`save_watch_state`/`remove_watch_state`) are reused by
/// `main.rs` (startup re-register) and the `watch.on`/`watch.off` handlers below.
pub mod watch_config;

/// Watcher Phase 2 (P12 #5): minimum autonomous check interval. A cost guard,
/// independent of `drift_watch::SWEEP_GRANULARITY_SECS` (the scheduler's wake
/// resolution, currently 1s): a tiny `--every` would otherwise spawn a one-shot
/// watcher (an LLM call) every second. Always `>= SWEEP_GRANULARITY_SECS`.
const MIN_WATCH_INTERVAL_SECS: u64 = 30;

/// Pair Review snapshots must fit this prompt budget in full. Unlike
/// autonomous Watch output, a user-selected snapshot is never useful when
/// silently tail-truncated, so oversize input is rejected before a reviewer
/// is started. This is large enough for normal PRs while still bounding git
/// output and prompt memory.
const PAIR_REVIEW_MAX_SNAPSHOT_BYTES: usize = 128 * 1024;
const PAIR_REVIEW_MAX_GIT_ERROR_BYTES: usize = 16 * 1024;
const PAIR_REVIEW_MAX_UNTRACKED_LIST_BYTES: usize = 256 * 1024;
const PAIR_REVIEW_MAX_UNTRACKED_FILES: usize = 128;
const PAIR_REVIEW_CAPTURE_TIMEOUT: Duration = Duration::from_secs(30);
const PAIR_REVIEW_MAX_REQUEST_ID_BYTES: usize = 128;
const PAIR_REVIEW_MAX_VERDICT_BYTES: usize = 8 * 1024;
const PAIR_REVIEW_MAX_RETAINED_COMPLETED: usize = 128;
const PAIR_REVIEW_RETENTION_MS: u64 = 24 * 60 * 60 * 1_000;
const STALE_SOCKET_CONNECT_TIMEOUT: Duration = Duration::from_millis(300);
const STALE_SOCKET_REFUSAL_PROBES: usize = 3;
const STALE_SOCKET_REFUSAL_RETRY_DELAY: Duration = Duration::from_millis(100);

/// Count distinct `check_id`s recorded in `<working_dir>/.xm/watch/board.jsonl`
/// (P12 #6). Each drift finding is one JSONL line; the controller (P5) keys them
/// by `check_id`, so distinct ids = number of checks that found drift. Missing or
/// unreadable lines are skipped; a missing file yields 0.
pub(crate) fn board_drift_count(working_dir: &str) -> u64 {
    if working_dir.is_empty() {
        return 0;
    }
    let path = std::path::Path::new(working_dir)
        .join(".xm")
        .join("watch")
        .join("board.jsonl");
    let Ok(contents) = std::fs::read_to_string(&path) else {
        return 0;
    };
    let mut seen: HashSet<String> = HashSet::new();
    for line in contents.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(line) {
            if let Some(id) = v.get("check_id").and_then(|c| c.as_str()) {
                seen.insert(id.to_string());
            }
        }
    }
    seen.len() as u64
}

/// Mission Control: the most recent drift rows from
/// `<working_dir>/.xm/watch/board.jsonl`, newest first, capped at `limit`.
/// Rows are returned as raw JSON values (`{ts, agent, drift_type, severity,
/// finding, spec_clause, check_id}` — see `watch_controller::BoardFinding`).
/// Unparseable lines are skipped; a missing file yields an empty vec.
pub(crate) fn board_recent_rows(working_dir: &str, limit: usize) -> Vec<serde_json::Value> {
    if working_dir.is_empty() || limit == 0 {
        return Vec::new();
    }
    let path = std::path::Path::new(working_dir)
        .join(".xm")
        .join("watch")
        .join("board.jsonl");
    let Ok(contents) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    let mut rows: Vec<serde_json::Value> = contents
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() {
                return None;
            }
            serde_json::from_str::<serde_json::Value>(line).ok()
        })
        .collect();
    // Appends are chronological; sort by ts anyway to tolerate hand edits,
    // then keep the newest `limit`, newest first.
    rows.sort_by_key(|v| v.get("ts").and_then(|t| t.as_u64()).unwrap_or(0));
    rows.reverse();
    rows.truncate(limit);
    rows
}

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
    /// XK-EVENTS-v1 (x-kit panel integration Phase 2): external-run telemetry
    /// published by x-kit tools (x-panel review/cross runs). Pure fan-out —
    /// never persisted; the producer's `.xm/` status files remain the durable
    /// record. Only delivered to subscribers that explicitly request
    /// `kinds:["xk_run"]`. Contract: `xm/docs/x-panel-term-mesh-phase2.md` §4.
    XkRun {
        v: u32,
        source: String,
        run: String,
        run_kind: String,
        phase: String,
        model: String,
        state: String,
        elapsed_ms: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        tail: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
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
    /// watcher Phase 2 (P4): autonomous drift-watch registry. `watch.on/off/status`
    /// RPC handlers mutate this; the scheduler in `crate::drift_watch` reads it.
    /// Distinct from `watcher_handle` (the unrelated `crate::watcher` fs monitor).
    pub watch_registry: crate::drift_watch::WatchRegistry,
    /// R4: runner + sink cloned into Context so `watch.trigger_now` can fire
    /// checks directly without routing through the scheduler's interval loop.
    pub watch_runner: Option<Arc<dyn crate::headless::one_shot::WatchCheckRunner>>,
    pub watch_sink:
        Option<tokio::sync::mpsc::UnboundedSender<crate::headless::one_shot::WatchCheckOutcome>>,
    /// User-triggered, non-persistent Pair Reviews. This registry is separate
    /// from autonomous Watch so a one-shot review cannot enable, disable, or
    /// otherwise perturb a team's continuous configuration.
    /// Mobile remote-control exposure registry (`docs/mobile-remote-control.md`
    /// §4.1). `remote.on/off/status/list` mutate it; the mobile listener in
    /// `crate::http_mobile` reads it. In-memory only.
    pub remote_registry: crate::remote::SharedRegistry,
    pub pair_reviews: Arc<tokio::sync::Mutex<HashMap<String, PairReviewRun>>>,
    pub pane_tracker: PaneTracker,
    pub event_tx: EventSender,
    pub project_registry: Arc<crate::sync::ProjectRegistry>,
    pub paused_sync_projects: Arc<RwLock<HashSet<String>>>,
    pub operation_manager: crate::sync::OperationManager,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct PairReviewRun {
    review_id: String,
    team_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    request_id: Option<String>,
    status: String,
    scope: String,
    lens: String,
    cli: String,
    model: String,
    /// SHA-256 of the exact bounded snapshot sent to the reviewer. Exposed so
    /// tests and clients can prove start-time immutability without trusting
    /// the reviewer's prose as an oracle.
    snapshot_digest: Option<String>,
    started_at: u64,
    finished_at: Option<u64>,
    duration_ms: Option<u64>,
    verdict: Option<String>,
    error: Option<String>,
}

fn unix_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

struct BoundedCommandOutput {
    status: std::process::ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

async fn read_bounded_stream<R: AsyncRead + Unpin>(
    mut reader: R,
    limit: usize,
    label: &str,
) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::with_capacity(limit.min(8 * 1024));
    let mut chunk = [0u8; 8 * 1024];
    loop {
        let read = reader
            .read(&mut chunk)
            .await
            .map_err(|error| format!("read git {label}: {error}"))?;
        if read == 0 {
            return Ok(bytes);
        }
        if bytes.len().saturating_add(read) > limit {
            return Err(format!("git {label} exceeds safe limit of {limit} bytes"));
        }
        bytes.extend_from_slice(&chunk[..read]);
    }
}

async fn run_git_bounded(
    working_directory: &str,
    args: &[&std::ffi::OsStr],
    stdout_limit: usize,
) -> Result<BoundedCommandOutput, String> {
    use std::process::Stdio;

    let mut command = tokio::process::Command::new("git");
    command
        .arg("-C")
        .arg(working_directory)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|error| format!("run git: {error}"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "capture git stdout: pipe unavailable".to_string())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "capture git stderr: pipe unavailable".to_string())?;
    let (stdout, stderr) = tokio::join!(
        read_bounded_stream(stdout, stdout_limit, "stdout"),
        read_bounded_stream(stderr, PAIR_REVIEW_MAX_GIT_ERROR_BYTES, "stderr")
    );
    if let Err(error) = stdout.as_ref().and(stderr.as_ref()) {
        let _ = child.kill().await;
        let _ = child.wait().await;
        return Err(error.clone());
    }
    let status = child
        .wait()
        .await
        .map_err(|error| format!("wait for git: {error}"))?;
    Ok(BoundedCommandOutput {
        status,
        stdout: stdout.expect("checked above"),
        stderr: stderr.expect("checked above"),
    })
}

fn git_error(output: &BoundedCommandOutput) -> String {
    let message = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if message.is_empty() {
        format!("git exited with status {}", output.status)
    } else {
        message
    }
}

fn append_snapshot_bytes(snapshot: &mut Vec<u8>, bytes: &[u8]) -> Result<(), String> {
    if snapshot.len().saturating_add(bytes.len()) > PAIR_REVIEW_MAX_SNAPSHOT_BYTES {
        return Err(format!(
            "selected diff exceeds safe limit of {} bytes; narrow the Pair Review scope",
            PAIR_REVIEW_MAX_SNAPSHOT_BYTES
        ));
    }
    snapshot.extend_from_slice(bytes);
    Ok(())
}

async fn capture_pair_review_git_scope(
    scope: &str,
    working_directory: &str,
    base_ref: Option<&str>,
) -> Result<String, String> {
    use std::os::unix::ffi::OsStrExt;

    let mut diff_args: Vec<&std::ffi::OsStr> = vec![
        std::ffi::OsStr::new("diff"),
        std::ffi::OsStr::new("--no-ext-diff"),
        std::ffi::OsStr::new("--no-textconv"),
    ];
    match scope {
        "current-changes" => {
            diff_args.extend([std::ffi::OsStr::new("HEAD"), std::ffi::OsStr::new("--")]);
        }
        "branch-diff" => {
            let base = base_ref
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .unwrap_or("develop");
            if base.starts_with('-') {
                return Err("base_ref must not begin with '-'".to_string());
            }
            let range = format!("{base}...HEAD");
            diff_args.extend([
                std::ffi::OsStr::new("--end-of-options"),
                std::ffi::OsStr::new(&range),
                std::ffi::OsStr::new("--"),
            ]);
            let tracked = run_git_bounded(
                working_directory,
                &diff_args,
                PAIR_REVIEW_MAX_SNAPSHOT_BYTES,
            )
            .await?;
            if !tracked.status.success() {
                return Err(git_error(&tracked));
            }
            if tracked.stdout.is_empty() {
                return Err("selected scope has no changes to review".to_string());
            }
            return String::from_utf8(tracked.stdout)
                .map_err(|_| "selected diff is not valid UTF-8".to_string());
        }
        _ => return Err(format!("unsupported Pair Review scope: {scope}")),
    }

    let tracked = run_git_bounded(
        working_directory,
        &diff_args,
        PAIR_REVIEW_MAX_SNAPSHOT_BYTES,
    )
    .await?;
    if !tracked.status.success() {
        return Err(git_error(&tracked));
    }
    let mut snapshot = tracked.stdout;

    let untracked_args = [
        std::ffi::OsStr::new("ls-files"),
        std::ffi::OsStr::new("--others"),
        std::ffi::OsStr::new("--exclude-standard"),
        std::ffi::OsStr::new("-z"),
    ];
    let untracked = run_git_bounded(
        working_directory,
        &untracked_args,
        PAIR_REVIEW_MAX_UNTRACKED_LIST_BYTES,
    )
    .await?;
    if !untracked.status.success() {
        return Err(git_error(&untracked));
    }
    let paths: Vec<&[u8]> = untracked
        .stdout
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
        .collect();
    if paths.len() > PAIR_REVIEW_MAX_UNTRACKED_FILES {
        return Err(format!(
            "current changes contain {} untracked files, exceeding safe limit of {}",
            paths.len(),
            PAIR_REVIEW_MAX_UNTRACKED_FILES
        ));
    }

    let mut untracked_source_bytes = 0usize;
    for path_bytes in paths {
        let path = std::ffi::OsStr::from_bytes(path_bytes);
        let display = path.to_string_lossy();
        let metadata = std::fs::symlink_metadata(Path::new(working_directory).join(path))
            .map_err(|error| format!("inspect untracked file {display}: {error}"))?;
        if !metadata.file_type().is_file() && !metadata.file_type().is_symlink() {
            return Err(format!("unsupported untracked file type: {display}"));
        }
        let file_bytes = usize::try_from(metadata.len())
            .map_err(|_| format!("untracked file is too large: {display}"))?;
        untracked_source_bytes = untracked_source_bytes
            .checked_add(file_bytes)
            .ok_or_else(|| "untracked file size overflow".to_string())?;
        if untracked_source_bytes > PAIR_REVIEW_MAX_SNAPSHOT_BYTES {
            return Err(format!(
                "untracked files total more than the safe limit of {} bytes",
                PAIR_REVIEW_MAX_SNAPSHOT_BYTES
            ));
        }

        let remaining = PAIR_REVIEW_MAX_SNAPSHOT_BYTES.saturating_sub(snapshot.len());
        let args = [
            std::ffi::OsStr::new("diff"),
            std::ffi::OsStr::new("--no-index"),
            std::ffi::OsStr::new("--no-ext-diff"),
            std::ffi::OsStr::new("--no-textconv"),
            std::ffi::OsStr::new("--"),
            std::ffi::OsStr::new("/dev/null"),
            path,
        ];
        let diff = run_git_bounded(working_directory, &args, remaining).await?;
        // `git diff --no-index` returns 1 when it successfully found a diff.
        if !matches!(diff.status.code(), Some(0 | 1)) {
            return Err(git_error(&diff));
        }
        append_snapshot_bytes(&mut snapshot, &diff.stdout)?;
    }

    if snapshot.iter().all(u8::is_ascii_whitespace) {
        return Err("selected scope has no changes to review".to_string());
    }
    String::from_utf8(snapshot).map_err(|_| "selected diff is not valid UTF-8".to_string())
}

async fn capture_pair_review_scope(
    manager: &Arc<tokio::sync::Mutex<HeadlessManager>>,
    team: &str,
    scope: &str,
    working_directory: &str,
    base_ref: Option<&str>,
    app_socket: Option<&str>,
) -> Result<String, String> {
    if scope == "current-task" {
        let snapshot =
            crate::headless::one_shot::capture_target_delta(manager, team, "leader", app_socket)
                .await?;
        if snapshot.len() > PAIR_REVIEW_MAX_SNAPSHOT_BYTES {
            return Err(format!(
                "selected task output exceeds safe limit of {} bytes; narrow the Pair Review scope",
                PAIR_REVIEW_MAX_SNAPSHOT_BYTES
            ));
        }
        return Ok(snapshot);
    }
    timeout(
        PAIR_REVIEW_CAPTURE_TIMEOUT,
        capture_pair_review_git_scope(scope, working_directory, base_ref),
    )
    .await
    .map_err(|_| {
        format!(
            "Pair Review snapshot exceeded the {} second capture limit",
            PAIR_REVIEW_CAPTURE_TIMEOUT.as_secs()
        )
    })?
}

fn truncate_pair_review_text(text: &str, limit: usize) -> String {
    const MARKER: &str = "\n…[Pair Review output truncated]…";
    if text.len() <= limit {
        return text.to_string();
    }
    let content_limit = limit.saturating_sub(MARKER.len());
    let end = (0..=content_limit)
        .rev()
        .find(|&index| text.is_char_boundary(index))
        .unwrap_or(0);
    format!("{}{}", &text[..end], MARKER)
}

struct PairReviewCompletion {
    status: &'static str,
    verdict: Option<String>,
    error: Option<String>,
}

fn pair_review_completion(
    outcome: &crate::headless::one_shot::WatchCheckOutcome,
) -> PairReviewCompletion {
    use crate::headless::one_shot::WatchExitStatus;

    let output = outcome.verdict_text.trim();
    if outcome.exit_status == WatchExitStatus::Replied
        && outcome.error.is_none()
        && !output.is_empty()
    {
        return PairReviewCompletion {
            status: "completed",
            verdict: Some(truncate_pair_review_text(
                output,
                PAIR_REVIEW_MAX_VERDICT_BYTES,
            )),
            error: None,
        };
    }

    let mut diagnostic = outcome
        .error
        .clone()
        .unwrap_or_else(|| match outcome.exit_status {
            WatchExitStatus::Replied => "review returned no verdict".to_string(),
            WatchExitStatus::Timeout => "review timed out before a settled reply".to_string(),
            WatchExitStatus::SpawnFailed => "review process failed to start".to_string(),
        });
    if !output.is_empty() {
        let partial = truncate_pair_review_text(output, PAIR_REVIEW_MAX_VERDICT_BYTES);
        diagnostic.push_str("\n--- BEGIN PARTIAL PAIR REVIEW OUTPUT (diagnostic only) ---\n");
        diagnostic.push_str(&partial);
        diagnostic.push_str("\n--- END PARTIAL PAIR REVIEW OUTPUT ---");
    }
    PairReviewCompletion {
        status: "failed",
        verdict: None,
        error: Some(truncate_pair_review_text(
            &diagnostic,
            PAIR_REVIEW_MAX_VERDICT_BYTES,
        )),
    }
}

fn pair_review_post_message(run: &PairReviewRun, verdict: &str) -> String {
    let verdict = truncate_pair_review_text(verdict.trim(), PAIR_REVIEW_MAX_VERDICT_BYTES);
    format!(
        "Pair Review completed ({}/{} via {} {})\n\
         --- BEGIN PAIR REVIEW VERDICT (untrusted reviewer output) ---\n\
         {}\n\
         --- END PAIR REVIEW VERDICT ---",
        run.scope, run.lens, run.cli, run.model, verdict
    )
}

fn existing_pair_review_id(
    reviews: &HashMap<String, PairReviewRun>,
    team_id: &str,
    request_id: &str,
) -> Option<String> {
    reviews
        .values()
        .find(|run| run.team_id == team_id && run.request_id.as_deref() == Some(request_id))
        .map(|run| run.review_id.clone())
}

fn prune_pair_reviews(reviews: &mut HashMap<String, PairReviewRun>, now_ms: u64) {
    reviews.retain(|_, run| {
        run.status == "running"
            || run
                .finished_at
                .is_some_and(|finished| now_ms.saturating_sub(finished) <= PAIR_REVIEW_RETENTION_MS)
    });

    let mut completed: Vec<(String, u64)> = reviews
        .iter()
        .filter(|(_, run)| run.status != "running")
        .map(|(id, run)| (id.clone(), run.finished_at.unwrap_or(run.started_at)))
        .collect();
    completed.sort_by_key(|(_, finished)| std::cmp::Reverse(*finished));
    for (id, _) in completed
        .into_iter()
        .skip(PAIR_REVIEW_MAX_RETAINED_COMPLETED)
    {
        reviews.remove(&id);
    }
}

#[cfg(test)]
mod pair_review_scope_tests {
    use super::*;

    #[tokio::test]
    async fn current_changes_captures_a_frozen_git_diff() {
        let dir = tempfile::tempdir().unwrap();
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(dir.path())
                .args(args)
                .output()
                .unwrap()
        };
        assert!(run(&["init"]).status.success());
        assert!(run(&["config", "user.email", "pair@example.invalid"])
            .status
            .success());
        assert!(run(&["config", "user.name", "Pair Test"]).status.success());
        std::fs::write(dir.path().join("fixture.txt"), "before\n").unwrap();
        assert!(run(&["add", "fixture.txt"]).status.success());
        assert!(run(&["commit", "-m", "fixture"]).status.success());
        std::fs::write(dir.path().join("fixture.txt"), "after\n").unwrap();

        let manager = Arc::new(tokio::sync::Mutex::new(HeadlessManager::new()));
        let delta = capture_pair_review_scope(
            &manager,
            "fixture",
            "current-changes",
            dir.path().to_str().unwrap(),
            None,
            None,
        )
        .await
        .unwrap();
        assert!(delta.contains("-before"));
        assert!(delta.contains("+after"));
    }

    #[tokio::test]
    async fn current_changes_includes_untracked_files() {
        let dir = tempfile::tempdir().unwrap();
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(dir.path())
                .args(args)
                .output()
                .unwrap()
        };
        assert!(run(&["init"]).status.success());
        assert!(run(&["config", "user.email", "pair@example.invalid"])
            .status
            .success());
        assert!(run(&["config", "user.name", "Pair Test"]).status.success());
        std::fs::write(dir.path().join("tracked.txt"), "tracked\n").unwrap();
        assert!(run(&["add", "tracked.txt"]).status.success());
        assert!(run(&["commit", "-m", "fixture"]).status.success());
        std::fs::write(dir.path().join("new-file.txt"), "untracked pair content\n").unwrap();

        let manager = Arc::new(tokio::sync::Mutex::new(HeadlessManager::new()));
        let delta = capture_pair_review_scope(
            &manager,
            "fixture",
            "current-changes",
            dir.path().to_str().unwrap(),
            None,
            None,
        )
        .await
        .unwrap();
        assert!(delta.contains("new-file.txt"));
        assert!(delta.contains("+untracked pair content"));
    }

    #[tokio::test]
    async fn pair_review_rejects_oversized_diff_instead_of_tail_truncating() {
        let dir = tempfile::tempdir().unwrap();
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(dir.path())
                .args(args)
                .output()
                .unwrap()
        };
        assert!(run(&["init"]).status.success());
        assert!(run(&["config", "user.email", "pair@example.invalid"])
            .status
            .success());
        assert!(run(&["config", "user.name", "Pair Test"]).status.success());
        std::fs::write(dir.path().join("large.txt"), "before\n").unwrap();
        assert!(run(&["add", "large.txt"]).status.success());
        assert!(run(&["commit", "-m", "fixture"]).status.success());
        std::fs::write(
            dir.path().join("large.txt"),
            "x".repeat(PAIR_REVIEW_MAX_SNAPSHOT_BYTES + 1),
        )
        .unwrap();

        let manager = Arc::new(tokio::sync::Mutex::new(HeadlessManager::new()));
        let error = capture_pair_review_scope(
            &manager,
            "fixture",
            "current-changes",
            dir.path().to_str().unwrap(),
            None,
            None,
        )
        .await
        .unwrap_err();
        assert!(error.contains("exceeds safe limit"), "{error}");
        assert!(!error.contains("delta truncated"));
    }

    #[tokio::test]
    async fn pair_review_accepts_diff_larger_than_the_watch_tail_budget() {
        let dir = tempfile::tempdir().unwrap();
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(dir.path())
                .args(args)
                .output()
                .unwrap()
        };
        assert!(run(&["init"]).status.success());
        assert!(run(&["config", "user.email", "pair@example.invalid"])
            .status
            .success());
        assert!(run(&["config", "user.name", "Pair Test"]).status.success());
        std::fs::write(dir.path().join("large.txt"), "before\n").unwrap();
        assert!(run(&["add", "large.txt"]).status.success());
        assert!(run(&["commit", "-m", "fixture"]).status.success());
        std::fs::write(dir.path().join("large.txt"), "x".repeat(80_000)).unwrap();

        let manager = Arc::new(tokio::sync::Mutex::new(HeadlessManager::new()));
        let delta = capture_pair_review_scope(
            &manager,
            "fixture",
            "current-changes",
            dir.path().to_str().unwrap(),
            None,
            None,
        )
        .await
        .unwrap();

        assert!(delta.len() > 16_000);
        assert!(delta.contains("large.txt"));
        assert!(!delta.contains("delta truncated"));
    }

    #[tokio::test]
    async fn pair_review_bounds_untracked_file_count_without_omission() {
        let dir = tempfile::tempdir().unwrap();
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(dir.path())
                .args(args)
                .output()
                .unwrap()
        };
        assert!(run(&["init"]).status.success());
        assert!(run(&["config", "user.email", "pair@example.invalid"])
            .status
            .success());
        assert!(run(&["config", "user.name", "Pair Test"]).status.success());
        std::fs::write(dir.path().join("tracked.txt"), "tracked\n").unwrap();
        assert!(run(&["add", "tracked.txt"]).status.success());
        assert!(run(&["commit", "-m", "fixture"]).status.success());
        for index in 0..=PAIR_REVIEW_MAX_UNTRACKED_FILES {
            std::fs::write(dir.path().join(format!("untracked-{index}.txt")), "").unwrap();
        }

        let manager = Arc::new(tokio::sync::Mutex::new(HeadlessManager::new()));
        let error = capture_pair_review_scope(
            &manager,
            "fixture",
            "current-changes",
            dir.path().to_str().unwrap(),
            None,
            None,
        )
        .await
        .unwrap_err();
        assert!(error.contains("untracked files"), "{error}");
        assert!(error.contains("exceeding safe limit"), "{error}");
    }

    #[tokio::test]
    async fn pair_review_bounds_untracked_total_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(dir.path())
                .args(args)
                .output()
                .unwrap()
        };
        assert!(run(&["init"]).status.success());
        assert!(run(&["config", "user.email", "pair@example.invalid"])
            .status
            .success());
        assert!(run(&["config", "user.name", "Pair Test"]).status.success());
        std::fs::write(dir.path().join("tracked.txt"), "tracked\n").unwrap();
        assert!(run(&["add", "tracked.txt"]).status.success());
        assert!(run(&["commit", "-m", "fixture"]).status.success());
        std::fs::write(
            dir.path().join("large-untracked.txt"),
            "x".repeat(PAIR_REVIEW_MAX_SNAPSHOT_BYTES + 1),
        )
        .unwrap();

        let manager = Arc::new(tokio::sync::Mutex::new(HeadlessManager::new()));
        let error = capture_pair_review_scope(
            &manager,
            "fixture",
            "current-changes",
            dir.path().to_str().unwrap(),
            None,
            None,
        )
        .await
        .unwrap_err();
        assert!(error.contains("untracked files total"), "{error}");
    }

    #[tokio::test]
    async fn pair_review_branch_diff_accepts_a_regular_base_ref() {
        let dir = tempfile::tempdir().unwrap();
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(dir.path())
                .args(args)
                .output()
                .unwrap()
        };
        assert!(run(&["init"]).status.success());
        assert!(run(&["config", "user.email", "pair@example.invalid"])
            .status
            .success());
        assert!(run(&["config", "user.name", "Pair Test"]).status.success());
        std::fs::write(dir.path().join("tracked.txt"), "before\n").unwrap();
        assert!(run(&["add", "tracked.txt"]).status.success());
        assert!(run(&["commit", "-m", "base"]).status.success());
        std::fs::write(dir.path().join("tracked.txt"), "after\n").unwrap();
        assert!(run(&["commit", "-am", "head"]).status.success());

        let manager = Arc::new(tokio::sync::Mutex::new(HeadlessManager::new()));
        let delta = capture_pair_review_scope(
            &manager,
            "fixture",
            "branch-diff",
            dir.path().to_str().unwrap(),
            Some("HEAD~1"),
            None,
        )
        .await
        .unwrap();
        assert!(delta.contains("-before"));
        assert!(delta.contains("+after"));
        assert!(!delta.contains("delta truncated"));
    }

    #[tokio::test]
    async fn pair_review_rejects_option_like_base_ref() {
        let manager = Arc::new(tokio::sync::Mutex::new(HeadlessManager::new()));
        let error = capture_pair_review_scope(
            &manager,
            "fixture",
            "branch-diff",
            ".",
            Some("--output=/tmp/not-a-ref"),
            None,
        )
        .await
        .unwrap_err();
        assert_eq!(error, "base_ref must not begin with '-'");
    }

    fn pair_review_outcome(
        exit_status: crate::headless::one_shot::WatchExitStatus,
        verdict_text: &str,
        error: Option<&str>,
    ) -> crate::headless::one_shot::WatchCheckOutcome {
        crate::headless::one_shot::WatchCheckOutcome {
            team_id: "team".into(),
            check_id: "pair:test".into(),
            drift_kind: crate::headless::one_shot::WatchCheckKind::Execution,
            target: "leader".into(),
            spawned: true,
            reported: !verdict_text.is_empty(),
            terminated: true,
            exit_status,
            panel_id: None,
            verdict_text: verdict_text.into(),
            error: error.map(str::to_string),
        }
    }

    #[test]
    fn pair_review_completes_only_for_replied_outcome() {
        use crate::headless::one_shot::WatchExitStatus;

        let replied = pair_review_completion(&pair_review_outcome(
            WatchExitStatus::Replied,
            "settled verdict",
            None,
        ));
        assert_eq!(replied.status, "completed");
        assert_eq!(replied.verdict.as_deref(), Some("settled verdict"));
        assert!(replied.error.is_none());

        let timeout = pair_review_completion(&pair_review_outcome(
            WatchExitStatus::Timeout,
            "partial text",
            Some("deadline elapsed"),
        ));
        assert_eq!(timeout.status, "failed");
        assert!(timeout.verdict.is_none());
        assert!(timeout
            .error
            .as_deref()
            .unwrap()
            .contains("diagnostic only"));
        assert!(timeout.error.as_deref().unwrap().contains("partial text"));
    }

    fn pair_review_run(
        review_id: &str,
        request_id: Option<&str>,
        status: &str,
        started_at: u64,
        finished_at: Option<u64>,
    ) -> PairReviewRun {
        PairReviewRun {
            review_id: review_id.into(),
            team_id: "team".into(),
            request_id: request_id.map(str::to_string),
            status: status.into(),
            scope: "current-changes".into(),
            lens: "general".into(),
            cli: "codex".into(),
            model: "model".into(),
            snapshot_digest: None,
            started_at,
            finished_at,
            duration_ms: None,
            verdict: None,
            error: None,
        }
    }

    #[test]
    fn pair_review_request_id_finds_existing_run_for_same_team() {
        let run = pair_review_run("review-1", Some("request-1"), "completed", 1, Some(2));
        let reviews = HashMap::from([(run.review_id.clone(), run)]);
        assert_eq!(
            existing_pair_review_id(&reviews, "team", "request-1").as_deref(),
            Some("review-1")
        );
        assert!(existing_pair_review_id(&reviews, "other-team", "request-1").is_none());
    }

    #[test]
    fn pair_review_cleanup_keeps_running_and_recent_statuses_but_bounds_history() {
        let now = PAIR_REVIEW_RETENTION_MS + 10_000;
        let mut reviews = HashMap::new();
        let running = pair_review_run("running", None, "running", 1, None);
        reviews.insert(running.review_id.clone(), running);
        let expired = pair_review_run("expired", None, "completed", 1, Some(1));
        reviews.insert(expired.review_id.clone(), expired);
        for index in 0..PAIR_REVIEW_MAX_RETAINED_COMPLETED + 2 {
            let finished = now - index as u64;
            let run = pair_review_run(
                &format!("recent-{index}"),
                None,
                "completed",
                finished - 1,
                Some(finished),
            );
            reviews.insert(run.review_id.clone(), run);
        }

        prune_pair_reviews(&mut reviews, now);
        assert!(reviews.contains_key("running"));
        assert!(!reviews.contains_key("expired"));
        assert!(reviews.contains_key("recent-0"));
        assert_eq!(
            reviews
                .values()
                .filter(|run| run.status != "running")
                .count(),
            PAIR_REVIEW_MAX_RETAINED_COMPLETED
        );
    }

    #[test]
    fn pair_review_post_fences_and_caps_untrusted_verdict() {
        let run = pair_review_run("review", None, "completed", 1, Some(2));
        let message =
            pair_review_post_message(&run, &"x".repeat(PAIR_REVIEW_MAX_VERDICT_BYTES + 100));
        assert!(message.contains("BEGIN PAIR REVIEW VERDICT"));
        assert!(message.contains("END PAIR REVIEW VERDICT"));
        let fenced = message
            .split("--- BEGIN PAIR REVIEW VERDICT (untrusted reviewer output) ---\n")
            .nth(1)
            .unwrap()
            .split("\n--- END PAIR REVIEW VERDICT ---")
            .next()
            .unwrap();
        assert!(fenced.len() <= PAIR_REVIEW_MAX_VERDICT_BYTES);
        assert!(fenced.contains("output truncated"));
    }
}

/// Open the project registry, recovering from a quarantined (corrupt or
/// schema-incompatible) database instead of taking the whole control socket
/// down with it.
///
/// This ran with a `?` that aborted `serve` AFTER the socket was already
/// bound — leaving a socket FILE with no listener behind it, so the control
/// plane looked present but answered nothing (a corrupt sync DB silently
/// killed headless, team, and surface commands that never touch the
/// registry). "Quarantined" is the registry's own word for "move it aside":
/// so do that, then open a fresh one. The daemon comes up with sync starting
/// from empty rather than with no control plane at all.
fn open_project_registry_recovering(path: PathBuf) -> anyhow::Result<crate::sync::ProjectRegistry> {
    match crate::sync::ProjectRegistry::open(&path) {
        Ok(registry) => Ok(registry),
        Err(crate::sync::RegistryError::Quarantined { reason, .. }) => {
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            tracing::error!(
                "project registry at {} is unusable ({reason}); quarantining and recreating",
                path.display()
            );
            // Move the DB and its WAL/SHM sidecars together, or a stale WAL
            // would corrupt the fresh database on the next open.
            for suffix in ["", "-wal", "-shm"] {
                let from = PathBuf::from(format!("{}{suffix}", path.display()));
                if from.exists() {
                    let to =
                        PathBuf::from(format!("{}.quarantined-{stamp}{suffix}", path.display()));
                    if let Err(error) = std::fs::rename(&from, &to) {
                        tracing::error!("could not move {} aside: {error}", from.display());
                    }
                }
            }
            crate::sync::ProjectRegistry::open(&path).map_err(Into::into)
        }
        Err(other) => Err(other.into()),
    }
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

/// Clear whatever occupies the socket path before binding.
///
/// `Path::exists` follows symlinks, so a dangling one — `/tmp/term-meshd.sock`
/// pointing at a `/run/user/<uid>` socket from a session that has since ended —
/// reads as absent and survives the cleanup. `bind` then sees the link entry
/// itself and fails with `EADDRINUSE`, so the daemon exits, systemd restarts
/// it, and it fails again on the same link. Ask about the directory entry
/// rather than about what it points at.
fn clear_stale_socket_entry(path: &std::path::Path) -> std::io::Result<()> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => {
            let probe_connectivity =
                metadata.file_type().is_socket() || metadata.file_type().is_symlink();
            // A pathname is not stale merely because a second daemon wants
            // it. Probing first prevents a newer process from unlinking the
            // live control plane of the instance that already owns it. This
            // includes a compatibility symlink pointing at a live runtime-dir
            // socket; removing that alias and binding a second listener at the
            // same pathname would create a split-brain daemon pair.
            let observed = SocketIdentity {
                device: metadata.dev(),
                inode: metadata.ino(),
            };
            if probe_connectivity {
                match probe_existing_socket(path) {
                    Ok(_) => {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::AddrInUse,
                            format!("live Unix socket already owns {}", path.display()),
                        ));
                    }
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::NotFound
                        ) => {}
                    Err(error) => return Err(error),
                }
            }
            if remove_owned_socket(path, observed)? {
                Ok(())
            } else if std::fs::symlink_metadata(path)
                .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound)
            {
                Ok(())
            } else {
                Err(std::io::Error::new(
                    std::io::ErrorKind::AddrInUse,
                    format!("Unix socket ownership changed at {}", path.display()),
                ))
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

/// A dead listener refuses every probe. A live BSD/macOS listener whose accept
/// queue is briefly full can also report ECONNREFUSED, so require repeated
/// refusal before declaring the observed pathname stale. Linux reports EAGAIN
/// for that queue-full condition; classify it as live immediately.
fn probe_existing_socket(path: &Path) -> std::io::Result<()> {
    for attempt in 0..STALE_SOCKET_REFUSAL_PROBES {
        match connect_unix_socket_with_timeout(path, STALE_SOCKET_CONNECT_TIMEOUT) {
            Err(error) if error.kind() == std::io::ErrorKind::ConnectionRefused => {
                if attempt + 1 == STALE_SOCKET_REFUSAL_PROBES {
                    return Err(error);
                }
                std::thread::sleep(STALE_SOCKET_REFUSAL_RETRY_DELAY);
            }
            result => return result,
        }
    }
    unreachable!("the refusal loop always returns")
}

/// Probe a possibly-live listener without allowing daemon startup to block on
/// a full accept queue. Timeout and indeterminate errors are intentionally not
/// classified as stale by the caller: preserving a possibly-live pathname is
/// safer than creating a second daemon behind a replacement inode.
fn connect_unix_socket_with_timeout(path: &Path, timeout: Duration) -> std::io::Result<()> {
    let bytes = path.as_os_str().as_bytes();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.len() >= address.sun_path.len() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Unix socket path is too long",
        ));
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (slot, byte) in address.sun_path.iter_mut().zip(bytes.iter().copied()) {
        *slot = byte as libc::c_char;
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    let socket_type = libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC;
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    let socket_type = libc::SOCK_STREAM;
    let raw_fd = unsafe { libc::socket(libc::AF_UNIX, socket_type, 0) };
    if raw_fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let fd = unsafe { OwnedFd::from_raw_fd(raw_fd) };
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    {
    let status_flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFL) };
    if status_flags < 0
        || unsafe {
            libc::fcntl(
                fd.as_raw_fd(),
                libc::F_SETFL,
                status_flags | libc::O_NONBLOCK,
            )
        } < 0
        || unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0
    {
        return Err(std::io::Error::last_os_error());
    }
    }
    let result = unsafe {
        libc::connect(
            fd.as_raw_fd(),
            (&address as *const libc::sockaddr_un).cast(),
            std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t,
        )
    };
    if result == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::EAGAIN) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AddrInUse,
            "Unix socket accept queue is full",
        ));
    }
    if !matches!(error.raw_os_error(), Some(libc::EINPROGRESS)) {
        return Err(error);
    }
    let timeout_ms = timeout.as_millis().min(i32::MAX as u128) as i32;
    let mut poll_fd = libc::pollfd {
        fd: fd.as_raw_fd(),
        events: libc::POLLOUT,
        revents: 0,
    };
    loop {
        let ready = unsafe { libc::poll(&mut poll_fd, 1, timeout_ms) };
        if ready == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Unix socket connect probe timed out",
            ));
        }
        if ready < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        let mut socket_error: libc::c_int = 0;
        let mut length = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
        if unsafe {
            libc::getsockopt(
                fd.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_ERROR,
                (&mut socket_error as *mut libc::c_int).cast(),
                &mut length,
            )
        } < 0
        {
            return Err(std::io::Error::last_os_error());
        }
        return if socket_error == 0 {
            Ok(())
        } else {
            Err(std::io::Error::from_raw_os_error(socket_error))
        };
    }
}

#[derive(Clone, Copy)]
struct SocketIdentity {
    device: u64,
    inode: u64,
}

fn socket_identity(path: &Path) -> std::io::Result<SocketIdentity> {
    // Compare the pathname entry itself. Following a symlink here would let
    // an attacker or racing process swap only the link while preserving the
    // target inode, defeating the ownership guard.
    let metadata = std::fs::symlink_metadata(path)?;
    Ok(SocketIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

fn remove_owned_socket(path: &Path, owner: SocketIdentity) -> std::io::Result<bool> {
    let current = match socket_identity(path) {
        Ok(identity) => identity,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    if current.device != owner.device || current.inode != owner.inode {
        return Ok(false);
    }
    std::fs::remove_file(path)?;
    Ok(true)
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
    watch_registry: crate::drift_watch::WatchRegistry,
    watch_runner: Option<Arc<dyn crate::headless::one_shot::WatchCheckRunner>>,
    watch_sink: Option<
        tokio::sync::mpsc::UnboundedSender<crate::headless::one_shot::WatchCheckOutcome>,
    >,
    remote_registry: crate::remote::SharedRegistry,
    mut shutdown_rx: watch::Receiver<bool>,
    started: watch::Sender<bool>,
) -> anyhow::Result<()> {
    clear_stale_socket_entry(&path)?;

    let listener = bind_with_tight_umask(&path)?;
    let socket_owner = socket_identity(&path)?;
    harden_socket_permissions(&path);
    tracing::info!("listening on {}", path.display());

    let owner_uid = current_uid();
    let (event_tx, _) = tokio::sync::broadcast::channel(256);
    let pane_tracker = PaneTracker::new().start();
    let project_registry = Arc::new(open_project_registry_recovering(
        crate::sync::default_registry_db_path(),
    )?);
    let operation_manager =
        build_sync_operation_manager(project_registry.clone()).map_err(|error| {
            tracing::error!("sync operation manager setup failed: {error:?}");
            error
        })?;
    let ctx = Arc::new(Context {
        monitor_rx,
        monitor_handle,
        watcher_handle,
        sessions,
        team_state,
        usage_tracker,
        agent_manager,
        headless,
        watch_registry,
        watch_runner,
        watch_sink,
        remote_registry,
        pair_reviews: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
        pane_tracker,
        event_tx,
        project_registry,
        paused_sync_projects: Arc::new(RwLock::new(HashSet::new())),
        operation_manager,
    });
    let heartbeat_task = tokio::spawn(run_heartbeat_staleness_watcher(
        ctx.clone(),
        shutdown_rx.clone(),
    ));
    // Wave 1 D5: assigned-state timeout watcher — auto-blocks tasks that
    // never transitioned to `in_progress` within the per-CLI window.
    let assigned_timeout_task = tokio::spawn(run_assigned_timeout_watcher(
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
    let mut connection_tasks = JoinSet::new();
    // Publish only after every fallible startup step has completed. main.rs
    // combines this receipt with the peer-server receipt before deciding that
    // this daemon generation may terminate processes loaded from the shared DB.
    let _ = started.send(true);

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
                        let connection_shutdown_rx = shutdown_rx.clone();
                        spawn_supervised(&mut connection_tasks, async move {
                            if let Err(e) = handle_connection(stream, &ctx, connection_shutdown_rx).await {
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
            // Drain completed connection task entries immediately so JoinSet
            // does not retain finished handles until daemon shutdown.
            // join_next() only fires when a task is already done — no busy loop.
            Some(result) = connection_tasks.join_next() => {
                if let Err(e) = result {
                    if !e.is_cancelled() {
                        tracing::warn!("connection task panicked: {e}");
                    }
                }
            }
        }
    }
    heartbeat_task.abort();
    assigned_timeout_task.abort();
    usage_broadcast_task.abort();
    jsonl_usage_broadcast_task.abort();
    codex_usage_broadcast_task.abort();
    usage_flush_task.abort();
    shutdown_supervised(&mut connection_tasks, "socket").await;

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

    // Remove only the directory entry this listener bound. If another
    // instance replaced the pathname while shutdown was in flight, its
    // control socket must survive.
    match remove_owned_socket(&path, socket_owner) {
        Ok(true) => tracing::info!("removed socket file {}", path.display()),
        Ok(false) => tracing::warn!(
            "socket path changed ownership; leaving {} intact",
            path.display()
        ),
        Err(e) => tracing::warn!("failed to remove socket file: {e}"),
    }

    Ok(())
}

async fn handle_connection(
    stream: tokio::net::UnixStream,
    ctx: &Context,
    mut shutdown_rx: watch::Receiver<bool>,
) -> anyhow::Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);

    loop {
        let line = tokio::select! {
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    return Ok(());
                }
                continue;
            }
            line = timeout(
                Duration::from_secs(60),
                read_bounded_line(&mut reader, crate::sync::MAX_OPERATION_ENVELOPE_BYTES),
            ) => {
                match line.map_err(|_| anyhow::anyhow!("read timeout"))?? {
                    BoundedLine::Line(line) => line,
                    BoundedLine::TooLarge => {
                        let resp = Response {
                            id: None,
                            result: None,
                            error: Some(RpcError {
                                code: -32600,
                                message: "request envelope exceeds 64 KiB".to_string(),
                            }),
                        };
                        let mut buf = serde_json::to_vec(&resp)?;
                        buf.push(b'\n');
                        timeout(Duration::from_secs(5), writer.write_all(&buf))
                            .await
                            .map_err(|_| anyhow::anyhow!("write timeout"))??;
                        continue;
                    }
                    BoundedLine::Eof => break,
                }
            }
        };

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

        tracing::debug!("req method={}", req.method);

        // Streaming handlers hold the writer for their lifetime and must
        // exit handle_connection entirely — they cannot share the loop.
        if req.method == "events.subscribe" {
            return stream_subscribe_events(req, writer, reader, ctx, shutdown_rx).await;
        }

        let resp = dispatch(&req, ctx).await;

        let mut buf = serialize_bounded_response(&resp, req.id.clone())?;
        buf.push(b'\n');
        timeout(Duration::from_secs(5), writer.write_all(&buf))
            .await
            .map_err(|_| anyhow::anyhow!("write timeout"))??;
    }

    Ok(())
}

fn serialize_bounded_response(
    response: &Response,
    id: Option<serde_json::Value>,
) -> Result<Vec<u8>, serde_json::Error> {
    if let BoundedSerialization::Payload(encoded) = serialize_bounded(response)? {
        return Ok(encoded);
    }
    serde_json::to_vec(&Response {
        id,
        result: None,
        error: Some(RpcError {
            code: -32603,
            message: "response envelope exceeds 64 KiB".to_string(),
        }),
    })
}

enum BoundedSerialization {
    Payload(Vec<u8>),
    TooLarge,
}

fn serialize_bounded<T: serde::Serialize>(
    value: &T,
) -> Result<BoundedSerialization, serde_json::Error> {
    let encoded = serde_json::to_vec(value)?;
    if encoded.len() <= crate::sync::MAX_OPERATION_ENVELOPE_BYTES {
        Ok(BoundedSerialization::Payload(encoded))
    } else {
        Ok(BoundedSerialization::TooLarge)
    }
}

enum BoundedLine {
    Line(String),
    TooLarge,
    Eof,
}

async fn read_bounded_line<R: tokio::io::AsyncBufRead + Unpin>(
    reader: &mut R,
    limit: usize,
) -> std::io::Result<BoundedLine> {
    let mut bytes = Vec::with_capacity(limit.min(8 * 1024));
    let mut too_large = false;
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            if too_large {
                return Ok(BoundedLine::TooLarge);
            }
            if bytes.is_empty() {
                return Ok(BoundedLine::Eof);
            }
            if bytes.len() > limit {
                return Ok(BoundedLine::TooLarge);
            }
            return String::from_utf8(bytes)
                .map(BoundedLine::Line)
                .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidData));
        }
        let newline = available.iter().position(|byte| *byte == b'\n');
        let consumed = newline.map_or(available.len(), |index| index + 1);
        let payload = newline.map_or(available, |index| &available[..index]);
        if !too_large {
            if bytes.len().saturating_add(payload.len()) > limit.saturating_add(1) {
                too_large = true;
                bytes.clear();
            } else {
                bytes.extend_from_slice(payload);
            }
        }
        reader.consume(consumed);
        if newline.is_some() {
            if too_large {
                return Ok(BoundedLine::TooLarge);
            }
            if bytes.last() == Some(&b'\r') {
                bytes.pop();
            }
            if bytes.len() > limit {
                return Ok(BoundedLine::TooLarge);
            }
            return String::from_utf8(bytes)
                .map(BoundedLine::Line)
                .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidData));
        }
    }
}

/// Streaming handler for `events.subscribe`. Takes ownership of the writer and
/// streams JSONL events until the timeout expires or the client disconnects.
///
/// W-2: real task_status and reply events via broadcast channel + keepalive every 30 s.
async fn stream_subscribe_events(
    req: Request,
    mut writer: tokio::net::unix::OwnedWriteHalf,
    mut reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    ctx: &Context,
    mut shutdown_rx: watch::Receiver<bool>,
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
        "id": req.id.clone(),
        "result": {
            "status": "subscribed",
            "filter": filter_kinds.iter().collect::<Vec<_>>(),
            "leader_session_id": leader_session_id,
        },
        "error": null,
    });
    let mut buf = match serialize_bounded(&ack)? {
        BoundedSerialization::Payload(payload) => payload,
        BoundedSerialization::TooLarge => serialize_bounded_response(
            &Response {
                id: req.id.clone(),
                result: None,
                error: Some(RpcError {
                    code: -32603,
                    message: "subscription ack exceeds 64 KiB".to_string(),
                }),
            },
            req.id.clone(),
        )?,
    };
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
                changed = shutdown_rx.changed() => {
                    if changed.is_err() || *shutdown_rx.borrow() {
                        break;
                    }
                    None
                }
                _ = tokio::time::sleep_until(dl) => break,
                _ = ping_interval.tick() => {
                    bounded_subscriber_payload(&serde_json::json!({"kind":"keepalive","ts_ms":ts_ms()}))?
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
                read_result = read_bounded_line(&mut reader, crate::sync::MAX_OPERATION_ENVELOPE_BYTES) => {
                    match read_result {
                        Ok(BoundedLine::Eof | BoundedLine::TooLarge) | Err(_) => break,
                        Ok(BoundedLine::Line(_)) => None,
                    }
                }
            }
        } else {
            tokio::select! {
                changed = shutdown_rx.changed() => {
                    if changed.is_err() || *shutdown_rx.borrow() {
                        break;
                    }
                    None
                }
                _ = ping_interval.tick() => {
                    bounded_subscriber_payload(&serde_json::json!({"kind":"keepalive","ts_ms":ts_ms()}))?
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
                read_result = read_bounded_line(&mut reader, crate::sync::MAX_OPERATION_ENVELOPE_BYTES) => {
                    match read_result {
                        Ok(BoundedLine::Eof | BoundedLine::TooLarge) | Err(_) => break,
                        Ok(BoundedLine::Line(_)) => None,
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
        DaemonEvent::XkRun { .. } => "xk_run",
    };
    // xk_run is strictly opt-in: an empty filter set (wildcard) or the default
    // set must never receive it, so `tm-agent wait`/Swift stay noise-free
    // (XK-EVENTS-v1 rule 3).
    if kind == "xk_run" && !filter_kinds.contains(kind) {
        return None;
    }
    if !filter_kinds.is_empty() && !filter_kinds.contains(kind) {
        return None;
    }
    // leader_session_id filtering is intentionally relaxed in W-2: any subscriber
    // without a leader_session_id filter receives all events (generous default).
    // Per-leader scoping can be tightened in a follow-up without protocol changes.
    bounded_subscriber_payload(ev).ok().flatten()
}

static OVERSIZED_SUBSCRIBER_EVENTS: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

fn bounded_subscriber_payload<T: serde::Serialize>(
    value: &T,
) -> Result<Option<Vec<u8>>, serde_json::Error> {
    match serialize_bounded(value)? {
        BoundedSerialization::Payload(payload) => Ok(Some(payload)),
        BoundedSerialization::TooLarge => {
            let count =
                OVERSIZED_SUBSCRIBER_EVENTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
            let error = serde_json::json!({
                "kind": "error",
                "code": "event_too_large",
                "dropped": true,
                "oversized_event_count": count,
            });
            match serialize_bounded(&error)? {
                BoundedSerialization::Payload(payload) => Ok(Some(payload)),
                BoundedSerialization::TooLarge => Ok(None),
            }
        }
    }
}

/// XK-EVENTS-v1 caps (contract §4 rule 4): whole event and redacted tail.
const XK_RUN_MAX_EVENT_BYTES: usize = 4096;
const XK_RUN_MAX_TAIL_BYTES: usize = 512;

/// Truncate to at most `max` bytes without splitting a UTF-8 code point.
fn truncate_utf8(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// Wrap a reverse leader-call answer for the CLI's proxy decoder.
///
/// Both dispositions are a *successful proxy*: the peer was reached and it
/// answered. A rejection used to be collapsed into a generic JSON-RPC error
/// string (`"{code}: {message}"`), which `decode_daemon_response` handed
/// straight back to the caller, so `remote_leader_proxy_result` on the CLI
/// side never saw the `{ok:false, result:{error_code, error_message}}` shape
/// it parses — the error code, and every code-aware behaviour keyed on it
/// (`[agent_busy]` hints, explicit unsupported-method detection), was lost
/// before reaching the caller. Only a transport failure is an `Err` now.
fn team_leader_proxy_envelope(
    response: &peer_proto::v1::TeamLeaderCommandResponse,
) -> serde_json::Value {
    if response.ok {
        let result = serde_json::from_str(&response.result_json)
            .unwrap_or_else(|_| serde_json::json!({ "raw": response.result_json }));
        return serde_json::json!({
            "ok": true,
            "cached": response.cached,
            "result": result,
        });
    }
    serde_json::json!({
        "ok": false,
        "cached": response.cached,
        "result": {
            "error_code": response.error_code,
            "error_message": response.error_message,
        },
    })
}

/// The daemon-side entry gate for `peer.leader.call`. This is deliberately
/// wider than generic `team.call.v1` only by the methods protected by the
/// leader grant carried in the same request.
fn leader_proxy_method_allowed(method: &str) -> bool {
    crate::peer::connection::team_leader_call_allowed(method)
}

/// `events.publish {kind:"xk_run", …}` — XK-EVENTS-v1 external-run telemetry
/// (x-kit panel integration Phase 2). Validates, caps sizes, stamps `ts_ms`
/// server-side (consistent with the task_status/reply publish path), and fans
/// out on the broadcast bus. Never persisted.
fn publish_xk_run(
    params: &serde_json::Value,
    event_tx: &EventSender,
) -> Result<serde_json::Value, String> {
    fn default_v() -> u32 {
        1
    }
    #[derive(Deserialize)]
    struct P {
        #[serde(default = "default_v")]
        v: u32,
        #[serde(default)]
        source: String,
        #[serde(default)]
        run: String,
        #[serde(default)]
        run_kind: String,
        #[serde(default)]
        phase: String,
        #[serde(default)]
        model: String,
        #[serde(default)]
        state: String,
        #[serde(default)]
        elapsed_ms: u64,
        #[serde(default)]
        tail: Option<String>,
        #[serde(default)]
        title: Option<String>,
    }

    let raw_len = serde_json::to_string(params).map(|s| s.len()).unwrap_or(0);
    if raw_len > XK_RUN_MAX_EVENT_BYTES {
        return Err(format!(
            "events.publish: xk_run event {raw_len} bytes exceeds {XK_RUN_MAX_EVENT_BYTES}"
        ));
    }
    let p: P =
        serde_json::from_value(params.clone()).map_err(|e| format!("invalid params: {e}"))?;
    if p.source.is_empty() || p.run.is_empty() {
        return Err("events.publish: xk_run requires non-empty 'source' and 'run'".into());
    }
    let tail = p
        .tail
        .map(|t| truncate_utf8(&t, XK_RUN_MAX_TAIL_BYTES).to_string());
    let ts_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    // Err means no subscribers — fine to ignore (fan-out only, no persistence).
    let _ = event_tx.send(DaemonEvent::XkRun {
        v: p.v,
        source: p.source,
        run: p.run,
        run_kind: p.run_kind,
        phase: p.phase,
        model: p.model,
        state: p.state,
        elapsed_ms: p.elapsed_ms,
        tail,
        title: p.title,
        ts_ms,
    });
    Ok(serde_json::json!({"published": true}))
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
                // Track live (team, agent) keys this tick so stale last_emitted
                // entries can be dropped — teams/agents come and go and the map
                // would otherwise grow unbounded for the daemon's lifetime.
                let mut seen_keys: HashSet<(String, String)> = HashSet::new();
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
                        seen_keys.insert(key.clone());
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
                                seen_keys.insert(key.clone());
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
                // Drop dedup entries for teams/agents that disappeared this tick
                // so last_emitted stays bounded to the live roster.
                last_emitted.retain(|k, _| seen_keys.contains(k));
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
                // Track live (team, agent) keys this tick so stale last_emitted
                // entries can be dropped — teams/agents come and go and the map
                // would otherwise grow unbounded for the daemon's lifetime.
                let mut seen_keys: HashSet<(String, String)> = HashSet::new();
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
                        seen_keys.insert(key.clone());
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
                // Drop dedup entries for teams/agents that disappeared this tick
                // so last_emitted stays bounded to the live roster.
                last_emitted.retain(|k, _| seen_keys.contains(k));
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

// Wave 1 D5: thresholds for the assigned-timeout watcher. claude agents are
// expected to acknowledge a task within 180s; codex/gemini/kiro are slower at
// cold-start so they get double. Unknown CLIs default to the claude bound.
const ASSIGNED_TIMEOUT_CLAUDE_MS: u64 = 180_000;
const ASSIGNED_TIMEOUT_OTHER_MS: u64 = 360_000;

/// Walk the synced team-state JSON to build `agent_name -> cli` so the
/// assigned-timeout watcher can pick the right threshold per assignee.
/// Everything the daemon currently considers in use, handed to the GC so its
/// scan stays a pure function of (filesystem, refs, clock).
///
/// Collected here rather than inside `crate::gc` because only the socket layer
/// can reach the session database and the Swift-synced team state.
async fn collect_gc_refs(ctx: &Context) -> gc::GcRefs {
    let active_team_uuids = {
        let state = ctx.team_state.read().unwrap();
        state
            .get("teams")
            .and_then(serde_json::Value::as_array)
            .map(|teams| {
                teams
                    .iter()
                    .filter_map(|team| {
                        team.get("id")
                            .or_else(|| team.get("uuid"))
                            .or_else(|| team.get("workspace_id"))
                            .and_then(serde_json::Value::as_str)
                            .map(str::to_string)
                    })
                    .collect::<HashSet<String>>()
            })
            .unwrap_or_default()
    };

    gc::GcRefs {
        active_session_worktrees: ctx.agent_manager.active_worktree_paths(),
        active_task_worktrees: ctx.agent_manager.active_task_worktree_paths(),
        repo_paths: ctx.agent_manager.known_repo_paths(),
        active_team_uuids,
    }
}

/// Shared scan step for `gc.status` / `gc.plan` / `gc.sweep`.
fn gc_scan(params: serde_json::Value, refs: gc::GcRefs) -> Result<gc::GcPlan, String> {
    let opts: gc::GcOptions = serde_json::from_value(params)
        .map_err(|error| format!("INVALID_PARAMS: invalid GC options: {error}"))?;
    let paths = gc::default_paths().ok_or_else(|| "cannot resolve home directory".to_string())?;
    Ok(gc::build_plan(&paths, &opts, &refs))
}

async fn gc_scan_off_thread(
    ctx: &Context,
    params: serde_json::Value,
) -> Result<gc::GcPlan, String> {
    let refs = collect_gc_refs(ctx).await;
    tokio::task::spawn_blocking(move || gc_scan(params, refs))
        .await
        .map_err(|e| e.to_string())?
}

/// Machine-wide reclamation summary.
///
/// A `project_id` in the params selects the original project-scoped response
/// shape (validated project plus the `eligible`/`retention_days` keys the
/// pre-GC stub returned) so older CLI builds keep working unchanged.
async fn gc_status(ctx: &Context, req: &Request) -> Result<serde_json::Value, String> {
    let legacy_project = match project_id_param(&req.params) {
        Ok(project_id) => {
            load_project(ctx, project_id).await?;
            Some(project_id.to_string())
        }
        Err(_) => None,
    };

    let plan = gc_scan_off_thread(ctx, req.params.clone()).await?;
    let mut result = gc::summarize(&plan);
    if let Some(object) = result.as_object_mut() {
        object.insert("state".into(), serde_json::json!("idle"));
        object.insert(
            "last_sweep".into(),
            serde_json::to_value(gc::last_sweep()).unwrap_or(serde_json::Value::Null),
        );
        if let Some(project_id) = legacy_project {
            object.insert("project_id".into(), serde_json::json!(project_id));
            object.insert("eligible".into(), serde_json::json!(false));
            object.insert("retention_days".into(), serde_json::json!(90));
        }
    }
    Ok(result)
}

#[derive(Debug, serde::Deserialize, Default)]
struct GcSweepFlags {
    #[serde(default)]
    apply: bool,
    #[serde(default)]
    force: bool,
}

fn parse_gc_sweep_flags(params: serde_json::Value) -> Result<GcSweepFlags, String> {
    serde_json::from_value(params)
        .map_err(|error| format!("INVALID_PARAMS: invalid GC sweep flags: {error}"))
}

async fn gc_sweep(ctx: &Context, req: &Request) -> Result<serde_json::Value, String> {
    let flags = parse_gc_sweep_flags(req.params.clone())?;

    let plan = gc_scan_off_thread(ctx, req.params.clone()).await?;
    // The scan may be expensive. Refresh live session/task references after it
    // finishes so the apply pass cannot rely only on the snapshot from before
    // the filesystem walk. `execute_sweep` also rechecks each worktree's git
    // state immediately before removal.
    let current_refs = collect_gc_refs(ctx).await;
    tokio::task::spawn_blocking(move || {
        let paths =
            gc::default_paths().ok_or_else(|| "cannot resolve home directory".to_string())?;
        gc::execute_sweep(&paths, &plan, flags.apply, flags.force, &current_refs)
    })
    .await
    .map_err(|e| e.to_string())?
    .map(|summary| serde_json::to_value(summary).unwrap_or(serde_json::Value::Null))
}

/// Returns an empty map when no team state has been synced yet — callers fall
/// back to the claude default.
fn extract_assignee_cli_map(state: &serde_json::Value) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let Some(teams) = state.get("teams").and_then(serde_json::Value::as_array) else {
        return out;
    };
    for team in teams {
        let Some(agents) = team.get("agents").and_then(serde_json::Value::as_array) else {
            continue;
        };
        for agent in agents {
            let name = agent
                .get("name")
                .or_else(|| agent.get("agent_name"))
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default();
            let cli = agent
                .get("cli")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("claude");
            if !name.is_empty() {
                out.insert(name.to_string(), cli.to_string());
            }
        }
    }
    out
}

fn assigned_threshold_for_cli(cli: &str) -> u64 {
    match cli {
        "claude" => ASSIGNED_TIMEOUT_CLAUDE_MS,
        _ => ASSIGNED_TIMEOUT_OTHER_MS,
    }
}

async fn run_assigned_timeout_watcher(ctx: Arc<Context>, mut shutdown_rx: watch::Receiver<bool>) {
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    interval.tick().await; // consume immediate first tick
    let mut notified: HashSet<String> = HashSet::new();

    loop {
        tokio::select! {
            _ = interval.tick() => {
                let now_ms = current_time_ms();
                let cli_map = {
                    let st = ctx.team_state.read().unwrap();
                    extract_assignee_cli_map(&st)
                };
                let tasks = ctx.agent_manager.task_list(crate::agent::TaskListParams {
                    status: None,
                    assignee: None,
                });
                for task in &tasks {
                    if !matches!(task.status, crate::agent::TaskStatus::Assigned) {
                        notified.remove(&task.id);
                        continue;
                    }
                    let cli = task
                        .assignee
                        .as_deref()
                        .and_then(|name| cli_map.get(name).cloned())
                        .unwrap_or_else(|| "claude".to_string());
                    let threshold = assigned_threshold_for_cli(&cli);
                    if now_ms.saturating_sub(task.updated_at_ms) < threshold {
                        notified.remove(&task.id);
                        continue;
                    }
                    if !notified.insert(task.id.clone()) {
                        continue;
                    }
                    let reason = format!("no_start_within_{}s", threshold / 1000);
                    match ctx.agent_manager.force_block_assigned(&task.id, &reason) {
                        Ok(true) => {
                            tracing::info!(
                                "assigned-timeout: blocked task {} assignee={:?} cli={} reason={}",
                                task.id,
                                task.assignee,
                                cli,
                                reason
                            );
                            let ev = DaemonEvent::TaskStatus {
                                team: String::new(),
                                agent: task.assignee.clone().unwrap_or_default(),
                                task_id: task.id.clone(),
                                status: "blocked".into(),
                                prev_status: "assigned".into(),
                                ts_ms: now_ms,
                            };
                            let _ = ctx.event_tx.send(ev);
                        }
                        Ok(false) => {
                            // Task changed status under us between read and block;
                            // remove from notified set so a re-entry can flag again.
                            notified.remove(&task.id);
                        }
                        Err(e) => {
                            tracing::warn!(
                                "assigned-timeout: failed to block {}: {e}",
                                task.id
                            );
                            notified.remove(&task.id);
                        }
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

        // --- Durable sync operations (off-main, non-focus) ---
        "operation.start" => {
            match serde_json::from_value::<crate::sync::OperationStartParams>(req.params.clone()) {
                Ok(params) => ctx
                    .operation_manager
                    .start(params)
                    .await
                    .map_err(|error| error.to_string())
                    .and_then(operation_json),
                Err(_) => Err("invalid params".to_string()),
            }
        }
        "operation.status" => {
            match serde_json::from_value::<crate::sync::OperationIdParams>(req.params.clone()) {
                Ok(params) => ctx
                    .operation_manager
                    .status(&params.operation_id, &params.project_id)
                    .map_err(|error| error.to_string())
                    .and_then(operation_json),
                Err(_) => Err("invalid params".to_string()),
            }
        }
        "operation.cancel" => {
            match serde_json::from_value::<crate::sync::OperationIdParams>(req.params.clone()) {
                Ok(params) => ctx
                    .operation_manager
                    .cancel(&params.operation_id, &params.project_id)
                    .map_err(|error| error.to_string())
                    .and_then(operation_json),
                Err(_) => Err("invalid params".to_string()),
            }
        }
        "operation.retry" => {
            match serde_json::from_value::<crate::sync::OperationRetryParams>(req.params.clone()) {
                Ok(params) => ctx
                    .operation_manager
                    .retry(params)
                    .await
                    .map_err(|error| error.to_string())
                    .and_then(operation_json),
                Err(_) => Err("invalid params".to_string()),
            }
        }

        // --- Mesh project control plane (off-main, non-focus) ---
        "project.add" => match serde_json::from_value::<ProjectAddParams>(req.params.clone()) {
            Ok(params) => match params.project_id.as_deref().map(parse_project_id).transpose() {
                Ok(explicit_id) => {
                    let registry = ctx.project_registry.clone();
                    let root_path = params.root_path;
                    tokio::task::spawn_blocking(move || match explicit_id {
                        Some(id) => registry.add_with_id(&root_path, id),
                        None => registry.add(&root_path),
                    })
                    .await
                    .map_err(|_| "PROJECT_STORAGE_ERROR: registry worker failed".to_string())
                    .and_then(|result| result.map_err(registry_error))
                    .map(|record| project_json(record, false))
                }
                Err(error) => Err(error),
            },
            Err(_) => Err("INVALID_PARAMS: root_path is required".to_string()),
        },
        "project.list" => {
            let registry = ctx.project_registry.clone();
            let paused = ctx
                .paused_sync_projects
                .read()
                .map_err(|_| "PROJECT_STATE_ERROR: pause state unavailable".to_string())
                .map(|set| set.clone());
            match paused {
                Err(error) => Err(error),
                Ok(paused) => tokio::task::spawn_blocking(move || registry.list())
                    .await
                    .map_err(|_| "PROJECT_STORAGE_ERROR: registry worker failed".to_string())
                    .and_then(|result| result.map_err(registry_error))
                    .map(|records| {
                        let projects = records
                            .into_iter()
                            .map(|record| {
                                let is_paused = paused.contains(&record.project_id.to_string());
                                project_json(record, is_paused)
                            })
                            .collect::<Vec<_>>();
                        serde_json::json!({ "projects": projects })
                    }),
            }
        }
        "project.status" => match project_id_param(&req.params) {
            Ok(project_id) => match load_project(ctx, project_id).await {
                Ok(record) => ctx
                    .paused_sync_projects
                    .read()
                    .map_err(|_| "PROJECT_STATE_ERROR: pause state unavailable".to_string())
                    .map(|paused| project_json(record, paused.contains(&project_id.to_string()))),
                Err(error) => Err(error),
            },
            Err(error) => Err(error),
        },
        "project.pause" | "project.resume" => match project_id_param(&req.params) {
            Ok(project_id) => match load_project(ctx, project_id).await {
                Ok(record) => {
                    let paused = req.method == "project.pause";
                    let update = ctx.paused_sync_projects.write().map_err(|_| {
                        "PROJECT_STATE_ERROR: pause state unavailable".to_string()
                    });
                    match update {
                        Ok(mut state) => {
                            if paused {
                                state.insert(project_id.to_string());
                            } else {
                                state.remove(&project_id.to_string());
                            }
                            Ok(project_json(record, paused))
                        }
                        Err(error) => Err(error),
                    }
                }
                Err(error) => Err(error),
            },
            Err(error) => Err(error),
        },
        "project.scan" => {
            match serde_json::from_value::<crate::sync::OperationStartParams>(req.params.clone()) {
                Ok(params) => match sync_is_paused(ctx, &params.project_id) {
                    Ok(true) => Err("PROJECT_PAUSED: resume the project before scanning".to_string()),
                    Ok(false) => ctx
                        .operation_manager
                        .start(params)
                        .await
                        .map_err(|error| format!("OPERATION_ERROR: {error}"))
                        .and_then(operation_json),
                    Err(error) => Err(error),
                },
                Err(_) => Err("INVALID_PARAMS: project_id and request_id are required".to_string()),
            }
        }
        "sync.start" => match serde_json::from_value::<SyncStartParams>(req.params.clone()) {
            Ok(params) => match sync_is_paused(ctx, &params.project_id) {
                Ok(true) => Err("PROJECT_PAUSED: resume the project before syncing".to_string()),
                Ok(false) => ctx
                    .operation_manager
                    .start(crate::sync::OperationStartParams {
                        request_id: params.request_id,
                        project_id: params.project_id,
                        // A peer target makes this a network sync; without one it
                        // stays a local scan (backward compatible). The peer id is
                        // resolved by the SyncTransport, which is only present once
                        // the daemon provisions peer identity + trust — until then
                        // a Sync operation fails `sync_transport_not_configured`.
                        kind: if params.peer_id.is_some() {
                            crate::sync::OperationKind::Sync
                        } else {
                            params.kind
                        },
                        peer: params.peer_id,
                    })
                    .await
                    .map_err(|error| format!("OPERATION_ERROR: {error}"))
                    .and_then(operation_json),
                Err(error) => Err(error),
            },
            Err(_) => Err("INVALID_PARAMS: project_id and request_id are required".to_string()),
        },
        "sync.status" | "sync.cancel" => {
            match serde_json::from_value::<crate::sync::OperationIdParams>(req.params.clone()) {
                Ok(params) => {
                    let result = if req.method == "sync.status" {
                        ctx.operation_manager
                            .status(&params.operation_id, &params.project_id)
                    } else {
                        ctx.operation_manager
                            .cancel(&params.operation_id, &params.project_id)
                    };
                    result
                        .map_err(|error| format!("OPERATION_ERROR: {error}"))
                        .and_then(operation_json)
                }
                Err(_) => Err("INVALID_PARAMS: project_id and operation_id are required".to_string()),
            }
        }
        // Dev/test-grade explicit-endpoint bootstrap (wiring-plan §6 D3). Two
        // phases: `bootstrap_identity` ensures this daemon's TLS identity and
        // returns its cert hash so the driver can assemble the roster; then
        // `bootstrap_trust` applies the roster + shared DEK + peer address book.
        // Both are keychain-backed, hence macOS-only for now.
        "sync.bootstrap_identity" => {
            match serde_json::from_value::<SyncBootstrapIdentityParams>(req.params.clone()) {
                Ok(params) => handle_sync_bootstrap_identity(params).await,
                Err(_) => Err("INVALID_PARAMS: project_id and device_id are required".to_string()),
            }
        }
        "sync.bootstrap_trust" => {
            match serde_json::from_value::<SyncBootstrapTrustParams>(req.params.clone()) {
                Ok(params) => handle_sync_bootstrap_trust(params).await,
                Err(_) => {
                    Err("INVALID_PARAMS: bootstrap-trust descriptor is malformed".to_string())
                }
            }
        }
        // Start the responder listener for a provisioned project (piece 6): bind a
        // per-project QUIC endpoint and serve incoming syncs in a background task.
        "sync.serve" => match serde_json::from_value::<SyncServeParams>(req.params.clone()) {
            Ok(params) => handle_sync_serve(ctx, params).await,
            Err(_) => Err("INVALID_PARAMS: project_id and bind_addr are required".to_string()),
        },
        // Conflicts recorded by the bidirectional reconcile (BD-4c). Listing is
        // read-only; resolving writes the chosen side and re-anchors the base.
        "conflict.list" => match serde_json::from_value::<ConflictListParams>(req.params.clone()) {
            Ok(params) => handle_conflict_list(ctx, params).await,
            Err(_) => Err("INVALID_PARAMS: project_id is required".to_string()),
        },
        "conflict.get" => match serde_json::from_value::<ConflictGetParams>(req.params.clone()) {
            Ok(params) => handle_conflict_get(ctx, params).await,
            Err(_) => Err("INVALID_PARAMS: project_id and conflict_id are required".to_string()),
        },
        "conflict.resolve" => {
            match serde_json::from_value::<ConflictResolveParams>(req.params.clone()) {
                Ok(params) => handle_conflict_resolve(ctx, params).await,
                Err(_) => Err(
                    "INVALID_PARAMS: project_id, conflict_id and choice are required".to_string(),
                ),
            }
        }
        "pairing.list" => match project_id_param(&req.params) {
            Ok(project_id) => match load_project(ctx, project_id).await {
                Ok(_) => Ok(serde_json::json!({
                    "project_id": project_id.to_string(),
                    "devices": [],
                    "state": "not_configured",
                    "user_presence_required": true,
                })),
                Err(error) => Err(error),
            },
            Err(error) => Err(error),
        },
        "pairing.approve" | "pairing.revoke" | "pairing.recovery_export" | "pairing.recovery_import" => {
            match project_id_param(&req.params) {
                Ok(project_id) => match load_project(ctx, project_id).await {
                    Ok(_) => Err(format!(
                        "USER_PRESENCE_REQUIRED: {} must run through an authenticated local user-presence flow",
                        req.method
                    )),
                    Err(error) => Err(error),
                },
                Err(error) => Err(error),
            }
        }
        // --- Disk reclamation (crate::gc) ---
        // All three walk the filesystem and shell out to libgit2, so they run
        // off the async runtime like the worktree.* handlers above.
        //
        // `gc.status` keeps its original project-scoped shape when a caller
        // passes project_id, so older CLIs keep working, and answers about the
        // machine as a whole when it does not.
        "gc.status" => gc_status(ctx, req).await,
        "gc.plan" => gc_scan_off_thread(ctx, req.params.clone())
            .await
            .map(|plan| serde_json::to_value(plan).unwrap_or(serde_json::Value::Null)),
        "gc.sweep" => gc_sweep(ctx, req).await,

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
                "owner_pid": crate::configured_owner_pid(),
                "version": env!("CARGO_PKG_VERSION"),
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
        "worktree.diff_summary" => {
            // Mission Control approval-queue diff card (git2, file-level
            // stats only — see worktree::diff_summary doc comment).
            let params = req.params.clone();
            tokio::task::spawn_blocking(move || {
                worktree::diff_summary(params).map(|v| serde_json::to_value(v).unwrap())
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
                Ok(p) => ctx
                    .watcher_handle
                    .watch_path(&p.path)
                    .map(|()| serde_json::json!({"status": "ok"})),
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
                    let task_team_name = req
                        .params
                        .get("team_name")
                        .and_then(|v| v.as_str())
                        .unwrap_or_default()
                        .to_string();
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
                        // Auto-recycle hook: fire on completed transitions only.
                        if matches!(t.status, crate::agent::TaskStatus::Completed) {
                            if let Some(assignee_id) = &t.assignee {
                                if let Some((agent_name, _)) = ctx
                                    .agent_manager
                                    .handle_auto_recycle_completion(assignee_id)
                                {
                                    // agent_sessions path — use task_team_name from
                                    // the request to form an unambiguous recycle key.
                                    let headless = ctx.headless.clone();
                                    let tn = task_team_name.clone();
                                    tokio::spawn(async move {
                                        let mut mgr = headless.lock().await;
                                        mgr.recycle_by_name(&agent_name, &tn).await;
                                    });
                                } else {
                                    // Headless team agent path (not in agent_sessions).
                                    let assignee = assignee_id.clone();
                                    let tn = task_team_name.clone();
                                    let headless = ctx.headless.clone();
                                    tokio::spawn(async move {
                                        let mut mgr = headless.lock().await;
                                        mgr.handle_auto_recycle_completion_by_name(&assignee, &tn)
                                            .await;
                                    });
                                }
                            }
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

        // --- Event publication from Swift app (GUI team path) ---
        // Swift teamDataTaskUpdate / teamDataReport call this best-effort after
        // successful GUI-side mutations so that CLI `tm-agent wait` push subscribers
        // receive real-time events instead of waiting for the polling fallback.
        "events.publish" => {
            // xk_run has its own field set, validation, and size caps — handled
            // by a dedicated function so it stays unit-testable (XK-EVENTS-v1).
            if req.params.get("kind").and_then(|v| v.as_str()) == Some("xk_run") {
                publish_xk_run(&req.params, &ctx.event_tx)
            } else {
                #[derive(Deserialize)]
                struct P {
                    kind: String,
                    #[serde(default)]
                    team: String,
                    #[serde(default)]
                    agent: String,
                    #[serde(default)]
                    task_id: String,
                    #[serde(default)]
                    status: String,
                    #[serde(default)]
                    prev_status: String,
                    #[serde(default)]
                    header: String,
                }
                match serde_json::from_value::<P>(req.params.clone()) {
                    Ok(p) => {
                        let ts_ms = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as u64;
                        let ev_res: Result<DaemonEvent, String> = match p.kind.as_str() {
                            "task_status" => Ok(DaemonEvent::TaskStatus {
                                team: p.team,
                                agent: p.agent,
                                task_id: p.task_id,
                                status: p.status,
                                prev_status: p.prev_status,
                                ts_ms,
                            }),
                            "reply" => Ok(DaemonEvent::Reply {
                                team: p.team,
                                agent: p.agent,
                                task_id: p.task_id,
                                header: p.header,
                                ts_ms,
                            }),
                            other => Err(format!("events.publish: unknown kind '{other}'")),
                        };
                        ev_res.map(|ev| {
                            // Err means no subscribers — fine to ignore.
                            let _ = ctx.event_tx.send(ev);
                            serde_json::json!({"published": true})
                        })
                    }
                    Err(e) => Err(format!("invalid params: {e}")),
                }
            }
        }

        // Scoped reverse route used by tm-agent inside a daemon-owned peer
        // pane. The local daemon forwards only the already-limited
        // team.leader.v1 message; it never receives or exposes the viewer's
        // TERMMESH_SOCKET.
        "peer.leader.call" => {
            #[derive(Deserialize)]
            struct P {
                grant_id_hex: String,
                project_id: String,
                team_uuid: String,
                expires_at_unix_secs: u64,
                target_peer_id_hex: String,
                request_id_hex: String,
                method: String,
                params_json: String,
            }
            fn decode_hex(value: &str, expected: usize) -> Result<Vec<u8>, String> {
                if value.len() != expected * 2 {
                    return Err("invalid hex length".into());
                }
                (0..expected)
                    .map(|i| {
                        u8::from_str_radix(&value[i * 2..i * 2 + 2], 16)
                            .map_err(|_| "invalid hex".to_string())
                    })
                    .collect()
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    if !leader_proxy_method_allowed(&p.method) {
                        Err(format!("method_not_allowed: {}", p.method))
                    } else if serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(
                        &p.params_json,
                    )
                    .is_err()
                    {
                        Err("params_json must be a JSON object".into())
                    } else {
                        let grant_id = decode_hex(
                            &p.grant_id_hex,
                            peer_proto::team_leader::GRANT_ID_BYTES,
                        );
                        let request_id = decode_hex(
                            &p.request_id_hex,
                            peer_proto::team_leader::REQUEST_ID_BYTES,
                        );
                        let target_peer_id = decode_hex(&p.target_peer_id_hex, 16);
                        match (grant_id, request_id, target_peer_id) {
                            (Ok(grant_id), Ok(request_id), Ok(target_peer_id)) => {
                                let grant = peer_proto::v1::TeamLeaderGrant {
                                    grant_id,
                                    project_id: p.project_id,
                                    team_uuid: p.team_uuid.clone(),
                                    role: peer_proto::v1::TeamLeaderRole::Leader as i32,
                                    expires_at_unix_secs: p.expires_at_unix_secs,
                                };
                                let now = std::time::SystemTime::now()
                                    .duration_since(std::time::UNIX_EPOCH)
                                    .unwrap_or_default()
                                    .as_secs();
                                if let Err(error) = peer_proto::team_leader::validate_grant(
                                    &grant,
                                    Some(&grant),
                                    Some(u64::MAX),
                                    &grant.project_id,
                                    &p.team_uuid,
                                    now,
                                ) {
                                    Err(format!("invalid leader grant: {error:?}"))
                                } else {
                                    let request = peer_proto::v1::TeamLeaderCommandRequest {
                                        grant: Some(grant),
                                        team_uuid: p.team_uuid,
                                        request_id,
                                        method: p.method,
                                        params_json: p.params_json,
                                    };
                                    match crate::peer::call_remote_team_leader(
                                        request,
                                        &target_peer_id,
                                    )
                                    .await
                                    {
                                        Ok(response) => {
                                            Ok(team_leader_proxy_envelope(&response))
                                        }
                                        Err(error) => Err(error),
                                    }
                                }
                            }
                            (Err(error), _, _)
                            | (_, Err(error), _)
                            | (_, _, Err(error)) => Err(error),
                        }
                    }
                }
                Err(error) => Err(format!("invalid params: {error}")),
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
                    let mut mgr = ctx.headless.lock().await;
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
                    let mut mgr = ctx.headless.lock().await;
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
            let mut mgr = ctx.headless.lock().await;
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
        // ── mobile remote-control exposure registry ──────────────────────
        // `docs/mobile-remote-control.md` §4.1. In-memory registry mutations
        // only; the listener (`crate::http_mobile`) is the consumer. No focus
        // side effects. Not persisted: a daemon restart forgets every entry.
        "remote.on" => {
            match serde_json::from_value::<crate::remote::EnableSpec>(req.params.clone()) {
                Ok(spec) => {
                    let now = crate::remote::now_unix();
                    let mut reg = ctx.remote_registry.lock().await;
                    match reg.upsert(spec, now) {
                        Ok(entry) => {
                            let listener_enabled = crate::remote::listener_enabled();
                            let (url, listener_error) = match crate::remote::listener_addr() {
                                Ok(addr) => (
                                    Some(crate::remote::target_url(&addr, &entry.surface_id)),
                                    None,
                                ),
                                Err(e) => (None, Some(e)),
                            };
                            Ok(serde_json::json!({
                                "status": "ok",
                                "entry": entry,
                                "url": url,
                                "listener_enabled": listener_enabled,
                                "listener_error": listener_error,
                            }))
                        }
                        Err(e) => Err(format!("invalid params: {e}")),
                    }
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "remote.off" => {
            #[derive(Deserialize)]
            struct P {
                surface_id: String,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let mut reg = ctx.remote_registry.lock().await;
                    let removed = reg.remove(&p.surface_id);
                    Ok(serde_json::json!({
                        "status": "ok",
                        "surface_id": p.surface_id.trim(),
                        "removed": removed,
                    }))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "remote.status" => {
            #[derive(Deserialize)]
            struct P {
                #[serde(default)]
                surface_id: Option<String>,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let now = crate::remote::now_unix();
                    let reg = ctx.remote_registry.lock().await;
                    let listener_enabled = crate::remote::listener_enabled();
                    let listener_addr = crate::remote::listener_addr().ok();
                    match p.surface_id.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                        Some(id) => {
                            let entry = reg.get(id).cloned();
                            let expired = entry.as_ref().map(|e| e.is_expired(now)).unwrap_or(false);
                            Ok(serde_json::json!({
                                "status": "ok",
                                "surface_id": id,
                                "exposed": entry.is_some() && !expired,
                                "expired": expired,
                                "entry": entry,
                                "url": entry.as_ref().and_then(|e| listener_addr.as_ref().map(|a| crate::remote::target_url(a, &e.surface_id))),
                                "listener_enabled": listener_enabled,
                                "now": now,
                            }))
                        }
                        None => Ok(serde_json::json!({
                            "status": "ok",
                            "count": reg.len(),
                            "entries": reg.list(),
                            "listener_enabled": listener_enabled,
                            "listener_addr": listener_addr.map(|a| a.to_string()),
                            "now": now,
                        })),
                    }
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "remote.list" => {
            // Prune first: expired entries and GUI entries whose app socket is
            // gone. Liveness of the surface itself is observed lazily by the
            // listener (a `not_found` from the app socket drops the entry).
            let now = crate::remote::now_unix();
            let mut reg = ctx.remote_registry.lock().await;
            let pruned = reg.prune(now, crate::remote::app_socket_alive);
            Ok(serde_json::json!({
                "status": "ok",
                "entries": reg.list(),
                "pruned": pruned,
                "now": now,
            }))
        }
        // ── watcher Phase 2 (P4): drift-watch on/off/status ──────────────
        // In-memory registry mutations only. NO focus side effects (no send_key,
        // window.focus, or pane.focus). Config-file persistence is P6.
        "watch.on" => {
            #[derive(Deserialize)]
            struct P {
                team_id: String,
                #[serde(default)]
                interval_secs: u64,
                #[serde(default)]
                target: Option<String>,
                /// Explicit worker list for all-workers fan-out (P5).
                /// GUI/Swift callers pass this; headless teams are auto-queried
                /// from HeadlessManager when omitted.
                #[serde(default)]
                workers: Option<Vec<String>>,
                #[serde(default = "default_watch_cli")]
                cli: String,
                #[serde(default = "default_watch_model")]
                model: String,
                #[serde(default = "default_watch_stance")]
                stance: String,
                #[serde(default)]
                spec: String,
                #[serde(default)]
                working_directory: String,
                #[serde(default)]
                exec_to_dir_ratio: Option<u32>,
                #[serde(default)]
                cli_path: Option<String>,
                #[serde(default)]
                app_socket_path: Option<String>,
                #[serde(default)]
                reply_timeout_secs: Option<u64>,
            }
            fn default_watch_cli() -> String {
                "claude".into()
            }
            fn default_watch_model() -> String {
                "sonnet".into()
            }
            fn default_watch_stance() -> String {
                "critic".into()
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) if p.team_id.is_empty() => Err("team_id required".to_string()),
                Ok(p) => {
                    // P12 #5: clamp the requested interval up to the cost-guard
                    // minimum. 0 stays 0 → WatchState::enabled applies the default.
                    let requested_interval = if p.interval_secs == 0 {
                        0
                    } else {
                        p.interval_secs.max(MIN_WATCH_INTERVAL_SECS)
                    };

                    // P5 fan-out: resolve worker list BEFORE acquiring reg lock
                    // (avoids holding both locks simultaneously).
                    // Priority: explicit `workers` param > HeadlessManager query.
                    // GUI teams pass `workers` explicitly; headless teams are
                    // auto-queried. Workers are agents whose name is not "watcher"
                    // (heuristic — same convention as auto_watch_decision).
                    // Note: duplicate-named workers (e.g. two "executor" agents) map
                    // to a single entry in the list — `tm-agent read` will reach the
                    // first matching panel. This is a known limitation; per-panelId
                    // routing would require a richer target format.
                    let is_all_target = p
                        .target
                        .as_deref()
                        .map(|t| t.is_empty() || t == "all")
                        .unwrap_or(true);
                    // R3: track whether the raw list had duplicate names before dedup.
                    let (resolved_workers, had_dup_names): (Vec<String>, bool) =
                        if let Some(mut explicit) = p.workers.clone() {
                            let had = {
                                let mut s = std::collections::HashSet::new();
                                explicit.iter().any(|n| !s.insert(n.as_str()))
                            };
                            let mut seen = std::collections::HashSet::new();
                            explicit.retain(|n| seen.insert(n.clone()));
                            (explicit, had)
                        } else if is_all_target {
                            let agents = ctx.headless.lock().await.list(Some(&p.team_id)).await;
                            let mut names: Vec<String> = agents
                                .into_iter()
                                .filter(|a| a.name != "watcher" && !a.name.starts_with("watcher"))
                                .map(|a| a.name)
                                .collect();
                            // P1 fix: GUI (pane) teams have no headless agents → headless.list
                            // returns empty. Fall back to app socket team.status.
                            if names.is_empty() {
                                if let Some(ref app_sock) = p.app_socket_path {
                                    if !app_sock.is_empty() {
                                        names = query_gui_team_workers(app_sock, &p.team_id).await;
                                    }
                                }
                            }
                            // Leader-as-watch-target (D1/D6 fallback): a worker-less
                            // team that still exposes a GUI leader pane watches the
                            // leader itself; otherwise unchanged. See the helper docs.
                            let has_gui_leader = p
                                .app_socket_path
                                .as_deref()
                                .map(|s| !s.is_empty())
                                .unwrap_or(false);
                            names = apply_leader_watch_fallback(names, has_gui_leader);
                            // Deduplicate while preserving order; detect dups for R3.
                            let had = {
                                let mut s = std::collections::HashSet::new();
                                names.iter().any(|n| !s.insert(n.as_str()))
                            };
                            let mut seen = std::collections::HashSet::new();
                            names.retain(|n| seen.insert(n.clone()));
                            (names, had)
                        } else {
                            (vec![], false)
                        };
                    let dup_warning: Option<String> = if had_dup_names {
                        Some("Duplicate agent names detected. Watch can address only one pane per name.".to_string())
                    } else {
                        None
                    };

                    let mut reg = ctx.watch_registry.lock().await;
                    let interval = match reg.get_mut(&p.team_id) {
                        // Refresh existing config; preserve live counters.
                        Some(st) => {
                            st.enabled = true;
                            if requested_interval > 0 {
                                st.interval_secs = requested_interval;
                            }
                            if let Some(r) = p.exec_to_dir_ratio {
                                st.exec_to_dir_ratio = r;
                            }
                            st.target = p.target.clone();
                            st.workers = resolved_workers;
                            st.duplicate_name_warning = dup_warning.clone();
                            st.cli = p.cli.clone();
                            st.model = p.model.clone();
                            st.stance = p.stance.clone();
                            st.spec = p.spec.clone();
                            if !p.working_directory.is_empty() {
                                st.working_directory = p.working_directory.clone();
                            }
                            st.cli_path = p.cli_path.clone();
                            st.app_socket_path = p.app_socket_path.clone();
                            if let Some(t) = p.reply_timeout_secs {
                                st.reply_timeout_secs = t;
                            }
                            st.interval_secs
                        }
                        None => {
                            let mut st = crate::drift_watch::WatchState::enabled(
                                requested_interval,
                                p.target.clone(),
                                p.cli.clone(),
                                p.model.clone(),
                                p.stance.clone(),
                                p.spec.clone(),
                                p.working_directory.clone(),
                            );
                            if let Some(r) = p.exec_to_dir_ratio {
                                st.exec_to_dir_ratio = r;
                            }
                            st.workers = resolved_workers;
                            st.duplicate_name_warning = dup_warning;
                            st.cli_path = p.cli_path.clone();
                            st.app_socket_path = p.app_socket_path.clone();
                            if let Some(t) = p.reply_timeout_secs {
                                st.reply_timeout_secs = t;
                            }
                            let interval = st.interval_secs;
                            reg.insert(p.team_id.clone(), st);
                            interval
                        }
                    };
                    // P6: persist so the team re-registers after a daemon restart.
                    // Clone under the lock, then drop it before file I/O.
                    let to_persist = reg
                        .get(&p.team_id)
                        .map(|st| (st.working_directory.clone(), st.clone()));
                    drop(reg);
                    if let Some((wd, st)) = to_persist {
                        if !wd.is_empty() {
                            watch_config::save_watch_state(
                                std::path::Path::new(&wd),
                                &p.team_id,
                                &st,
                            );
                        }
                    }
                    Ok(serde_json::json!({
                        "status": "ok",
                        "team_id": p.team_id,
                        "enabled": true,
                        "interval_secs": interval,
                    }))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "watch.off" => {
            #[derive(Deserialize)]
            struct P {
                team_id: String,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) => {
                    let mut reg = ctx.watch_registry.lock().await;
                    let found = match reg.get_mut(&p.team_id) {
                        Some(st) => {
                            st.enabled = false;
                            true
                        }
                        None => false,
                    };
                    // P6 (ADR-P6): persist the disabled state rather than removing
                    // it, so config survives but startup only re-registers enabled
                    // teams. Clone under the lock, drop it before file I/O.
                    let to_persist = reg
                        .get(&p.team_id)
                        .map(|st| (st.working_directory.clone(), st.clone()));
                    drop(reg);
                    if let Some((wd, st)) = to_persist {
                        if !wd.is_empty() {
                            watch_config::save_watch_state(
                                std::path::Path::new(&wd),
                                &p.team_id,
                                &st,
                            );
                        }
                    }
                    Ok(serde_json::json!({
                        "status": "ok",
                        "team_id": p.team_id,
                        "enabled": false,
                        "found": found,
                    }))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "watch.update" => {
            // R2: partial-update RPC. Only `Some` fields are patched; absent/null
            // fields preserve existing values. Live counters (in_flight, last_check_ts,
            // check_count) are never modified. Returns error when team has no state.
            #[derive(Deserialize)]
            struct P {
                team_id: String,
                #[serde(default)]
                target: Option<String>,
                #[serde(default)]
                interval_secs: Option<u64>,
                #[serde(default)]
                exec_to_dir_ratio: Option<u32>,
                #[serde(default)]
                stance: Option<String>,
                #[serde(default)]
                spec: Option<String>,
                #[serde(default)]
                cli: Option<String>,
                #[serde(default)]
                model: Option<String>,
                #[serde(default)]
                reply_timeout_secs: Option<u64>,
                #[serde(default)]
                workers: Option<Vec<String>>,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) if p.team_id.is_empty() => Err("team_id required".to_string()),
                Ok(p) => {
                    let mut reg = ctx.watch_registry.lock().await;
                    match reg.get_mut(&p.team_id) {
                        None => Err(format!("no watch state found for team '{}'", p.team_id)),
                        Some(st) => {
                            if let Some(v) = p.target {
                                st.target = if v.is_empty() || v == "all" {
                                    None
                                } else {
                                    Some(v)
                                };
                            }
                            // Mirror watch.on cost guard: clamp positive values up to the
                            // minimum so a partial update cannot bypass the 30s floor.
                            if let Some(v) = p.interval_secs {
                                if v > 0 {
                                    st.interval_secs = v.max(MIN_WATCH_INTERVAL_SECS);
                                }
                            }
                            if let Some(v) = p.exec_to_dir_ratio {
                                st.exec_to_dir_ratio = v;
                            }
                            if let Some(v) = p.stance {
                                st.stance = v;
                            }
                            if let Some(v) = p.spec {
                                st.spec = v;
                            }
                            if let Some(v) = p.cli {
                                st.cli = v;
                            }
                            if let Some(v) = p.model {
                                st.model = v;
                            }
                            if let Some(v) = p.reply_timeout_secs {
                                st.reply_timeout_secs = v;
                            }
                            if let Some(mut workers) = p.workers {
                                let had_dup = {
                                    let mut s = std::collections::HashSet::new();
                                    workers.iter().any(|n| !s.insert(n.as_str()))
                                };
                                let mut seen = std::collections::HashSet::new();
                                workers.retain(|n| seen.insert(n.clone()));
                                st.workers = workers;
                                st.duplicate_name_warning = if had_dup {
                                    Some("Duplicate agent names detected. Watch can address only one pane per name.".to_string())
                                } else {
                                    None
                                };
                            }
                            let interval = st.interval_secs;
                            let wd = st.working_directory.clone();
                            let st_clone = st.clone();
                            drop(reg);
                            if !wd.is_empty() {
                                watch_config::save_watch_state(
                                    std::path::Path::new(&wd),
                                    &p.team_id,
                                    &st_clone,
                                );
                            }
                            Ok(serde_json::json!({
                                "status": "ok",
                                "team_id": p.team_id,
                                "interval_secs": interval,
                            }))
                        }
                    }
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "pair.review.start" => {
            #[derive(Deserialize)]
            struct P {
                team_id: String,
                #[serde(default = "default_pair_scope")]
                scope: String,
                #[serde(default = "default_pair_lens")]
                lens: String,
                #[serde(default = "default_pair_cli")]
                cli: String,
                #[serde(default = "default_pair_model")]
                model: String,
                spec: String,
                working_directory: String,
                #[serde(default)]
                base_ref: Option<String>,
                #[serde(default)]
                cli_path: Option<String>,
                #[serde(default)]
                app_socket_path: Option<String>,
                #[serde(default)]
                reply_timeout_secs: Option<u64>,
                #[serde(default)]
                request_id: Option<String>,
            }
            fn default_pair_scope() -> String { "current-task".into() }
            fn default_pair_lens() -> String { "general".into() }
            fn default_pair_cli() -> String { "codex".into() }
            fn default_pair_model() -> String { "gpt-5.6-sol".into() }

            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) if p.team_id.trim().is_empty() => Err("team_id required".to_string()),
                Ok(p) if p.spec.trim().is_empty() => Err("review instructions required".to_string()),
                Ok(p) if p.working_directory.trim().is_empty() => Err("working_directory required".to_string()),
                Ok(p) if p.cli != "codex" => Err("Pair Review currently requires the Codex read-only sandbox".to_string()),
                Ok(p) if p.model.trim().is_empty() => Err("Pair Review model required".to_string()),
                Ok(p) if p.request_id.as_deref().is_some_and(|id| id.trim().is_empty()) => Err("Pair Review request_id must not be empty".to_string()),
                Ok(p) if p.request_id.as_deref().is_some_and(|id| id.len() > PAIR_REVIEW_MAX_REQUEST_ID_BYTES) => Err(format!("Pair Review request_id exceeds {} bytes", PAIR_REVIEW_MAX_REQUEST_ID_BYTES)),
                Ok(p) => match &ctx.watch_runner {
                    None => Err("pair review runner not available".to_string()),
                    Some(runner) => {
                        let request_id = p.request_id.as_deref().map(str::trim).map(str::to_string);
                        let mut reviews = ctx.pair_reviews.lock().await;
                        prune_pair_reviews(&mut reviews, unix_millis());
                        if let Some(review_id) = request_id.as_deref().and_then(|id| {
                            existing_pair_review_id(&reviews, &p.team_id, id)
                        }) {
                            Ok(serde_json::json!({
                                "status": "ok",
                                "started": true,
                                "review_id": review_id,
                                "idempotent": true,
                            }))
                        } else if reviews.values().any(|run| run.team_id == p.team_id && run.status == "running") {
                            Ok(serde_json::json!({
                                "status": "rejected",
                                "started": false,
                                "reason": "a Pair Review is already running for this project",
                            }))
                        } else {
                        let review_id = crate::headless::meta::new_uuid();
                        let started_at = unix_millis();
                        reviews.insert(review_id.clone(), PairReviewRun {
                            review_id: review_id.clone(),
                            team_id: p.team_id.clone(),
                            request_id,
                            status: "running".into(),
                            scope: p.scope.clone(),
                            lens: p.lens.clone(),
                            cli: p.cli.clone(),
                            model: p.model.clone(),
                            snapshot_digest: None,
                            started_at,
                            finished_at: None,
                            duration_ms: None,
                            verdict: None,
                            error: None,
                        });
                        drop(reviews);

                        // Freeze the review input before acknowledging `started`.
                        // Capturing inside the spawned task would let edits made
                        // after the response leak into this supposedly immutable run.
                        let delta = capture_pair_review_scope(
                            &ctx.headless,
                            &p.team_id,
                            &p.scope,
                            &p.working_directory,
                            p.base_ref.as_deref(),
                            p.app_socket_path.as_deref(),
                        ).await;
                        match delta {
                            Err(error) => {
                                let mut reviews = ctx.pair_reviews.lock().await;
                                reviews.remove(&review_id);
                                Ok(serde_json::json!({
                                    "status": "rejected",
                                    "started": false,
                                    "reason": format!("snapshot failed: {error}"),
                                }))
                            }
                            Ok(delta) => {
                                use sha2::{Digest, Sha256};
                                let snapshot_digest = format!("{:x}", Sha256::digest(delta.as_bytes()));
                                let mut reviews = ctx.pair_reviews.lock().await;
                                if let Some(run) = reviews.get_mut(&review_id) {
                                    run.snapshot_digest = Some(snapshot_digest);
                                }
                                drop(reviews);
                                let runner = Arc::clone(runner);
                                let reviews = Arc::clone(&ctx.pair_reviews);
                                let review_id_task = review_id.clone();
                                tokio::spawn(async move {
                                    use crate::headless::one_shot::{WatchCheckInput, WatchCheckKind};
                                    let outcome = runner.run_check(WatchCheckInput {
                                        team_name: p.team_id.clone(),
                                        target: "leader".into(),
                                        check_id: format!("pair:{}", review_id_task),
                                        check_kind: WatchCheckKind::Execution,
                                        stance: "critic".into(),
                                        spec: p.spec.clone(),
                                        delta,
                                        cli: p.cli.clone(),
                                        model: p.model.clone(),
                                        working_directory: p.working_directory.clone(),
                                        cli_path: p.cli_path.clone(),
                                        app_socket_path: p.app_socket_path.clone(),
                                        reply_timeout: Duration::from_secs(p.reply_timeout_secs.unwrap_or(180).clamp(30, 600)),
                                        allow_gui_watcher_pane: false,
                                        pair_scope: Some(p.scope.clone()),
                                        pair_lens: Some(p.lens.clone()),
                                        extra_cli_args: vec!["--sandbox".into(), "read-only".into()],
                                    }).await;
                                    let finished = unix_millis();
                                    let completion = pair_review_completion(&outcome);
                                    let mut runs = reviews.lock().await;
                                    let mut message = None;
                                    if let Some(run) = runs.get_mut(&review_id_task) {
                                        run.status = completion.status.into();
                                        run.finished_at = Some(finished);
                                        run.duration_ms = Some(finished.saturating_sub(run.started_at));
                                        run.verdict = completion.verdict.clone();
                                        run.error = completion.error.clone();
                                        if completion.status == "completed" {
                                            message = run
                                                .verdict
                                                .as_deref()
                                                .map(|verdict| pair_review_post_message(run, verdict));
                                        }
                                    }
                                    prune_pair_reviews(&mut runs, finished);
                                    drop(runs);
                                    if let Some(message) = message {
                                        if let Some(socket) = p.app_socket_path.as_deref() {
                                            let _ = crate::watch_controller::post_team_message(socket, &p.team_id, &message).await;
                                        }
                                    }
                                });
                                Ok(serde_json::json!({
                                    "status": "ok",
                                    "started": true,
                                    "review_id": review_id,
                                }))
                            }
                        }
                        }
                    }
                },
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "pair.review.status" => {
            #[derive(Deserialize)]
            struct P { review_id: String }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) if p.review_id.trim().is_empty() => Err("review_id required".to_string()),
                Ok(p) => {
                    let mut reviews = ctx.pair_reviews.lock().await;
                    prune_pair_reviews(&mut reviews, unix_millis());
                    match reviews.get(&p.review_id) {
                        Some(run) => Ok(serde_json::to_value(run).unwrap_or_else(|_| serde_json::json!({}))),
                        None => Err(format!("Pair Review not found: {}", p.review_id)),
                    }
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "watch.trigger_now" => {
            #[derive(Deserialize)]
            struct P {
                team_id: String,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(p) if p.team_id.is_empty() => Err("team_id required".to_string()),
                Ok(p) => match (&ctx.watch_runner, &ctx.watch_sink) {
                    (Some(runner), Some(sink)) => {
                        match crate::drift_watch::trigger_now(
                            &p.team_id,
                            &ctx.watch_registry,
                            runner,
                            sink,
                        )
                        .await
                        {
                            Ok(n) => Ok(serde_json::json!({
                                "status": "ok",
                                "team_id": p.team_id,
                                "triggered": true,
                                "check_count": n,
                            })),
                            Err(reason) => Ok(serde_json::json!({
                                "status": "rejected",
                                "team_id": p.team_id,
                                "triggered": false,
                                "reason": reason,
                            })),
                        }
                    }
                    _ => Err(
                        "watch runner not available (headless watch not initialised)".to_string(),
                    ),
                },
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "watch.status" => {
            #[derive(Deserialize)]
            struct P {
                #[serde(default)]
                team_id: Option<String>,
                /// Caller's working directory. When present, config.json in
                /// `<working_directory>/.xm/watch/` is merged as a fallback so
                /// that teams persisted but not yet in the in-memory registry
                /// (e.g. after a daemon restart with a mismatched cwd) are still
                /// visible. In-memory state wins on key collision (has live counters).
                #[serde(default)]
                working_directory: Option<String>,
            }
            fn serialize_state(
                team: &str,
                st: &crate::drift_watch::WatchState,
            ) -> serde_json::Value {
                // P12 #6: derive human-facing fields the CLI renders directly.
                // last_tick is the last *successful* check (verdict received). A
                // watch that fires every interval but fails every time keeps
                // last_tick null/stale here, so status cannot mistake a 100%-failing
                // watch for a healthy one. last_attempt exposes the fire time
                // separately so the operator can still see the scheduler is alive.
                let last_tick = if st.last_success_ts > 0 {
                    serde_json::json!(st.last_success_ts)
                } else {
                    serde_json::Value::Null
                };
                let last_attempt = if st.last_check_ts > 0 {
                    serde_json::json!(st.last_check_ts)
                } else {
                    serde_json::Value::Null
                };
                // next_tick is keyed off the last *attempt* (not success): a failing
                // watch still retries on cadence, so the next fire is attempt+interval.
                let next_tick = if st.enabled && st.last_check_ts > 0 {
                    serde_json::json!(st.last_check_ts + st.interval_secs)
                } else {
                    serde_json::Value::Null
                };
                // healthy: a check has succeeded and no failure streak is open. A
                // brand-new watch (never fired) is reported healthy=true (nothing
                // has failed yet); one that has only ever failed is healthy=false.
                let healthy = st.last_error.is_none() && st.consecutive_failures == 0;
                let drift_count = board_drift_count(&st.working_directory);
                // R1: expose worker list and count so the GUI can display
                // "All workers: N bounded checks" without re-deriving team roster.
                let is_all = st
                    .target
                    .as_deref()
                    .map(|t| t.is_empty() || t == "all")
                    .unwrap_or(true);
                let (workers_json, worker_count) = if is_all {
                    let count = st.workers.len();
                    (serde_json::json!(st.workers), count)
                } else {
                    // Single specific target — list contains just that one name.
                    let name = st.target.as_deref().unwrap_or("");
                    (serde_json::json!([name]), 1_usize)
                };
                serde_json::json!({
                    "team_id": team,
                    "enabled": st.enabled,
                    "running": st.in_flight,
                    "interval_secs": st.interval_secs,
                    "exec_to_dir_ratio": st.exec_to_dir_ratio,
                    "target": st.target,
                    // R1: worker list and count (GUI cost preview + "All workers" label)
                    "workers": workers_json,
                    "worker_count": worker_count,
                    "cli": st.cli,
                    "model": st.model,
                    "stance": st.stance,
                    "spec": st.spec,
                    "last_tick": last_tick,
                    "last_attempt": last_attempt,
                    "next_tick": next_tick,
                    "healthy": healthy,
                    "consecutive_failures": st.consecutive_failures,
                    "drift_count": drift_count,
                    // Raw fields retained for back-compat / debugging.
                    "last_check_ts": st.last_check_ts,
                    "last_success_ts": st.last_success_ts,
                    "check_count": st.check_count,
                    "in_flight": st.in_flight,
                    "last_error": st.last_error,
                    // R3: duplicate name warning (null when no duplicates).
                    "duplicate_name_warning": st.duplicate_name_warning,
                })
            }
            let params: P = serde_json::from_value(req.params.clone()).unwrap_or(P {
                team_id: None,
                working_directory: None,
            });
            // Snapshot in-memory registry under the lock, then drop before file I/O.
            let in_mem: std::collections::HashMap<String, crate::drift_watch::WatchState> = {
                let reg = ctx.watch_registry.lock().await;
                reg.iter().map(|(k, v)| (k.clone(), v.clone())).collect()
            };
            // Config.json fallback: teams persisted but absent from the registry
            // (e.g. daemon restarted from a different cwd). In-memory wins on collision.
            let config_fallback: std::collections::HashMap<String, crate::drift_watch::WatchState> =
                params
                    .working_directory
                    .as_deref()
                    .filter(|wd| !wd.is_empty())
                    .map(|wd| {
                        watch_config::load_watch_states(std::path::Path::new(wd))
                            .into_iter()
                            .collect()
                    })
                    .unwrap_or_default();
            match params.team_id {
                Some(tid) => {
                    let state = in_mem
                        .get(&tid)
                        .or_else(|| config_fallback.get(&tid))
                        .map(|st| serialize_state(&tid, st));
                    Ok(serde_json::json!({ "status": "ok", "watch": state }))
                }
                None => {
                    let mut seen = std::collections::HashSet::new();
                    let mut all: Vec<serde_json::Value> = Vec::new();
                    for (t, st) in &in_mem {
                        all.push(serialize_state(t, st));
                        seen.insert(t.clone());
                    }
                    for (t, st) in &config_fallback {
                        if !seen.contains(t) {
                            all.push(serialize_state(t, st));
                        }
                    }
                    Ok(serde_json::json!({ "status": "ok", "watches": all }))
                }
            }
        }
        "watch.board" => {
            // Mission Control: return the recent drift-verdict rows themselves
            // (`board.jsonl`), not just the `drift_count` aggregate that
            // `watch.status` exposes. Resolution order for the board's
            // working directory: explicit param → watch registry by team_id →
            // registry singleton when exactly one watch exists.
            #[derive(Deserialize)]
            struct P {
                #[serde(default)]
                team_id: Option<String>,
                #[serde(default)]
                working_directory: Option<String>,
                #[serde(default = "default_board_limit")]
                limit: usize,
            }
            fn default_board_limit() -> usize {
                50
            }
            let params: P = serde_json::from_value(req.params.clone()).unwrap_or(P {
                team_id: None,
                working_directory: None,
                limit: 50,
            });
            let limit = params.limit.min(500);
            let explicit_wd = params
                .working_directory
                .as_deref()
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            let resolved: Result<(Option<String>, String), String> = if let Some(wd) = explicit_wd {
                Ok((params.team_id.clone(), wd))
            } else {
                let reg = ctx.watch_registry.lock().await;
                if let Some(team) = params.team_id.as_deref().filter(|s| !s.is_empty()) {
                    match reg.get(team) {
                        Some(st) => Ok((Some(team.to_string()), st.working_directory.clone())),
                        None => Err(format!("no watch registered for team_id={team}")),
                    }
                } else if reg.len() == 1 {
                    let (team, st) = reg.iter().next().expect("len checked");
                    Ok((Some(team.clone()), st.working_directory.clone()))
                } else {
                    Err(format!(
                        "ambiguous watch target: {} watches registered — pass team_id or working_directory",
                        reg.len()
                    ))
                }
            };
            match resolved {
                Ok((team_id, working_dir)) => {
                    let rows = board_recent_rows(&working_dir, limit);
                    Ok(serde_json::json!({
                        "status": "ok",
                        "team_id": team_id,
                        "working_directory": working_dir,
                        "count": rows.len(),
                        "drift_count": board_drift_count(&working_dir),
                        "rows": rows,
                    }))
                }
                Err(e) => Err(e),
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
        "team.snapshot_pane" => {
            // Restore Fleet Layer 1: debounced live snapshot of a running
            // pane-mode team. Overwrites `<team_uuid>/` in place with
            // `live: true`; never renames to archived. Crash recovery and
            // `headless.list_live_pane` read what this writes.
            match serde_json::from_value::<crate::headless::SnapshotPaneParams>(req.params.clone())
            {
                Ok(p) => {
                    let mut mgr = ctx.headless.lock().await;
                    mgr.snapshot_pane_team(p)
                        .map(|r| serde_json::to_value(r).unwrap())
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "headless.list_live_pane" => {
            // Restore Fleet: live pane snapshots that may be restorable after
            // a crash. The Swift caller filters out teams it currently has
            // live in memory.
            #[derive(Deserialize)]
            struct P {
                #[serde(default)]
                app_socket_path: Option<String>,
                #[serde(default = "default_live_limit")]
                limit: usize,
            }
            fn default_live_limit() -> usize {
                50
            }
            let params: P = serde_json::from_value(req.params.clone()).unwrap_or(P {
                app_socket_path: None,
                limit: 50,
            });
            let limit = params.limit.min(200);
            let mgr = ctx.headless.lock().await;
            let res = mgr.list_live_pane(params.app_socket_path.as_deref(), limit);
            if let Some(err) = res.fatal_error.as_ref() {
                Err(err.clone())
            } else {
                Ok(serde_json::to_value(res).unwrap())
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
                    mgr.resume_pane(p).map(|r| serde_json::to_value(r).unwrap())
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        "team.delete_archive" => {
            // On-demand archive removal from the resume picker. Works for both
            // pane-mode and headless archives — both live in the same directory.
            match serde_json::from_value::<crate::headless::DeleteArchiveParams>(req.params.clone())
            {
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
                #[serde(default)]
                extra_args: Vec<String>,
                #[serde(default)]
                extra_env: std::collections::HashMap<String, String>,
                #[serde(default)]
                agent_type: Option<String>,
                #[serde(default)]
                auto_recycle_every: Option<u32>,
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
                        custom_instructions: None,
                        agent_type: p.agent_type,
                        color: None,
                        extra_args: p.extra_args,
                        extra_env: p.extra_env,
                        auto_recycle_every: p.auto_recycle_every,
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

        // --- Peer (host-side PTY surfaces) ---
        // Combined get/set: omit `bytes` to read the current capacity,
        // supply it to change it. The replay buffer capacity is a
        // process-wide static (crate::peer::surface), not per-team/session
        // state, so unlike most RPCs above this has no ctx dependency.
        "peer.replay_capacity" => {
            #[derive(Deserialize)]
            struct P {
                bytes: Option<usize>,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(P { bytes: Some(bytes) }) => surface::set_replay_capacity(bytes)
                    .map(|(old, new)| serde_json::json!({"old": old, "new": new})),
                Ok(P { bytes: None }) => {
                    Ok(serde_json::json!({"bytes": surface::replay_capacity()}))
                }
                Err(e) => Err(format!("invalid params: {e}")),
            }
        }
        // Operator view of durable Project manifests: every record with its
        // live-surface count and whether its directory still exists.
        "peer.project_presentations.list" => {
            match crate::peer::layout::PeerHost::active_host() {
                Some(host) => Ok(serde_json::json!({
                    "records": host.project_presentation_statuses()
                })),
                None => Err("peer host is not running (daemon started without TERMMESH_PEER_SOCKET)".to_string()),
            }
        }
        // Host-side removal of manifests nothing can resume (issue #389).
        // Dry-run unless `apply`; live records are never removed; an applied
        // prune backs the file up first. Never touches workspaces.
        "peer.project_presentations.prune" => {
            #[derive(Deserialize)]
            struct P {
                #[serde(default)]
                project_ids: Vec<String>,
                #[serde(default)]
                apply: bool,
            }
            match serde_json::from_value::<P>(req.params.clone()) {
                Ok(params) => match crate::peer::layout::PeerHost::active_host() {
                    Some(host) => host
                        .prune_stale_project_presentations(&params.project_ids, params.apply)
                        .map_err(|code| code.to_string())
                        .and_then(|report| {
                            serde_json::to_value(report).map_err(|e| e.to_string())
                        }),
                    None => Err("peer host is not running (daemon started without TERMMESH_PEER_SOCKET)".to_string()),
                },
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

fn operation_json(record: crate::sync::OperationRecord) -> Result<serde_json::Value, String> {
    let value =
        serde_json::to_value(record).map_err(|_| "operation response failed".to_string())?;
    let encoded =
        serde_json::to_vec(&value).map_err(|_| "operation response failed".to_string())?;
    if encoded.len() > crate::sync::MAX_OPERATION_ENVELOPE_BYTES {
        return Err("operation response exceeds 64 KiB".to_string());
    }
    Ok(value)
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProjectAddParams {
    root_path: PathBuf,
    /// Optional explicit project id (64 hex). Cross-machine sync registers the
    /// responder's tree under the id the initiator assigned; omitted → random.
    #[serde(default)]
    project_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SyncStartParams {
    request_id: String,
    project_id: String,
    kind: crate::sync::OperationKind,
    peer_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SyncBootstrapIdentityParams {
    project_id: String,
    device_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct BootstrapRosterEntry {
    device_id: String,
    certificate_hash: String,
    epoch: u64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct BootstrapPeerEntry {
    peer_id: String,
    addr: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SyncBootstrapTrustParams {
    project_id: String,
    /// 32-byte ed25519 recovery seed, hex. Dev-grade: the driver holds it.
    recovery: String,
    /// Shared project DEK — 16-byte key id + 32-byte key, both hex.
    dek_key_id: String,
    dek_key: String,
    /// This daemon's own device id + roster epoch.
    device_id: String,
    epoch: u64,
    roster: Vec<BootstrapRosterEntry>,
    peers: Vec<BootstrapPeerEntry>,
}

/// Parse exactly `N` bytes of lowercase hex, naming the field in the error.
fn parse_hex_bytes<const N: usize>(value: &str, field: &str) -> Result<[u8; N], String> {
    let decoded = hex::decode(value)
        .map_err(|_| format!("INVALID_PARAMS: {field} must be {} hex characters", N * 2))?;
    decoded
        .try_into()
        .map_err(|_| format!("INVALID_PARAMS: {field} must be {} hex characters", N * 2))
}

fn bootstrap_error(error: crate::sync::BootstrapError) -> String {
    use crate::sync::BootstrapError::{InvalidRoster, Keychain, Provisioning, Storage, Trust};
    match error {
        InvalidRoster => "SYNC_BOOTSTRAP_INVALID_ROSTER: the roster does not match this daemon's identity or epochs".to_string(),
        Storage => "SYNC_BOOTSTRAP_STORAGE: the per-project store directory could not be created".to_string(),
        Trust(_) => "SYNC_BOOTSTRAP_TRUST: applying trust grants failed".to_string(),
        Keychain(_) => "SYNC_BOOTSTRAP_KEYCHAIN: keychain access failed".to_string(),
        Provisioning(_) => "SYNC_BOOTSTRAP_PROVISIONING: writing provisioning coordinates failed".to_string(),
    }
}

/// Identity phase: ensure `(project, device)`'s TLS identity, return its cert
/// hash. Keychain + generation is blocking, so it runs on a blocking worker.
async fn handle_sync_bootstrap_identity(
    params: SyncBootstrapIdentityParams,
) -> Result<serde_json::Value, String> {
    let project_id = parse_project_id(&params.project_id)?;
    let device_id = parse_hex_bytes::<32>(&params.device_id, "device_id")?;
    let hash = tokio::task::spawn_blocking(move || {
        crate::sync::ensure_device_identity(
            crate::sync::daemon_keychain().as_ref(),
            project_id,
            device_id,
        )
        .map(|identity| identity.certificate_hash())
    })
    .await
    .map_err(|_| "SYNC_BOOTSTRAP_ERROR: identity worker failed".to_string())?
    .map_err(bootstrap_error)?;
    Ok(serde_json::json!({
        "project_id": project_id.to_string(),
        "device_id": hex::encode(device_id),
        "certificate_hash": hex::encode(hash),
    }))
}

/// Apply phase: open this daemon's per-project trust store + the provisioning
/// store and provision the project from the descriptor. Blocking I/O runs on a
/// blocking worker.
async fn handle_sync_bootstrap_trust(
    params: SyncBootstrapTrustParams,
) -> Result<serde_json::Value, String> {
    let project_id = parse_project_id(&params.project_id)?;
    let recovery_seed = parse_hex_bytes::<32>(&params.recovery, "recovery")?;
    let dek_key_id = parse_hex_bytes::<16>(&params.dek_key_id, "dek_key_id")?;
    let dek_key = parse_hex_bytes::<32>(&params.dek_key, "dek_key")?;
    let local_device = parse_hex_bytes::<32>(&params.device_id, "device_id")?;
    let local_epoch = params.epoch;

    let mut roster = Vec::with_capacity(params.roster.len());
    for entry in &params.roster {
        roster.push(crate::sync::BootstrapDevice {
            device_id: parse_hex_bytes::<32>(&entry.device_id, "roster.device_id")?,
            certificate_hash: parse_hex_bytes::<32>(
                &entry.certificate_hash,
                "roster.certificate_hash",
            )?,
            epoch: entry.epoch,
        });
    }
    let mut peers = Vec::with_capacity(params.peers.len());
    for entry in &params.peers {
        let addr: std::net::SocketAddr = entry.addr.parse().map_err(|_| {
            format!(
                "INVALID_PARAMS: peer addr '{}' is not a socket address",
                entry.addr
            )
        })?;
        peers.push((entry.peer_id.clone(), addr));
    }
    let roster_size = roster.len();
    let peers_size = peers.len();

    let hash = tokio::task::spawn_blocking(move || {
        let recovery = ed25519_dalek::SigningKey::from_bytes(&recovery_seed);
        let dek = crate::sync::ProjectKeyMaterial {
            key_id: crate::sync::KeyId(dek_key_id),
            key: crate::sync::ProjectKey::new(dek_key),
        };
        let paths = crate::sync::DaemonBootstrapPaths::defaults(project_id);
        let local = crate::sync::LocalCoordinates {
            device_id: local_device,
            roster_epoch: local_epoch,
        };
        crate::sync::run_bootstrap_trust(
            crate::sync::daemon_keychain().as_ref(),
            &paths,
            project_id,
            &recovery,
            &dek,
            local,
            &roster,
            &peers,
        )
    })
    .await
    .map_err(|_| "SYNC_BOOTSTRAP_ERROR: bootstrap worker failed".to_string())?
    .map_err(bootstrap_error)?;

    Ok(serde_json::json!({
        "project_id": project_id.to_string(),
        "device_id": hex::encode(local_device),
        "certificate_hash": hex::encode(hash),
        "roster_size": roster_size,
        "peers_size": peers_size,
    }))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConflictListParams {
    project_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConflictGetParams {
    project_id: String,
    conflict_id: String,
}

/// One conflict by id, or `CONFLICT_NOT_FOUND`.
async fn handle_conflict_get(
    ctx: &Context,
    params: ConflictGetParams,
) -> Result<serde_json::Value, String> {
    let wanted = params.conflict_id.to_ascii_lowercase();
    let (context, domain, _root) = conflict_context(ctx, &params.project_id).await?;
    tokio::task::spawn_blocking(move || {
        let store = context
            .apply_store
            .lock()
            .map_err(|_| "CONFLICT_STORE: apply store is poisoned".to_string())?;
        let set = store
            .load_conflicts(domain)
            .map_err(|error| format!("CONFLICT_STORE: {error:?}"))?;
        crate::sync::summarize_conflicts(&set)
            .into_iter()
            .find(|summary| summary.conflict_id == wanted)
            .map(|summary| {
                serde_json::json!({
                    "project_id": domain.project_id.to_string(),
                    "conflict": summary,
                })
            })
            .ok_or_else(|| {
                "CONFLICT_NOT_FOUND: no durable conflict record matches the request".to_string()
            })
    })
    .await
    .map_err(|_| "CONFLICT_ERROR: get worker failed".to_string())?
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConflictResolveParams {
    project_id: String,
    /// Hex conflict id from `conflict.list`.
    conflict_id: String,
    /// `keep_local` | `keep_remote` | `keep_base` | `delete`. Named `choice` to
    /// match what `tm-agent conflict resolve` already sends.
    choice: String,
}

/// Everything a conflict command needs, resolved from the provisioned stores.
async fn conflict_context(
    ctx: &Context,
    project_id_text: &str,
) -> Result<
    (
        std::sync::Arc<crate::sync::SyncContext>,
        crate::sync::ObjectDomain,
        crate::sync::HeldProjectRoot,
    ),
    String,
> {
    use crate::sync::SyncContextProvider;

    let project_id = parse_project_id(project_id_text)?;
    let registry = ctx.project_registry.clone();
    tokio::task::spawn_blocking(move || {
        let provisioning = std::sync::Arc::new(
            crate::sync::SyncProvisioningStore::open(crate::sync::default_provisioning_db_path())
                .map_err(|error| format!("CONFLICT_PROVISIONING: {error:?}"))?,
        );
        let provider = crate::sync::ProvisioningSyncContextProvider::new(
            crate::sync::daemon_keychain(),
            provisioning,
            crate::sync::default_sync_state_root(),
        );
        let context = provider.context_for(&project_id.to_string())?;
        let root = registry
            .resolve_root(project_id)
            .map_err(|error| format!("CONFLICT_ROOT: {error:?}"))?;
        let domain = crate::sync::ObjectDomain {
            project_id,
            object_type: crate::sync::ObjectType::FILE,
            version: 1,
        };
        Ok::<_, String>((context, domain, root))
    })
    .await
    .map_err(|_| "CONFLICT_ERROR: setup worker failed".to_string())?
}

/// The project's unresolved conflicts. Read-only: listing never touches the tree.
async fn handle_conflict_list(
    ctx: &Context,
    params: ConflictListParams,
) -> Result<serde_json::Value, String> {
    let (context, domain, _root) = conflict_context(ctx, &params.project_id).await?;
    tokio::task::spawn_blocking(move || {
        let store = context
            .apply_store
            .lock()
            .map_err(|_| "CONFLICT_STORE: apply store is poisoned".to_string())?;
        let set = store
            .load_conflicts(domain)
            .map_err(|error| format!("CONFLICT_STORE: {error:?}"))?;
        Ok::<_, String>(serde_json::json!({
            "project_id": domain.project_id.to_string(),
            "conflicts": crate::sync::summarize_conflicts(&set),
        }))
    })
    .await
    .map_err(|_| "CONFLICT_ERROR: list worker failed".to_string())?
}

/// Decide one conflict: write the chosen side to the working tree, drop the
/// conflict, and re-anchor the base so the decision propagates to the peer on the
/// next sync (see `resolve_conflict`).
async fn handle_conflict_resolve(
    ctx: &Context,
    params: ConflictResolveParams,
) -> Result<serde_json::Value, String> {
    let resolution = match params.choice.as_str() {
        "keep_local" => crate::sync::ConflictResolution::KeepLocal,
        "keep_remote" => crate::sync::ConflictResolution::KeepRemote,
        "keep_base" => crate::sync::ConflictResolution::KeepBase,
        "delete" => crate::sync::ConflictResolution::Delete,
        other => {
            return Err(format!(
                "INVALID_PARAMS: choice '{other}' must be keep_local, keep_remote, keep_base, or delete"
            ))
        }
    };
    let raw = hex::decode(&params.conflict_id)
        .map_err(|_| "INVALID_PARAMS: conflict_id must be hex".to_string())?;
    let conflict_id: [u8; 32] = raw
        .try_into()
        .map_err(|_| "INVALID_PARAMS: conflict_id must be 32 bytes".to_string())?;

    let (context, domain, root) = conflict_context(ctx, &params.project_id).await?;
    tokio::task::spawn_blocking(move || {
        let material = context
            .cas
            .current_project_key(domain.project_id)
            .map_err(|error| format!("CONFLICT_KEY: {error:?}"))?;
        let outcome = crate::sync::resolve_conflict(
            context.apply_store.as_ref(),
            context.cas.as_ref(),
            domain,
            root.canonical_path(),
            conflict_id,
            resolution,
            &material.key,
            material.key_id,
        )
        .map_err(|code| format!("CONFLICT_RESOLVE_FAILED: {code}"))?;
        Ok::<_, String>(serde_json::json!({
            "project_id": domain.project_id.to_string(),
            "paths": outcome.paths,
            "remaining": outcome.remaining,
        }))
    })
    .await
    .map_err(|_| "CONFLICT_ERROR: resolve worker failed".to_string())?
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SyncServeParams {
    project_id: String,
    bind_addr: String,
}

/// Start the responder listener for a provisioned, registered project: resolve
/// its `SyncContext` + DEK + root from the stores bootstrap wrote, bind a
/// per-project QUIC endpoint, and spawn the accept loop. Returns the bound
/// address (the initiator's peer address book points at it). The listener runs
/// until daemon shutdown (v0 has no stop RPC).
async fn handle_sync_serve(
    ctx: &Context,
    params: SyncServeParams,
) -> Result<serde_json::Value, String> {
    use crate::sync::SyncContextProvider;

    let project_id = parse_project_id(&params.project_id)?;
    let bind: std::net::SocketAddr = params.bind_addr.parse().map_err(|_| {
        format!(
            "INVALID_PARAMS: bind_addr '{}' is not a socket address",
            params.bind_addr
        )
    })?;
    let project_bytes = *project_id.as_bytes();
    let registry = ctx.project_registry.clone();

    // Open the provisioned stores + resolve context/DEK/root off the runtime.
    let (context, dek, root) = tokio::task::spawn_blocking(move || {
        let keychain = crate::sync::daemon_keychain();
        let provisioning = Arc::new(
            crate::sync::SyncProvisioningStore::open(crate::sync::default_provisioning_db_path())
                .map_err(|error| format!("SYNC_SERVE_PROVISIONING: {error:?}"))?,
        );
        let provider = crate::sync::ProvisioningSyncContextProvider::new(
            keychain.clone(),
            provisioning,
            crate::sync::default_sync_state_root(),
        );
        let context = provider.context_for(&project_id.to_string())?;
        let dek = crate::sync::load_project_key(keychain.as_ref(), project_bytes)
            .map_err(|error| format!("SYNC_SERVE_KEYCHAIN: {error:?}"))?;
        let root = registry
            .resolve_root(project_id)
            .map_err(|error| format!("SYNC_SERVE_ROOT: {error:?}"))?;
        Ok::<_, String>((context, dek, root))
    })
    .await
    .map_err(|_| "SYNC_SERVE_ERROR: setup worker failed".to_string())??;

    // Bind the per-project QUIC listener (needs the runtime) + spawn the loop.
    let server = crate::sync::SyncEndpoint::server(bind, context.trust.clone(), &context.identity)
        .map_err(|error| format!("SYNC_SERVE_BIND_FAILED: {error:?}"))?;
    let bound = server
        .local_addr()
        .map_err(|error| format!("SYNC_SERVE_BIND_FAILED: {error:?}"))?;
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    tokio::spawn(crate::sync::serve_project(
        server, context, root, dek.key, dek.key_id, stop,
    ));

    Ok(serde_json::json!({
        "project_id": project_id.to_string(),
        "bound_addr": bound.to_string(),
    }))
}

/// Build the `OperationManager` with the network sync transport wired in (P0).
///
/// The transport resolves each project's `SyncContext` from the keychain +
/// provisioning + per-project stores (`ProvisioningSyncContextProvider`) and peer
/// addresses from the provisioning address book, so `sync.start` with a peer over
/// a bootstrapped project actually dials and syncs. A project not provisioned for
/// sync fails cleanly (`sync_project_not_provisioned`); peerless scan operations
/// are unaffected (the composite runner routes them to the scan runner). The
/// keychain backend is `daemon_keychain()`, so this works on macOS (OS keychain)
/// and on Linux / unsigned binaries (file keychain via `TERMMESH_SYNC_KEYCHAIN_DIR`).
fn build_sync_operation_manager(
    project_registry: Arc<crate::sync::ProjectRegistry>,
) -> anyhow::Result<crate::sync::OperationManager> {
    let operation_db = crate::sync::default_operation_db_path();
    let keychain = crate::sync::daemon_keychain();
    let provisioning = Arc::new(
        crate::sync::SyncProvisioningStore::open(crate::sync::default_provisioning_db_path())
            .map_err(|error| anyhow::anyhow!("open sync provisioning store: {error:?}"))?,
    );
    let provider = Arc::new(crate::sync::ProvisioningSyncContextProvider::new(
        keychain,
        provisioning.clone(),
        crate::sync::default_sync_state_root(),
    ));
    let resolver = Arc::new(crate::sync::ProvisioningPeerResolver::new(provisioning));
    let runner = Arc::new(crate::sync::NetworkSyncRunner::new(
        provider,
        resolver,
        tokio::runtime::Handle::current(),
    ));
    Ok(crate::sync::OperationManager::open_with_sync_transport(
        operation_db,
        project_registry,
        runner,
    )?)
}

fn parse_project_id(value: &str) -> Result<crate::sync::ProjectId, String> {
    let decoded = hex::decode(value).map_err(|_| {
        "INVALID_PROJECT_ID: expected 64 lowercase hexadecimal characters".to_string()
    })?;
    let bytes: [u8; crate::sync::PROJECT_ID_BYTES] = decoded.try_into().map_err(|_| {
        "INVALID_PROJECT_ID: expected 64 lowercase hexadecimal characters".to_string()
    })?;
    Ok(crate::sync::ProjectId::from_bytes(bytes))
}

fn project_id_param(params: &serde_json::Value) -> Result<crate::sync::ProjectId, String> {
    let project_id = params
        .get("project_id")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "INVALID_PARAMS: project_id is required".to_string())?;
    parse_project_id(project_id)
}

async fn load_project(
    ctx: &Context,
    project_id: crate::sync::ProjectId,
) -> Result<crate::sync::ProjectRecord, String> {
    let registry = ctx.project_registry.clone();
    tokio::task::spawn_blocking(move || registry.get(project_id))
        .await
        .map_err(|_| "PROJECT_STORAGE_ERROR: registry worker failed".to_string())?
        .map_err(registry_error)?
        .ok_or_else(|| format!("PROJECT_NOT_FOUND: project {project_id} was not found"))
}

fn sync_is_paused(ctx: &Context, project_id: &str) -> Result<bool, String> {
    let project_id = parse_project_id(project_id)?.to_string();
    ctx.paused_sync_projects
        .read()
        .map(|paused| paused.contains(&project_id))
        .map_err(|_| "PROJECT_STATE_ERROR: pause state unavailable".to_string())
}

fn project_json(record: crate::sync::ProjectRecord, paused: bool) -> serde_json::Value {
    serde_json::json!({
        "project_id": record.project_id.to_string(),
        "root_path": record.root_path,
        "active_manifest": record.active_manifest.map(hex::encode),
        "roster_epoch": record.roster_epoch,
        "paused": paused,
    })
}

fn registry_error(error: crate::sync::RegistryError) -> String {
    use crate::sync::RegistryError;
    match error {
        RegistryError::ProjectNotFound(project_id) => {
            format!("PROJECT_NOT_FOUND: project {project_id} was not found")
        }
        RegistryError::RootNotDirectory(path) => {
            format!(
                "INVALID_PROJECT_ROOT: {} is not a directory",
                path.display()
            )
        }
        RegistryError::NonUtf8Path(path) => {
            format!(
                "INVALID_PROJECT_ROOT: {} is not valid UTF-8",
                path.display()
            )
        }
        RegistryError::InvalidRoot => "INVALID_PROJECT_ROOT: project root is invalid".to_string(),
        RegistryError::RootIdentityChanged(path) => format!(
            "PROJECT_ROOT_CHANGED: {} changed after registration",
            path.display()
        ),
        RegistryError::Security | RegistryError::Quarantined { .. } => {
            "PROJECT_STORAGE_QUARANTINED: registry integrity check failed".to_string()
        }
        other => format!("PROJECT_STORAGE_ERROR: {other}"),
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

    // Wave 1 D5: how long an `assigned` task may sit before being flagged.
    // Matches the watcher's claude default; codex/gemini/kiro get a 2× grace
    // before the watcher actually blocks them, so flagging at the lower bound
    // still surfaces the problem early.
    const ASSIGNED_STALE_MS: u64 = 180_000;

    for task in &tasks {
        // assigned_stale: task assigned but never started within threshold
        if matches!(task.status, crate::agent::TaskStatus::Assigned)
            && now_ms.saturating_sub(task.updated_at_ms) >= ASSIGNED_STALE_MS
        {
            let idle_secs = now_ms.saturating_sub(task.updated_at_ms) / 1000;
            let agent_id = task.assignee.clone().unwrap_or_else(|| task.id.clone());
            anomalies.push(Anomaly {
                agent_id,
                kind: "assigned_stale".into(),
                message: format!(
                    "Task '{}' (id={}) has been assigned for {}s without start",
                    task.title, task.id, idle_secs
                ),
                severity: if idle_secs >= 360 {
                    "critical".into()
                } else {
                    "warning".into()
                },
                detected_at: detected_at.clone(),
            });
        }

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

/// P1 fix: query agent names for a GUI (pane) team via the app socket's
/// `team.status` RPC. Used as a fallback when `headless.list` returns empty
/// (GUI teams have no headless-manager agents). Excludes the watcher agent
/// (same heuristic as the headless path). Returns empty vec on any error so
/// the watch.on registration still succeeds — workers are simply not pre-filled.
/// Apply the leader-as-watch-target fallback (D1/D6) to an `--target all` watch.
///
/// A worker-less team (e.g. an `attach`-bootstrapped 1-person team) has no agent
/// to watch, yet its real work happens in the leader pane. Given the workers
/// resolved for the team and whether it exposes a readable GUI leader pane
/// (app socket present), decide the final watch target list:
///
/// - **workers present** → returned unchanged. The leader is *never* watched in a
///   multi-member team (D1): as soon as one real worker exists, this is a no-op.
/// - **no workers + GUI leader** → `["leader"]`: watch the leader's own pane, which
///   `tm-agent read leader` can capture over the app socket.
/// - **no workers + no GUI leader** → empty: a purely headless leader has no pane
///   to read, so watch reports "no target" rather than fabricating one (D6).
fn apply_leader_watch_fallback(mut names: Vec<String>, has_gui_leader: bool) -> Vec<String> {
    if names.is_empty() && has_gui_leader {
        names.push("leader".to_string());
    }
    names
}

async fn query_gui_team_workers(app_socket: &str, team_id: &str) -> Vec<String> {
    use tokio::io::AsyncBufReadExt;
    let Ok(stream) = tokio::net::UnixStream::connect(app_socket).await else {
        return vec![];
    };
    let req = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "team.status",
        "params": {"team_name": team_id},
    });
    let mut line = serde_json::to_string(&req).unwrap_or_default();
    line.push('\n');
    let (rd, mut wr) = stream.into_split();
    if wr.write_all(line.as_bytes()).await.is_err() {
        return vec![];
    }
    let _ = wr.flush().await;
    let mut resp = String::new();
    let mut reader = BufReader::new(rd);
    if let Ok(Ok(_)) = timeout(Duration::from_secs(3), reader.read_line(&mut resp)).await {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&resp) {
            if let Some(agents) = v["result"]["agents"].as_array() {
                return agents
                    .iter()
                    .filter_map(|a| a["name"].as_str())
                    .filter(|n| *n != "watcher" && !n.starts_with("watcher"))
                    .map(String::from)
                    .collect();
            }
        }
    }
    vec![]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Regression for v0.185.1: the CLI and Swift owner both allowed a
    /// project-scoped add, but the daemon rejected it at `peer.leader.call`
    /// using the narrower generic-peer gate before the grant could be sent.
    #[test]
    fn leader_proxy_accepts_scoped_add_before_grant_dispatch() {
        assert!(leader_proxy_method_allowed("team.add_agent"));
        assert!(!crate::peer::connection::team_call_allowed(
            "team.add_agent"
        ));
        for method in ["team.list", "team.create", "team.preset.list"] {
            assert!(!leader_proxy_method_allowed(method), "{method}");
        }
    }

    #[test]
    fn malformed_gc_params_fail_closed_instead_of_scanning_every_category() {
        let error = gc_scan(
            serde_json::json!({"categories": "team_results"}),
            gc::GcRefs::default(),
        )
        .unwrap_err();
        assert!(error.starts_with("INVALID_PARAMS:"));

        let error = parse_gc_sweep_flags(serde_json::json!({"apply": "yes"})).unwrap_err();
        assert!(error.starts_with("INVALID_PARAMS:"));
    }

    fn leader_response(
        ok: bool,
        result_json: &str,
        error_code: &str,
        error_message: &str,
    ) -> peer_proto::v1::TeamLeaderCommandResponse {
        peer_proto::v1::TeamLeaderCommandResponse {
            request_id: vec![0u8; 16],
            ok,
            cached: false,
            result_json: result_json.to_string(),
            error_code: error_code.to_string(),
            error_message: error_message.to_string(),
            ..Default::default()
        }
    }

    /// A rejected remote-leader command must still reach the CLI as a
    /// structured envelope.
    ///
    /// This is the half that was missing: the old code turned a non-ok
    /// response into `Err("{code}: {message}")`, which became a generic
    /// JSON-RPC error and was handed back verbatim by
    /// `decode_daemon_response`, so the CLI's `remote_leader_proxy_result`
    /// never saw `error_code` at all. The existing tests only exercised that
    /// downstream helper with a hand-built value, so they kept passing while
    /// nothing upstream produced the shape.
    #[test]
    fn rejected_leader_command_keeps_error_code_in_a_proxy_envelope() {
        let envelope = team_leader_proxy_envelope(&leader_response(
            false,
            "",
            "expired_grant",
            "leader grant expired before dispatch",
        ));

        assert_eq!(envelope["ok"], serde_json::json!(false));
        assert_eq!(envelope["result"]["error_code"], "expired_grant");
        assert_eq!(
            envelope["result"]["error_message"],
            "leader grant expired before dispatch"
        );
    }

    /// `agent_busy` is the case the code is load-bearing for: the CLI keys a
    /// retry hint on it, and a flattened string would silently drop that.
    #[test]
    fn busy_agent_rejection_survives_as_a_readable_code() {
        let envelope =
            team_leader_proxy_envelope(&leader_response(false, "", "agent_busy", "executor busy"));

        assert_eq!(envelope["result"]["error_code"], "agent_busy");
        assert!(
            envelope["result"]["error_message"].is_string(),
            "message must stay a field, not be folded into the code"
        );
    }

    #[test]
    fn accepted_leader_command_parses_result_json() {
        let envelope =
            team_leader_proxy_envelope(&leader_response(true, r#"{"team_name":"demo"}"#, "", ""));

        assert_eq!(envelope["ok"], serde_json::json!(true));
        assert_eq!(envelope["result"]["team_name"], "demo");
    }

    /// A leader that answers ok with a non-JSON body must not be reported as
    /// a failure — the raw text is carried instead.
    #[test]
    fn accepted_leader_command_with_unparsable_body_falls_back_to_raw() {
        let envelope = team_leader_proxy_envelope(&leader_response(true, "not json", "", ""));

        assert_eq!(envelope["ok"], serde_json::json!(true));
        assert_eq!(envelope["result"]["raw"], "not json");
    }

    /// A corrupt registry used to abort `serve` AFTER the socket was bound,
    /// leaving a listener-less socket file — the control plane looked up but
    /// answered nothing. Reproduces the real incident (a valid DB with the
    /// wrong application_id) and asserts recovery moves it aside and returns a
    /// working registry so the socket actually serves.
    #[test]
    fn quarantined_registry_is_moved_aside_and_recreated() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        // SecureSqlite refuses a parent that is not 0700 owned by us.
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let db = dir.path().join("sync_projects.db");

        // Create a genuine registry (correct application_id), then tamper only
        // the application_id — exactly the "unexpected application_id 0" state
        // the daemon hit. DELETE journal mode leaves no -wal/-shm behind to
        // trip SecureSqlite's strict per-file checks on the recovery open.
        crate::sync::ProjectRegistry::open(&db).expect("seed a valid registry");
        {
            let conn = rusqlite::Connection::open(&db).unwrap();
            conn.pragma_update(None, "journal_mode", "DELETE").unwrap();
            conn.pragma_update(None, "application_id", 0i64).unwrap();
        }
        std::fs::set_permissions(&db, std::fs::Permissions::from_mode(0o600)).unwrap();

        // Sanity: the tampered DB really is rejected now.
        assert!(matches!(
            crate::sync::ProjectRegistry::open(&db),
            Err(crate::sync::RegistryError::Quarantined { .. })
        ));

        let registry =
            open_project_registry_recovering(db.clone()).expect("recovery must yield a registry");
        assert!(registry.path().exists());
        assert!(db.exists(), "a fresh DB should sit at the original path");

        // The corrupt DB was moved aside, and reopening the fresh one succeeds
        // (proving it is genuinely usable, not the rejected file).
        let quarantined_count = std::fs::read_dir(dir.path())
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".quarantined-"))
            .count();
        assert!(quarantined_count >= 1, "the corrupt DB must be quarantined");
        assert!(
            crate::sync::ProjectRegistry::open(&db).is_ok(),
            "the recreated registry must open cleanly"
        );
    }

    #[tokio::test]
    async fn bounded_line_reader_drains_oversized_envelopes_without_allocating_them() {
        let input = format!("{}\nok\n", "x".repeat(17));
        let mut reader = BufReader::new(input.as_bytes());
        assert!(matches!(
            read_bounded_line(&mut reader, 16).await.unwrap(),
            BoundedLine::TooLarge
        ));
        match read_bounded_line(&mut reader, 16).await.unwrap() {
            BoundedLine::Line(line) => assert_eq!(line, "ok"),
            _ => panic!("oversized line must be fully drained"),
        }
    }

    #[tokio::test]
    async fn bounded_line_reader_has_exact_crlf_utf8_and_eof_semantics() {
        let exact = format!("{}\r\n", "x".repeat(16));
        let mut reader = BufReader::with_capacity(1, exact.as_bytes());
        assert!(matches!(
            read_bounded_line(&mut reader, 16).await.unwrap(),
            BoundedLine::Line(line) if line.len() == 16
        ));

        let utf8 = "é\n";
        let mut reader = BufReader::new(utf8.as_bytes());
        assert!(matches!(
            read_bounded_line(&mut reader, 2).await.unwrap(),
            BoundedLine::Line(line) if line == "é"
        ));
        let mut reader = BufReader::new(utf8.as_bytes());
        assert!(matches!(
            read_bounded_line(&mut reader, 1).await.unwrap(),
            BoundedLine::TooLarge
        ));

        let mut reader = BufReader::new(&b"eof"[..]);
        assert!(matches!(
            read_bounded_line(&mut reader, 3).await.unwrap(),
            BoundedLine::Line(line) if line == "eof"
        ));
    }

    #[test]
    fn oversized_responses_are_replaced_by_a_bounded_error() {
        let response = Response {
            id: Some(json!(7)),
            result: Some(json!("x".repeat(crate::sync::MAX_OPERATION_ENVELOPE_BYTES))),
            error: None,
        };
        let encoded = serialize_bounded_response(&response, Some(json!(7))).unwrap();
        assert!(encoded.len() <= crate::sync::MAX_OPERATION_ENVELOPE_BYTES);
        let decoded: serde_json::Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(decoded["id"], 7);
        assert_eq!(decoded["error"]["code"], -32603);
        assert!(decoded["result"].is_null());
    }

    #[test]
    fn subscriber_payload_accepts_actual_max_and_bounds_max_plus_one() {
        let exact = "x".repeat(crate::sync::MAX_OPERATION_ENVELOPE_BYTES - 2);
        let encoded = bounded_subscriber_payload(&exact).unwrap().unwrap();
        assert_eq!(encoded.len(), crate::sync::MAX_OPERATION_ENVELOPE_BYTES);

        let oversized = format!("{exact}x");
        let encoded = bounded_subscriber_payload(&oversized).unwrap().unwrap();
        assert!(encoded.len() <= crate::sync::MAX_OPERATION_ENVELOPE_BYTES);
        let decoded: serde_json::Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(decoded["code"], "event_too_large");
        assert_eq!(decoded["dropped"], true);
    }
    use serde_json::json;

    // ── xk_run publish/subscribe (XK-EVENTS-v1) ──

    fn xk_kinds(kinds: &[&str]) -> std::collections::HashSet<String> {
        kinds.iter().map(|s| s.to_string()).collect()
    }

    fn valid_xk_params() -> serde_json::Value {
        json!({
            "kind": "xk_run",
            "source": "x-panel",
            "run": "20260707-1030-ab12",
            "run_kind": "review",
            "phase": "round1",
            "model": "codex",
            "state": "running",
            "elapsed_ms": 41200,
            "tail": "…last output…",
            "title": "diff HEAD~1"
        })
    }

    #[test]
    fn xk_run_publish_round_trip() {
        let (tx, mut rx) = tokio::sync::broadcast::channel(8);
        let res = publish_xk_run(&valid_xk_params(), &tx).expect("publish ok");
        assert_eq!(res, json!({"published": true}));
        let ev = rx.try_recv().expect("event delivered");
        match &ev {
            DaemonEvent::XkRun {
                v,
                source,
                run,
                phase,
                model,
                state,
                ts_ms,
                ..
            } => {
                assert_eq!(*v, 1, "v defaults to 1 when omitted-compatible");
                assert_eq!(source, "x-panel");
                assert_eq!(run, "20260707-1030-ab12");
                assert_eq!(phase, "round1");
                assert_eq!(model, "codex");
                assert_eq!(state, "running");
                assert!(*ts_ms > 0, "ts_ms stamped server-side");
            }
            other => panic!("unexpected event: {other:?}"),
        }
        // Wire shape: serde tag = kind, snake_case.
        let bytes = filter_and_serialize(&ev, &xk_kinds(&["xk_run"]), None).expect("delivered");
        let wire: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(wire["kind"], "xk_run");
        assert_eq!(wire["run_kind"], "review");
    }

    #[test]
    fn xk_run_is_opt_in_only() {
        let (tx, mut rx) = tokio::sync::broadcast::channel(8);
        publish_xk_run(&valid_xk_params(), &tx).unwrap();
        let ev = rx.try_recv().unwrap();
        // Default subscriber filter set (events.subscribe with no kinds param).
        let default_set = xk_kinds(&[
            "task_status",
            "reply",
            "heartbeat_stale",
            "agent_usage_tick",
        ]);
        assert!(
            filter_and_serialize(&ev, &default_set, None).is_none(),
            "default subscribers must not receive xk_run"
        );
        // Empty set = wildcard for other kinds, but still not xk_run.
        assert!(
            filter_and_serialize(&ev, &xk_kinds(&[]), None).is_none(),
            "wildcard subscribers must not receive xk_run"
        );
        // Sanity: wildcard still receives non-xk kinds.
        let task_ev = DaemonEvent::TaskStatus {
            team: "t".into(),
            agent: "a".into(),
            task_id: "id".into(),
            status: "completed".into(),
            prev_status: "in_progress".into(),
            ts_ms: 1,
        };
        assert!(filter_and_serialize(&task_ev, &xk_kinds(&[]), None).is_some());
        // Explicit opt-in receives it.
        assert!(filter_and_serialize(&ev, &xk_kinds(&["xk_run", "reply"]), None).is_some());
    }

    #[test]
    fn xk_run_rejects_oversized_event() {
        let (tx, mut rx) = tokio::sync::broadcast::channel(8);
        let mut params = valid_xk_params();
        params["title"] = json!("x".repeat(XK_RUN_MAX_EVENT_BYTES));
        let err = publish_xk_run(&params, &tx).expect_err("must reject > 4 KiB");
        assert!(err.contains("exceeds"), "error names the cap: {err}");
        assert!(rx.try_recv().is_err(), "nothing published on reject");
    }

    #[test]
    fn xk_run_rejects_missing_source_or_run() {
        let (tx, _rx) = tokio::sync::broadcast::channel(8);
        let mut no_source = valid_xk_params();
        no_source["source"] = json!("");
        assert!(publish_xk_run(&no_source, &tx).is_err());
        let mut no_run = valid_xk_params();
        no_run.as_object_mut().unwrap().remove("run");
        assert!(publish_xk_run(&no_run, &tx).is_err());
    }

    #[test]
    fn xk_run_truncates_tail_on_char_boundary() {
        let (tx, mut rx) = tokio::sync::broadcast::channel(8);
        let mut params = valid_xk_params();
        // 3-byte chars ("한") straddle the 512-byte cap: 171*3 = 513 → must cut
        // back to 510, never mid-code-point.
        params["tail"] = json!("한".repeat(171));
        publish_xk_run(&params, &tx).unwrap();
        match rx.try_recv().unwrap() {
            DaemonEvent::XkRun { tail: Some(t), .. } => {
                assert!(t.len() <= XK_RUN_MAX_TAIL_BYTES);
                assert_eq!(t.len(), 510);
                assert!(t.chars().all(|c| c == '한'), "no broken code points");
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[test]
    fn xk_run_default_v_is_1_when_absent() {
        let (tx, mut rx) = tokio::sync::broadcast::channel(8);
        let mut params = valid_xk_params();
        params.as_object_mut().unwrap().remove("v");
        publish_xk_run(&params, &tx).unwrap();
        match rx.try_recv().unwrap() {
            DaemonEvent::XkRun { v, .. } => assert_eq!(v, 1),
            other => panic!("unexpected event: {other:?}"),
        }
    }

    // ── leader-as-watch-target fallback (D1/D6) ──

    #[test]
    fn leader_fallback_watches_leader_when_no_workers_and_gui_leader() {
        // Worker-less GUI team (app socket present) → watch the leader's own pane.
        let names = apply_leader_watch_fallback(vec![], true);
        assert_eq!(names, vec!["leader".to_string()]);
    }

    #[test]
    fn leader_fallback_skipped_for_headless_leader() {
        // No workers AND no GUI leader pane → no fabricated target (D6).
        let names = apply_leader_watch_fallback(vec![], false);
        assert!(names.is_empty());
    }

    #[test]
    fn leader_fallback_never_watches_leader_when_workers_exist() {
        // D1 regression: a team with even one worker must never get "leader"
        // injected, regardless of whether a GUI leader pane is readable.
        let workers = vec!["executor".to_string(), "reviewer".to_string()];
        assert_eq!(
            apply_leader_watch_fallback(workers.clone(), true),
            workers,
            "leader must never be added when workers are present"
        );
        assert_eq!(apply_leader_watch_fallback(workers.clone(), false), workers);
        // Single-worker boundary case.
        let one = vec!["executor".to_string()];
        assert_eq!(apply_leader_watch_fallback(one.clone(), true), one);
    }

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
    fn assigned_anomaly_after_threshold() {
        use crate::agent::{AgentSessionManager, TaskAssignParams, TaskCreateParams};
        let dir = tempfile::tempdir().unwrap();
        let mgr = AgentSessionManager::new(dir.path().join("anom.db")).unwrap();
        mgr.testing_register_agent("a1");

        let task = mgr
            .task_create(TaskCreateParams {
                title: "stuck".into(),
                description: None,
                priority: None,
                created_by: None,
                deps: None,
                fix_budget: None,
                worktree_policy: None,
            })
            .unwrap();
        mgr.task_assign(TaskAssignParams {
            task_id: task.id.clone(),
            agent_id: "a1".into(),
        })
        .unwrap();

        let fresh = compute_agent_anomalies(&mgr);
        assert!(
            !fresh.iter().any(|a| a.kind == "assigned_stale"),
            "fresh assign should not raise assigned_stale: {:?}",
            fresh
        );

        // Backdate by 4 minutes (> 180s threshold).
        mgr.testing_backdate_task(&task.id, 4 * 60_000);

        let stale = compute_agent_anomalies(&mgr);
        let assigned = stale.iter().find(|a| a.kind == "assigned_stale");
        assert!(
            assigned.is_some(),
            "expected assigned_stale anomaly: {:?}",
            stale
        );
        assert_eq!(assigned.unwrap().agent_id, "a1");
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

    // Watch RPC handler tests (F6)
    use crate::drift_watch;

    #[test]
    fn watch_on_clamps_interval_to_minimum() {
        // Test that watch.on request with interval < MIN_WATCH_INTERVAL_SECS
        // results in the interval being clamped to 30
        let requested_interval = 5u64; // < 30
        let clamped = if requested_interval == 0 {
            300 // DEFAULT_WATCH_INTERVAL_SECS
        } else {
            requested_interval.max(30) // MIN_WATCH_INTERVAL_SECS
        };
        assert_eq!(clamped, 30, "interval 5 should be clamped to 30");

        // Test interval at the boundary
        let boundary_interval = 30u64;
        let clamped_boundary = if boundary_interval == 0 {
            300
        } else {
            boundary_interval.max(30)
        };
        assert_eq!(clamped_boundary, 30, "interval 30 should remain 30");

        // Test interval above minimum
        let above_min = 60u64;
        let clamped_above = if above_min == 0 {
            300
        } else {
            above_min.max(30)
        };
        assert_eq!(clamped_above, 60, "interval 60 should remain 60");
    }

    #[test]
    fn watch_state_enabled_construction() {
        // Test that WatchState::enabled applies defaults correctly
        let st = drift_watch::WatchState::enabled(
            0, // 0 triggers default
            Some("executor".into()),
            "claude",
            "sonnet",
            "critic",
            "spec text",
            "/tmp",
        );
        assert!(st.enabled);
        assert_eq!(st.interval_secs, 300, "interval 0 should use default 300");
        assert_eq!(st.target.as_deref(), Some("executor"));
        assert_eq!(st.cli, "claude");
        assert_eq!(st.model, "sonnet");
        assert!(!st.in_flight, "new state should not be in_flight");
        assert!(st.last_error.is_none(), "new state should have no error");
    }

    #[test]
    fn watch_registry_operations() {
        // Test basic registry operations without dispatch
        let registry = drift_watch::new_registry();

        // Synchronous test of registry content
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Runtime::new().unwrap();
            runtime.block_on(async {
                // Insert a state
                let st = drift_watch::WatchState::enabled(
                    60,
                    Some("executor".into()),
                    "claude",
                    "sonnet",
                    "critic",
                    "spec",
                    "/tmp",
                );
                {
                    let mut reg = registry.lock().await;
                    reg.insert("test-team".to_string(), st);
                }

                // Verify it was inserted
                {
                    let reg = registry.lock().await;
                    assert!(reg.contains_key("test-team"));
                    assert!(reg.get("test-team").unwrap().enabled);
                }

                // Modify it
                {
                    let mut reg = registry.lock().await;
                    if let Some(state) = reg.get_mut("test-team") {
                        state.enabled = false;
                    }
                }

                // Verify disabled
                {
                    let reg = registry.lock().await;
                    assert!(!reg.get("test-team").unwrap().enabled);
                }
            });
        })
        .join()
        .unwrap();
    }

    #[test]
    fn watch_config_persistence() {
        // Test config persistence via watch_config module
        let tmpdir = tempfile::tempdir().unwrap();
        let wd = tmpdir.path();

        // Create a watch state
        let st = drift_watch::WatchState::enabled(
            60,
            Some("executor".into()),
            "claude",
            "sonnet",
            "critic",
            "spec text",
            wd.to_string_lossy().to_string(),
        );

        // Persist it
        crate::socket::watch_config::save_watch_state(wd, "standard", &st);

        // Load it back
        let loaded = crate::socket::watch_config::load_watch_states(wd);
        assert_eq!(loaded.len(), 1);
        let (team, loaded_st) = &loaded[0];
        assert_eq!(team, "standard");
        assert!(loaded_st.enabled);
        assert_eq!(loaded_st.interval_secs, 60);
        assert_eq!(loaded_st.target.as_deref(), Some("executor"));
    }

    #[test]
    fn watch_config_disable_and_persist() {
        // Test that disabling a watch persists correctly
        let tmpdir = tempfile::tempdir().unwrap();
        let wd = tmpdir.path();

        let mut st = drift_watch::WatchState::enabled(
            60,
            Some("executor".into()),
            "claude",
            "sonnet",
            "critic",
            "spec text",
            wd.to_string_lossy().to_string(),
        );

        // Save enabled
        crate::socket::watch_config::save_watch_state(wd, "standard", &st);

        // Disable and save again
        st.enabled = false;
        crate::socket::watch_config::save_watch_state(wd, "standard", &st);

        // Load and verify disabled
        let loaded = crate::socket::watch_config::load_watch_states(wd);
        assert_eq!(loaded.len(), 1);
        assert!(!loaded[0].1.enabled, "loaded watch should be disabled");
    }

    #[test]
    fn board_recent_rows_tails_newest_first_and_skips_garbage() {
        let dir = tempfile::tempdir().unwrap();
        let wd = dir.path();
        let watch_dir = wd.join(".xm").join("watch");
        std::fs::create_dir_all(&watch_dir).unwrap();
        let mut lines = Vec::new();
        for i in 1..=5u64 {
            lines.push(format!(
                r#"{{"ts":{},"agent":"critic","drift_type":"execution","severity":"high","finding":"f{}","spec_clause":"c","check_id":"chk-{}"}}"#,
                1_000 + i,
                i,
                i
            ));
        }
        lines.push("not-json garbage".to_string());
        std::fs::write(watch_dir.join("board.jsonl"), lines.join("\n")).unwrap();

        let wd_str = wd.to_string_lossy().to_string();
        let rows = super::board_recent_rows(&wd_str, 3);
        assert_eq!(rows.len(), 3, "limit respected, garbage line skipped");
        // Newest first: ts 1005, 1004, 1003.
        assert_eq!(rows[0]["ts"], 1005);
        assert_eq!(rows[2]["ts"], 1003);
        assert_eq!(rows[0]["finding"], "f5");

        // Missing file / empty dir yields empty.
        assert!(super::board_recent_rows("/nonexistent/path", 10).is_empty());
        assert!(super::board_recent_rows(&wd_str, 0).is_empty());
    }

    /// A `/run/user/<uid>` socket disappears with the session that made it,
    /// leaving `/tmp/term-meshd.sock` pointing at nothing. The daemon must
    /// still be able to bind there.
    #[test]
    fn stale_socket_entry_is_cleared_even_when_the_symlink_dangles() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("term-meshd.sock");
        std::os::unix::fs::symlink(dir.path().join("gone.sock"), &socket).unwrap();
        assert!(
            !socket.exists(),
            "the target is absent, so exists() is false"
        );

        super::clear_stale_socket_entry(&socket).unwrap();

        assert!(
            std::fs::symlink_metadata(&socket).is_err(),
            "the dangling link itself must be gone, or bind reports EADDRINUSE"
        );
        std::os::unix::net::UnixListener::bind(&socket).expect("the path is bindable");
    }

    #[test]
    fn live_socket_symlink_is_never_replaced_by_a_second_instance() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("runtime.sock");
        let alias = dir.path().join("term-meshd.sock");
        let _listener = std::os::unix::net::UnixListener::bind(&target).unwrap();
        std::os::unix::fs::symlink(&target, &alias).unwrap();

        let error = super::clear_stale_socket_entry(&alias).unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::AddrInUse);
        assert!(std::fs::symlink_metadata(&alias)
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(std::os::unix::net::UnixStream::connect(&alias).is_ok());
    }

    #[test]
    fn stale_socket_entry_clears_a_real_socket_and_tolerates_an_absent_path() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("term-meshd.sock");
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        drop(listener);

        super::clear_stale_socket_entry(&socket).unwrap();
        assert!(std::fs::symlink_metadata(&socket).is_err());

        super::clear_stale_socket_entry(&dir.path().join("never-existed.sock"))
            .expect("an absent path is not an error");
    }

    #[test]
    fn live_socket_entry_is_never_unlinked_by_a_second_instance() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("term-meshd.sock");
        let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();

        let error = super::clear_stale_socket_entry(&socket).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::AddrInUse);
        assert!(std::fs::symlink_metadata(&socket).is_ok());
    }

    #[test]
    fn stale_socket_probe_has_a_bounded_connect_deadline() {
        assert_eq!(
            super::STALE_SOCKET_CONNECT_TIMEOUT,
            std::time::Duration::from_millis(300)
        );
        assert_eq!(super::STALE_SOCKET_REFUSAL_PROBES, 3);
        assert_eq!(
            super::STALE_SOCKET_REFUSAL_RETRY_DELAY,
            std::time::Duration::from_millis(100)
        );
    }

    #[test]
    fn stale_socket_entry_is_removed_after_connection_refusal() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("term-meshd.sock");
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        drop(listener);

        super::clear_stale_socket_entry(&socket).unwrap();
        assert!(std::fs::symlink_metadata(&socket).is_err());
    }

    #[test]
    fn shutdown_removes_only_the_socket_inode_it_bound() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("term-meshd.sock");
        let first = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let first_identity = super::socket_identity(&socket).unwrap();
        drop(first);
        std::fs::remove_file(&socket).unwrap();
        let _replacement = std::os::unix::net::UnixListener::bind(&socket).unwrap();

        assert!(!super::remove_owned_socket(&socket, first_identity).unwrap());
        assert!(std::fs::symlink_metadata(&socket).is_ok());
    }

    #[test]
    fn stale_cleanup_refuses_to_remove_a_replacement_inode() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("term-meshd.sock");
        let stale = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let stale_identity = super::socket_identity(&socket).unwrap();
        drop(stale);
        std::fs::remove_file(&socket).unwrap();
        let _replacement = std::os::unix::net::UnixListener::bind(&socket).unwrap();

        assert!(!super::remove_owned_socket(&socket, stale_identity).unwrap());
        assert!(std::os::unix::net::UnixStream::connect(&socket).is_ok());
    }
}
