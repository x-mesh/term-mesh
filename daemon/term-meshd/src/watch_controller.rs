//! Watch result controller (watcher Phase 2 — P5).
//!
//! Consumes the [`WatchCheckOutcome`] stream produced by the drift-watch
//! scheduler ([`crate::drift_watch::run_watch_scheduler`]) and turns each DRIFT
//! verdict into two side effects, and ONLY these two:
//!   1. an idempotent append to the team worktree's `.xm/watch/board.jsonl`
//!      (deduped by `check_id`), and
//!   2. a single message to the team **leader** inbox (`team.message.post`,
//!      never `--to <agent>`).
//!
//! Boundaries:
//! - **F2** — the watcher subprocess itself never writes the board or messages
//!   anyone; this controller is the single writer.
//! - **NFR2 focus** — this module performs data/file/inbox work only. It never
//!   calls `send_key`, `window.focus`, `pane.focus`, or any app-activation path.
//!   The only outward call is the focus-free `team.message.post` RPC.
//!
//! Real bounded-delta fetching happens in the runner (`headless::one_shot`); this
//! module only consumes verdicts.

use std::path::{Path, PathBuf};

use tokio::sync::mpsc;

use crate::headless::one_shot::WatchCheckOutcome;

/// A single drift row written to `.xm/watch/board.jsonl`.
#[derive(Debug, Clone)]
pub(crate) struct BoardFinding {
    pub ts: u64,
    pub agent: String,
    pub drift_type: String,
    pub severity: String,
    pub finding: String,
    pub spec_clause: String,
    pub check_id: String,
}

/// Parsed fields extracted from a watcher's raw verdict text. Tolerant of both
/// `[TAG] value` and `TAG: value` shapes.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct ParsedVerdict {
    pub is_drift: bool,
    pub drift_type: Option<String>,
    pub severity: Option<String>,
    pub finding: Option<String>,
    pub spec_clause: Option<String>,
}

/// Outcome of handling a single check, for logging / test assertions.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ControllerAction {
    /// DRIFT: appended a fresh board row + posted to the leader inbox.
    Appended,
    /// DRIFT but the `check_id` was already on the board → no write, no inbox.
    Duplicate,
    /// on-track verdict → nothing recorded (F2: silence is fine).
    NoDrift,
    /// The check errored / produced no verdict → logged only.
    Errored,
    /// Board write failed → inbox skipped.
    BoardError,
}

fn now_unix() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Text after the first `]` (for `[TAG] value`) or `:` (for `TAG: value`).
fn tag_value(line: &str) -> String {
    if let Some(idx) = line.find(']') {
        return line[idx + 1..].trim().to_string();
    }
    if let Some(idx) = line.find(':') {
        return line[idx + 1..].trim().to_string();
    }
    String::new()
}

/// Parse a watcher verdict (P11 #8). DRIFT requires a *positive* signal — a
/// VERDICT line that says drift (not "no drift" / "not drifting" / "on-track" /
/// "ok"), or an explicit execution/direction drift_type when no VERDICT line is
/// present. Negated phrases like "no drift" are correctly treated as OK.
pub(crate) fn parse_verdict(text: &str) -> ParsedVerdict {
    let mut v = ParsedVerdict::default();
    // VERDICT-line decision, if a VERDICT line is present: Some(true)=drift.
    let mut verdict_decision: Option<bool> = None;
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        let lower = line.to_lowercase();
        let key = lower.trim_start_matches('[');
        if key.starts_with("verdict") {
            let val = tag_value(line).to_lowercase();
            let token = if val.is_empty() { lower.clone() } else { val };
            // Explicit OK tokens win, so "no drift" / "not drifting" stay OK.
            let says_ok = token.contains("on-track")
                || token.contains("on track")
                || token.contains("no drift")
                || token.contains("no-drift")
                || token.contains("not drift")
                || token.contains("not drifting")
                || token.contains("none")
                || token == "ok"
                || token.ends_with(" ok")
                || token.ends_with("] ok");
            let says_drift = !says_ok && token.contains("drift");
            verdict_decision = Some(says_drift);
            if token.contains("execution") {
                v.drift_type = Some("execution".into());
            } else if token.contains("direction") {
                v.drift_type = Some("direction".into());
            }
        } else if key.starts_with("drift_type") || key.starts_with("drift-type") {
            let val = tag_value(line).to_lowercase();
            if val.contains("execution") {
                v.drift_type = Some("execution".into());
            } else if val.contains("direction") {
                v.drift_type = Some("direction".into());
            }
        } else if key.starts_with("severity") {
            let val = tag_value(line);
            if !val.is_empty() && val.to_lowercase() != "n/a" {
                v.severity = Some(val);
            }
        } else if key.starts_with("finding") {
            let val = tag_value(line);
            if !val.is_empty() && val.to_lowercase() != "none" {
                v.finding = Some(val);
            }
        } else if key.starts_with("spec_clause")
            || key.starts_with("spec-clause")
            || key.starts_with("spec clause")
        {
            let val = tag_value(line);
            if !val.is_empty() && val.to_lowercase() != "n/a" {
                v.spec_clause = Some(val);
            }
        }
    }
    // Final decision: a VERDICT line wins; otherwise an explicit drift_type is a
    // positive signal. No positive signal → OK (default false).
    v.is_drift = match verdict_decision {
        Some(d) => d,
        None => v.drift_type.is_some(),
    };
    v
}

fn board_dir(working_dir: &Path) -> PathBuf {
    working_dir.join(".xm").join("watch")
}

/// Append one finding to `.xm/watch/board.jsonl`, deduped by `check_id`.
/// Returns `Ok(true)` when a new row was written, `Ok(false)` when the
/// `check_id` was already present (idempotent skip).
pub(crate) fn append_board_finding(
    working_dir: &Path,
    f: &BoardFinding,
) -> std::io::Result<bool> {
    use std::io::Write;
    let dir = board_dir(working_dir);
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("board.jsonl");

    // Idempotency: skip if this check_id already has a row.
    if path.exists() {
        let content = std::fs::read_to_string(&path)?;
        for line in content.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(line) {
                if v.get("check_id").and_then(|x| x.as_str()) == Some(f.check_id.as_str()) {
                    return Ok(false);
                }
            }
        }
    }

    let row = serde_json::json!({
        "ts": f.ts,
        "agent": f.agent,
        "drift_type": f.drift_type,
        "severity": f.severity,
        "finding": f.finding,
        "spec_clause": f.spec_clause,
        "check_id": f.check_id,
    });
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    writeln!(file, "{}", serde_json::to_string(&row).unwrap_or_default())?;
    Ok(true)
}

/// Where a drift finding is delivered for human attention. The real impl posts
/// `team.message.post` to the app socket (leader inbox); tests record.
///
/// Implementations MUST target the team **leader** only (no `--to <agent>`) and
/// MUST NOT trigger any focus change (NFR2).
pub(crate) type InboxFuture<'a> =
    std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>>;

pub(crate) trait LeaderInbox: Send + Sync {
    fn post<'a>(
        &'a self,
        team_id: &'a str,
        content: &'a str,
        app_socket: Option<&'a str>,
    ) -> InboxFuture<'a>;
}

/// Production inbox: posts the focus-free `team.message.post` RPC to the Swift
/// app over its Unix socket. No `to` field → routes to the leader inbox.
pub struct AppSocketInbox;

impl LeaderInbox for AppSocketInbox {
    fn post<'a>(
        &'a self,
        team_id: &'a str,
        content: &'a str,
        app_socket: Option<&'a str>,
    ) -> InboxFuture<'a> {
        let team_id = team_id.to_string();
        let content = content.to_string();
        let app_socket = app_socket.map(|s| s.to_string());
        Box::pin(async move {
            let Some(sock) = app_socket else {
                tracing::warn!("watch: no app socket — leader inbox skipped (team {team_id})");
                return;
            };
            if let Err(e) = post_team_message(&sock, &team_id, &content).await {
                tracing::warn!("watch: leader inbox post failed (team {team_id}): {e}");
            }
        })
    }
}

/// Focus-free `team.message.post` over the app Unix socket. NO `to` field, so the
/// app routes it to the leader inbox; this is a data command and never activates
/// or raises any window (NFR2).
async fn post_team_message(
    app_socket: &str,
    team_id: &str,
    content: &str,
) -> std::io::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut stream = tokio::net::UnixStream::connect(app_socket).await?;
    let req = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "team.message.post",
        "params": {
            "team_name": team_id,
            "from": "watcher",
            "content": content,
            "type": "note",
            // intentionally NO "to" → leader inbox (R: leader-only, never --to agent)
        },
    });
    let mut line = serde_json::to_string(&req).unwrap_or_default();
    line.push('\n');
    stream.write_all(line.as_bytes()).await?;
    stream.flush().await?;
    // Best-effort, bounded read of the one-line response (ignored).
    let mut buf = [0u8; 4096];
    let _ = tokio::time::timeout(std::time::Duration::from_secs(3), stream.read(&mut buf)).await;
    Ok(())
}

/// Handle a single check outcome: parse → (DRIFT) board append + leader inbox.
/// The inbox post happens only when a *new* board row was written, so retried
/// ticks with the same `check_id` neither duplicate the board nor re-notify the
/// leader.
///
/// `working_dir` (team worktree) and `app_socket` are resolved by the caller
/// from the [`WatchRegistry`] — they are not on the outcome, so the
/// `WatchCheckOutcome` shape stays owned by P1/P4 (`watch.rs`/`one_shot.rs`).
pub(crate) async fn handle_outcome<I: LeaderInbox + ?Sized>(
    outcome: &WatchCheckOutcome,
    working_dir: &Path,
    app_socket: Option<&str>,
    inbox: &I,
) -> ControllerAction {
    if let Some(err) = &outcome.error {
        if !outcome.reported {
            tracing::warn!(
                "watch check error: team={} check={} target={} error={}",
                outcome.team_id,
                outcome.check_id,
                outcome.target,
                err
            );
            return ControllerAction::Errored;
        }
    }

    let parsed = parse_verdict(&outcome.verdict_text);
    if !parsed.is_drift {
        // F2: on-track verdicts are silent — no board row, no inbox message.
        return ControllerAction::NoDrift;
    }

    let drift_type = parsed
        .drift_type
        .clone()
        .unwrap_or_else(|| outcome.drift_kind.as_str().to_string());
    let severity = parsed.severity.clone().unwrap_or_else(|| "medium".to_string());
    let finding = parsed
        .finding
        .clone()
        .unwrap_or_else(|| "drift detected".to_string());
    let spec_clause = parsed.spec_clause.clone().unwrap_or_else(|| "n/a".to_string());

    let finding_row = BoardFinding {
        ts: now_unix(),
        agent: outcome.target.clone(),
        drift_type: drift_type.clone(),
        severity: severity.clone(),
        finding: finding.clone(),
        spec_clause: spec_clause.clone(),
        check_id: outcome.check_id.clone(),
    };

    match append_board_finding(working_dir, &finding_row) {
        Ok(true) => {
            let content = format!(
                "[watch:{drift_type}/{severity}] {target}: {finding} (spec: {spec_clause}) [check_id={cid}]",
                target = outcome.target,
                cid = outcome.check_id,
            );
            // Leader inbox only — never --to <agent>. Focus-free.
            inbox.post(&outcome.team_id, &content, app_socket).await;
            ControllerAction::Appended
        }
        Ok(false) => ControllerAction::Duplicate,
        Err(e) => {
            tracing::warn!(
                "watch: board append failed (team {} check {}): {e}",
                outcome.team_id,
                outcome.check_id
            );
            ControllerAction::BoardError
        }
    }
}

/// Drain the scheduler's outcome stream until the channel closes. Replaces the
/// P4 log-only drain task. The team's worktree dir + app socket are resolved
/// from the shared [`WatchRegistry`] by `team_id`.
pub async fn run_watch_controller<I: LeaderInbox + 'static>(
    mut rx: mpsc::UnboundedReceiver<WatchCheckOutcome>,
    registry: crate::drift_watch::WatchRegistry,
    inbox: I,
) {
    while let Some(outcome) = rx.recv().await {
        let (working_dir, app_socket) = {
            let reg = registry.lock().await;
            match reg.get(&outcome.team_id) {
                Some(st) => (st.working_directory.clone(), st.app_socket_path.clone()),
                None => (String::new(), None),
            }
        };
        if working_dir.is_empty() {
            tracing::warn!(
                "watch: no registry working_dir for team {} — skipping board/inbox",
                outcome.team_id
            );
            continue;
        }
        let _ = handle_outcome(
            &outcome,
            Path::new(&working_dir),
            app_socket.as_deref(),
            &inbox,
        )
        .await;
    }
}

// P10: the persisted-config loader now lives in `crate::socket::watch_config`
// (P6). `main.rs` calls it directly at startup — this module no longer carries a
// stub.

#[cfg(test)]
mod tests {
    use super::*;
    use crate::headless::one_shot::{WatchCheckKind, WatchExitStatus};
    use std::sync::{Arc, Mutex};

    /// Records leader-inbox posts. Has ONLY a post path — there is deliberately
    /// no focus method anywhere in this module (NFR2).
    struct RecordingInbox {
        posts: Arc<Mutex<Vec<(String, String)>>>,
    }

    impl RecordingInbox {
        fn new() -> Self {
            Self {
                posts: Arc::new(Mutex::new(Vec::new())),
            }
        }
    }

    impl LeaderInbox for RecordingInbox {
        fn post<'a>(
            &'a self,
            team_id: &'a str,
            content: &'a str,
            _app_socket: Option<&'a str>,
        ) -> InboxFuture<'a> {
            let posts = Arc::clone(&self.posts);
            let team = team_id.to_string();
            let content = content.to_string();
            Box::pin(async move {
                posts.lock().unwrap().push((team, content));
            })
        }
    }

    fn outcome(check_id: &str, verdict: &str) -> WatchCheckOutcome {
        WatchCheckOutcome {
            team_id: "standard".into(),
            check_id: check_id.into(),
            drift_kind: WatchCheckKind::Execution,
            target: "executor".into(),
            spawned: true,
            reported: true,
            terminated: true,
            exit_status: WatchExitStatus::Replied,
            panel_id: None,
            verdict_text: verdict.into(),
            error: None,
        }
    }

    const DRIFT_VERDICT: &str = "[VERDICT] drift(execution)\n[SEVERITY] high\n[FINDING] ignored a failing build\n[SPEC_CLAUSE] keep the build green";

    #[tokio::test]
    async fn drift_appends_board_and_posts_inbox() {
        let dir = tempfile::tempdir().unwrap();
        let inbox = RecordingInbox::new();
        let o = outcome("chk-1", DRIFT_VERDICT);

        let action = handle_outcome(&o, dir.path(), None, &inbox).await;
        assert_eq!(action, ControllerAction::Appended);

        let board = std::fs::read_to_string(board_dir(dir.path()).join("board.jsonl")).unwrap();
        assert_eq!(board.lines().count(), 1, "exactly one board row");
        assert!(board.contains("\"check_id\":\"chk-1\""));
        assert!(board.contains("\"drift_type\":\"execution\""));
        assert!(board.contains("\"severity\":\"high\""));
        assert!(board.contains("ignored a failing build"));

        let posts = inbox.posts.lock().unwrap();
        assert_eq!(posts.len(), 1, "one leader inbox message");
        assert_eq!(posts[0].0, "standard");
        assert!(posts[0].1.contains("executor"));
        assert!(posts[0].1.contains("chk-1"));
    }

    #[tokio::test]
    async fn duplicate_check_id_skips_board_and_inbox() {
        let dir = tempfile::tempdir().unwrap();
        let inbox = RecordingInbox::new();

        let first =
            handle_outcome(&outcome("chk-dup", DRIFT_VERDICT), dir.path(), None, &inbox).await;
        assert_eq!(first, ControllerAction::Appended);
        // Same check_id again (a retried tick) → idempotent skip.
        let second =
            handle_outcome(&outcome("chk-dup", DRIFT_VERDICT), dir.path(), None, &inbox).await;
        assert_eq!(second, ControllerAction::Duplicate);

        let board = std::fs::read_to_string(board_dir(dir.path()).join("board.jsonl")).unwrap();
        assert_eq!(board.lines().count(), 1, "duplicate must not add a board row");
        assert_eq!(
            inbox.posts.lock().unwrap().len(),
            1,
            "duplicate must not re-notify the leader"
        );
    }

    #[tokio::test]
    async fn on_track_records_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let inbox = RecordingInbox::new();
        let ok = "[VERDICT] on-track\n[FINDING] none\n[SPEC_CLAUSE] n/a";

        let action = handle_outcome(&outcome("chk-ok", ok), dir.path(), None, &inbox).await;
        assert_eq!(action, ControllerAction::NoDrift);

        assert!(
            !board_dir(dir.path()).join("board.jsonl").exists(),
            "on-track must not create the board"
        );
        assert!(
            inbox.posts.lock().unwrap().is_empty(),
            "on-track must not message the leader"
        );
    }

    #[tokio::test]
    async fn errored_outcome_is_logged_only() {
        let dir = tempfile::tempdir().unwrap();
        let inbox = RecordingInbox::new();
        let mut o = outcome("chk-err", "");
        o.reported = false;
        o.error = Some("spawn failed: boom".into());

        let action = handle_outcome(&o, dir.path(), None, &inbox).await;
        assert_eq!(action, ControllerAction::Errored);
        assert!(!board_dir(dir.path()).join("board.jsonl").exists());
        assert!(inbox.posts.lock().unwrap().is_empty());
    }

    #[test]
    fn parse_verdict_extracts_drift_fields() {
        let p = parse_verdict(DRIFT_VERDICT);
        assert!(p.is_drift);
        assert_eq!(p.drift_type.as_deref(), Some("execution"));
        assert_eq!(p.severity.as_deref(), Some("high"));
        assert_eq!(p.finding.as_deref(), Some("ignored a failing build"));
        assert_eq!(p.spec_clause.as_deref(), Some("keep the build green"));

        let ok = parse_verdict("[VERDICT] on-track\n[FINDING] none");
        assert!(!ok.is_drift);
        assert!(ok.finding.is_none());
    }

    #[test]
    fn parse_verdict_negated_drift_is_ok() {
        // P11 #8: positive signal required — negated phrases stay OK.
        assert!(!parse_verdict("[VERDICT] no drift").is_drift);
        assert!(!parse_verdict("VERDICT: not drifting").is_drift);
        assert!(!parse_verdict("[VERDICT] on-track").is_drift);
        assert!(!parse_verdict("[VERDICT] OK").is_drift);
        // Positive signals.
        assert!(parse_verdict("[VERDICT] drift(execution)").is_drift);
        assert!(parse_verdict("VERDICT: DRIFT").is_drift);
        // drift_type alone (no VERDICT line) is a positive signal.
        assert!(parse_verdict("[DRIFT_TYPE] execution").is_drift);
        // Nothing positive → OK.
        assert!(!parse_verdict("[FINDING] none").is_drift);
    }

    /// P11 #1 end-to-end (minus the real CLI): a real headless watcher spawn
    /// whose fake CLI emits a stream-json DRIFT `result` event flows through the
    /// runner's verdict extraction and into the controller's board + inbox. This
    /// is the exact chain that was silently dropping verdicts. Sets a process-wide
    /// env var, so run under --test-threads=1 (the VERIFY command does).
    #[tokio::test]
    async fn real_spawn_drift_verdict_reaches_board() {
        use crate::headless::one_shot::{
            HeadlessOneShotRunner, WatchCheckInput, WatchCheckKind, WatchCheckRunner,
        };
        use crate::headless::HeadlessManager;
        use std::time::Duration;
        use tokio::sync::Mutex;

        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("TERMMESH_HEADLESS_ROOT", dir.path());

        // Fake claude: emit a stream-json result with a DRIFT verdict, then idle
        // on stdin so the spawn handshake stays alive until the daemon reaps it.
        let fake_cli = dir.path().join("fake-watcher.sh");
        std::fs::write(
            &fake_cli,
            "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"[VERDICT] drift(execution)\\n[FINDING] ignored a failing build\\n[SPEC_CLAUSE] keep the build green\"}'\ncat >/dev/null 2>&1\n",
        )
        .unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&fake_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let workdir = dir.path().to_string_lossy().to_string();

        let manager = Arc::new(Mutex::new(HeadlessManager::new()));
        let runner = HeadlessOneShotRunner::new(manager.clone());
        let input = WatchCheckInput {
            team_name: "e2e".into(),
            target: "executor".into(),
            check_id: "chk-e2e".into(),
            check_kind: WatchCheckKind::Execution,
            stance: "critic".into(),
            spec: "keep the build green".into(),
            delta: String::new(),
            cli: "claude".into(),
            model: "sonnet".into(),
            working_directory: workdir.clone(),
            cli_path: Some(fake_cli.to_string_lossy().to_string()),
            app_socket_path: None,
            reply_timeout: Duration::from_secs(4),
        };

        let outcome = runner.run_check(input).await;
        // Verdict extraction (P11 #1): the stream-json result text is surfaced.
        assert!(
            outcome.verdict_text.contains("drift(execution)"),
            "verdict_text should carry the extracted DRIFT verdict, got: {:?}",
            outcome.verdict_text
        );

        // Controller turns it into a board row + leader inbox message.
        let inbox = RecordingInbox::new();
        let action = handle_outcome(&outcome, dir.path(), None, &inbox).await;
        assert_eq!(action, ControllerAction::Appended);

        let board =
            std::fs::read_to_string(board_dir(dir.path()).join("board.jsonl")).unwrap();
        assert!(board.contains("\"check_id\":\"chk-e2e\""));
        assert!(board.contains("\"drift_type\":\"execution\""));
        assert!(board.contains("ignored a failing build"));
        assert_eq!(inbox.posts.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn controller_full_path_writes_board_and_inbox_via_channel() {
        // P11 #1: full spawn→verdict→board path minus the real subprocess. A
        // DRIFT outcome flows through the mpsc channel into run_watch_controller,
        // which resolves the team's working_dir from the registry and writes both
        // board.jsonl and the leader inbox.
        let dir = tempfile::tempdir().unwrap();
        let registry = crate::drift_watch::new_registry();
        registry.lock().await.insert(
            "standard".into(),
            crate::drift_watch::WatchState::enabled(
                5,
                Some("executor".into()),
                "claude",
                "sonnet",
                "critic",
                "spec",
                dir.path().to_string_lossy().to_string(),
            ),
        );
        let inbox = RecordingInbox::new();
        let posts = Arc::clone(&inbox.posts);
        let (tx, rx) = mpsc::unbounded_channel();
        let handle = tokio::spawn(run_watch_controller(rx, registry, inbox));

        tx.send(outcome("chk-int", DRIFT_VERDICT)).unwrap();
        drop(tx); // close channel → controller drains then exits
        handle.await.unwrap();

        let board =
            std::fs::read_to_string(board_dir(dir.path()).join("board.jsonl")).unwrap();
        assert!(board.contains("\"check_id\":\"chk-int\""));
        assert!(board.contains("\"agent\":\"executor\""));
        let posts = posts.lock().unwrap();
        assert_eq!(posts.len(), 1, "leader inbox got the finding");
        assert_eq!(posts[0].0, "standard");
    }
}
