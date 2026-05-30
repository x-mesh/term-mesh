//! Autonomous drift-watch scheduler (watcher Phase 2 — P1 core, P4 reconcile).
//!
//! A daemon-side periodic scheduler that decides *when* to run a stateless
//! drift check for each enabled team, then drives the canonical
//! [`WatchCheckRunner`] seam (P2's headless one-shot runner in production, a
//! fake in tests) and forwards each [`WatchCheckOutcome`] to a result sink
//! (`mpsc` — consumed by P5's `WatchController`; a plain receiver in tests).
//!
//! Type ownership (P4 unification): the rich check types — [`WatchCheckInput`],
//! [`WatchCheckOutcome`], [`WatchCheckKind`], and the [`WatchCheckRunner`] trait
//! — are defined once in [`crate::headless::one_shot`] and reused here. This
//! module owns only the registry, the trigger cadence, and the
//! `WatchState → WatchCheckInput` build (check kind + check id).
//!
//! Naming: the file is `watch.rs` but the module is `drift_watch` so it does not
//! collide with the `tokio::sync::watch` import or the unrelated
//! `crate::watcher` filesystem monitor (`Context.watcher_handle`).
//!
//! Runtime wiring (main spawn + socket RPC handlers) is in `main.rs`/`socket.rs`
//! (P4). Bounded-delta fetching and config persistence are P5/P6.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, watch, Mutex};
use tokio::time::{Instant as TokioInstant, MissedTickBehavior};

use crate::headless::one_shot::{
    WatchCheckInput, WatchCheckKind, WatchCheckOutcome, WatchCheckRunner,
};

/// How often the scheduler wakes to evaluate which teams are due. Kept small
/// (P11 #3) so a configured `--every N` interval is honored to within ~1s rather
/// than being floored to a coarse sweep. A sweep is a cheap registry lock + scan.
pub const SWEEP_GRANULARITY_SECS: u64 = 1;

/// Default executions-per-direction ratio: every `ratio + 1`-th check is a
/// (rarer) direction-drift check; the rest are execution-drift checks.
pub const DEFAULT_EXEC_TO_DIR_RATIO: u32 = 5;

/// Default per-team check interval when none is supplied (5 minutes).
pub const DEFAULT_WATCH_INTERVAL_SECS: u64 = 300;

/// Default upper bound on how long to wait for a one-shot watcher's verdict.
pub const DEFAULT_REPLY_TIMEOUT_SECS: u64 = 120;

/// Per-team watch configuration + live counters. Held in the [`WatchRegistry`].
///
/// `Serialize`/`Deserialize` (P6) back the `.xm/watch/config.json` persistence in
/// [`crate::socket::watch_config`]; live counters are reset on load there.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WatchState {
    pub enabled: bool,
    pub interval_secs: u64,
    /// Every `exec_to_dir_ratio + 1`-th check is a direction check.
    pub exec_to_dir_ratio: u32,
    /// Watched agent name. `None` or `"all"` = fan-out over every name in `workers`.
    pub target: Option<String>,
    /// Worker names to monitor when target is None/"all" (P5 fan-out).
    /// Populated by `watch.on` — either from explicit `workers` param (GUI/Swift)
    /// or auto-queried from HeadlessManager (headless teams).
    #[serde(default)]
    pub workers: Vec<String>,
    pub cli: String,
    pub model: String,
    /// `critic` (default) | `advisor` | `pair`.
    pub stance: String,
    /// Spec text, or `@path` to read live each cycle (resolution is P2/P5).
    pub spec: String,
    /// Working directory the one-shot watcher is spawned in.
    pub working_directory: String,
    /// Resolved CLI binary path (Swift-supplied / config); `None` = PATH lookup.
    pub cli_path: Option<String>,
    /// Swift app socket so the watcher's `tm-agent` reaches the app.
    pub app_socket_path: Option<String>,
    /// Per-check verdict wait budget.
    pub reply_timeout_secs: u64,
    /// Unix seconds of the last *triggered* check (0 = never). Reporting only.
    pub last_check_ts: u64,
    /// Total checks triggered for this team — drives execution/direction choice.
    pub check_count: u64,
    /// A check is currently running; new ticks coalesce (NFR1: 1 check/team).
    pub in_flight: bool,
    pub last_error: Option<String>,
    /// R3: set when the workers list contained duplicate names (deduped on watch.on/update).
    /// GUI shows a warning so users understand only one pane per name is addressed.
    #[serde(default)]
    pub duplicate_name_warning: Option<String>,
}

impl WatchState {
    /// Build an enabled state with sensible defaults for the unset fields.
    #[allow(clippy::too_many_arguments)]
    pub fn enabled(
        interval_secs: u64,
        target: Option<String>,
        cli: impl Into<String>,
        model: impl Into<String>,
        stance: impl Into<String>,
        spec: impl Into<String>,
        working_directory: impl Into<String>,
    ) -> Self {
        Self {
            enabled: true,
            interval_secs: if interval_secs == 0 {
                DEFAULT_WATCH_INTERVAL_SECS
            } else {
                interval_secs
            },
            exec_to_dir_ratio: DEFAULT_EXEC_TO_DIR_RATIO,
            target,
            workers: vec![],
            cli: cli.into(),
            model: model.into(),
            stance: stance.into(),
            spec: spec.into(),
            working_directory: working_directory.into(),
            cli_path: None,
            app_socket_path: None,
            reply_timeout_secs: DEFAULT_REPLY_TIMEOUT_SECS,
            last_check_ts: 0,
            check_count: 0,
            in_flight: false,
            last_error: None,
            duplicate_name_warning: None,
        }
    }
}

/// Registry of per-team watch state. Shared between the scheduler, RPC handlers
/// (`socket.rs`), and the result controller (P5).
pub type WatchRegistry = Arc<Mutex<HashMap<String, WatchState>>>;

/// Create an empty registry.
pub fn new_registry() -> WatchRegistry {
    Arc::new(Mutex::new(HashMap::new()))
}

/// Deterministic execution/direction selector. `check_count` is 1-based. Never
/// random — reproducible cadence (every `ratio + 1`-th check is direction).
pub fn drift_kind_for(check_count: u64, exec_to_dir_ratio: u32) -> WatchCheckKind {
    let period = exec_to_dir_ratio as u64 + 1; // ratio execs then 1 direction
    if period > 0 && check_count % period == 0 {
        WatchCheckKind::Direction
    } else {
        WatchCheckKind::Execution
    }
}

/// Deterministic, idempotency-friendly check id from the check's identity.
pub fn make_check_id(
    ts: u64,
    team: &str,
    target: Option<&str>,
    spec_clause: &str,
    check_count: u64,
) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(ts.to_le_bytes());
    hasher.update(b"|");
    hasher.update(team.as_bytes());
    hasher.update(b"|");
    hasher.update(target.unwrap_or("").as_bytes());
    hasher.update(b"|");
    hasher.update(spec_clause.as_bytes());
    hasher.update(b"|");
    hasher.update(check_count.to_le_bytes());
    hex::encode(&hasher.finalize()[..8]) // 16 hex chars
}

fn now_unix() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Resolve a watch spec (P11 #2). Three forms are supported:
///
/// - **Literal**: returned verbatim.
/// - **`@path`**: read from disk each tick, relative to `working_dir`. Edits
///   to the file take effect on the next check.
/// - **`preset:<name>`**: shorthand for `@.xm/watch/specs/<name>.md`. The same
///   security rules apply (no `..`, no absolute path, 64 KiB cap).
///
/// A missing/empty/unreadable file is an `Err` (the caller skips the tick with
/// `last_error`, no board/inbox side effect).
///
/// Security (F2): absolute paths, `..`, and symlink escapes are rejected.
/// File size is capped at 64 KiB.
pub(crate) fn resolve_spec(spec: &str, working_dir: &str) -> Result<String, String> {
    // `preset:<name>` → `.xm/watch/specs/<name>.md` under working_dir.
    let spec = if let Some(name) = spec.strip_prefix("preset:") {
        let name = name.trim();
        if name.is_empty() {
            return Err("preset name is empty".to_string());
        }
        // Reject names that could escape the specs directory.
        if name.contains('/') || name.contains('\\') || name.contains("..") {
            return Err(format!("invalid preset name (no path separators allowed): {name}"));
        }
        let preset_path = format!(".xm/watch/specs/{name}.md");
        return resolve_spec(&format!("@{preset_path}"), working_dir);
    } else {
        spec
    };

    let Some(path) = spec.strip_prefix('@') else {
        return Ok(spec.to_string());
    };
    let path = path.trim();
    if path.is_empty() {
        return Err("empty @path".to_string());
    }

    let candidate = std::path::Path::new(path);

    // Reject absolute paths.
    if candidate.is_absolute() {
        return Err(format!("absolute paths not allowed: {path}"));
    }

    // Reject paths containing ".." components (parent dir traversal).
    if candidate.components().any(|c| c == std::path::Component::ParentDir) {
        return Err(format!("parent dir (..) not allowed in spec path: {path}"));
    }

    // Canonicalize working_dir to resolve symlinks.
    let working_canonical = std::fs::canonicalize(working_dir)
        .map_err(|e| format!("working_dir canonicalize: {e}"))?;

    // Join and canonicalize the full path.
    let full_path = working_canonical.join(path);
    let full_canonical = std::fs::canonicalize(&full_path)
        .map_err(|e| format!("canonicalize {}: {e}", full_path.display()))?;

    // Enforce that the resolved path is under working_dir (symlink escape check).
    if !full_canonical.starts_with(&working_canonical) {
        return Err(format!(
            "spec path {} escapes working_dir {}",
            full_canonical.display(),
            working_canonical.display()
        ));
    }

    let metadata = std::fs::metadata(&full_canonical)
        .map_err(|e| format!("stat {}: {e}", full_canonical.display()))?;

    // Enforce file size cap (64 KiB).
    const MAX_SPEC_SIZE: u64 = 64 * 1024;
    if metadata.len() > MAX_SPEC_SIZE {
        return Err(format!(
            "spec file {} too large: {} bytes (max {})",
            full_canonical.display(),
            metadata.len(),
            MAX_SPEC_SIZE
        ));
    }

    let content = std::fs::read_to_string(&full_canonical)
        .map_err(|e| format!("read {}: {e}", full_canonical.display()))?;
    if content.trim().is_empty() {
        return Err(format!("spec file {} is empty", full_canonical.display()));
    }
    Ok(content)
}

/// Evaluate every team once and trigger checks for those that are due.
///
/// Due-ness is tracked off `last_fired` (tokio `Instant`, so paused-clock tests
/// are deterministic). A team first observed here records a baseline and is NOT
/// fired immediately — its first real check happens one `interval_secs` later
/// (R3: "first check after every"). In-flight teams are skipped (overrun
/// coalesce / NFR1). Each triggered check runs on its own task; on completion it
/// clears `in_flight`, records any error, and forwards the outcome to the sink.
async fn sweep_once(
    registry: &WatchRegistry,
    runner: &Arc<dyn WatchCheckRunner>,
    sink: &mpsc::UnboundedSender<WatchCheckOutcome>,
    last_fired: &mut HashMap<String, TokioInstant>,
) {
    let now = TokioInstant::now();
    let mut to_fire: Vec<WatchCheckInput> = Vec::new();

    {
        let mut reg = registry.lock().await;
        for (team_id, st) in reg.iter_mut() {
            if !st.enabled || st.in_flight {
                continue;
            }
            match last_fired.get(team_id) {
                // First observation: baseline only, do not fire (R3).
                None => {
                    last_fired.insert(team_id.clone(), now);
                    continue;
                }
                Some(prev) => {
                    if now.duration_since(*prev) < Duration::from_secs(st.interval_secs) {
                        continue; // not due yet
                    }
                }
            }

            // Due. Record the evaluation now (throttle retries to the interval
            // cadence) regardless of whether the check actually fires below.
            last_fired.insert(team_id.clone(), now);

            // #1-b: Resolve target(s). A specific name → single check. None / "" / "all"
            // → fan-out over every name in `st.workers` (P5). Without workers,
            // skip and record the reason.
            let is_all = st
                .target
                .as_deref()
                .map(|t| t.is_empty() || t == "all")
                .unwrap_or(true);
            let targets: Vec<String> = if is_all {
                if st.workers.is_empty() {
                    st.last_error = Some(
                        "watch target required: no workers configured \
                         (set --target <name> or pass workers via watch.on)"
                            .to_string(),
                    );
                    continue;
                }
                st.workers.clone()
            } else {
                vec![st.target.clone().unwrap()]
            };

            // #2: resolve an `@path` spec from the worktree each tick so spec-file
            // edits take effect on the next check. A read failure skips this tick
            // with no board/inbox side effect (just last_error).
            let spec = match resolve_spec(&st.spec, &st.working_directory) {
                Ok(s) => s,
                Err(e) => {
                    st.last_error = Some(format!("spec resolve failed: {e}"));
                    continue;
                }
            };

            // Valid → trigger. Update counters once per tick (not per worker) so
            // the exec/direction cadence counts ticks, not individual agent checks.
            st.check_count += 1;
            st.in_flight = true;
            st.last_check_ts = now_unix();
            st.last_error = None;
            let check_kind = drift_kind_for(st.check_count, st.exec_to_dir_ratio);
            let ts = st.last_check_ts;
            let count = st.check_count;

            // Fan-out: one WatchCheckInput per target, each with a worker-specific
            // check_id so board.jsonl can attribute verdicts per worker.
            for target in targets {
                let check_id = make_check_id(ts, team_id, Some(target.as_str()), &spec, count);
                to_fire.push(WatchCheckInput {
                    team_name: team_id.clone(),
                    target,
                    check_id,
                    check_kind,
                    stance: st.stance.clone(),
                    spec: spec.clone(),
                    // The spawned watcher self-collects the bounded target delta over
                    // its own app socket (P10), so the scheduler leaves delta empty.
                    delta: String::new(),
                    cli: st.cli.clone(),
                    model: st.model.clone(),
                    working_directory: st.working_directory.clone(),
                    cli_path: st.cli_path.clone(),
                    app_socket_path: st.app_socket_path.clone(),
                    reply_timeout: Duration::from_secs(st.reply_timeout_secs),
                });
            }
        }
    }

    // P2-A fix: group by team so in_flight is cleared exactly once per team
    // after ALL its workers finish — not by the first worker that completes.
    // One tokio::spawn per team runs workers sequentially within that team.
    let mut by_team: HashMap<String, Vec<WatchCheckInput>> = HashMap::new();
    for input in to_fire {
        by_team.entry(input.team_name.clone()).or_default().push(input);
    }
    for (team_id, inputs) in by_team {
        let runner = Arc::clone(runner);
        let sink = sink.clone();
        let registry = Arc::clone(registry);
        tokio::spawn(async move {
            let mut last_error: Option<String> = None;
            for input in inputs {
                let outcome = runner.run_check(input).await;
                last_error = outcome.error.clone();
                let _ = sink.send(outcome);
            }
            // Clear in_flight once after ALL workers for this team complete.
            if let Some(st) = registry.lock().await.get_mut(&team_id) {
                st.in_flight = false;
                st.last_error = last_error;
            }
        });
    }
}

/// R4: Immediately fire one check for `team_id`, bypassing the cadence timer.
///
/// Returns `Ok(n)` where `n` is the number of checks triggered (1 for a
/// single-target team, N for an all-workers fan-out), or an error string that
/// the socket handler forwards as an RPC error.
///
/// Guards: `enabled=false` and `in_flight=true` are both rejected so the
/// manual trigger never duplicates a running check or starts a check for a
/// disabled watch.
pub async fn trigger_now(
    team_id: &str,
    registry: &WatchRegistry,
    runner: &Arc<dyn WatchCheckRunner>,
    sink: &mpsc::UnboundedSender<WatchCheckOutcome>,
) -> Result<usize, String> {
    let to_fire: Vec<WatchCheckInput>;
    {
        let mut reg = registry.lock().await;
        let st = reg
            .get_mut(team_id)
            .ok_or_else(|| format!("no watch config for team '{team_id}'"))?;

        if !st.enabled {
            return Err("watch is not enabled for this team".to_string());
        }
        if st.in_flight {
            return Err("a check is already in progress for this team".to_string());
        }

        let is_all = st
            .target
            .as_deref()
            .map(|t| t.is_empty() || t == "all")
            .unwrap_or(true);
        let targets: Vec<String> = if is_all {
            if st.workers.is_empty() {
                return Err(
                    "no workers configured (set --target <name> or pass workers via watch.on)"
                        .to_string(),
                );
            }
            st.workers.clone()
        } else {
            vec![st.target.clone().unwrap()]
        };

        let spec = resolve_spec(&st.spec, &st.working_directory)
            .map_err(|e| format!("spec resolve failed: {e}"))?;

        st.check_count += 1;
        st.in_flight = true;
        st.last_check_ts = now_unix();
        st.last_error = None;

        let check_kind = drift_kind_for(st.check_count, st.exec_to_dir_ratio);
        let ts = st.last_check_ts;
        let count = st.check_count;

        to_fire = targets
            .into_iter()
            .map(|target| {
                let check_id = make_check_id(ts, team_id, Some(target.as_str()), &spec, count);
                WatchCheckInput {
                    team_name: team_id.to_string(),
                    target,
                    check_id,
                    check_kind,
                    stance: st.stance.clone(),
                    spec: spec.clone(),
                    delta: String::new(),
                    cli: st.cli.clone(),
                    model: st.model.clone(),
                    working_directory: st.working_directory.clone(),
                    cli_path: st.cli_path.clone(),
                    app_socket_path: st.app_socket_path.clone(),
                    reply_timeout: Duration::from_secs(st.reply_timeout_secs),
                }
            })
            .collect();
    } // registry lock released

    let n = to_fire.len();
    let team_id = team_id.to_string();
    let runner = Arc::clone(runner);
    let sink = sink.clone();
    let registry = Arc::clone(registry);
    tokio::spawn(async move {
        let mut last_error: Option<String> = None;
        for input in to_fire {
            let outcome = runner.run_check(input).await;
            last_error = outcome.error.clone();
            let _ = sink.send(outcome);
        }
        if let Some(st) = registry.lock().await.get_mut(&team_id) {
            st.in_flight = false;
            st.last_error = last_error;
        }
    });
    Ok(n)
}

/// Run the autonomous watch scheduler until `shutdown_rx` flips to `true`.
///
/// Wakes every `sweep_granularity` (the immediate first interval tick is
/// consumed — R3) and calls [`sweep_once`]. Intended to be `tokio::spawn`-ed by
/// `main.rs` (P4).
pub async fn run_watch_scheduler(
    registry: WatchRegistry,
    runner: Arc<dyn WatchCheckRunner>,
    sink: mpsc::UnboundedSender<WatchCheckOutcome>,
    mut shutdown_rx: watch::Receiver<bool>,
    sweep_granularity: Duration,
) {
    let mut last_fired: HashMap<String, TokioInstant> = HashMap::new();
    let mut interval = tokio::time::interval(sweep_granularity);
    interval.set_missed_tick_behavior(MissedTickBehavior::Skip);
    interval.tick().await; // consume the immediate first tick (R3)

    loop {
        tokio::select! {
            _ = interval.tick() => {
                sweep_once(&registry, &runner, &sink, &mut last_fired).await;
            }
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::headless::one_shot::{WatchCheckFuture, WatchExitStatus};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::time::{advance, timeout};

    /// Fake runner over the *unified* [`WatchCheckRunner`] trait: counts
    /// invocations and either completes immediately or stays pending forever (to
    /// exercise the in-flight overrun guard).
    struct FakeRunner {
        calls: Arc<AtomicUsize>,
        pending: bool,
    }

    impl WatchCheckRunner for FakeRunner {
        fn run_check<'a>(&'a self, input: WatchCheckInput) -> WatchCheckFuture<'a> {
            let calls = Arc::clone(&self.calls);
            let pending = self.pending;
            Box::pin(async move {
                calls.fetch_add(1, Ordering::SeqCst);
                if pending {
                    std::future::pending::<()>().await; // never resolves
                }
                WatchCheckOutcome {
                    team_id: input.team_name,
                    check_id: input.check_id,
                    drift_kind: input.check_kind,
                    target: input.target,
                    spawned: true,
                    reported: true,
                    terminated: true,
                    exit_status: WatchExitStatus::Replied,
                    panel_id: None,
                    verdict_text: "OK".into(),
                    error: None,
                }
            })
        }
    }

    fn fake(pending: bool) -> (Arc<dyn WatchCheckRunner>, Arc<AtomicUsize>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let runner: Arc<dyn WatchCheckRunner> = Arc::new(FakeRunner {
            calls: Arc::clone(&calls),
            pending,
        });
        (runner, calls)
    }

    fn registry_with(team: &str, st: WatchState) -> WatchRegistry {
        let reg = new_registry();
        reg.try_lock().unwrap().insert(team.to_string(), st);
        reg
    }

    /// Let spawned check tasks make progress after a manual clock advance.
    async fn settle() {
        for _ in 0..16 {
            tokio::task::yield_now().await;
        }
    }

    #[tokio::test(start_paused = true)]
    async fn watch_interval_ticks_without_sleeping() {
        let granularity = Duration::from_secs(1);
        let st = WatchState::enabled(1, Some("executor".into()), "claude", "sonnet", "critic", "spec", "/tmp");
        let registry = registry_with("t1", st);
        let (runner, calls) = fake(false);
        let (tx, mut rx) = mpsc::unbounded_channel();
        let (_sd_tx, sd_rx) = watch::channel(false);

        tokio::spawn(run_watch_scheduler(
            Arc::clone(&registry),
            runner,
            tx,
            sd_rx,
            granularity,
        ));

        // Auto-advance fires the interval; we must receive an outcome without any
        // real sleep. Wrap in a timeout so a regression can't hang.
        let outcome = timeout(Duration::from_secs(3600), rx.recv())
            .await
            .expect("scheduler hung — no tick fired")
            .expect("sink closed");
        assert_eq!(outcome.team_id, "t1");
        assert!(calls.load(Ordering::SeqCst) >= 1);
    }

    #[tokio::test(start_paused = true)]
    async fn watch_scheduler_skips_immediate_tick() {
        let interval = Duration::from_secs(5);
        let st = WatchState::enabled(5, Some("executor".into()), "claude", "sonnet", "critic", "spec", "/tmp");
        let registry = registry_with("t1", st);
        let (runner, _calls) = fake(false);
        let (tx, mut rx) = mpsc::unbounded_channel();
        let (_sd_tx, sd_rx) = watch::channel(false);

        let start = TokioInstant::now();
        tokio::spawn(run_watch_scheduler(
            Arc::clone(&registry),
            runner,
            tx,
            sd_rx,
            interval,
        ));

        let outcome = timeout(Duration::from_secs(3600), rx.recv())
            .await
            .expect("scheduler hung")
            .expect("sink closed");
        assert_eq!(outcome.team_id, "t1");
        // The immediate tick was consumed: the first real check lands no sooner
        // than one interval after start.
        assert!(
            start.elapsed() >= interval,
            "first check fired too early: {:?}",
            start.elapsed()
        );
    }

    #[tokio::test(start_paused = true)]
    async fn watch_off_stops_ticks() {
        let granularity = Duration::from_secs(1);
        let mut st = WatchState::enabled(1, Some("executor".into()), "claude", "sonnet", "critic", "spec", "/tmp");
        st.enabled = false; // disabled from the start
        let registry = registry_with("t1", st);
        let (runner, calls) = fake(false);
        let (tx, mut rx) = mpsc::unbounded_channel();
        let (_sd_tx, sd_rx) = watch::channel(false);

        tokio::spawn(run_watch_scheduler(
            Arc::clone(&registry),
            runner,
            tx,
            sd_rx,
            granularity,
        ));

        for _ in 0..20 {
            advance(granularity).await;
            settle().await;
        }
        assert!(rx.try_recv().is_err(), "disabled team must not produce checks");
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn watch_exec_direction_ratio() {
        // ratio = 5 → every 6th check is a direction check.
        let ratio = DEFAULT_EXEC_TO_DIR_RATIO; // 5
        let mut exec = 0;
        let mut dir = 0;
        for n in 1..=12u64 {
            match drift_kind_for(n, ratio) {
                WatchCheckKind::Execution => exec += 1,
                WatchCheckKind::Direction => dir += 1,
            }
        }
        // 12 checks: #6 and #12 are direction, the other 10 execution.
        assert_eq!(exec, 10, "execution count");
        assert_eq!(dir, 2, "direction count");
        assert_eq!(drift_kind_for(6, ratio), WatchCheckKind::Direction);
        assert_eq!(drift_kind_for(5, ratio), WatchCheckKind::Execution);
        assert_eq!(drift_kind_for(7, ratio), WatchCheckKind::Execution);
    }

    #[tokio::test(start_paused = true)]
    async fn watch_in_flight_overrun_skip() {
        let granularity = Duration::from_secs(1);
        let st = WatchState::enabled(1, Some("executor".into()), "claude", "sonnet", "critic", "spec", "/tmp");
        let registry = registry_with("t1", st);
        // pending runner: the first check never completes, so in_flight stays set.
        let (runner, calls) = fake(true);
        let (tx, _rx) = mpsc::unbounded_channel();
        let (_sd_tx, sd_rx) = watch::channel(false);

        tokio::spawn(run_watch_scheduler(
            Arc::clone(&registry),
            runner,
            tx,
            sd_rx,
            granularity,
        ));

        for _ in 0..25 {
            advance(granularity).await;
            settle().await;
        }
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "overrunning ticks must coalesce to one in-flight check per team"
        );
        assert!(registry.lock().await.get("t1").unwrap().in_flight);
    }

    #[test]
    fn check_id_is_deterministic_and_target_sensitive() {
        let a = make_check_id(100, "team", Some("watcher"), "spec", 1);
        let b = make_check_id(100, "team", Some("watcher"), "spec", 1);
        let c = make_check_id(100, "team", Some("executor"), "spec", 1);
        assert_eq!(a, b, "same identity → same id");
        assert_ne!(a, c, "different target → different id");
        assert_eq!(a.len(), 16);
    }

    #[test]
    fn resolve_spec_rejects_absolute_path() {
        let dir = tempfile::tempdir().unwrap();
        let result = resolve_spec("@/etc/passwd", dir.path().to_str().unwrap());
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("absolute paths not allowed"));
    }

    #[test]
    fn resolve_spec_rejects_parent_dir_escape() {
        let dir = tempfile::tempdir().unwrap();
        let workdir = dir.path().to_string_lossy();
        // Attempt to escape via .. → should be caught by component check
        let result = resolve_spec("@../../../etc/passwd", &workdir);
        assert!(result.is_err(), "escape attempt should fail");
        assert!(result.unwrap_err().contains("parent dir (..) not allowed"));
    }

    #[test]
    fn resolve_spec_accepts_valid_relative_path() {
        let dir = tempfile::tempdir().unwrap();
        let spec_file = dir.path().join("spec.txt");
        std::fs::write(&spec_file, "valid spec content").unwrap();

        let workdir = dir.path().to_string_lossy();
        let result = resolve_spec("@spec.txt", &workdir);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "valid spec content");
    }

    #[test]
    fn resolve_spec_rejects_oversized_file() {
        let dir = tempfile::tempdir().unwrap();
        let spec_file = dir.path().join("huge.txt");
        // Create a file > 64 KiB
        let huge_content = "x".repeat(65 * 1024);
        std::fs::write(&spec_file, huge_content).unwrap();

        let workdir = dir.path().to_string_lossy();
        let result = resolve_spec("@huge.txt", &workdir);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("too large"));
    }

    #[test]
    fn resolve_spec_rejects_nonexistent_file() {
        let dir = tempfile::tempdir().unwrap();
        let workdir = dir.path().to_string_lossy();
        let result = resolve_spec("@nonexistent.txt", &workdir);
        assert!(result.is_err());
    }
}
