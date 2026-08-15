//! Phase 2 watcher — headless one-shot drift-check helper (ADR-P5).
//!
//! Each autonomous watch tick spawns a *fresh* headless watcher (no GUI pane),
//! sends it a single REVIEW request (spec + bounded delta + stance + check_kind),
//! waits for its first verdict (or a timeout), then terminates it. A fresh spawn
//! per tick keeps the watcher stateless: it never accumulates the watched
//! agent's history, which is exactly what would make the watcher itself drift
//! (docs/watcher-pair-programming.md §2).
//!
//! Boundary (F2): this helper is side-effect-free w.r.t. drift bookkeeping. It
//! returns the raw verdict text only. Parsing, `.xm/watch/board.jsonl`
//! persistence, and leader reporting are the WatchController's job (P5). The
//! tick scheduler (P1) drives this via the [`WatchCheckRunner`] trait.

use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::Mutex;
use tokio::time::timeout;

use super::{merge_instructions, HeadlessManager, SpawnParams};

/// Concise role directive for a one-shot watcher. Complements the project spec
/// (which carries the *what to watch*); this carries the *how to behave*. Folded
/// with the spec via [`merge_instructions`] (F1) so the spec survives verbatim.
const WATCHER_ONESHOT_DIRECTIVE: &str = "\
You are a stateless drift watcher for a term-mesh agent team. Each check you \
receive only the spec and a bounded recent delta of one watched agent — never \
its full history. Compare the delta against the spec, decide whether the agent \
is on-track or drifting, and distinguish execution drift (doing the task wrong) \
from direction drift (doing the wrong task). Report to the leader only; never \
edit files or message other agents. If nothing is wrong, say so in one line.";

const PAIR_REVIEW_ONESHOT_DIRECTIVE: &str = "\
You are a stateless Pair Reviewer for a term-mesh project. Review exactly one \
immutable, bounded snapshot through the user-selected lens. You are read-only: \
never edit files, run mutating commands, commit, or message another agent. Base \
every finding on evidence present in the snapshot. Prefer no finding over a \
speculative one. Return only the requested structured review.";

/// Tail length (lines) of the watched agent's output used as the review delta.
/// Bounded by construction (R6): only the most recent N lines, never history.
const DELTA_TAIL_LINES: usize = 200;

/// Hard upper bound (chars) on the delta fed to the watcher, so a single noisy
/// line cannot blow up the review prompt. Keeps each check bounded (R6).
const DELTA_MAX_CHARS: usize = 16_000;

/// Truncate the delta to [`DELTA_MAX_CHARS`], keeping the most recent tail
/// (drift shows up in the latest output). Prefixed with an elision marker when cut.
pub(crate) fn bound_delta(delta: &str) -> String {
    if delta.len() <= DELTA_MAX_CHARS {
        return delta.to_string();
    }
    let start = delta.len() - DELTA_MAX_CHARS;
    // Snap to a char boundary so we never split a UTF-8 sequence.
    let start = (start..delta.len())
        .find(|&i| delta.is_char_boundary(i))
        .unwrap_or(delta.len());
    format!("…[delta truncated]…\n{}", &delta[start..])
}

/// Freeze the watched target's bounded output before a user-triggered review
/// starts. This is deliberately separate from `run_check_impl`, whose fallback
/// may collect later, because Pair Review promises a start-time snapshot.
pub(crate) async fn capture_target_delta(
    manager: &Arc<Mutex<HeadlessManager>>,
    team: &str,
    target: &str,
    app_socket: Option<&str>,
) -> Result<String, String> {
    let agent_id = format!("{target}@{team}");
    let lines = manager
        .lock()
        .await
        .read_output(&agent_id, DELTA_TAIL_LINES)
        .await
        .unwrap_or_default();
    if !lines.is_empty() {
        let text = extract_verdict_text(&lines);
        if !text.trim().is_empty() {
            return Ok(bound_delta(&text));
        }
    }
    let socket =
        app_socket.ok_or_else(|| "app socket required to snapshot GUI leader".to_string())?;
    let text = app_read_pane(socket, team, target, DELTA_TAIL_LINES).await?;
    if text.trim().is_empty() {
        return Err(format!("no output available for {target}"));
    }
    Ok(bound_delta(&text))
}

/// Which class of drift this tick is checking for.
// `Direction` is constructed by P1's scheduler (5:1 execution:direction cadence);
// no in-crate constructor exists yet, so allow the dead-code lint until then.
#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatchCheckKind {
    /// Tactical: the agent is doing the task incorrectly. Checked often.
    Execution,
    /// Strategic: the agent is doing the wrong task entirely. Checked rarely.
    Direction,
}

impl WatchCheckKind {
    pub fn as_str(self) -> &'static str {
        match self {
            WatchCheckKind::Execution => "execution",
            WatchCheckKind::Direction => "direction",
        }
    }
}

/// How a one-shot check ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatchExitStatus {
    /// A non-empty verdict was captured before the timeout.
    Replied,
    /// The watcher produced no settled verdict before `reply_timeout`.
    Timeout,
    /// The watcher subprocess could not be spawned.
    SpawnFailed,
}

/// Everything a single drift check needs. By construction this carries only the
/// spec and a *bounded* delta — there is deliberately no field for the watched
/// agent's full transcript (R6). The scheduler (P1) must pre-bound `delta`.
#[derive(Debug, Clone)]
pub struct WatchCheckInput {
    /// Team the watched agent belongs to. The watcher is spawned into the same
    /// team namespace so its `tm-agent msg send` reaches that team's leader.
    pub team_name: String,
    /// Name of the watched agent the verdict is about.
    pub target: String,
    /// Idempotency id (`{team}:{kind}:{epoch}`) threaded into the verdict so P5
    /// can dedupe board.jsonl lines across retried ticks.
    pub check_id: String,
    pub check_kind: WatchCheckKind,
    /// "critic" (default) | "advisor" | "pair" (single dual-lens, ADR-P3).
    pub stance: String,
    /// Oversight spec → folded into the system prompt as custom instructions (F1).
    pub spec: String,
    /// BOUNDED recent delta of the watched agent. Never the full history (R6).
    pub delta: String,
    pub cli: String,
    pub model: String,
    pub working_directory: String,
    /// Resolved CLI binary path (Swift-supplied / config).
    pub cli_path: Option<String>,
    /// Swift app socket so the watcher's `tm-agent` reaches the app.
    pub app_socket_path: Option<String>,
    /// Upper bound on how long to wait for the watcher's verdict.
    pub reply_timeout: Duration,
    /// Autonomous Watch may reuse the team's GUI watcher pane. A user-triggered
    /// Pair Review sets this to false so every run is a fresh, disposable
    /// subprocess and can never depend on or mutate continuous Watch state.
    pub allow_gui_watcher_pane: bool,
    /// Optional one-shot Pair Review framing. Autonomous drift checks leave
    /// these empty and retain the established drift verdict contract.
    pub pair_scope: Option<String>,
    pub pair_lens: Option<String>,
    /// Extra CLI arguments owned by the caller's safety policy. Pair Review
    /// uses this to override Codex's normal worker sandbox to read-only.
    pub extra_cli_args: Vec<String>,
}

/// Result of one check. `verdict_text` is raw — P5 parses it.
///
/// Carries both the routing identity (copied from the [`WatchCheckInput`] so the
/// result sink / `WatchController` (P5) can attribute and dedupe the verdict
/// without re-deriving it) and the run result.
// The P4 drain task only logs routing + reported/error; the remaining result
// fields are consumed by P5's WatchController (board.jsonl + leader report).
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct WatchCheckOutcome {
    // ── routing (copied verbatim from the input) ──
    /// Team the verdict belongs to (`input.team_name`).
    pub team_id: String,
    /// Idempotency id threaded through from the input.
    pub check_id: String,
    /// Which drift class this check targeted.
    pub drift_kind: WatchCheckKind,
    /// Watched agent the verdict is about.
    pub target: String,

    // ── run result ──
    pub spawned: bool,
    /// True when a non-empty verdict was captured before the timeout.
    pub reported: bool,
    pub terminated: bool,
    pub exit_status: WatchExitStatus,
    /// Always `None`: a headless one-shot watcher never occupies a GUI pane.
    pub panel_id: Option<String>,
    /// Raw watcher reply text. Parsing / board.jsonl / leader report are P5's job.
    pub verdict_text: String,
    /// Set when the check could not run/settle (spawn failure, etc.).
    pub error: Option<String>,
}

/// Future returned by [`WatchCheckRunner::run_check`]. Boxed so the trait stays
/// object-safe (the scheduler may hold a `Box<dyn WatchCheckRunner>`) without
/// pulling in `async-trait`.
pub type WatchCheckFuture<'a> =
    std::pin::Pin<Box<dyn std::future::Future<Output = WatchCheckOutcome> + Send + 'a>>;

/// Runs a single stateless drift check. Implemented by the real
/// [`HeadlessOneShotRunner`] and, in tests, by `FakeOneShotRunner`.
pub trait WatchCheckRunner: Send + Sync {
    fn run_check<'a>(&'a self, input: WatchCheckInput) -> WatchCheckFuture<'a>;
}

/// System prompt for the one-shot watcher: role directive + spec, merged with the
/// same F1 helper used at create-time so the spec survives verbatim.
pub fn compose_watcher_instructions(spec: &str) -> Option<String> {
    merge_instructions(Some(WATCHER_ONESHOT_DIRECTIVE), Some(spec))
}

pub fn compose_pair_review_instructions(spec: &str) -> Option<String> {
    merge_instructions(Some(PAIR_REVIEW_ONESHOT_DIRECTIVE), Some(spec))
}

/// Per-tick REVIEW message. The spec lives in the system prompt
/// (see [`compose_watcher_instructions`]); this carries only the framing plus a
/// delta instruction.
///
/// GUI-compatible delta (P10): the daemon no longer pre-reads the target's
/// output (which only worked for headless targets). Instead the spawned watcher
/// self-collects the target's recent, BOUNDED delta over its own app socket
/// (`tm-agent read <target> --lines N`) — this works for both GUI (pane) and
/// headless targets. A read-only collect is not a reporting side effect, so it
/// does not violate F2; board/leader reporting stays with the WatchController.
/// If a caller pre-supplied `input.delta`, it is inlined (bounded) instead.
pub fn build_review_message(input: &WatchCheckInput) -> String {
    let delta_section = if input.delta.trim().is_empty() {
        format!(
            "Step 1 (read-only): fetch the watched agent's recent output yourself via your app socket, \
             BOUNDED to the last {n} lines — never the full history (R6). Run: \
             tm-agent read {target} --lines {n}  (or: tm-agent collect --lines {n}, \
             then focus on \"{target}\"). Use ONLY that bounded recent delta. \
             If the socket is unavailable or the agent is not active, report that as an error \
             (do not output a verdict).",
            n = DELTA_TAIL_LINES,
            target = input.target,
        )
    } else {
        format!(
            "Use ONLY the bounded recent delta below — do not request the full history (R6):\n\
             --- BEGIN DELTA (bounded; recent output only) ---\n\
             {delta}\n\
             --- END DELTA ---",
            delta = bound_delta(&input.delta),
        )
    };
    // D3 (leader-as-watch-target): when the watched target is the team LEADER's
    // own pane, the delta is the user's live, in-progress work — not a worker's
    // settled output. Tell the watcher to tolerate mid-stream/incomplete output so
    // it does not misread an unfinished step as drift.
    let leader_note = if input.target == "leader" {
        "IN-PROGRESS TOLERANCE: this target is the team LEADER's own pane — the \
         user's live, in-progress work (active typing, streaming CLI output, shell \
         noise). Incomplete or mid-stream output is NOT drift. Judge only a clear, \
         settled deviation from the spec; when in doubt, report on-track.\n\n"
    } else {
        ""
    };
    if let Some(scope) = input.pair_scope.as_deref() {
        let lens = input.pair_lens.as_deref().unwrap_or("general");
        return format!(
            "PAIR REVIEW NOW\n\
             check_id: {check_id}\n\
             scope: {scope}\n\
             lens: {lens}\n\
             target: {target}\n\n\
             {delta_section}\n\n\
             {leader_note}\
             Review only the stated scope through the stated lens. Treat this as \
             read-only review: never edit files, commit, or message another agent. \
             Output one structured result and nothing else:\n\
             [VERDICT] approve | changes-requested | blocked\n\
             [FINDINGS] numbered findings with severity and concrete evidence, or none\n\
             [RECOMMENDED_ACTIONS] numbered bounded actions, or none",
            check_id = input.check_id,
            scope = scope,
            lens = lens,
            target = input.target,
            delta_section = delta_section,
            leader_note = leader_note,
        );
    }
    format!(
        "REVIEW NOW\n\
         check_id: {check_id}\n\
         check_kind: {kind}\n\
         stance: {stance}\n\
         target: {target}\n\n\
         {delta_section}\n\n\
         {leader_note}\
         Then judge the watched agent \"{target}\" against your spec and output a \
         single structured verdict (and nothing else):\n\
         [VERDICT] on-track | drift(execution) | drift(direction)\n\
         [FINDING] one line citing the spec clause — or \"none\"\n\
         [SPEC_CLAUSE] the clause referenced — or \"n/a\"",
        check_id = input.check_id,
        kind = input.check_kind.as_str(),
        stance = input.stance,
        target = input.target,
        delta_section = delta_section,
        leader_note = leader_note,
    )
}

/// Production runner: spawns/reaps a real headless watcher via [`HeadlessManager`].
pub struct HeadlessOneShotRunner {
    manager: Arc<Mutex<HeadlessManager>>,
}

// Wired by P1's WatchController scheduler; until then the production build has
// no caller, so suppress the expected dead-code warnings on the runner internals.
#[allow(dead_code)]
impl HeadlessOneShotRunner {
    pub fn new(manager: Arc<Mutex<HeadlessManager>>) -> Self {
        Self { manager }
    }

    async fn run_check_impl(&self, mut input: WatchCheckInput) -> WatchCheckOutcome {
        // Routing identity copied into the outcome so the sink (P5) can attribute
        // and dedupe without re-deriving it.
        let team_id = input.team_name.clone();
        let check_id = input.check_id.clone();
        let drift_kind = input.check_kind;
        let target = input.target.clone();

        // P13: prefer a daemon-side pre-fetch of the watched target's bounded
        // delta. For a HEADLESS target the agent lives in this process's manager,
        // so read_output returns its recent output and we inline it — avoiding a
        // fragile self-collect tool-call (which made real claude pause mid-turn
        // and produce no settled verdict). A GUI (pane) target is NOT in the
        // manager → read_output is empty → the watcher self-collects over its app
        // socket instead (build_review_message fallback).
        if input.delta.trim().is_empty() && !input.target.is_empty() {
            let target_agent_id = format!("{}@{}", input.target, input.team_name);
            let lines = self
                .manager
                .lock()
                .await
                .read_output(&target_agent_id, DELTA_TAIL_LINES)
                .await
                .unwrap_or_default();
            if !lines.is_empty() {
                let text = extract_verdict_text(&lines);
                if !text.trim().is_empty() {
                    input.delta = bound_delta(&text);
                    tracing::debug!(
                        "watch: pre-fetched {} bytes of delta for headless target {}",
                        input.delta.len(),
                        target_agent_id
                    );
                }
            }
        }

        // §4: route a GUI-pane team (its panes live in the Swift app, not this
        // daemon's headless manager) with a live app socket to the pane-recycle
        // path. Pure-headless teams — and GUI teams without an app socket — keep
        // the one-shot spawn below.
        let is_headless_team = self.manager.lock().await.has_team(&input.team_name);
        if input.allow_gui_watcher_pane
            && should_use_gui_pane_path(is_headless_team, input.app_socket_path.as_deref())
        {
            let app_socket = input.app_socket_path.clone().unwrap_or_default();
            tracing::debug!(
                "watch: team {} → §4 GUI pane-recycle path (watcher pane over app socket)",
                input.team_name
            );
            return self.run_check_gui_pane(input, &app_socket).await;
        }

        // Unique per-tick name → a fresh subprocess every check (no context reuse).
        let agent_name = format!("watcher-{}", super::meta::new_uuid());
        let instructions = if input.pair_scope.is_some() {
            compose_pair_review_instructions(&input.spec)
        } else {
            compose_watcher_instructions(&input.spec)
        };

        let spawn_params = SpawnParams {
            name: agent_name,
            team_name: input.team_name.clone(),
            cli: input.cli.clone(),
            model: input.model.clone(),
            working_directory: input.working_directory.clone(),
            cli_path: input.cli_path.clone(),
            app_socket_path: input.app_socket_path.clone(),
            instructions,
            // The watcher must report under a distinct identity so its reply does
            // not collide with the watched agent in the team namespace.
            agent_name_override: None,
            extra_args: input.extra_cli_args.clone(),
        };

        // 1. Spawn (hold the manager lock only for the spawn itself).
        let agent_id = match self.manager.lock().await.spawn_agent(spawn_params).await {
            Ok(info) => info.id,
            Err(e) => {
                return WatchCheckOutcome {
                    team_id,
                    check_id,
                    drift_kind,
                    target,
                    spawned: false,
                    reported: false,
                    terminated: false,
                    exit_status: WatchExitStatus::SpawnFailed,
                    panel_id: None,
                    verdict_text: format!("spawn failed: {e}"),
                    error: Some(format!("spawn failed: {e}")),
                };
            }
        };

        // 2. Inject the per-tick REVIEW request.
        let message = build_review_message(&input);
        tracing::debug!(
            "watch: sending review to {agent_id} ({} bytes, delta_inlined={})",
            message.len(),
            !input.delta.trim().is_empty()
        );
        let _ = self
            .manager
            .lock()
            .await
            .send_message(&agent_id, &message)
            .await;

        // 3. Wait for the settled verdict (or timeout). For claude we wait for the
        // terminal stream-json result event (a mid-turn thinking/tool pause must
        // NOT be mistaken for completion — P13 #A).
        let (verdict_text, status) =
            wait_for_verdict(&self.manager, &agent_id, input.reply_timeout, &input.cli).await;
        tracing::debug!(
            "watch: verdict capture agent={agent_id} status={status:?} verdict_len={} preview={:?}",
            verdict_text.len(),
            verdict_text.chars().take(120).collect::<String>()
        );

        // 4. Reap — always terminate the one-shot watcher (no pane to leave behind).
        let terminated = self.manager.lock().await.terminate(&agent_id).await.is_ok();

        let reported = !verdict_text.trim().is_empty();

        // P13 fallback: detect collection/RPC errors and surface as errors (not drifts).
        // If the watcher tried to run tm-agent read/collect and got an error, it should
        // report that explicitly, not output a verdict. Errors like "unknown method",
        // "socket unavailable", "agent not active" indicate collection failure.
        let collection_error = verdict_text.contains("unknown method")
            || verdict_text.contains("socket")
            || verdict_text.contains("not active")
            || verdict_text.contains("connection refused")
            || verdict_text.contains("team.read")
            || verdict_text.contains("team.collect")
            || verdict_text.contains("team.status");

        let error = match status {
            WatchExitStatus::Timeout if !reported => Some("verdict timeout".to_string()),
            _ if collection_error && reported => {
                // Watcher reported a collection/RPC error instead of a verdict.
                // Surface this as an error, not a drift.
                tracing::warn!(
                    "watch: collection error from watcher (team={} check={}): {}",
                    team_id,
                    check_id,
                    verdict_text.chars().take(200).collect::<String>()
                );
                Some(format!(
                    "collection failed: {}",
                    verdict_text.chars().take(100).collect::<String>()
                ))
            }
            _ => None,
        };
        WatchCheckOutcome {
            team_id,
            check_id,
            drift_kind,
            target,
            spawned: true,
            reported: reported && !collection_error, // Don't mark as reported if it's an error
            terminated,
            exit_status: status,
            panel_id: None,
            verdict_text,
            error,
        }
    }

    /// §4 GUI pane-recycle path: recycle the live watcher pane (drop context),
    /// send it the review prompt, press Return, then poll the pane's terminal for
    /// the sentinel-wrapped verdict. Unlike the headless one-shot it never spawns
    /// or terminates a subprocess — the watcher is a persistent Swift-app pane
    /// reused across checks, so `recycle` is the stateless guarantee here.
    async fn run_check_gui_pane(
        &self,
        input: WatchCheckInput,
        app_socket: &str,
    ) -> WatchCheckOutcome {
        const WATCHER: &str = "watcher";
        let make = |spawned: bool,
                    reported: bool,
                    exit_status: WatchExitStatus,
                    verdict_text: String,
                    error: Option<String>|
         -> WatchCheckOutcome {
            WatchCheckOutcome {
                team_id: input.team_name.clone(),
                check_id: input.check_id.clone(),
                drift_kind: input.check_kind,
                target: input.target.clone(),
                spawned,
                reported,
                terminated: false, // the GUI watcher pane stays live across checks
                exit_status,
                panel_id: Some(format!("{}:{}", input.team_name, WATCHER)),
                verdict_text,
                error,
            }
        };

        // 1. Recycle (hard restart) → drop accumulated context = stateless check.
        if let Err(e) = app_recycle_pane(app_socket, &input.team_name, WATCHER).await {
            let msg = format!("recycle failed: {e}");
            return make(
                false,
                false,
                WatchExitStatus::SpawnFailed,
                msg.clone(),
                Some(msg),
            );
        }
        // 2. Wait for the respawned CLI to finish cold-starting, then add an
        //    input-ready buffer: live testing showed the prompt is dropped when it
        //    lands while the CLI's input box is still initializing (output had
        //    settled but the TUI was not yet accepting input).
        wait_pane_ready(
            app_socket,
            &input.team_name,
            WATCHER,
            Duration::from_millis(GUI_RECYCLE_READY_CAP_MS),
        )
        .await;
        tokio::time::sleep(Duration::from_millis(GUI_INPUT_READY_BUFFER_MS)).await;
        // 3-5. Send a plain review prompt and poll the watcher's reply file. The
        //      GUI watcher is a real claude/codex CLI running its own runbook — it
        //      answers via `tm-agent reply`, which always writes the full reply to
        //      ~/.term-mesh/results/<team>/<watcher>-reply.md (the leader-inbox
        //      message is only a truncated summary), so no sentinel directive.
        //      The recycled CLI's input box may not be ready when the first prompt
        //      lands (cold-starting Claude Code / codex drops it), so re-send every
        //      GUI_RESEND_INTERVAL until the watcher replies (reply file rewritten
        //      after `since`) or the budget elapses. Re-sending a busy watcher is
        //      harmless — the file holds its latest reply.
        let since = std::time::SystemTime::now();
        // build_review_message tells the watcher to "output a single structured
        // verdict (and nothing else)", which makes a GUI claude/codex print the
        // verdict to its terminal but NOT run `tm-agent reply` — so no reply file
        // is written and §4 can't recover it. Override that for the GUI path: the
        // verdict is only delivered by RUNNING `tm-agent reply` (its result file is
        // what we poll). Printing alone does nothing here.
        let message = format!(
            "{}\n\nDELIVERY (overrides any \"nothing else\" instruction above): submit \
             the verdict by RUNNING `tm-agent reply` with the whole header+body as ONE \
             single-quoted positional argument (a heredoc or pipe also works now, but \
             the quoted-arg form is simplest — do not rely on stdin alone). The first \
             line MUST be `STATUS: DONE` (or BLOCKED / NEEDS_REVIEW), then \
             FILES/VERIFY/NEXT/FULL_REPORT, a blank line, then your \
             [VERDICT]/[FINDING]/[SPEC_CLAUSE] lines. You are the stateless watcher, so \
             do NOT pass --task-id and ignore any \"no active task\" note. Running the \
             command is the only delivery; printing to the terminal alone does nothing.",
            build_review_message(&input)
        );
        let reply_path = watcher_reply_path(&input.team_name, WATCHER);
        let deadline = Instant::now() + input.reply_timeout;
        let mut last_send: Option<Instant> = None;
        let mut last_send_err: Option<String> = None;
        loop {
            let resend_due = last_send
                .map(|t| t.elapsed() >= GUI_RESEND_INTERVAL)
                .unwrap_or(true);
            if resend_due {
                // Send errors are tolerated and retried: a transient team.send
                // parse/RPC failure (pane mid-transition, app momentarily busy)
                // must not kill the whole tick. Keep the last error for the
                // timeout message.
                if let Err(e) = app_send_pane(app_socket, &input.team_name, WATCHER, &message).await
                {
                    last_send_err = Some(format!("send: {e}"));
                } else if let Err(e) =
                    app_send_key_pane(app_socket, &input.team_name, WATCHER, "return").await
                {
                    last_send_err = Some(format!("send_key: {e}"));
                } else {
                    last_send_err = None;
                }
                last_send = Some(Instant::now());
            }
            // A fresh (mtime > since) non-empty reply settles this tick's verdict.
            if let Some(ref p) = reply_path {
                if let Ok(meta) = tokio::fs::metadata(p).await {
                    if meta.modified().map(|m| m > since).unwrap_or(false) {
                        if let Ok(content) = tokio::fs::read_to_string(p).await {
                            if !content.trim().is_empty() {
                                return make(true, true, WatchExitStatus::Replied, content, None);
                            }
                        }
                    }
                }
            }
            if Instant::now() >= deadline {
                let msg = match &last_send_err {
                    Some(e) => {
                        format!("verdict timeout (watcher wrote no reply; last send error: {e})")
                    }
                    None => {
                        "verdict timeout (watcher wrote no reply before reply_timeout)".to_string()
                    }
                };
                return make(
                    true,
                    false,
                    WatchExitStatus::Timeout,
                    String::new(),
                    Some(msg),
                );
            }
            tokio::time::sleep(Duration::from_millis(400)).await;
        }
    }
}

impl WatchCheckRunner for HeadlessOneShotRunner {
    fn run_check<'a>(&'a self, input: WatchCheckInput) -> WatchCheckFuture<'a> {
        Box::pin(async move { self.run_check_impl(input).await })
    }
}

/// Extract the watcher's verdict text from raw stdout lines (P11 #1).
///
/// Claude headless agents emit `--output-format stream-json`, so the raw buffer
/// is JSON events, not plain text — the verdict tags live INSIDE the JSON. This
/// pulls the assistant's text out: it prefers the terminal `result` event
/// (complete turn text), falls back to concatenated `assistant` text blocks, and
/// finally to the raw join (non-claude / already-plain output).
pub(crate) fn extract_verdict_text(raw_lines: &[String]) -> String {
    let mut assistant = String::new();
    let mut result: Option<String> = None;
    for line in raw_lines {
        let line = line.trim();
        if !line.starts_with('{') {
            continue;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        match v.get("type").and_then(|t| t.as_str()) {
            Some("result") => {
                if let Some(r) = v.get("result").and_then(|r| r.as_str()) {
                    result = Some(r.to_string());
                }
            }
            Some("assistant") => {
                if let Some(content) = v
                    .get("message")
                    .and_then(|m| m.get("content"))
                    .and_then(|c| c.as_array())
                {
                    for block in content {
                        if block.get("type").and_then(|t| t.as_str()) == Some("text") {
                            if let Some(t) = block.get("text").and_then(|t| t.as_str()) {
                                assistant.push_str(t);
                                assistant.push('\n');
                            }
                        }
                    }
                }
            }
            // codex: the assistant's reply arrives as a completed `agent_message`
            // item. codex has no claude-style `result`, so this feeds the
            // assistant fallback below.
            Some("item.completed") => {
                if let Some(item) = v.get("item") {
                    if item.get("type").and_then(|t| t.as_str()) == Some("agent_message") {
                        if let Some(t) = item.get("text").and_then(|t| t.as_str()) {
                            assistant.push_str(t);
                            assistant.push('\n');
                        }
                    }
                }
            }
            _ => {}
        }
    }
    if let Some(r) = result {
        if !r.trim().is_empty() {
            return r;
        }
    }
    if !assistant.trim().is_empty() {
        return assistant;
    }
    raw_lines.join("\n")
}

/// §4 routing predicate: a watch tick uses the GUI pane-recycle path when the
/// team is NOT a daemon-managed headless team (so its panes live in the Swift
/// app) AND a live app socket is available to drive recycle/send/read on the
/// pane. Otherwise the tick uses the headless one-shot spawn.
fn should_use_gui_pane_path(is_headless_team: bool, app_socket_path: Option<&str>) -> bool {
    !is_headless_team
        && app_socket_path
            .map(|s| !s.trim().is_empty())
            .unwrap_or(false)
}

// ── §4 P2b-1: daemon → Swift-app RPC client ─────────────────────────────────
// The GUI watch path drives a watcher pane the daemon does not own, so it must
// talk to the Swift app over the app socket. Same wire format as
// query_gui_team_workers (newline-delimited JSON-RPC, single-line response).
// P2b-2 wires these into the GUI execution path; until then they are unused.

/// Send one JSON-RPC request to the Swift app over its unix socket and return the
/// parsed response envelope.
#[allow(dead_code)]
async fn call_app_rpc(
    app_socket: &str,
    method: &str,
    params: serde_json::Value,
    timeout_secs: u64,
) -> Result<serde_json::Value, String> {
    let stream = UnixStream::connect(app_socket)
        .await
        .map_err(|e| format!("connect {app_socket}: {e}"))?;
    let req = serde_json::json!({
        "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
    });
    let mut line = serde_json::to_string(&req).map_err(|e| format!("serialize: {e}"))?;
    line.push('\n');
    let (rd, mut wr) = stream.into_split();
    wr.write_all(line.as_bytes())
        .await
        .map_err(|e| format!("write: {e}"))?;
    wr.flush().await.map_err(|e| format!("flush: {e}"))?;
    let mut resp = String::new();
    let mut reader = BufReader::new(rd);
    match timeout(
        Duration::from_secs(timeout_secs),
        reader.read_line(&mut resp),
    )
    .await
    {
        Ok(Ok(_)) => {}
        Ok(Err(e)) => return Err(format!("read: {e}")),
        Err(_) => {
            return Err(format!(
                "app rpc '{method}' timed out after {timeout_secs}s"
            ))
        }
    }
    if resp.trim().is_empty() {
        return Err(format!(
            "app rpc '{method}': empty response (app unreachable?)"
        ));
    }
    serde_json::from_str(&resp).map_err(|e| format!("parse '{method}' response: {e}"))
}

/// Unwrap a Swift v2 RPC envelope: returns the `result` value, or an error when
/// the app reported an `error` payload or `ok:false`.
#[allow(dead_code)]
fn app_rpc_result(v: &serde_json::Value) -> Result<&serde_json::Value, String> {
    if let Some(err) = v.get("error") {
        return Err(format!("{err}"));
    }
    if v.get("ok").and_then(|b| b.as_bool()) == Some(false) {
        return Err(format!("rpc reported failure: {v}"));
    }
    Ok(v.get("result").unwrap_or(v))
}

/// §4 GUI path: hard-restart (recycle) a watcher pane to drop accumulated context
/// before a fresh check — the stateless guarantee, applied to the live pane.
#[allow(dead_code)]
async fn app_recycle_pane(app_socket: &str, team: &str, agent: &str) -> Result<(), String> {
    let v = call_app_rpc(
        app_socket,
        "team.restart",
        serde_json::json!({"team_name": team, "agent_name": agent, "mode": "hard"}),
        10,
    )
    .await?;
    app_rpc_result(&v).map(|_| ())
}

/// §4 GUI path: send the review prompt text to the watcher pane.
#[allow(dead_code)]
async fn app_send_pane(
    app_socket: &str,
    team: &str,
    agent: &str,
    text: &str,
) -> Result<(), String> {
    let v = call_app_rpc(
        app_socket,
        "team.send",
        serde_json::json!({"team_name": team, "agent_name": agent, "text": text}),
        10,
    )
    .await?;
    app_rpc_result(&v).map(|_| ())
}

/// §4 GUI path: read the watcher pane's terminal text. Swift already base64-
/// decodes it into `result.text`, so we return that string directly.
#[allow(dead_code)]
async fn app_read_pane(
    app_socket: &str,
    team: &str,
    agent: &str,
    lines: usize,
) -> Result<String, String> {
    let v = call_app_rpc(
        app_socket,
        "team.read",
        serde_json::json!({"team_name": team, "agent_name": agent, "lines": lines}),
        10,
    )
    .await?;
    let result = app_rpc_result(&v)?;
    Ok(result
        .get("text")
        .and_then(|t| t.as_str())
        .unwrap_or("")
        .to_string())
}

/// §4 GUI path: press a key (e.g. "return") on the watcher pane. team.send only
/// injects text (withReturn=false), so the prompt is not executed until Return is
/// pressed separately via team.send_key.
async fn app_send_key_pane(
    app_socket: &str,
    team: &str,
    agent: &str,
    key: &str,
) -> Result<(), String> {
    let v = call_app_rpc(
        app_socket,
        "team.send_key",
        serde_json::json!({"team_name": team, "agent_name": agent, "key": key}),
        10,
    )
    .await?;
    app_rpc_result(&v).map(|_| ())
}

/// How many trailing terminal lines to read each poll when sensing pane readiness.
const GUI_READ_LINES: usize = 2000;
/// Hard cap on waiting for the recycled watcher CLI to finish cold-starting
/// before injecting the prompt (see `wait_pane_ready`). A fixed short sleep
/// dropped the prompt in live testing — Claude Code / codex boots (load + MCP +
/// plugins) take several seconds, longer than the old 1500ms settle.
const GUI_RECYCLE_READY_CAP_MS: u64 = 12000;
/// Extra pause after startup output settles, covering the window between "banner
/// finished rendering" and "input box accepts paste". Live testing showed a
/// prompt sent right at output-settle was still dropped.
const GUI_INPUT_READY_BUFFER_MS: u64 = 2500;
/// Re-send the review if the watcher hasn't replied within this interval — the
/// recycled CLI may have dropped the first prompt while still cold-starting.
const GUI_RESEND_INTERVAL: Duration = Duration::from_secs(30);

/// §4 GUI path: after a recycle (hard restart), wait until the freshly respawned
/// CLI in the watcher pane is ready for input. A fixed sleep is fragile — Claude
/// Code / codex cold-start (load + MCP + plugins) takes several seconds, and a
/// too-short wait drops the injected prompt (observed live: the pane showed the
/// Claude banner but the review never landed). Poll the pane's terminal until its
/// output stops growing (the startup banner finished rendering) or a hard cap
/// elapses, then proceed.
async fn wait_pane_ready(app_socket: &str, team: &str, agent: &str, max_wait: Duration) {
    const POLL: Duration = Duration::from_millis(300);
    const QUIET: Duration = Duration::from_millis(1200);
    let deadline = Instant::now() + max_wait;
    let mut last_len: usize = 0;
    let mut last_change = Instant::now();
    let mut saw_output = false;
    loop {
        let len = app_read_pane(app_socket, team, agent, GUI_READ_LINES)
            .await
            .map(|t| t.len())
            .unwrap_or(0);
        if len != last_len {
            last_len = len;
            last_change = Instant::now();
            if len > 0 {
                saw_output = true;
            }
        }
        // Ready once the startup output has been quiet (stopped growing) — the
        // CLI has finished booting and is at its prompt.
        if saw_output && last_change.elapsed() >= QUIET {
            return;
        }
        if Instant::now() >= deadline {
            return; // hard cap: proceed anyway
        }
        tokio::time::sleep(POLL).await;
    }
}

/// Path of the watcher's reply file. `tm-agent reply` ALWAYS writes the full,
/// untruncated reply here as `<agent>-reply.md` — the canonical verdict source
/// (the leader-inbox message is only a 1500-char summary). §4 recovers the
/// verdict from this file.
fn watcher_reply_path(team: &str, agent: &str) -> Option<std::path::PathBuf> {
    dirs::home_dir().map(|h| {
        h.join(".term-mesh")
            .join("results")
            .join(team)
            .join(format!("{agent}-reply.md"))
    })
}

/// True once the claude turn has settled — a terminal `result` event is present.
fn has_result_event(raw_lines: &[String]) -> bool {
    raw_lines.iter().any(|line| {
        let line = line.trim();
        if !line.starts_with('{') {
            return false;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            return false;
        };
        // claude stream-json emits a terminal `result`; codex emits
        // `turn.completed` when the turn (and its agent_message) is done.
        matches!(
            v.get("type").and_then(|t| t.as_str()),
            Some("result") | Some("turn.completed")
        )
    })
}

/// Poll the agent's stdout until its turn completes, then return the EXTRACTED
/// verdict text (not raw stream-json). Completion is detected by:
///   - claude: ONLY the terminal stream-json `result` event (or `timeout`). A
///     mid-turn pause (thinking, tool call) must not be read as completion —
///     that was P13 root cause #A: the old quiet-period heuristic returned an
///     empty/partial verdict while claude was still working, then terminated it.
///   - other CLIs: a `result` event if present, else output that goes quiet for
///     `QUIET_PERIOD` (no stream-json result to rely on).
/// The manager lock is held only for each short `read_output` call.
async fn wait_for_verdict(
    manager: &Arc<Mutex<HeadlessManager>>,
    agent_id: &str,
    timeout: Duration,
    cli: &str,
) -> (String, WatchExitStatus) {
    const POLL: Duration = Duration::from_millis(200);
    const QUIET_PERIOD: Duration = Duration::from_millis(1500);
    // Claude emits a definitive `result` event; never settle on quiet for it.
    // Claude and Codex both expose definitive terminal events. Treating a
    // short quiet gap after Codex's thread.started/turn.started events as a
    // completed answer returned raw protocol JSON as the Pair Review verdict.
    let use_quiet_fallback =
        !cli.eq_ignore_ascii_case("claude") && !cli.eq_ignore_ascii_case("codex");

    let deadline = Instant::now() + timeout;
    let mut last_len: usize = 0;
    let mut last_change = Instant::now();
    let mut saw_output = false;

    loop {
        if Instant::now() >= deadline {
            let lines = read_lines(manager, agent_id).await;
            return (extract_verdict_text(&lines), WatchExitStatus::Timeout);
        }
        tokio::time::sleep(POLL).await;

        let lines = read_lines(manager, agent_id).await;
        // Strongest completion signal: the terminal result event.
        if has_result_event(&lines) {
            return (extract_verdict_text(&lines), WatchExitStatus::Replied);
        }
        if use_quiet_fallback {
            let len = lines.len();
            if len != last_len {
                last_len = len;
                last_change = Instant::now();
                if len > 0 {
                    saw_output = true;
                }
            }
            if saw_output && last_change.elapsed() >= QUIET_PERIOD {
                return (extract_verdict_text(&lines), WatchExitStatus::Replied);
            }
        }
    }
}

async fn read_lines(manager: &Arc<Mutex<HeadlessManager>>, agent_id: &str) -> Vec<String> {
    let mut mgr = manager.lock().await;
    mgr.read_output(agent_id, 10_000).await.unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_input(delta: &str) -> WatchCheckInput {
        WatchCheckInput {
            team_name: "standard".into(),
            target: "executor".into(),
            check_id: "standard:execution:1700000000".into(),
            check_kind: WatchCheckKind::Execution,
            stance: "critic".into(),
            spec: "SPEC-SENTINEL-ONE-SHOT".into(),
            delta: delta.into(),
            cli: "claude".into(),
            model: "sonnet".into(),
            working_directory: "/tmp".into(),
            cli_path: None,
            app_socket_path: None,
            reply_timeout: Duration::from_millis(800),
            allow_gui_watcher_pane: true,
            pair_scope: None,
            pair_lens: None,
            extra_cli_args: vec![],
        }
    }

    #[test]
    fn compose_watcher_instructions_folds_spec_via_f1() {
        let out = compose_watcher_instructions("SPEC-SENTINEL-ONE-SHOT").unwrap();
        assert!(out.contains(WATCHER_ONESHOT_DIRECTIVE));
        assert!(out.contains("## Custom Instructions"));
        assert!(out.contains("SPEC-SENTINEL-ONE-SHOT"));
    }

    #[test]
    fn pair_review_message_has_read_only_structured_contract() {
        let mut input = sample_input("diff --git a/a b/a");
        input.target = "leader".into();
        input.pair_scope = Some("current-changes".into());
        input.pair_lens = Some("security".into());
        input.allow_gui_watcher_pane = false;

        let message = build_review_message(&input);
        assert!(message.contains("PAIR REVIEW NOW"));
        assert!(message.contains("scope: current-changes"));
        assert!(message.contains("lens: security"));
        assert!(message.contains("never edit files"));
        assert!(message.contains("[VERDICT] approve | changes-requested | blocked"));
        assert!(message.contains("[FINDINGS]"));
        assert!(message.contains("[RECOMMENDED_ACTIONS]"));
    }

    #[test]
    fn review_message_carries_only_bounded_delta_and_metadata() {
        let input = sample_input("DELTA-LINE-ONLY-RECENT");
        let msg = build_review_message(&input);
        // Carries the bounded delta + stance + kind + idempotency id.
        assert!(msg.contains("DELTA-LINE-ONLY-RECENT"));
        assert!(msg.contains("execution"));
        assert!(msg.contains("critic"));
        assert!(msg.contains("standard:execution:1700000000"));
        // R6: explicitly tells the watcher not to use full history, and the spec
        // text is NOT inlined into the per-tick message (it lives in the system
        // prompt only) so the message stays bounded.
        assert!(msg.contains("bounded"));
        assert!(!msg.contains("SPEC-SENTINEL-ONE-SHOT"));
    }

    #[test]
    fn extract_verdict_text_pulls_assistant_text_from_stream_json() {
        // P11 #1: claude emits stream-json; the verdict tags live inside the JSON.
        let lines = vec![
            r#"{"type":"system","subtype":"init"}"#.to_string(),
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"[VERDICT] drift(execution)"}]}}"#.to_string(),
            r#"{"type":"result","subtype":"success","result":"[VERDICT] drift(execution)\n[FINDING] ignored a failing build"}"#.to_string(),
        ];
        let text = extract_verdict_text(&lines);
        assert!(text.contains("[VERDICT] drift(execution)"));
        assert!(text.contains("ignored a failing build"));
        assert!(has_result_event(&lines));
    }

    #[test]
    fn extract_verdict_text_reads_codex_agent_message() {
        // codex emits JSONL: agent_message item carries the reply, turn.completed
        // is the terminal event. The claude-stream-json adapter could parse none
        // of this, which is why codex watchers timed out with verdict_len=0.
        let lines = vec![
            r#"{"type":"thread.started","thread_id":"x"}"#.to_string(),
            r#"{"type":"turn.started"}"#.to_string(),
            r#"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"[VERDICT] OK\n[FINDING] none"}}"#.to_string(),
            r#"{"type":"turn.completed","usage":{"output_tokens":6}}"#.to_string(),
        ];
        let text = extract_verdict_text(&lines);
        assert!(text.contains("[VERDICT] OK"), "got: {text}");
        assert!(text.contains("[FINDING] none"));
        // turn.completed must count as a settle signal so wait_for_verdict returns
        // Replied instead of waiting out the full timeout.
        assert!(has_result_event(&lines));
    }

    #[test]
    fn has_result_event_ignores_codex_intermediate_events() {
        // Only the terminal turn.completed settles; earlier codex events must not.
        let pre = vec![
            r#"{"type":"thread.started"}"#.to_string(),
            r#"{"type":"item.completed","item":{"type":"agent_message","text":"partial"}}"#
                .to_string(),
        ];
        assert!(!has_result_event(&pre));
    }

    #[test]
    fn gui_pane_path_only_for_gui_team_with_app_socket() {
        // GUI team (not in the headless manager) + live app socket → recycle path.
        assert!(should_use_gui_pane_path(false, Some("/tmp/term-mesh.sock")));
        // Headless team always takes the one-shot, even with an app socket.
        assert!(!should_use_gui_pane_path(true, Some("/tmp/term-mesh.sock")));
        // GUI team but no usable app socket → can't drive the pane → one-shot.
        assert!(!should_use_gui_pane_path(false, None));
        assert!(!should_use_gui_pane_path(false, Some("")));
        assert!(!should_use_gui_pane_path(false, Some("   ")));
    }

    #[test]
    fn app_rpc_result_unwraps_ok_and_rejects_errors() {
        // Swift v2 success envelope → return the result object (team.read shape).
        let ok = serde_json::json!({"id":1,"ok":true,"result":{"text":"verdict"}});
        assert_eq!(app_rpc_result(&ok).unwrap()["text"], "verdict");
        // error payload → Err
        let err = serde_json::json!({"id":1,"error":{"code":"not_found","message":"x"}});
        assert!(app_rpc_result(&err).is_err());
        // explicit ok:false → Err
        let nak = serde_json::json!({"id":1,"ok":false});
        assert!(app_rpc_result(&nak).is_err());
    }

    #[test]
    fn watcher_reply_path_under_results_dir() {
        // §4 recovers the GUI verdict from the watcher's reply file at
        // ~/.term-mesh/results/<team>/<agent>-reply.md (canonical, full content).
        let p = watcher_reply_path("ws-abc123", "watcher").expect("home dir");
        assert!(p.ends_with("watcher-reply.md"));
        assert!(p
            .to_string_lossy()
            .contains(".term-mesh/results/ws-abc123/"));
    }

    #[test]
    fn extract_verdict_text_falls_back_to_raw_for_plain_text() {
        let lines = vec!["[VERDICT] on-track".to_string()];
        assert_eq!(extract_verdict_text(&lines), "[VERDICT] on-track");
        assert!(!has_result_event(&lines));
    }

    #[test]
    fn extract_verdict_text_concats_assistant_when_no_result() {
        let lines = vec![
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"[VERDICT] on-track"}]}}"#.to_string(),
        ];
        let text = extract_verdict_text(&lines);
        assert!(text.contains("[VERDICT] on-track"));
    }

    #[test]
    fn review_message_self_collects_when_delta_empty() {
        // P10 GUI-compatible delta: with no pre-fetched delta the watcher is told
        // to read the target's bounded recent output itself (works for GUI panes,
        // not just headless agents). R6: bounded by --lines, never full history.
        let input = sample_input("");
        let msg = build_review_message(&input);
        assert!(msg.contains("tm-agent read executor"));
        assert!(msg.contains("--lines"));
        assert!(msg.contains(&DELTA_TAIL_LINES.to_string()));
        assert!(msg.contains("read-only"));
        // Spec is never inlined (system prompt only); message stays bounded.
        assert!(!msg.contains("SPEC-SENTINEL-ONE-SHOT"));
    }

    /// FakeOneShotRunner records every input it receives so the scheduler (P1)
    /// and this crate can assert the runner is only ever fed spec + bounded delta
    /// + stance + check_kind — there is no full-transcript field to leak (R6).
    struct FakeOneShotRunner {
        received: Arc<Mutex<Vec<WatchCheckInput>>>,
        canned_verdict: String,
    }

    impl FakeOneShotRunner {
        fn new(canned_verdict: &str) -> Self {
            Self {
                received: Arc::new(Mutex::new(Vec::new())),
                canned_verdict: canned_verdict.into(),
            }
        }
    }

    impl WatchCheckRunner for FakeOneShotRunner {
        fn run_check<'a>(&'a self, input: WatchCheckInput) -> WatchCheckFuture<'a> {
            Box::pin(async move {
                let team_id = input.team_name.clone();
                let check_id = input.check_id.clone();
                let drift_kind = input.check_kind;
                let target = input.target.clone();
                self.received.lock().await.push(input);
                WatchCheckOutcome {
                    team_id,
                    check_id,
                    drift_kind,
                    target,
                    spawned: true,
                    reported: true,
                    terminated: true,
                    exit_status: WatchExitStatus::Replied,
                    panel_id: None,
                    verdict_text: self.canned_verdict.clone(),
                    error: None,
                }
            })
        }
    }

    #[tokio::test]
    async fn fake_one_shot_runner_receives_only_bounded_input() {
        let runner = FakeOneShotRunner::new("[VERDICT] on-track");
        let input = sample_input("BOUNDED-DELTA-42");
        let outcome = runner.run_check(input).await;

        assert!(outcome.spawned && outcome.reported && outcome.terminated);
        assert_eq!(outcome.exit_status, WatchExitStatus::Replied);
        assert!(
            outcome.panel_id.is_none(),
            "headless watcher must not own a pane"
        );
        assert_eq!(outcome.verdict_text, "[VERDICT] on-track");

        let got = runner.received.lock().await;
        assert_eq!(got.len(), 1);
        let recorded = &got[0];
        // Exactly the bounded inputs — and the delta is the bounded one we passed.
        assert_eq!(recorded.delta, "BOUNDED-DELTA-42");
        assert_eq!(recorded.spec, "SPEC-SENTINEL-ONE-SHOT");
        assert_eq!(recorded.stance, "critic");
        assert_eq!(recorded.check_kind, WatchCheckKind::Execution);
    }

    /// Real runner against an isolated `TERMMESH_HEADLESS_ROOT`, using a fake CLI
    /// that blocks on stdin (no stdout). Verifies spawn → timeout → terminate
    /// fully reaps the subprocess (no agent left registered, no pane).
    #[tokio::test]
    async fn one_shot_real_spawn_then_terminate_cleans_up() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("TERMMESH_HEADLESS_ROOT", dir.path());

        let fake_cli = dir.path().join("fake-cli.sh");
        std::fs::write(&fake_cli, "#!/bin/sh\nexec cat >/dev/null 2>&1\n").unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&fake_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let fake_cli = fake_cli.to_string_lossy().to_string();
        let workdir = dir.path().to_string_lossy().to_string();

        let manager = Arc::new(Mutex::new(HeadlessManager::new()));
        let runner = HeadlessOneShotRunner::new(manager.clone());

        let mut input = sample_input("BOUNDED-DELTA-REAL");
        input.team_name = "one-shot-test".into();
        input.working_directory = workdir;
        input.cli_path = Some(fake_cli);
        input.reply_timeout = Duration::from_millis(600);

        let outcome = runner.run_check(input).await;

        assert!(outcome.spawned, "spawn should succeed with the fake CLI");
        assert!(outcome.terminated, "the one-shot watcher must be reaped");
        assert!(
            outcome.panel_id.is_none(),
            "headless one-shot never owns a pane"
        );
        // Fake CLI emits no verdict → timeout, no settled report.
        assert_eq!(outcome.exit_status, WatchExitStatus::Timeout);
        assert!(!outcome.reported);

        // Cleanup proof: no agent left registered after terminate.
        let remaining = manager.lock().await.list(Some("one-shot-test")).await;
        assert!(
            remaining.is_empty(),
            "terminate must remove the watcher agent, found: {remaining:?}"
        );
    }
}
