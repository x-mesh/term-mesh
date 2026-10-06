#![allow(
    clippy::doc_lazy_continuation,
    clippy::too_many_arguments,
    clippy::while_let_loop
)]

mod agent;
mod app_socket;
mod auto_reply;
mod auto_reply_emit;
mod codex_tokens;
mod gc;
mod headless;
mod http;
mod http_mobile;
pub(crate) use http_mobile::cli_path;
mod monitor;
mod pane_tracker;
mod paste_cleanup;
mod peer;
mod remote;
mod shutdown;
mod socket;
mod supervisor;
#[allow(dead_code)]
mod sync;
mod task_diff;
mod tokens;
// watcher Phase 2 (P1): autonomous drift-watch scheduler. The file is
// `watch.rs` but the module is named `drift_watch` so it does not collide with
// the `tokio::sync::watch` import (or the existing `crate::watcher` file
// monitor). Runtime wiring (main spawn + socket RPC handlers) lands in P4 —
// until then the module is only exercised by its own unit tests.
#[path = "watch.rs"]
#[allow(dead_code)]
mod drift_watch;
// watcher Phase 2 (P5): watch result controller — consumes scheduler outcomes,
// writes .xm/watch/board.jsonl, and posts to the leader inbox.
mod watch_controller;
mod watcher;
mod worktree;

use std::net::SocketAddr;
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};
use tokio::sync::watch;
use tracing_subscriber::EnvFilter;

/// Global start time for uptime reporting.
static START_TIME: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

/// How long the whole teardown may take before the watchdog exits the
/// process. The sum of the per-step limits below stays under this.
const SHUTDOWN_BUDGET: Duration = Duration::from_secs(30);
/// How far the runtime heartbeat may fall behind before the watchdog reports
/// the runtime as stalled.
const RUNTIME_STALL_THRESHOLD: Duration = Duration::from_secs(10);
/// Per-step teardown limits.
const HEADLESS_LIMIT: Duration = Duration::from_secs(8);
const AGENT_LIMIT: Duration = Duration::from_secs(12);
const RESUME_LIMIT: Duration = Duration::from_secs(3);
const SERVER_JOIN_LIMIT: Duration = Duration::from_secs(5);
/// GUI owner PID, when the daemon was launched as an app child. Standalone and
/// headless daemon launches intentionally leave this unset.
static OWNER_PID: std::sync::OnceLock<Option<u32>> = std::sync::OnceLock::new();

#[derive(Debug)]
struct RuntimeOwnerState {
    owner_pid: Option<u32>,
    managed: bool,
    shutdown_committed: bool,
    ownerless_empty_checks: u8,
}

/// Runtime ownership for a daemon launched by the GUI.
///
/// Claim, release, dead-owner observation, and ownerless shutdown all use one
/// mutex. Once shutdown wins that mutex, a later claim cannot revive a daemon
/// whose teardown already started. Standalone daemons never become managed.
pub(crate) struct RuntimeOwner {
    state: Mutex<RuntimeOwnerState>,
    shutdown_tx: watch::Sender<bool>,
}

impl RuntimeOwner {
    fn new(initial_owner: Option<u32>, shutdown_tx: watch::Sender<bool>) -> Self {
        Self {
            state: Mutex::new(RuntimeOwnerState {
                owner_pid: initial_owner,
                managed: initial_owner.is_some(),
                shutdown_committed: false,
                ownerless_empty_checks: 0,
            }),
            shutdown_tx,
        }
    }

    pub(crate) fn owner_pid(&self) -> Option<u32> {
        self.state.lock().unwrap().owner_pid
    }

    pub(crate) fn claim(&self, pid: u32, peer_ready: bool) -> Result<(), String> {
        if parse_owner_pid(Some(&pid.to_string()), std::process::id()).is_none() {
            return Err("invalid owner pid".to_string());
        }
        if !process_exists(pid) {
            return Err(format!("owner pid {pid} is not running"));
        }
        if !peer_ready {
            return Err(
                "durable peer listener is unavailable (daemon started without a working TERMMESH_PEER_SOCKET)"
                    .to_string(),
            );
        }

        let mut state = self.state.lock().unwrap();
        if state.shutdown_committed {
            return Err("daemon shutdown is already committed".to_string());
        }
        if let Some(owner) = state.owner_pid {
            if owner != pid && process_exists(owner) {
                return Err(format!("daemon is owned by live pid {owner}"));
            }
        }
        state.owner_pid = Some(pid);
        state.managed = true;
        state.ownerless_empty_checks = 0;
        Ok(())
    }

    pub(crate) fn release(&self, pid: u32) -> Result<(), String> {
        let mut state = self.state.lock().unwrap();
        if state.owner_pid != Some(pid) {
            return Err(format!(
                "pid {pid} cannot release owner {:?}",
                state.owner_pid
            ));
        }
        state.owner_pid = None;
        state.ownerless_empty_checks = 0;
        Ok(())
    }

    fn evaluate(&self, live_surfaces: bool) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.owner_pid.is_some_and(|pid| !process_exists(pid)) {
            state.owner_pid = None;
            state.ownerless_empty_checks = 0;
        }
        Self::commit_ownerless_shutdown(&mut state, live_surfaces, &self.shutdown_tx);
        state.shutdown_committed
    }

    fn commit_ownerless_shutdown(
        state: &mut RuntimeOwnerState,
        live_surfaces: bool,
        shutdown_tx: &watch::Sender<bool>,
    ) {
        if state.owner_pid.is_some() || live_surfaces {
            state.ownerless_empty_checks = 0;
            return;
        }
        if state.managed && !state.shutdown_committed {
            state.ownerless_empty_checks = state.ownerless_empty_checks.saturating_add(1);
        }
        // Require two 500ms observations. The first empty read can race a
        // surface ensure that already authenticated but has not inserted into
        // the registry yet; a full grace interval lets that mutation land.
        if state.managed
            && state.ownerless_empty_checks >= 2
            && !state.shutdown_committed {
            state.shutdown_committed = true;
            let _ = shutdown_tx.send(true);
        }
    }
}

fn parse_owner_pid(value: Option<&str>, daemon_pid: u32) -> Option<u32> {
    value
        .and_then(|raw| raw.parse::<u32>().ok())
        .filter(|pid| *pid > 1 && *pid != daemon_pid)
}

pub(crate) fn configured_owner_pid() -> Option<u32> {
    *OWNER_PID.get_or_init(|| {
        parse_owner_pid(
            std::env::var("TERMMESH_OWNER_PID").ok().as_deref(),
            std::process::id(),
        )
    })
}

fn preserve_shared_processes_after_required_server_exit(
    control_server_started: bool,
    peer_server_configured: bool,
    peer_server_started: bool,
) -> bool {
    !control_server_started || (peer_server_configured && !peer_server_started)
}

fn process_exists(pid: u32) -> bool {
    // Signal 0 performs existence/permission checking without delivering a
    // signal. EPERM still means the process exists.
    let result = unsafe { libc::kill(pid as libc::pid_t, 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

fn evaluate_runtime_owner(owner: &RuntimeOwner) {
    if let Some(host) = peer::layout::PeerHost::active_host() {
        host.evaluate_surface_admission(|| {
            owner.evaluate(host.has_live_attachable_surfaces())
        });
    } else {
        owner.evaluate(false);
    }
}

async fn supervise_runtime_owner(owner: Arc<RuntimeOwner>) {
    let mut interval = tokio::time::interval(Duration::from_millis(500));
    loop {
        interval.tick().await;
        evaluate_runtime_owner(&owner);
    }
}

/// Running term-meshd *is* starting the daemon, so there are no subcommands
/// and no flags beyond the two clap generates. The parser exists for what it
/// refuses: `args.iter().any(...)` used to ignore everything it did not
/// recognize, so `term-meshd doctor` — or any typo — started a second daemon
/// that shares this machine's peer state files with the first.
#[derive(clap::Parser, Debug)]
#[command(
    name = "term-meshd",
    about = "term-mesh background daemon",
    disable_version_flag = false,
    version
)]
struct Cli {}

/// `EX_USAGE` from sysexits.h. Deliberately not clap's default of 2: that is
/// already `shutdown::FORCED_EXIT_CODE`, so reusing it would make "your
/// arguments were wrong" indistinguishable from "teardown blew its budget and
/// the watchdog killed us".
const EXIT_USAGE: i32 = 64;

/// What a parse failure should exit with. `--help` and `--version` reach us
/// as errors too, and those are successful runs.
fn usage_exit_code(kind: clap::error::ErrorKind) -> i32 {
    use clap::error::ErrorKind;

    match kind {
        ErrorKind::DisplayHelp
        | ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand
        | ErrorKind::DisplayVersion => 0,
        _ => EXIT_USAGE,
    }
}

/// Parse argv, or exit. Returns only when the daemon should start.
fn parse_args_or_exit() {
    use clap::error::ErrorKind;
    use clap::Parser;

    let Err(error) = Cli::try_parse() else { return };
    let code = usage_exit_code(error.kind());
    if error.kind() == ErrorKind::DisplayVersion {
        // Printed here rather than left to clap: the app's host probe matches
        // `^term-meshd \S+$` exactly to tell a Linux daemon from a Mac app
        // bundle (`PeerHostDoctor.parseHostVersionLine`), and that contract
        // must not move when clap changes its rendering.
        println!("term-meshd {}", env!("CARGO_PKG_VERSION"));
    } else if code == 0 {
        print!("{error}");
    } else {
        eprint!("{error}");
    }
    std::process::exit(code);
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Before any subsystem init: a rejected argument must not have started a
    // logger, a socket, or a second peer server.
    parse_args_or_exit();

    // The app and systemd hand stdout a file or the journal; colour escapes
    // there split `key=value` fields and defeat grep.
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("term_meshd=debug".parse()?))
        .with_ansi(std::io::IsTerminal::is_terminal(&std::io::stdout()))
        .init();

    START_TIME.get_or_init(Instant::now);
    tracing::info!("term-meshd starting");

    // Bound teardown ourselves. Every per-step limit below adds up to less
    // than this budget, and the budget is far under the unit's
    // TimeoutStopSec, so a stuck step costs seconds of relay downtime
    // instead of the full stop timeout.
    let raw_signal_observer = shutdown::install(SHUTDOWN_BUDGET, RUNTIME_STALL_THRESHOLD);
    let owner_pid = configured_owner_pid();
    if let Some(pid) = owner_pid {
        tracing::info!("GUI owner supervision enabled (pid: {pid})");
    } else {
        tracing::info!("standalone daemon mode (no GUI owner PID)");
    }

    // Peer PTY-surface replay buffer capacity (TERMMESH_PEER_REPLAY_BYTES
    // env override; further adjustable at runtime via the
    // peer.replay_capacity RPC / `tm-agent daemon replay-capacity --set`).
    peer::surface::init_replay_capacity_from_env();

    // 1. Detect orphan worktrees from previous crashed sessions
    worktree::detect_orphan_worktrees();

    // 2. Start subsystems
    let watcher_handle = watcher::start_watcher();
    tracing::info!("file watcher started");

    let budget_config = monitor::BudgetConfig::default();
    let (monitor_rx, monitor_handle) = monitor::start_monitor(budget_config);
    tracing::info!("resource monitor started");

    let usage_tracker = tokens::UsageTracker::new().start();
    tracing::info!("usage tracker initialized (JSONL parsing)");

    // Owned here rather than inside `socket::serve` because the mobile
    // listener needs the same correlation: which panel is running which CLI.
    // One poller, two readers — a second tracker would walk the process table
    // again every three seconds to learn the same thing.
    let pane_tracker = pane_tracker::PaneTracker::new().start();

    // Agent session manager (F-06)
    let agent_db_path = agent::default_db_path();
    let agent_manager = Arc::new(
        agent::AgentSessionManager::new(agent_db_path)
            .expect("failed to initialize agent session DB"),
    );
    tracing::info!("agent session manager initialized");

    // Wave 1 D5: startup sweep — force-block any `assigned` tasks older than
    // the conservative 360s bound (the codex/kiro/gemini watcher window).
    // Using the wider bound at boot avoids false-blocking non-claude agents
    // whose tasks legitimately sit in `assigned` between 181s and 359s after
    // a daemon restart; any claude-owned zombie inside that window is picked
    // up by the periodic watcher on its next 30s tick.
    {
        const STARTUP_ASSIGNED_THRESHOLD_MS: u64 = 360_000;
        let blocked =
            agent_manager.sweep_assigned_timeouts(STARTUP_ASSIGNED_THRESHOLD_MS, "startup_sweep");
        if !blocked.is_empty() {
            tracing::info!(
                "startup sweep: force-blocked {} assigned-state zombie task(s): {:?}",
                blocked.len(),
                blocked
            );
        }
    }

    // Prune old DB data on startup and every 6 hours (24h TTL)
    {
        let mgr = Arc::clone(&agent_manager);
        const PRUNE_TTL_MS: u64 = 24 * 60 * 60 * 1000; // 24 hours
        mgr.prune_old_data(PRUNE_TTL_MS);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(6 * 3600));
            interval.tick().await; // skip immediate tick (already pruned above)
            loop {
                interval.tick().await;
                mgr.prune_old_data(PRUNE_TTL_MS);
            }
        });
    }

    // Paste artifacts are copied to remote hosts outside the normal sync
    // lifecycle. Reclaim only our expired files without blocking the daemon's
    // async runtime; a failed sweep is logged and retried on the next interval.
    {
        tokio::task::spawn_blocking(|| {
            match paste_cleanup::sweep_paste_artifacts(
                std::path::Path::new(paste_cleanup::PASTE_DIRECTORY),
                paste_cleanup::PASTE_TTL,
            ) {
                Ok(removed) if removed > 0 => {
                    tracing::info!("paste cleanup: removed {removed} expired artifact(s)");
                }
                Ok(_) => {}
                Err(error) => tracing::warn!("paste cleanup on startup failed: {error}"),
            }
        });

        tokio::spawn(async {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(6 * 3600));
            interval.tick().await; // startup sweep above owns the first run
            loop {
                interval.tick().await;
                let result = tokio::task::spawn_blocking(|| {
                    paste_cleanup::sweep_paste_artifacts(
                        std::path::Path::new(paste_cleanup::PASTE_DIRECTORY),
                        paste_cleanup::PASTE_TTL,
                    )
                })
                .await;

                match result {
                    Ok(Ok(removed)) if removed > 0 => {
                        tracing::info!("paste cleanup: removed {removed} expired artifact(s)");
                    }
                    Ok(Ok(_)) => {}
                    Ok(Err(error)) => tracing::warn!("periodic paste cleanup failed: {error}"),
                    Err(error) => tracing::warn!("periodic paste cleanup task failed: {error}"),
                }
            }
        });
    }

    // Disk reclamation. Deliberately narrower than what `tm-agent gc sweep`
    // can do: the unattended pass only touches derived state (expired agent
    // reports, stale git worktree registrations, oversized logs). Team boards
    // require live app state and remain explicit-only. Worktrees and agent
    // checkouts are never removed without someone asking, because only a human
    // can judge whether
    // an uncommitted tree still matters.
    {
        let mgr = Arc::clone(&agent_manager);
        let sweep = move || {
            let Some(paths) = gc::default_paths() else {
                return;
            };
            let refs = gc::GcRefs {
                active_session_worktrees: mgr.active_worktree_paths(),
                active_task_worktrees: mgr.active_task_worktree_paths(),
                repo_paths: mgr.known_repo_paths(),
                // Team liveness comes from the Swift-synced state, which the
                // socket layer owns; the periodic pass sticks to the age gate
                // plus the on-disk headless snapshot check.
                active_team_uuids: Default::default(),
            };
            match gc::periodic_safe_sweep(&paths, &refs) {
                Ok(summary) if summary.removed > 0 => tracing::info!(
                    "gc sweep: reclaimed {} item(s), {} bytes",
                    summary.removed,
                    summary.reclaimed_bytes
                ),
                Ok(_) => {}
                Err(error) => tracing::warn!("gc sweep failed: {error}"),
            }
        };

        let startup = sweep.clone();
        tokio::task::spawn_blocking(startup);

        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(6 * 3600));
            interval.tick().await; // startup sweep above owns the first run
            loop {
                interval.tick().await;
                let pass = sweep.clone();
                if let Err(error) = tokio::task::spawn_blocking(pass).await {
                    tracing::warn!("periodic gc sweep task failed: {error}");
                }
            }
        });
    }

    // Headless agent manager
    let headless_manager = Arc::new(tokio::sync::Mutex::new(headless::HeadlessManager::new()));
    tracing::info!("headless manager initialized");

    // Phase 2: startup fixup for crashed-mid-destroy / crashed-mid-resume
    // teams, then run an initial GC sweep. Both are filesystem-only and run
    // off the main socket-handler thread (we're still in main's async setup,
    // not inside any RPC handler). See contract §3.3 and §7.
    tokio::task::spawn_blocking(|| {
        headless::meta::startup_fixup();
        let demoted = headless::meta::sweep_stale_live_snapshots();
        if demoted > 0 {
            tracing::info!(
                "headless gc: demoted {demoted} stale live snapshot(s) to archived on startup"
            );
        }
        let removed = headless::meta::gc_sweep();
        if removed > 0 {
            tracing::info!("headless gc: removed {removed} archived team(s) on startup");
        }
        let zombies = headless::meta::sweep_zombie_pane_archives();
        if zombies > 0 {
            tracing::info!("headless gc: removed {zombies} zombie pane archive(s) on startup");
        }
    });

    // Phase 2: periodic GC sweep every 12 hours (contract §3.3).
    tokio::spawn(async {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(
            headless::meta::GC_INTERVAL_SECS,
        ));
        interval.tick().await; // skip immediate tick (startup already swept)
        loop {
            interval.tick().await;
            let _ = tokio::task::spawn_blocking(|| {
                headless::meta::sweep_stale_live_snapshots();
                headless::meta::gc_sweep();
                headless::meta::sweep_zombie_pane_archives();
            })
            .await;
        }
    });

    // Phase 2: idle auto-park timer (60s granularity).
    {
        let mgr = headless_manager.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
            interval.tick().await; // skip first immediate tick
            loop {
                interval.tick().await;
                let parked = mgr.lock().await.idle_park_sweep().await;
                if !parked.is_empty() {
                    tracing::debug!("idle park sweep parked {} agent(s)", parked.len());
                }
            }
        });
    }

    // Shared session store (populated by Swift app via session.sync RPC)
    let sessions: socket::SessionStore = Arc::new(RwLock::new(Vec::new()));
    let team_state: socket::TeamStateStore = Arc::new(RwLock::new(serde_json::json!({
        "teams": [],
        "tasks": [],
        "attention": [],
        "instance": {},
    })));

    // 3. Shutdown channel
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let (owner_shutdown_tx, mut owner_shutdown_rx) = watch::channel(false);
    let runtime_owner = Arc::new(RuntimeOwner::new(owner_pid, owner_shutdown_tx));
    let owner_supervisor = tokio::spawn(supervise_runtime_owner(runtime_owner.clone()));

    // 3b. watcher Phase 2: autonomous drift-watch scheduler (P4) + result
    // controller (P5). The scheduler runs one-shot watchers on a cadence and
    // streams outcomes to the WatchController, which writes .xm/watch/board.jsonl
    // and posts DRIFT findings to the team leader inbox (focus-free).
    let watch_registry = drift_watch::new_registry();
    // R4: keep runner + sink alive in outer scope so socket::serve can use them
    // for watch.trigger_now without going through the scheduler's interval loop.
    let watch_runner_for_serve: Option<std::sync::Arc<dyn headless::one_shot::WatchCheckRunner>>;
    let watch_sink_for_serve: Option<
        tokio::sync::mpsc::UnboundedSender<headless::one_shot::WatchCheckOutcome>,
    >;
    {
        // P10: populate the registry from persisted /watch config (P6's loader),
        // so `/watch on` survives a daemon restart (R13). The daemon cwd is the
        // best-effort root for the worktree's .xm/watch/config.json.
        if let Ok(cwd) = std::env::current_dir() {
            let loaded = crate::socket::watch_config::load_watch_states(&cwd);
            if !loaded.is_empty() {
                let mut reg = watch_registry.lock().await;
                for (team_id, state) in loaded {
                    reg.insert(team_id, state);
                }
                tracing::info!(
                    "watch: restored {} team(s) from persisted config",
                    reg.len()
                );
            }
        }

        let (watch_sink_tx, watch_sink_rx) =
            tokio::sync::mpsc::unbounded_channel::<headless::one_shot::WatchCheckOutcome>();

        // P5 controller: the single board/inbox writer (F2). Replaces the prior
        // log-only drain. Uses the real app-socket leader inbox (focus-free).
        tokio::spawn(watch_controller::run_watch_controller(
            watch_sink_rx,
            watch_registry.clone(),
            watch_controller::AppSocketInbox,
        ));

        let runner: std::sync::Arc<dyn headless::one_shot::WatchCheckRunner> = std::sync::Arc::new(
            headless::one_shot::HeadlessOneShotRunner::new(headless_manager.clone()),
        );
        // Stash clones before moving runner + sink into the scheduler task.
        watch_runner_for_serve = Some(std::sync::Arc::clone(&runner));
        watch_sink_for_serve = Some(watch_sink_tx.clone());
        tokio::spawn(drift_watch::run_watch_scheduler(
            watch_registry.clone(),
            runner,
            watch_sink_tx,
            shutdown_rx.clone(),
            std::time::Duration::from_secs(drift_watch::SWEEP_GRANULARITY_SECS),
        ));
        tracing::info!(
            "watch scheduler + controller started (sweep {}s)",
            drift_watch::SWEEP_GRANULARITY_SECS
        );
    }

    // 3c. Mobile remote-control exposure registry (docs/mobile-remote-control.md
    // §4.1). Shared by the control-socket `remote.*` RPCs and the mobile
    // listener. In-memory only.
    let remote_registry = remote::new_registry();

    // 4. HTTP server (can be disabled via TERM_MESH_HTTP_DISABLED=1)
    let http_disabled = std::env::var("TERM_MESH_HTTP_DISABLED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);

    let http_task = if http_disabled {
        tracing::info!("HTTP dashboard disabled via TERM_MESH_HTTP_DISABLED");
        tokio::spawn(async { Ok(()) })
    } else {
        let http_addr: SocketAddr = std::env::var("TERM_MESH_HTTP_ADDR")
            .unwrap_or_else(|_| "127.0.0.1:9876".to_string())
            .parse()
            .unwrap_or_else(|_| SocketAddr::from(([127, 0, 0, 1], 9876)));

        let http_password = std::env::var("TERM_MESH_HTTP_PASSWORD")
            .ok()
            .filter(|s| !s.is_empty());

        tokio::spawn(http::serve(
            http_addr,
            monitor_rx.clone(),
            monitor_handle.clone(),
            watcher_handle.clone(),
            sessions.clone(),
            team_state.clone(),
            usage_tracker.clone(),
            agent_manager.clone(),
            http_password,
            watch_registry.clone(),
            shutdown_rx.clone(),
        ))
    };

    // 4b. Mobile remote-control listener (docs/mobile-remote-control.md §4.4).
    // Opt-in via TERM_MESH_MOBILE_ENABLED=1; loopback only; a bad address or
    // auth mode is a visible startup error, not a fallback.
    let mobile_task: Option<tokio::task::JoinHandle<anyhow::Result<()>>> =
        if remote::listener_enabled() {
            match http_mobile::MobileConfig::from_env() {
                Ok(config) => Some(tokio::spawn(http_mobile::serve(
                    config,
                    remote_registry.clone(),
                    Some(mobile_session_resolver(
                        pane_tracker.clone(),
                        usage_tracker.clone(),
                    )),
                    Some(mobile_surface_access()),
                    shutdown_rx.clone(),
                ))),
                Err(e) => {
                    tracing::error!("mobile listener not started: {e}");
                    None
                }
            }
        } else {
            tracing::info!("mobile listener disabled (set TERM_MESH_MOBILE_ENABLED=1 to enable)");
            None
        };

    // 5a. Peer federation server (opt-in via TERMMESH_PEER_SOCKET).
    let (peer_started_tx, peer_started_rx) = tokio::sync::watch::channel(false);
    // A peer that attaches a surface can also ask for that pane's transcript;
    // the reader lives here because the session logs and the pane tracker do.
    peer::layout::set_transcript_provider(peer_transcript_provider(
        pane_tracker.clone(),
        usage_tracker.clone(),
    ));

    let mut peer_task: Option<tokio::task::JoinHandle<anyhow::Result<()>>> =
        std::env::var("TERMMESH_PEER_SOCKET")
            .ok()
            .filter(|s| !s.is_empty())
            .map(std::path::PathBuf::from)
            .map(|path| {
                tokio::spawn(peer::serve(
                    path,
                    shutdown_rx.clone(),
                    monitor_rx.clone(),
                    headless_manager.clone(),
                    agent_manager.clone(),
                    peer_started_tx.clone(),
                ))
            });
    if peer_task.is_some() {
        tracing::info!("peer-federation server enabled");
    }
    let peer_server_configured = peer_task.is_some();

    // 5. Unix socket server
    let socket_path = socket::default_socket_path();
    let (control_started_tx, control_started_rx) = tokio::sync::watch::channel(false);
    let socket_task = tokio::spawn(socket::serve(
        socket_path.clone(),
        monitor_rx,
        monitor_handle.clone(),
        watcher_handle.clone(),
        sessions,
        team_state,
        usage_tracker,
        agent_manager.clone(),
        headless_manager.clone(),
        watch_registry,
        watch_runner_for_serve,
        watch_sink_for_serve,
        remote_registry.clone(),
        pane_tracker,
        runtime_owner,
        shutdown_rx,
        control_started_tx,
    ));

    // 6. Wait for a shutdown signal — OR for either required socket to die.
    // `socket::serve` loops forever on success, so if it ever RETURNS, it
    // failed. Dropping its JoinHandle (the previous behavior) meant the
    // daemon kept running with a dead control plane, answering nothing while
    // still looking alive: the exact shape a corrupt sync DB produced. Select
    // on it too, so control-socket death is a clean, logged exit instead of a
    // silent zombie.
    let runtime_signal = async {
        if raw_signal_observer {
            std::future::pending::<()>().await;
        } else {
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {},
                _ = sigterm() => {},
            }
        }
    };
    tokio::pin!(runtime_signal);
    let (shutdown_reason, peer_task_finished) = {
        let peer_wait = async {
            match peer_task.as_mut() {
                Some(task) => Some(task.await),
                None => std::future::pending().await,
            }
        };
        tokio::pin!(peer_wait);
        tokio::select! {
        _ = shutdown::stop_requested() => ("SIGTERM/SIGINT", false),
        _ = &mut runtime_signal => ("SIGTERM/SIGINT (runtime fallback)", false),
        changed = owner_shutdown_rx.changed() => {
            let reason = if changed.is_err() {
                "runtime owner supervisor stopped"
            } else {
                "GUI owner released and no live peer surfaces remain"
            };
            (reason, false)
        },
        result = socket_task => {
            let reason = match result {
                Ok(Ok(())) => "control socket closed",
                Ok(Err(error)) => {
                    tracing::error!("control socket server failed: {error:?}");
                    "control socket server error"
                }
                Err(join_error) => {
                    tracing::error!("control socket task panicked: {join_error}");
                    "control socket task panic"
                }
            };
            (reason, false)
        }
        result = &mut peer_wait => {
            let reason = match result.expect("peer wait only resolves when configured") {
                Ok(Ok(())) => "peer socket closed",
                Ok(Err(error)) => {
                    tracing::error!("peer socket server failed: {error:?}");
                    "peer socket server error"
                }
                Err(join_error) => {
                    tracing::error!("peer socket task panicked: {join_error}");
                    "peer socket task panic"
                }
            };
            (reason, true)
        }
        }
    };
    // Before the wedge, not after: the hard-exit thread starts its budget from
    // either the raw signal or this mark, and only a signal sets the first.
    // Shutting down because the GUI owner exited or a required socket closed
    // sets no signal, so a wedge placed ahead of this had no deadline at all
    // on those paths and simply slept.
    shutdown::begin();
    // Injected before the receipt below on purpose: the 2026-08-27 hang logged
    // no SIGTERM receipt at all, so the wedge has to sit where nothing else on
    // this path has run yet. Only the hard-exit thread can end the process
    // from here, which is the property under test.
    if shutdown::stall() == Some(shutdown::Stall::Teardown) {
        shutdown::wedge_teardown(SHUTDOWN_BUDGET);
    }
    tracing::info!("received {shutdown_reason}, initiating graceful shutdown...");

    // 7. Shutdown sequence
    // a. Signal servers to stop
    let _ = shutdown_tx.send(true);
    owner_supervisor.abort();

    if preserve_shared_processes_after_required_server_exit(
        *control_started_rx.borrow(),
        peer_server_configured,
        *peer_started_rx.borrow(),
    ) {
        // Either required server can fail before this generation owns the
        // complete control+peer topology. AgentSessionManager has already
        // opened the shared DB, so running terminate_all in that state could
        // kill the real owner's agents by stale PID. Judge ownership from both
        // startup receipts, never from whichever task won tokio::select!.
        tracing::warn!(
            "required server failed during startup; preserving shared agent and headless processes"
        );
    } else {
        // b. Terminate all headless agents
        let headless = headless_manager.clone();
        // Snapshot process groups before awaiting the manager mutex. If a
        // handler holds that lock forever, timeout still drops this guard and
        // kills every registered headless group.
        let mut headless_kill_guard = headless::shutdown_kill_guard();
        let headless_finished =
            shutdown::step(shutdown::STEP_HEADLESS, HEADLESS_LIMIT, async move {
                headless.lock().await.terminate_all().await;
            })
            .await;
        if headless_finished.is_some() {
            headless_kill_guard.disarm();
        } else {
            drop(headless_kill_guard);
        }

        // c. Terminate all agent sessions (cleanup worktrees + PIDs)
        // terminate_all() contains a blocking sleep (SIGTERM → wait → SIGKILL), so
        // offload it to a blocking thread to avoid starving the tokio executor.
        let mgr = agent_manager.clone();
        let wh = watcher_handle.clone();
        shutdown::step(shutdown::STEP_AGENTS, AGENT_LIMIT, async move {
            let _ = tokio::task::spawn_blocking(move || mgr.terminate_all(&wh)).await;
        })
        .await;

        // d. Resume all stopped processes. This one is synchronous, so it
        // runs on the blocking pool: each resume reads the process table to
        // confirm identity, and it must not block a runtime worker.
        let monitor = monitor_handle.clone();
        let resumed = shutdown::step(shutdown::STEP_RESUME, RESUME_LIMIT, async move {
            tokio::task::spawn_blocking(move || monitor.resume_all_stopped())
                .await
                .unwrap_or(0)
        })
        .await
        .unwrap_or(0);
        if resumed > 0 {
            tracing::info!("resumed {resumed} stopped process(es)");
        }
    }

    // e. Wait for servers to finish (with timeout). `socket_task` was already
    // consumed by the select above (that is how control-socket death is
    // observed), so only the remaining servers are joined here.
    shutdown::step(shutdown::STEP_SERVERS, SERVER_JOIN_LIMIT, async {
        let _ = http_task.await;
        if let Some(t) = mobile_task {
            let _ = t.await;
        }
        if !peer_task_finished {
            if let Some(t) = peer_task {
                let _ = t.await;
            }
        }
    })
    .await;

    // `socket::serve` removes only the pathname inode it bound. Do not add a
    // second unconditional cleanup here: another daemon may have replaced
    // the pathname while this instance was shutting down.

    tracing::info!("shutdown complete");
    shutdown::exit_success()
}

async fn sigterm() {
    use tokio::signal::unix::{signal, SignalKind};
    let mut sig = signal(SignalKind::terminate()).expect("failed to register SIGTERM handler");
    sig.recv().await;
}

#[cfg(test)]
mod shutdown_budget_tests {
    use super::SERVER_JOIN_LIMIT;
    use crate::supervisor::CONNECTION_DRAIN_LIMIT;

    /// The drain must finish with budget left for the work that follows it.
    ///
    /// These were both 5s. A drain that ran long therefore ended at the exact
    /// moment the step bounding it did, and the peer server's surface reaping
    /// and socket removal never ran — measured on a production daemon, three
    /// surfaces left unreaped. Equal budgets are the bug; keep the gap.
    #[test]
    fn a_connection_drain_leaves_room_for_what_follows_it() {
        assert!(
            CONNECTION_DRAIN_LIMIT < SERVER_JOIN_LIMIT,
            "drain {CONNECTION_DRAIN_LIMIT:?} must be under the step's {SERVER_JOIN_LIMIT:?}"
        );
        // Not merely smaller: the reaping after it signals every surface, waits
        // 100ms, then escalates. A sliver of margin would starve that.
        assert!(
            SERVER_JOIN_LIMIT - CONNECTION_DRAIN_LIMIT >= SERVER_JOIN_LIMIT / 3,
            "the margin after the drain is too thin to reap surfaces in"
        );
    }
}

/// Answer, for one exposed pane, which CLI session the phone can follow.
///
/// The pane trackers already correlate panels to sessions for token
/// accounting: `PaneTracker` reads `TERMMESH_PANEL_ID` out of every live
/// `claude`/`codex` process, and each usage tracker zips those panes against
/// the session files by start time within a working directory. Chat needs the
/// same answer, so it asks the same question rather than inventing a second
/// way to guess.
///
/// This exists because the CLI hands its session id only to its own children.
/// `/rc on` runs as one of those children and reads it directly; the app that
/// owns the pane never sees it, so a pane exposed from the app arrived with no
/// session and the phone hid the Chat/Terminal switch.
///
/// `None` means this surface is not running a CLI we know. A CLI that is
/// running but has no session to follow yet — a fresh one writes its session
/// file only with its first reply — comes back with `session_id: None`, so
/// the phone offers Chat before the first turn. Resolved per request, so
/// starting or restarting a CLI is picked up without re-exposing the pane.
/// Serves the listener's `surface.*` calls from this daemon's own surfaces.
///
/// Only the calls a surface can answer by itself. Input is deliberately absent:
/// `surface.send_key` names a key so the app can encode it for the keyboard
/// protocol the pane negotiated, and this daemon has no such encoder — raw CSI
/// bytes reach a plain shell but not a kitty-protocol TUI. Returning `None`
/// leaves the caller to report `method_not_found` rather than type something
/// the pane would misread.
/// Reads a surface's agent transcript for a peer that asks over
/// `team.call.v1` (`PeerHost::transcript`).
///
/// The host answers from its own state: the surface names the directory, the
/// session resolver names the CLI and the session. Nothing about the path or
/// the log comes from the caller.
fn peer_transcript_provider(
    pane_tracker: pane_tracker::PaneTracker,
    usage_tracker: tokens::UsageTracker,
) -> peer::layout::TranscriptProvider {
    let resolver = mobile_session_resolver(pane_tracker, usage_tracker);
    std::sync::Arc::new(move |surface_id: &[u8], limit: usize| {
        let host =
            peer::layout::PeerHost::active_host().ok_or_else(|| "no peer host".to_string())?;
        let hex = peer::surface::hex_id(surface_id);
        let surface = host
            .pty
            .list()
            .into_iter()
            .find(|s| peer::surface::hex_id(&s.info().surface_id) == hex)
            .ok_or_else(|| format!("no surface {hex} on this host"))?;
        let session = resolver(&hex)
            .ok_or_else(|| "no claude or codex session for this surface".to_string())?;
        http_mobile::transcript_for_peer(
            &session.cli,
            session.session_id.as_deref(),
            &surface.info().cwd,
            limit,
        )
    })
}

fn mobile_surface_access() -> http_mobile::SurfaceAccess {
    std::sync::Arc::new(|method: &str, params: &serde_json::Value| {
        let host = peer::layout::PeerHost::active_host()?;
        let find = |host: &std::sync::Arc<peer::layout::PeerHost>, id: &str| {
            host.pty
                .list()
                .into_iter()
                .find(|s| peer::surface::hex_id(&s.info().surface_id) == id)
        };
        let want = |key: &str| {
            params
                .get(key)
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .to_string()
        };
        match method {
            // The roster the listener reads liveness from.
            "surface.list" => {
                let surfaces: Vec<serde_json::Value> = host
                    .pty
                    .list()
                    .into_iter()
                    .map(|surface| {
                        serde_json::json!({
                            "id": peer::surface::hex_id(&surface.info().surface_id),
                        })
                    })
                    .collect();
                Some(Ok(serde_json::json!({ "surfaces": surfaces })))
            }
            "surface.read_text" => {
                let id = want("surface_id");
                let Some(surface) = find(&host, &id) else {
                    return Some(Err(format!("no surface {id} on this host")));
                };
                match surface.screen_text() {
                    Some(text) => Some(Ok(serde_json::json!({ "text": text }))),
                    None => Some(Err("surface has no screen to read".to_string())),
                }
            }
            "surface.send_text" => {
                let id = want("surface_id");
                let Some(surface) = find(&host, &id) else {
                    return Some(Err(format!("no surface {id} on this host")));
                };
                match surface.write_all(want("text").as_bytes()) {
                    Ok(()) => Some(Ok(serde_json::json!({ "ok": true }))),
                    Err(e) => Some(Err(format!("write failed: {e}"))),
                }
            }
            "surface.send_key" => {
                let id = want("surface_id");
                let Some(surface) = find(&host, &id) else {
                    return Some(Err(format!("no surface {id} on this host")));
                };
                // DECCKM decides the arrow encoding and the program on the
                // surface owns that mode, so read it instead of guessing.
                let application_cursor = surface.application_cursor().unwrap_or(false);
                let Some(bytes) = named_key_bytes(&want("key"), application_cursor) else {
                    return Some(Err(format!("unsupported key {:?}", want("key"))));
                };
                match surface.write_all(bytes) {
                    Ok(()) => Some(Ok(serde_json::json!({ "ok": true }))),
                    Err(e) => Some(Err(format!("write failed: {e}"))),
                }
            }
            _ => None,
        }
    })
}

/// Bytes for the key names the mobile page is allowed to send
/// (`http_mobile::gui_key`). Only the legacy encodings: this daemon cannot see
/// whether the program negotiated the kitty keyboard protocol — the terminal
/// model it keeps (`vt100`) tracks DECCKM and the keypad but no kitty flags —
/// and every one of these keys keeps its legacy form in that protocol unless
/// the program asks for the report-all-keys mode.
fn named_key_bytes(key: &str, application_cursor: bool) -> Option<&'static [u8]> {
    Some(match key {
        "enter" => b"\r".as_slice(),
        "escape" => b"\x1b".as_slice(),
        "tab" => b"\t".as_slice(),
        // DEL, not BS: what a terminal sends for Backspace by default.
        "backspace" => b"\x7f".as_slice(),
        "ctrl-c" => b"\x03".as_slice(),
        "up" if application_cursor => b"\x1bOA".as_slice(),
        "down" if application_cursor => b"\x1bOB".as_slice(),
        "right" if application_cursor => b"\x1bOC".as_slice(),
        "left" if application_cursor => b"\x1bOD".as_slice(),
        "up" => b"\x1b[A".as_slice(),
        "down" => b"\x1b[B".as_slice(),
        "right" => b"\x1b[C".as_slice(),
        "left" => b"\x1b[D".as_slice(),
        _ => return None,
    })
}

fn mobile_session_resolver(
    pane_tracker: pane_tracker::PaneTracker,
    usage_tracker: tokens::UsageTracker,
) -> http_mobile::SessionResolver {
    // Built once: `new` only locates `~/.codex/sessions`, while the scan that
    // costs anything happens per call and is incremental.
    let codex = codex_tokens::CodexUsageTracker::new();
    let last_outcome: std::sync::Mutex<std::collections::HashMap<String, String>> =
        std::sync::Mutex::new(std::collections::HashMap::new());
    // Resolved on every poll, so only a change of outcome is worth a line.
    let note = move |surface_id: &str, outcome: String| {
        let mut seen = last_outcome.lock().unwrap();
        if seen.get(surface_id) != Some(&outcome) {
            tracing::info!("mobile session resolver: surface {surface_id}: {outcome}");
            seen.insert(surface_id.to_string(), outcome);
        }
    };
    std::sync::Arc::new(move |surface_id: &str| {
        let panes = pane_tracker.snapshot();
        let Some(info) = panes.get(surface_id) else {
            note(surface_id, "no claude/codex process tagged with this panel".into());
            return None;
        };
        let correlation: Vec<(String, String, i64, u32)> = panes
            .iter()
            .map(|(panel_id, pane)| {
                (
                    panel_id.clone(),
                    pane.cwd.clone(),
                    pane.proc_start_unix,
                    pane.pid,
                )
            })
            .collect();
        let session_id = match info.cli.as_str() {
            "claude" => usage_tracker
                .sessions_by_panel(&correlation)
                .remove(surface_id),
            "codex" => codex
                .as_ref()
                .and_then(|c| c.sessions_by_panel(&correlation).ok())
                .and_then(|mut m| m.remove(surface_id)),
            other => {
                note(surface_id, format!("unsupported cli {other:?}"));
                return None;
            }
        };
        match &session_id {
            Some(session_id) => note(
                surface_id,
                format!("resolved {} session {session_id}", info.cli),
            ),
            None => {
                let same_cwd = panes.values().filter(|p| p.cwd == info.cwd).count();
                let nearest_gap = (info.cli == "claude")
                    .then(|| {
                        usage_tracker
                            .sessions_in_cwd(&info.cwd)
                            .iter()
                            .map(|(_, started)| (started - info.proc_start_unix).abs())
                            .min()
                    })
                    .flatten();
                note(
                    surface_id,
                    format!(
                        "{} running, no session yet: cwd={} panes_in_cwd={} nearest_session_gap_secs={:?}",
                        info.cli, info.cwd, same_cwd, nearest_gap
                    ),
                );
            }
        }
        Some(http_mobile::PaneSession {
            cli: info.cli.clone(),
            session_id,
        })
    })
}

#[cfg(test)]
mod owner_tests {
    use super::*;

    /// The page sends key names; the pane reads bytes. DECCKM is the program's
    /// choice, so the arrows have to follow it — the wrong form moves the
    /// cursor in some TUIs and types a letter in others.
    #[test]
    fn named_keys_follow_the_cursor_mode_the_program_set() {
        assert_eq!(named_key_bytes("enter", false), Some(b"\r".as_slice()));
        assert_eq!(named_key_bytes("escape", false), Some(b"\x1b".as_slice()));
        assert_eq!(named_key_bytes("tab", false), Some(b"\t".as_slice()));
        // DEL, which is what a terminal sends for Backspace by default.
        assert_eq!(named_key_bytes("backspace", false), Some(b"\x7f".as_slice()));
        assert_eq!(named_key_bytes("ctrl-c", true), Some(b"\x03".as_slice()));
        assert_eq!(named_key_bytes("up", false), Some(b"\x1b[A".as_slice()));
        assert_eq!(named_key_bytes("up", true), Some(b"\x1bOA".as_slice()));
        assert_eq!(named_key_bytes("left", true), Some(b"\x1bOD".as_slice()));
        // Outside the page's allowlist nothing is sent at all.
        assert_eq!(named_key_bytes("f1", false), None);
    }

    #[test]
    fn owner_pid_parser_rejects_invalid_and_self_values() {
        assert_eq!(parse_owner_pid(None, 42), None);
        assert_eq!(parse_owner_pid(Some(""), 42), None);
        assert_eq!(parse_owner_pid(Some("abc"), 42), None);
        assert_eq!(parse_owner_pid(Some("0"), 42), None);
        assert_eq!(parse_owner_pid(Some("1"), 42), None);
        assert_eq!(parse_owner_pid(Some("42"), 42), None);
        assert_eq!(parse_owner_pid(Some("99"), 42), Some(99));
    }

    #[test]
    fn current_process_is_detected_as_alive() {
        assert!(process_exists(std::process::id()));
    }

    #[test]
    fn non_owner_release_is_rejected() {
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let owner = RuntimeOwner::new(Some(std::process::id()), shutdown_tx);
        assert!(owner.release(std::process::id() + 1).is_err());
        assert_eq!(owner.owner_pid(), Some(std::process::id()));
        assert!(!*shutdown_rx.borrow());
    }

    #[test]
    fn ownerless_daemon_stays_for_live_surfaces_then_stops() {
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let owner = RuntimeOwner::new(Some(std::process::id()), shutdown_tx);
        owner.release(std::process::id()).unwrap();
        assert!(!*shutdown_rx.borrow());
        owner.evaluate(true);
        assert!(!*shutdown_rx.borrow());
        owner.evaluate(false);
        assert!(!*shutdown_rx.borrow());
        owner.evaluate(false);
        assert!(*shutdown_rx.borrow());
    }

    #[test]
    fn shutdown_commit_fences_a_late_claim() {
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let owner = RuntimeOwner::new(Some(std::process::id()), shutdown_tx);
        owner.release(std::process::id()).unwrap();
        owner.evaluate(false);
        owner.evaluate(false);
        assert!(*shutdown_rx.borrow());
        assert!(owner.claim(std::process::id(), true).is_err());
        assert_eq!(owner.owner_pid(), None);
    }

    #[test]
    fn a_surface_arriving_during_ownerless_grace_cancels_shutdown() {
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let owner = RuntimeOwner::new(Some(std::process::id()), shutdown_tx);
        owner.release(std::process::id()).unwrap();
        owner.evaluate(false);
        owner.evaluate(true);
        owner.evaluate(false);
        assert!(!*shutdown_rx.borrow());
        owner.evaluate(false);
        assert!(*shutdown_rx.borrow());
    }

    #[test]
    fn surface_admission_serializes_registry_mutation_and_owner_evaluation() {
        let manager = std::sync::Arc::new(crate::peer::surface::PtyManager::new());
        let host = crate::peer::layout::PeerHost::new(manager);
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let owner = RuntimeOwner::new(Some(std::process::id()), shutdown_tx);
        owner.release(std::process::id()).unwrap();
        host.evaluate_surface_admission(|| owner.evaluate(false));
        assert!(!*shutdown_rx.borrow());
        host.evaluate_surface_admission(|| owner.evaluate(false));
        assert!(*shutdown_rx.borrow());
        assert!(host.with_open_surface_admission(|| ()).is_none());
    }

    #[test]
    fn claim_requires_a_durable_peer_listener() {
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let owner = RuntimeOwner::new(None, shutdown_tx);
        assert!(owner.claim(std::process::id(), false).is_err());
        assert_eq!(owner.owner_pid(), None);
        assert!(!*shutdown_rx.borrow());
    }

    #[test]
    fn teardown_requires_complete_required_server_ownership() {
        // Exact collision regression: the control task may win select while
        // the peer lock task has also failed before publishing its receipt.
        assert!(preserve_shared_processes_after_required_server_exit(
            false, true, false
        ));
        assert!(preserve_shared_processes_after_required_server_exit(
            true, true, false
        ));
        assert!(preserve_shared_processes_after_required_server_exit(
            false, true, true
        ));
        assert!(!preserve_shared_processes_after_required_server_exit(
            true, true, true
        ));
        assert!(!preserve_shared_processes_after_required_server_exit(
            true, false, false
        ));
    }

    /// The parser's whole job is refusing what the old `args.iter().any(...)`
    /// swallowed. An unrecognized argument must not reach daemon startup.
    #[test]
    fn unknown_arguments_are_refused_rather_than_starting_a_daemon() {
        use clap::Parser;

        for argv in [
            vec!["term-meshd", "doctor"],
            vec!["term-meshd", "reset", "--apply"],
            vec!["term-meshd", "--nope"],
            vec!["term-meshd", "-x"],
        ] {
            let error = Cli::try_parse_from(&argv).expect_err(&format!("{argv:?} must not parse"));
            assert_eq!(
                usage_exit_code(error.kind()),
                EXIT_USAGE,
                "{argv:?} should exit {EXIT_USAGE}"
            );
        }
    }

    /// systemd's ExecStart runs the binary with no arguments at all.
    #[test]
    fn no_arguments_still_means_start_the_daemon() {
        use clap::Parser;

        assert!(Cli::try_parse_from(["term-meshd"]).is_ok());
    }

    /// clap reports these as errors; they are successful runs.
    #[test]
    fn help_and_version_exit_zero() {
        use clap::error::ErrorKind;
        use clap::Parser;

        for (argv, expected) in [
            (vec!["term-meshd", "--help"], ErrorKind::DisplayHelp),
            (vec!["term-meshd", "-h"], ErrorKind::DisplayHelp),
            (vec!["term-meshd", "--version"], ErrorKind::DisplayVersion),
            (vec!["term-meshd", "-V"], ErrorKind::DisplayVersion),
        ] {
            let error = Cli::try_parse_from(&argv).expect_err(&format!("{argv:?}"));
            assert_eq!(error.kind(), expected, "{argv:?}");
            assert_eq!(usage_exit_code(error.kind()), 0, "{argv:?}");
        }
    }

    /// A usage error and a teardown that blew its budget must stay
    /// distinguishable — which is why this is 64 and not clap's default of 2.
    #[test]
    fn usage_exit_code_does_not_collide_with_the_shutdown_watchdog() {
        assert_ne!(EXIT_USAGE, shutdown::FORCED_EXIT_CODE);
        assert_ne!(EXIT_USAGE, 0);
    }

    #[test]
    fn cli_definition_is_well_formed() {
        use clap::CommandFactory;

        Cli::command().debug_assert();
    }
}
