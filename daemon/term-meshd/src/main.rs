#![allow(
    clippy::doc_lazy_continuation,
    clippy::too_many_arguments,
    clippy::while_let_loop
)]

mod agent;
mod codex_tokens;
mod headless;
mod http;
mod monitor;
mod pane_tracker;
mod peer;
mod socket;
mod tokens;
mod watcher;
mod worktree;

use std::net::SocketAddr;
use std::sync::{Arc, RwLock};
use std::time::Instant;
use tokio::sync::watch;
use tracing_subscriber::EnvFilter;

/// Global start time for uptime reporting.
static START_TIME: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

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

    // Headless agent manager
    let headless_manager = Arc::new(tokio::sync::Mutex::new(headless::HeadlessManager::new()));
    tracing::info!("headless manager initialized");

    // Phase 2: startup fixup for crashed-mid-destroy / crashed-mid-resume
    // teams, then run an initial GC sweep. Both are filesystem-only and run
    // off the main socket-handler thread (we're still in main's async setup,
    // not inside any RPC handler). See contract §3.3 and §7.
    tokio::task::spawn_blocking(|| {
        headless::meta::startup_fixup();
        let removed = headless::meta::gc_sweep();
        if removed > 0 {
            tracing::info!("headless gc: removed {removed} archived team(s) on startup");
        }
        let zombies = headless::meta::sweep_zombie_pane_archives();
        if zombies > 0 {
            tracing::info!(
                "headless gc: removed {zombies} zombie pane archive(s) on startup"
            );
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
            shutdown_rx.clone(),
        ))
    };

    // 5a. Peer federation server (opt-in via TERMMESH_PEER_SOCKET).
    let peer_task: Option<tokio::task::JoinHandle<anyhow::Result<()>>> =
        std::env::var("TERMMESH_PEER_SOCKET")
            .ok()
            .filter(|s| !s.is_empty())
            .map(std::path::PathBuf::from)
            .map(|path| tokio::spawn(peer::serve(path, shutdown_rx.clone())));
    if peer_task.is_some() {
        tracing::info!("peer-federation server enabled");
    }

    // 5. Unix socket server
    let socket_path = socket::default_socket_path();
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
        shutdown_rx,
    ));

    // 6. Wait for shutdown signal (Ctrl-C or SIGTERM)
    let shutdown_reason = tokio::select! {
        _ = tokio::signal::ctrl_c() => "SIGINT (Ctrl-C)",
        _ = sigterm() => "SIGTERM",
    };
    tracing::info!("received {shutdown_reason}, initiating graceful shutdown...");

    // 7. Shutdown sequence
    // a. Signal servers to stop
    let _ = shutdown_tx.send(true);

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

    // d. Wait for servers to finish (with timeout)
    let timeout = tokio::time::Duration::from_secs(5);
    match tokio::time::timeout(timeout, async {
        let _ = socket_task.await;
        let _ = http_task.await;
        if let Some(t) = peer_task {
            let _ = t.await;
        }
    })
    .await
    {
        Ok(_) => tracing::info!("servers shut down cleanly"),
        Err(_) => tracing::warn!("server shutdown timed out after 5s"),
    }

    // e. Final cleanup: ensure socket file is removed
    if socket_path.exists() {
        let _ = std::fs::remove_file(&socket_path);
    }

    tracing::info!("shutdown complete");
    Ok(())
}

/// Wait for SIGTERM signal.
async fn sigterm() {
    use tokio::signal::unix::{signal, SignalKind};
    let mut sig = signal(SignalKind::terminate()).expect("failed to register SIGTERM handler");
    sig.recv().await;
}
