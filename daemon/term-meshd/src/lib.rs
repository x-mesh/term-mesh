#![allow(
    clippy::doc_lazy_continuation,
    clippy::too_many_arguments,
    clippy::while_let_loop
)]

use std::time::Instant;

/// Global start time for uptime reporting, initialised by `main` at startup.
pub static START_TIME: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

pub mod agent;
pub mod headless;
pub mod http;
pub mod multiplexer;
pub mod monitor;
pub mod peer;
pub mod socket;
pub mod tokens;
pub mod watcher;
pub mod worktree;
