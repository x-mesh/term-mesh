//! Auto-reply detector for TM-PROTOCOL-v1 (Phase B1).
//!
//! Watches agent terminal output for the 5-line STATUS/FILES/VERIFY/NEXT/FULL_REPORT
//! header followed by a body, and emits an event so the caller can post the
//! equivalent of an explicit `tm-agent reply` (team.report + team.task.update)
//! when the TUI agent prints the header text but forgot to invoke the shell
//! command. The prompt-strengthening (Phase A) reduces the miss rate; this
//! detector is the safety net.
//!
//! ## State machine
//!
//! ```text
//! Idle ── STATUS: ──► SawStatus ── FILES: ──► SawFiles ── VERIFY: ──► SawVerify
//!                                                                          │
//!                              ┌───────────── NEXT: ────────────────────────┘
//!                              ▼
//!                          SawNext ── FULL_REPORT: ──► Body ── commit ──► Idle
//! ```
//!
//! Any out-of-order line during the header phase resets to Idle (strict 5/5).
//!
//! ## Commit triggers
//!
//! After the header completes, body lines accumulate until one of:
//! 1. `idle_debounce` elapses with no new bytes (checked via [`AutoReplyDetector::tick`])
//! 2. `hard_cap` elapses since header started (checked via `tick`)
//! 3. A new `STATUS:` line is observed (commit current, start new capture)
//! 4. [`AutoReplyDetector::flush`] is called explicitly (e.g., on agent exit)
//!
//! Prompt-based commit is intentionally omitted — prompts vary too much across
//! CLIs (Claude TUI, Codex, raw shell) and produce false negatives. Debounce
//! alone is reliable enough at the default 500ms.
//!
//! ## Caller responsibilities (NOT handled here)
//!
//! - Idempotency dedup — use [`AutoReplyEvent::content_hash`]
//! - Skip when the agent's active task is already terminal
//! - Skip when an explicit `tm-agent reply` arrived first
//! - Route to `team.report` + `team.task.update` RPCs

use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Idle,
    SawStatus,
    SawFiles,
    SawVerify,
    SawNext,
    Body,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutoReplyEvent {
    pub status: String,
    pub files: String,
    pub verify: String,
    pub next: String,
    pub full_report: String,
    /// Body text after the 5-line header (lines joined with `\n`, no trailing newline).
    pub body: String,
    /// Verbatim captured text (header + body) for full_report file persistence.
    pub raw: String,
}

impl AutoReplyEvent {
    /// Stable hash for caller-side dedup. Two events with identical user-visible
    /// content (header values + body) collide; trailing whitespace differences
    /// in `raw` do not affect the hash.
    pub fn content_hash(&self) -> u64 {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        let mut hasher = DefaultHasher::new();
        self.status.hash(&mut hasher);
        self.files.hash(&mut hasher);
        self.verify.hash(&mut hasher);
        self.next.hash(&mut hasher);
        self.full_report.hash(&mut hasher);
        self.body.hash(&mut hasher);
        hasher.finish()
    }
}

#[derive(Debug, Clone)]
pub struct DetectorConfig {
    pub idle_debounce: Duration,
    pub hard_cap: Duration,
}

impl Default for DetectorConfig {
    fn default() -> Self {
        Self {
            idle_debounce: Duration::from_millis(500),
            hard_cap: Duration::from_secs(5),
        }
    }
}

pub struct AutoReplyDetector {
    config: DetectorConfig,
    state: State,
    /// Partial line accumulator — bytes between newlines.
    line_buf: String,
    header_status: String,
    header_files: String,
    header_verify: String,
    header_next: String,
    header_full_report: String,
    body_lines: Vec<String>,
    raw_lines: Vec<String>,
    header_started_at: Option<Instant>,
    last_body_input_at: Option<Instant>,
}

impl Default for AutoReplyDetector {
    fn default() -> Self {
        Self::new()
    }
}

impl AutoReplyDetector {
    pub fn new() -> Self {
        Self::with_config(DetectorConfig::default())
    }

    pub fn with_config(config: DetectorConfig) -> Self {
        Self {
            config,
            state: State::Idle,
            line_buf: String::new(),
            header_status: String::new(),
            header_files: String::new(),
            header_verify: String::new(),
            header_next: String::new(),
            header_full_report: String::new(),
            body_lines: Vec::new(),
            raw_lines: Vec::new(),
            header_started_at: None,
            last_body_input_at: None,
        }
    }

    /// Feed raw bytes from the agent's terminal output. Returns Some(event)
    /// only when a body-phase new `STATUS:` line forces an immediate commit
    /// of the previous capture. Time-based commits arrive via [`Self::tick`].
    pub fn push_bytes(&mut self, bytes: &[u8], now: Instant) -> Option<AutoReplyEvent> {
        let text = String::from_utf8_lossy(bytes);
        let mut emitted = None;
        for ch in text.chars() {
            if ch == '\n' {
                let line = std::mem::take(&mut self.line_buf);
                if let Some(ev) = self.process_line(&line, now) {
                    debug_assert!(emitted.is_none(), "only one event per push_bytes");
                    emitted = Some(ev);
                }
            } else if ch != '\r' {
                self.line_buf.push(ch);
            }
        }
        emitted
    }

    /// Time-based commit check. Call periodically (e.g., every 100ms) from
    /// the wire-up layer. Returns Some(event) when the body has been idle
    /// for `idle_debounce` or total capture exceeded `hard_cap`.
    pub fn tick(&mut self, now: Instant) -> Option<AutoReplyEvent> {
        if self.state != State::Body {
            return None;
        }
        let last = self.last_body_input_at.unwrap_or(now);
        let started = self.header_started_at.unwrap_or(now);
        let idle_elapsed = now.duration_since(last);
        let total_elapsed = now.duration_since(started);
        if idle_elapsed >= self.config.idle_debounce || total_elapsed >= self.config.hard_cap {
            return self.commit();
        }
        None
    }

    /// Force commit any pending body (e.g., when the agent process exits).
    pub fn flush(&mut self) -> Option<AutoReplyEvent> {
        if self.state == State::Body {
            self.commit()
        } else {
            None
        }
    }

    fn process_line(&mut self, raw_line: &str, now: Instant) -> Option<AutoReplyEvent> {
        let stripped = strip_ansi(raw_line);
        let line = stripped.trim_end();
        let header = parse_header_line(line);

        match (self.state, header) {
            (State::Idle, Some((HeaderKey::Status, val))) => {
                self.reset_capture();
                self.header_status = val.to_string();
                self.raw_lines.push(line.to_string());
                self.state = State::SawStatus;
                self.header_started_at = Some(now);
                None
            }
            (State::SawStatus, Some((HeaderKey::Files, val))) => {
                self.header_files = val.to_string();
                self.raw_lines.push(line.to_string());
                self.state = State::SawFiles;
                None
            }
            (State::SawFiles, Some((HeaderKey::Verify, val))) => {
                self.header_verify = val.to_string();
                self.raw_lines.push(line.to_string());
                self.state = State::SawVerify;
                None
            }
            (State::SawVerify, Some((HeaderKey::Next, val))) => {
                self.header_next = val.to_string();
                self.raw_lines.push(line.to_string());
                self.state = State::SawNext;
                None
            }
            (State::SawNext, Some((HeaderKey::FullReport, val))) => {
                self.header_full_report = val.to_string();
                self.raw_lines.push(line.to_string());
                self.state = State::Body;
                self.last_body_input_at = Some(now);
                None
            }
            (State::Body, Some((HeaderKey::Status, val))) => {
                // A new reply began before debounce fired — commit the previous
                // capture, then start fresh with this STATUS line.
                let prev = self.commit();
                self.header_status = val.to_string();
                self.raw_lines.push(line.to_string());
                self.state = State::SawStatus;
                self.header_started_at = Some(now);
                prev
            }
            (State::Body, _) => {
                // Empty or content line is body. Skip pure-empty leading lines
                // so a single trailing newline after FULL_REPORT doesn't bloat.
                if !(self.body_lines.is_empty() && line.is_empty()) {
                    self.body_lines.push(line.to_string());
                }
                self.raw_lines.push(line.to_string());
                self.last_body_input_at = Some(now);
                None
            }
            (_, _) => {
                // Out-of-order header or non-header in header phase: strict 5/5 reset.
                self.reset_capture();
                None
            }
        }
    }

    fn commit(&mut self) -> Option<AutoReplyEvent> {
        if self.state != State::Body {
            return None;
        }
        // Trim trailing empty lines from body
        while self.body_lines.last().map(|s| s.is_empty()).unwrap_or(false) {
            self.body_lines.pop();
        }
        let event = AutoReplyEvent {
            status: std::mem::take(&mut self.header_status),
            files: std::mem::take(&mut self.header_files),
            verify: std::mem::take(&mut self.header_verify),
            next: std::mem::take(&mut self.header_next),
            full_report: std::mem::take(&mut self.header_full_report),
            body: self.body_lines.join("\n"),
            raw: self.raw_lines.join("\n"),
        };
        self.reset_capture();
        Some(event)
    }

    fn reset_capture(&mut self) {
        self.header_status.clear();
        self.header_files.clear();
        self.header_verify.clear();
        self.header_next.clear();
        self.header_full_report.clear();
        self.body_lines.clear();
        self.raw_lines.clear();
        self.header_started_at = None;
        self.last_body_input_at = None;
        self.state = State::Idle;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HeaderKey {
    Status,
    Files,
    Verify,
    Next,
    FullReport,
}

fn parse_header_line(line: &str) -> Option<(HeaderKey, &str)> {
    let (key, rest) = line.split_once(':')?;
    let key = match key {
        "STATUS" => HeaderKey::Status,
        "FILES" => HeaderKey::Files,
        "VERIFY" => HeaderKey::Verify,
        "NEXT" => HeaderKey::Next,
        "FULL_REPORT" => HeaderKey::FullReport,
        _ => return None,
    };
    let value = rest.strip_prefix(' ').unwrap_or(rest);
    Some((key, value))
}

/// Strip ANSI CSI (`ESC [ ... letter`) and OSC (`ESC ] ... BEL | ESC \\`) sequences.
/// UTF-8 safe (operates on chars). Lone ESCs are skipped.
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut iter = s.chars().peekable();
    while let Some(c) = iter.next() {
        if c == '\u{001b}' {
            match iter.peek() {
                Some('[') => {
                    iter.next();
                    while let Some(c) = iter.next() {
                        let b = c as u32;
                        if (0x40..=0x7e).contains(&b) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    iter.next();
                    while let Some(c) = iter.next() {
                        if c == '\u{0007}' {
                            break;
                        }
                        if c == '\u{001b}' && iter.peek() == Some(&'\\') {
                            iter.next();
                            break;
                        }
                    }
                }
                _ => {
                    // Lone ESC — drop
                }
            }
            continue;
        }
        out.push(c);
    }
    out
}

// ── Tests ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn t0() -> Instant {
        Instant::now()
    }

    fn drain(d: &mut AutoReplyDetector, t: Instant) -> Option<AutoReplyEvent> {
        // Simulate debounce expiry by ticking far in the future.
        d.tick(t + Duration::from_secs(10))
    }

    #[test]
    fn strict_pass_done() {
        let input = "STATUS: DONE\nFILES: src/foo.rs\nVERIFY: cargo test\nNEXT: NONE\nFULL_REPORT: n/a\n\nfix landed; tests green\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        assert!(d.push_bytes(input.as_bytes(), t).is_none(), "no immediate commit");
        let ev = drain(&mut d, t).expect("expected event after debounce");
        assert_eq!(ev.status, "DONE");
        assert_eq!(ev.files, "src/foo.rs");
        assert_eq!(ev.verify, "cargo test");
        assert_eq!(ev.next, "NONE");
        assert_eq!(ev.full_report, "n/a");
        assert_eq!(ev.body, "fix landed; tests green");
    }

    #[test]
    fn strict_pass_blocked_with_reason() {
        let input = "STATUS: BLOCKED\nFILES: none\nVERIFY: n/a\nNEXT: leader unblock\nFULL_REPORT: n/a\n\nneed schema decision before continuing\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        let ev = drain(&mut d, t).unwrap();
        assert_eq!(ev.status, "BLOCKED");
        assert_eq!(ev.body, "need schema decision before continuing");
    }

    #[test]
    fn strict_pass_needs_review() {
        let input = "STATUS: NEEDS_REVIEW\nFILES: src/auth.rs\nVERIFY: cargo build\nNEXT: reviewer LGTM\nFULL_REPORT: ~/.term-mesh/results/team/exec.md\n\npatched the bug\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        let ev = drain(&mut d, t).unwrap();
        assert_eq!(ev.status, "NEEDS_REVIEW");
        assert_eq!(ev.full_report, "~/.term-mesh/results/team/exec.md");
    }

    #[test]
    fn with_ansi_escapes() {
        // ANSI bold around STATUS key (Claude TUI style)
        let input = "\x1b[1mSTATUS:\x1b[0m DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\n\nshort body\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        let ev = drain(&mut d, t).unwrap();
        assert_eq!(ev.status, "DONE");
        assert_eq!(ev.body, "short body");
    }

    #[test]
    fn partial_3of5_no_event() {
        let input = "STATUS: DONE\nFILES: none\nVERIFY: cargo test\n\nrest of body without NEXT/FULL_REPORT\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        assert!(drain(&mut d, t).is_none(), "strict 5/5 must reject partial");
    }

    #[test]
    fn false_positive_echo_no_event() {
        // Body contains "STATUS: ok" but nothing else
        let input = "Looking at the file...\nSTATUS: ok\nDone.\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        assert!(drain(&mut d, t).is_none());
    }

    #[test]
    fn out_of_order_resets() {
        // FILES before STATUS — must reset and not emit
        let input = "FILES: foo.rs\nSTATUS: DONE\nVERIFY: x\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        assert!(drain(&mut d, t).is_none());
    }

    #[test]
    fn typewriter_chunks_one_char_at_a_time() {
        let input = "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\n\nbody line\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        for byte in input.as_bytes() {
            d.push_bytes(&[*byte], t);
        }
        let ev = drain(&mut d, t).unwrap();
        assert_eq!(ev.status, "DONE");
        assert_eq!(ev.body, "body line");
    }

    #[test]
    fn debounce_holds_until_idle() {
        let input = "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\nbody\n";
        let mut d = AutoReplyDetector::with_config(DetectorConfig {
            idle_debounce: Duration::from_millis(500),
            hard_cap: Duration::from_secs(5),
        });
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        // Before debounce elapses, tick returns None
        assert!(d.tick(t + Duration::from_millis(100)).is_none());
        assert!(d.tick(t + Duration::from_millis(400)).is_none());
        // After debounce, commit
        assert!(d.tick(t + Duration::from_millis(600)).is_some());
    }

    #[test]
    fn hard_cap_forces_commit() {
        let input = "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\n";
        let mut d = AutoReplyDetector::with_config(DetectorConfig {
            idle_debounce: Duration::from_secs(100), // huge debounce
            hard_cap: Duration::from_secs(5),
        });
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        // Keep feeding body bytes — debounce never fires
        for sec in 1..=6 {
            d.push_bytes(b"more body\n", t + Duration::from_secs(sec));
        }
        // Hard cap (5s since header start) reached
        let ev = d.tick(t + Duration::from_secs(6)).expect("hard cap commit");
        assert_eq!(ev.status, "DONE");
    }

    #[test]
    fn second_status_commits_first_then_starts_new() {
        let input = "STATUS: DONE\nFILES: a\nVERIFY: x\nNEXT: y\nFULL_REPORT: n/a\nfirst body\nSTATUS: BLOCKED\nFILES: b\nVERIFY: z\nNEXT: leader\nFULL_REPORT: n/a\nsecond body\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        // First push contains both replies; second STATUS forces commit of first
        let first = d.push_bytes(input.as_bytes(), t).expect("first commit");
        assert_eq!(first.status, "DONE");
        assert_eq!(first.body, "first body");
        // Now drain the second
        let second = drain(&mut d, t).expect("second commit");
        assert_eq!(second.status, "BLOCKED");
        assert_eq!(second.body, "second body");
    }

    #[test]
    fn flush_emits_pending() {
        let input = "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\nbody\n";
        let mut d = AutoReplyDetector::new();
        d.push_bytes(input.as_bytes(), t0());
        let ev = d.flush().unwrap();
        assert_eq!(ev.status, "DONE");
        assert_eq!(ev.body, "body");
    }

    #[test]
    fn flush_idle_returns_none() {
        let mut d = AutoReplyDetector::new();
        d.push_bytes(b"random log line\n", t0());
        assert!(d.flush().is_none());
    }

    #[test]
    fn content_hash_stable_across_raw_whitespace() {
        let mut a = AutoReplyDetector::new();
        a.push_bytes(b"STATUS: DONE\nFILES: x\nVERIFY: y\nNEXT: z\nFULL_REPORT: n/a\nbody\n", t0());
        let ev_a = a.flush().unwrap();

        let mut b = AutoReplyDetector::new();
        b.push_bytes(
            b"STATUS: DONE   \nFILES: x\nVERIFY: y\nNEXT: z\nFULL_REPORT: n/a\nbody\n",
            t0(),
        );
        let ev_b = b.flush().unwrap();
        // trim_end removes trailing whitespace in values too
        assert_eq!(ev_a.status, ev_b.status);
        assert_eq!(ev_a.content_hash(), ev_b.content_hash());
    }

    #[test]
    fn ansi_strip_preserves_unicode() {
        let s = "\x1b[31m한글\x1b[0m테스트";
        assert_eq!(strip_ansi(s), "한글테스트");
    }

    #[test]
    fn ansi_strip_osc_terminated_by_bel() {
        let s = "\x1b]0;title\x07after";
        assert_eq!(strip_ansi(s), "after");
    }

    #[test]
    fn parse_header_no_space_after_colon() {
        // Some agents may omit space after colon
        let input = "STATUS:DONE\nFILES:none\nVERIFY:n/a\nNEXT:NONE\nFULL_REPORT:n/a\nbody\n";
        let mut d = AutoReplyDetector::new();
        d.push_bytes(input.as_bytes(), t0());
        let ev = d.flush().unwrap();
        assert_eq!(ev.status, "DONE");
        assert_eq!(ev.files, "none");
    }
}
