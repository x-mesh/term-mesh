// Phase 1.0 smoke test for TmuxControlBackend parser.
//
// Connects to a live SSH host running tmux in control mode (tmux -CC) and
// feeds each stdout line through ControlModeParser::feed_line, printing
// decoded events and a summary at the end.
//
// Usage:
//   cargo run --release --example tmux_smoke -- <ssh-host> <tmux-session> [duration-secs]
//
// Example:
//   cargo run --release --example tmux_smoke -- ubuntu@100.70.102.125 feat-tmux-remote 10

use std::collections::HashMap;
use std::process::Stdio;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::time::timeout;

use term_meshd::multiplexer::tmux::parser::{ControlModeParser, TmuxEvent};

// ── Stats ─────────────────────────────────────────────────────────────────────

#[derive(Default)]
struct Stats {
    lines_parsed: u64,
    output_events: u64,
    begin_end_events: u64,
    error_events: u64,
    pause_continue_events: u64,
    session_changed_events: u64,
    exit_events: u64,
    unknown_names: HashMap<String, u64>,
    control_bytes: u64,
}

impl Stats {
    fn record(&mut self, event: &TmuxEvent) {
        match event {
            TmuxEvent::Output { bytes, .. } => {
                self.output_events += 1;
                self.control_bytes +=
                    bytes.iter().filter(|&&b| b < 0x20 || b == 0x1b).count() as u64;
            }
            TmuxEvent::BeginBlock(_) | TmuxEvent::EndBlock(_) => {
                self.begin_end_events += 1;
            }
            TmuxEvent::ErrorBlock(_) => { self.error_events += 1; }
            TmuxEvent::Pause { .. } | TmuxEvent::Continue { .. } => {
                self.pause_continue_events += 1;
            }
            TmuxEvent::SessionChanged { .. } => {
                self.session_changed_events += 1;
            }
            TmuxEvent::Exit => { self.exit_events += 1; }
            TmuxEvent::Unknown(s) => {
                let name = s.split_whitespace().next().unwrap_or("?").to_string();
                *self.unknown_names.entry(name).or_insert(0) += 1;
            }
        }
    }

    fn total_events(&self) -> u64 {
        self.output_events
            + self.begin_end_events
            + self.error_events
            + self.pause_continue_events
            + self.session_changed_events
            + self.exit_events
            + self.unknown_names.values().sum::<u64>()
    }

    fn known_events(&self) -> u64 {
        self.total_events() - self.unknown_names.values().sum::<u64>()
    }

    fn print_summary(&self, duration: f64) {
        println!();
        println!("=== smoke test result ===");
        println!("duration            : {:.1}s", duration);
        println!("lines parsed        : {}", self.lines_parsed);
        println!("total events        : {}", self.total_events());
        println!("  %output           : {}", self.output_events);
        println!("  %begin/%end       : {} (pairs={})", self.begin_end_events, self.begin_end_events / 2.max(1));
        println!("  %error            : {}", self.error_events);
        println!("  %pause/%continue  : {}", self.pause_continue_events);
        println!("  %session-changed  : {}", self.session_changed_events);
        println!("  %exit             : {}", self.exit_events);
        if !self.unknown_names.is_empty() {
            let mut v: Vec<_> = self.unknown_names.iter().collect();
            v.sort_by_key(|(_, &c)| std::cmp::Reverse(c));
            let s: Vec<_> = v.iter().map(|(k, c)| format!("{}({})", k, c)).collect();
            println!("  unknown notifs    : {}", s.join(", "));
        }
        println!("control bytes via octal unescape: {}", self.control_bytes);

        let total = self.total_events();
        let known = self.known_events();
        let ratio = if total > 0 { known as f64 / total as f64 } else { 0.0 };
        println!();
        if self.lines_parsed == 0 {
            println!("RESULT: FAIL — no lines received from tmux -CC");
        } else if ratio < 0.5 {
            println!(
                "RESULT: WARN — known event ratio {:.0}% < 50%",
                ratio * 100.0
            );
        } else {
            println!(
                "RESULT: PASS — {}/{} events recognised ({:.0}%)",
                known, total, ratio * 100.0
            );
        }
    }
}

// ── Main ──────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: tmux_smoke <ssh-host> <tmux-session> [duration-secs]");
        std::process::exit(1);
    }
    let host = &args[1];
    let session = &args[2];
    let duration_secs: u64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(10);

    println!("tmux-smoke: host={} session={} duration={}s", host, session, duration_secs);
    println!("spawning: ssh -t -t {} tmux -CC attach-session -t {}", host, session);

    // -t -t: force PTY allocation even when local stdin is piped.
    // tmux -CC requires a terminal; without -tt it exits with
    // "tcgetattr failed: Inappropriate ioctl for device".
    let mut child = Command::new("ssh")
        .args([
            "-t", "-t",
            "-o", "LogLevel=QUIET",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            host.as_str(),
            "tmux", "-CC", "attach-session", "-t", session.as_str(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("failed to spawn ssh")?;

    let mut stdin = child.stdin.take().context("missing stdin")?;
    let stdout = child.stdout.take().context("missing stdout")?;

    let mut reader = BufReader::new(stdout).lines();
    let mut parser = ControlModeParser::new();
    let mut stats = Stats::default();
    let start = Instant::now();
    let ts = start;

    println!("--- raw events ---");

    let read_loop = async {
        while let Ok(Some(raw_line)) = reader.next_line().await {
            // PTY adds \r before \n; strip trailing \r.
            let line = raw_line.trim_end_matches('\r');
            stats.lines_parsed += 1;
            for ev in parser.feed_line(line) {
                let ms = ts.elapsed().as_millis();
                match &ev {
                    TmuxEvent::Output { pane_id, bytes } => {
                        let preview: String = bytes.iter().take(60)
                            .map(|&b| if b >= 0x20 && b < 0x7f { b as char } else { '.' })
                            .collect();
                        println!(
                            "[{:6}ms] Output pane={} len={} {:?}",
                            ms, pane_id, bytes.len(), preview
                        );
                    }
                    other => println!("[{:6}ms] {:?}", ms, other),
                }
                stats.record(&ev);
            }
        }
    };

    let _ = timeout(Duration::from_secs(duration_secs), read_loop).await;
    let elapsed = start.elapsed().as_secs_f64();

    // Detach cleanly, then kill.
    let _ = stdin.write_all(b"detach-client\n").await;
    let _ = stdin.flush().await;
    let _ = timeout(Duration::from_secs(2), child.wait()).await;
    let _ = child.kill().await;

    stats.print_summary(elapsed);
    Ok(())
}
