mod http;
mod monitor;
mod socket;
mod tokens;
mod watcher;
mod worktree;

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("term_meshd=debug".parse()?))
        .init();

    tracing::info!("term-meshd starting");

    let watcher_handle = watcher::start_watcher();
    tracing::info!("file watcher started");

    let budget_config = monitor::BudgetConfig::default();
    let (monitor_rx, monitor_handle) = monitor::start_monitor(budget_config);
    tracing::info!("resource monitor started");

    let usage_tracker = tokens::UsageTracker::new().start();
    tracing::info!("usage tracker initialized (JSONL parsing)");

    // Shared session store (populated by Swift app via session.sync RPC)
    let sessions: socket::SessionStore = Arc::new(Mutex::new(Vec::new()));

    // HTTP server
    let http_addr: SocketAddr = std::env::var("TERM_MESH_HTTP_ADDR")
        .unwrap_or_else(|_| "0.0.0.0:9876".to_string())
        .parse()
        .unwrap_or_else(|_| SocketAddr::from(([0, 0, 0, 0], 9876)));

    let http_sessions = sessions.clone();
    let http_monitor_rx = monitor_rx.clone();
    let http_monitor_handle = monitor_handle.clone();
    let http_watcher_handle = watcher_handle.clone();
    let http_usage_tracker = usage_tracker.clone();
    tokio::spawn(async move {
        if let Err(e) = http::serve(
            http_addr, http_monitor_rx, http_monitor_handle,
            http_watcher_handle, http_sessions, http_usage_tracker,
        ).await {
            tracing::error!("HTTP server error: {e}");
        }
    });

    // Unix socket server (main loop)
    let socket_path = socket::default_socket_path();
    socket::serve(&socket_path, monitor_rx, monitor_handle, watcher_handle, sessions, usage_tracker).await
}
