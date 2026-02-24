mod http;
mod monitor;
mod socket;
mod tokens;
mod watcher;
mod worktree;

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use tokio::sync::watch;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("term_meshd=debug".parse()?))
        .init();

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

    // Shared session store (populated by Swift app via session.sync RPC)
    let sessions: socket::SessionStore = Arc::new(Mutex::new(Vec::new()));

    // 3. Shutdown channel
    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    // 4. HTTP server
    let http_addr: SocketAddr = std::env::var("TERM_MESH_HTTP_ADDR")
        .unwrap_or_else(|_| "0.0.0.0:9876".to_string())
        .parse()
        .unwrap_or_else(|_| SocketAddr::from(([0, 0, 0, 0], 9876)));

    let http_task = tokio::spawn(http::serve(
        http_addr,
        monitor_rx.clone(),
        monitor_handle.clone(),
        watcher_handle.clone(),
        sessions.clone(),
        usage_tracker.clone(),
        shutdown_rx.clone(),
    ));

    // 5. Unix socket server
    let socket_path = socket::default_socket_path();
    let socket_task = tokio::spawn(socket::serve(
        socket_path.clone(),
        monitor_rx,
        monitor_handle.clone(),
        watcher_handle,
        sessions,
        usage_tracker,
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

    // b. Resume all stopped processes
    let resumed = monitor_handle.resume_all_stopped();
    if resumed > 0 {
        tracing::info!("resumed {resumed} stopped process(es)");
    }

    // c. Wait for servers to finish (with timeout)
    let timeout = tokio::time::Duration::from_secs(5);
    match tokio::time::timeout(timeout, async {
        let _ = socket_task.await;
        let _ = http_task.await;
    })
    .await
    {
        Ok(_) => tracing::info!("servers shut down cleanly"),
        Err(_) => tracing::warn!("server shutdown timed out after 5s"),
    }

    // d. Final cleanup: ensure socket file is removed
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
