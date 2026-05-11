// Phase 1.0/1.1 smoke test — parser validation + optional round-trip input.
//
// Usage:
//   cargo run --release --example tmux_smoke -- [--input <text>] <host> <session> [secs]
//
// Read-only:
//   cargo run --release --example tmux_smoke -- ubuntu@100.70.102.125 feat-tmux-remote 10
//
// Round-trip:
//   cargo run --release --example tmux_smoke -- --input "echo hello" ubuntu@100.70.102.125 feat-tmux-remote 8

use std::collections::{HashMap, VecDeque};
use std::process::Stdio;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::Mutex;

use term_meshd::multiplexer::tmux::encoder;
use term_meshd::multiplexer::tmux::parser::{ControlModeParser, TmuxEvent};

// ── Arg helpers ───────────────────────────────────────────────────────────────

fn flag_value(args: &[String], flag: &str) -> Option<String> {
    args.windows(2).find(|w| w[0] == flag).map(|w| w[1].clone())
}

fn positional_args(args: &[String], skip_flags: &[&str]) -> Vec<String> {
    let mut skip_next = false;
    args.iter()
        .skip(1)
        .filter(|a| {
            if skip_next { skip_next = false; return false; }
            if skip_flags.iter().any(|f| a.as_str() == *f) { skip_next = true; return false; }
            true
        })
        .cloned()
        .collect()
}

// ── Stats ─────────────────────────────────────────────────────────────────────

#[derive(Default)]
struct Stats {
    lines_parsed: u64,
    output_events: u64,
    begin_end_events: u64,
    error_events: u64,
    pause_continue_events: u64,
    session_changed_events: u64,
    layout_change_events: u64,
    exit_events: u64,
    unknown_names: HashMap<String, u64>,
    control_bytes: u64,
    output_events_after_send: u64,
    output_bytes_after_send: u64,
}

impl Stats {
    fn record(&mut self, event: &TmuxEvent, after_send: bool) {
        match event {
            TmuxEvent::Output { bytes, .. } => {
                self.output_events += 1;
                let ctrl = bytes.iter().filter(|&&b| b < 0x20 || b == 0x1b).count() as u64;
                self.control_bytes += ctrl;
                if after_send {
                    self.output_events_after_send += 1;
                    self.output_bytes_after_send += bytes.len() as u64;
                }
            }
            TmuxEvent::BeginBlock(_) | TmuxEvent::EndBlock(_) => { self.begin_end_events += 1; }
            TmuxEvent::ErrorBlock(_) => { self.error_events += 1; }
            TmuxEvent::Pause { .. } | TmuxEvent::Continue { .. } => { self.pause_continue_events += 1; }
            TmuxEvent::SessionChanged { .. } => { self.session_changed_events += 1; }
            TmuxEvent::LayoutChange { .. } => { self.layout_change_events += 1; }
            TmuxEvent::Exit => { self.exit_events += 1; }
            TmuxEvent::Unknown(s) => {
                let name = s.split_whitespace().next().unwrap_or("?").to_string();
                *self.unknown_names.entry(name).or_insert(0) += 1;
            }
        }
    }

    fn total_events(&self) -> u64 {
        self.output_events + self.begin_end_events + self.error_events
            + self.pause_continue_events + self.session_changed_events
            + self.exit_events + self.unknown_names.values().sum::<u64>()
    }

    fn known_events(&self) -> u64 {
        self.total_events() - self.unknown_names.values().sum::<u64>()
    }

    fn print_summary(&self, elapsed: f64, send_info: Option<&SendInfo>, last_payloads: &VecDeque<String>) {
        println!();
        println!("=== smoke test result ===");
        println!("duration            : {:.1}s", elapsed);
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
        println!("control bytes       : {}", self.control_bytes);

        if let Some(si) = send_info {
            println!();
            println!("=== round-trip ===");
            if let Some(ref sent) = si.sent {
                println!("input sent          : YES at {}ms → pane={}", sent.at_ms, sent.pane);
                println!("  cmd               : {}", sent.cmd);
                println!("output after send   : {} events, {} raw bytes",
                    self.output_events_after_send, self.output_bytes_after_send);
                if !last_payloads.is_empty() {
                    println!("last payloads (tail):");
                    for (i, p) in last_payloads.iter().enumerate() {
                        println!("  [{i}] {p}");
                    }
                }
                if self.output_events_after_send > 0 {
                    println!("ROUND-TRIP: PASS — got {} output events after send", self.output_events_after_send);
                } else {
                    println!("ROUND-TRIP: NEEDS_REVIEW — 0 output events after send (pane may not echo)");
                }
            } else if let Some(ref reason) = si.skip_reason {
                println!("input sent          : SKIP — {}", reason);
                println!("ROUND-TRIP: SKIP");
            }
        }

        let total = self.total_events();
        let known = self.known_events();
        let ratio = if total > 0 { known as f64 / total as f64 } else { 0.0 };
        println!();
        if self.lines_parsed == 0 {
            println!("RESULT: FAIL — no lines received from tmux -CC");
        } else if ratio < 0.5 {
            println!("RESULT: WARN — known event ratio {:.0}% < 50%", ratio * 100.0);
        } else {
            println!("RESULT: PASS — {}/{} events recognised ({:.0}%)", known, total, ratio * 100.0);
        }
    }
}

struct SentInfo { at_ms: u64, pane: String, cmd: String }
struct SendInfo { sent: Option<SentInfo>, skip_reason: Option<String> }

// ── Main ──────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let input_text = flag_value(&args, "--input");
    let pos = positional_args(&args, &["--input"]);

    if pos.len() < 2 {
        eprintln!("Usage: tmux_smoke [--input <text>] <host> <session> [duration-secs]");
        std::process::exit(1);
    }
    let host = &pos[0];
    let session = &pos[1];
    let duration_secs: u64 = pos.get(2).and_then(|s| s.parse().ok()).unwrap_or(10);
    let send_delay = Duration::from_millis(duration_secs.saturating_sub(1) * 500);

    println!("tmux-smoke: host={} session={} duration={}s", host, session, duration_secs);
    if let Some(ref t) = input_text {
        println!("  --input {:?} (send at {}ms)", t, send_delay.as_millis());
    }

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

    let raw_stdin = child.stdin.take().context("missing stdin")?;
    let stdout = child.stdout.take().context("missing stdout")?;
    let stdin = Arc::new(Mutex::new(raw_stdin));

    // Shared state between read loop and send task.
    let last_pane: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let send_done = Arc::new(AtomicBool::new(false));
    let send_info_shared: Arc<Mutex<Option<SendInfo>>> = Arc::new(Mutex::new(None));

    // Spawn send task — fires at send_delay, writes send-keys to stdin.
    if let Some(text) = input_text.clone() {
        let stdin = Arc::clone(&stdin);
        let last_pane = Arc::clone(&last_pane);
        let send_done = Arc::clone(&send_done);
        let send_info_shared = Arc::clone(&send_info_shared);
        let start_clone = Instant::now();
        tokio::spawn(async move {
            tokio::time::sleep(send_delay).await;
            let pane = last_pane.lock().await.clone();
            let at_ms = start_clone.elapsed().as_millis() as u64;
            let si = match pane {
                None => {
                    println!("  [send @{at_ms}ms] no pane seen — skip");
                    SendInfo { sent: None, skip_reason: Some("no pane seen before send window".into()) }
                }
                Some(ref pid) => {
                    let mut bytes = text.into_bytes();
                    bytes.push(b'\r'); // CR executes the line in the remote shell
                    let cmd = encoder::send_keys_hex(pid, &bytes);
                    let mut g = stdin.lock().await;
                    let _ = g.write_all(cmd.as_bytes()).await;
                    let _ = g.write_all(b"\n").await;
                    let _ = g.flush().await;
                    drop(g);
                    send_done.store(true, Ordering::Release);
                    println!("  [send @{at_ms}ms] pane={pid} → {cmd}");
                    SendInfo { sent: Some(SentInfo { at_ms, pane: pid.clone(), cmd }), skip_reason: None }
                }
            };
            *send_info_shared.lock().await = Some(si);
        });
    }

    // Read loop: select between deadline and next SSH stdout line.
    let mut reader = BufReader::new(stdout).lines();
    let mut parser = ControlModeParser::new();
    let mut stats = Stats::default();
    let mut last_payloads: VecDeque<String> = VecDeque::new();
    let start = Instant::now();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(duration_secs);

    println!("--- raw events ---");
    loop {
        tokio::select! {
            biased;
            _ = tokio::time::sleep_until(deadline) => break,
            result = reader.next_line() => {
                match result {
                    Ok(Some(raw_line)) => {
                        let line = raw_line.trim_end_matches('\r');
                        stats.lines_parsed += 1;
                        let after = send_done.load(Ordering::Acquire);
                        for ev in parser.feed_line(line) {
                            let ms = start.elapsed().as_millis();
                            match &ev {
                                TmuxEvent::Output { pane_id, bytes } => {
                                    // Track first seen pane for send task.
                                    {
                                        let mut lp = last_pane.lock().await;
                                        if lp.is_none() { *lp = Some(pane_id.clone()); }
                                    }
                                    // Printable preview (ESC → ^[).
                                    let preview: String = bytes.iter().take(80)
                                        .flat_map(|&b| {
                                            if b == 0x1b { b"^[".to_vec() }
                                            else if b >= 0x20 && b < 0x7f { vec![b] }
                                            else { vec![b'.'] }
                                        })
                                        .map(|b| b as char)
                                        .collect();
                                    last_payloads.push_back(preview.clone());
                                    if last_payloads.len() > 5 { last_payloads.pop_front(); }
                                    println!(
                                        "[{:6}ms] Output pane={} len={}{} {:?}",
                                        ms, pane_id, bytes.len(),
                                        if after { " [*]" } else { "" },
                                        &preview[..preview.len().min(60)]
                                    );
                                }
                                other => println!("[{:6}ms] {:?}", ms, other),
                            }
                            stats.record(&ev, after);
                        }
                    }
                    _ => break,
                }
            }
        }
    }
    let elapsed = start.elapsed().as_secs_f64();

    // Detach cleanly.
    {
        let mut g = stdin.lock().await;
        let _ = g.write_all(b"detach-client\n").await;
        let _ = g.flush().await;
    }
    let _ = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;
    let _ = child.kill().await;

    let send_info = send_info_shared.lock().await;
    let send_info_ref = if input_text.is_some() { send_info.as_ref() } else { None };
    stats.print_summary(elapsed, send_info_ref, &last_payloads);
    Ok(())
}
