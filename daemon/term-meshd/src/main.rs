#![allow(
    clippy::doc_lazy_continuation,
    clippy::too_many_arguments,
    clippy::while_let_loop
)]

mod agent;
mod auto_reply;
mod auto_reply_emit;
mod codex_tokens;
mod gc;
mod headless;
mod http;
mod monitor;
mod pane_tracker;
mod paste_cleanup;
mod peer;
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
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};
use tokio::sync::watch;
use tracing_subscriber::EnvFilter;

/// Global start time for uptime reporting.
static START_TIME: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
/// GUI owner PID, when the daemon was launched as an app child. Standalone and
/// headless daemon launches intentionally leave this unset.
static OWNER_PID: std::sync::OnceLock<Option<u32>> = std::sync::OnceLock::new();

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

async fn wait_for_owner_exit(owner_pid: Option<u32>) {
    let Some(owner_pid) = owner_pid else {
        std::future::pending::<()>().await;
        return;
    };

    let mut interval = tokio::time::interval(Duration::from_millis(500));
    loop {
        interval.tick().await;
        if !process_exists(owner_pid) {
            return;
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Handle --version before any subsystem init
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("term-meshd {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }

    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("term_meshd=debug".parse()?))
        .init();

    START_TIME.get_or_init(Instant::now);
    tracing::info!("term-meshd starting");
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

    // 5a. Peer federation server (opt-in via TERMMESH_PEER_SOCKET).
    let (peer_started_tx, peer_started_rx) = tokio::sync::watch::channel(false);
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
    let owner_exit = wait_for_owner_exit(owner_pid);
    tokio::pin!(owner_exit);
    let (shutdown_reason, peer_task_finished) = {
        let peer_wait = async {
            match peer_task.as_mut() {
                Some(task) => Some(task.await),
                None => std::future::pending().await,
            }
        };
        tokio::pin!(peer_wait);
        tokio::select! {
        _ = tokio::signal::ctrl_c() => ("SIGINT (Ctrl-C)", false),
        _ = sigterm() => ("SIGTERM", false),
        _ = &mut owner_exit => ("GUI owner process exited", false),
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
    tracing::info!("received {shutdown_reason}, initiating graceful shutdown...");

    // 7. Shutdown sequence
    // a. Signal servers to stop
    let _ = shutdown_tx.send(true);

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
        headless_manager.lock().await.terminate_all().await;
        tracing::info!("headless agents terminated");

        // c. Terminate all agent sessions (cleanup worktrees + PIDs)
        // terminate_all() contains a blocking sleep (SIGTERM → wait → SIGKILL), so
        // offload it to a blocking thread to avoid starving the tokio executor.
        {
            let mgr = agent_manager.clone();
            let wh = watcher_handle.clone();
            let _ = tokio::task::spawn_blocking(move || mgr.terminate_all(&wh)).await;
        }
        tracing::info!("agent sessions terminated");

        // c. Resume all stopped processes
        let resumed = monitor_handle.resume_all_stopped();
        if resumed > 0 {
            tracing::info!("resumed {resumed} stopped process(es)");
        }
    }

    // d. Wait for servers to finish (with timeout). `socket_task` was already
    // consumed by the select above (that is how control-socket death is
    // observed), so only the remaining servers are joined here.
    let timeout = tokio::time::Duration::from_secs(5);
    match tokio::time::timeout(timeout, async {
        let _ = http_task.await;
        if !peer_task_finished {
            if let Some(t) = peer_task {
                let _ = t.await;
            }
        }
    })
    .await
    {
        Ok(_) => tracing::info!("servers shut down cleanly"),
        Err(_) => tracing::warn!("server shutdown timed out after 5s"),
    }

    // `socket::serve` removes only the pathname inode it bound. Do not add a
    // second unconditional cleanup here: another daemon may have replaced
    // the pathname while this instance was shutting down.

    tracing::info!("shutdown complete");
    Ok(())
}

/// Wait for SIGTERM signal.
async fn sigterm() {
    use tokio::signal::unix::{signal, SignalKind};
    let mut sig = signal(SignalKind::terminate()).expect("failed to register SIGTERM handler");
    sig.recv().await;
}

#[cfg(test)]
mod owner_tests {
    use super::*;

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
}
