//! Auto-reply detector for TM-PROTOCOL-v1 (Phase B1).
//!
//! ## Sliding window approach (Fix D)
//!
//! Keeps a 30-line rolling buffer. On every `tick()` call the buffer is
//! scanned for STATUS (mandatory) plus the other 4 header fields (optional,
//! default "n/a"). Commit fires when:
//!
//! 1. All 5 fields present **and** `idle_debounce` elapsed since last byte.
//! 2. STATUS + ≥2 other fields present **and** `hard_cap` elapsed since STATUS.
//! 3. `flush()` called explicitly (e.g. agent exit) — STATUS + ≥1 other.
//!
//! Order and interleaved noise no longer matter. Body = lines in the buffer
//! after the most-recent STATUS line, excluding header lines.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

const BUFFER_CAP: usize = 30;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutoReplyEvent {
    pub status: String,
    pub files: String,
    pub verify: String,
    pub next: String,
    pub full_report: String,
    pub body: String,
    pub raw: String,
}

impl AutoReplyEvent {
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
    line_buffer: VecDeque<String>,
    line_buf: String,
    /// When the most-recent STATUS line was pushed (hard_cap clock).
    status_seen_at: Option<Instant>,
    /// When the last line was pushed (idle_debounce clock).
    last_input_at: Option<Instant>,
    /// True after an emit — prevents double-emit until a new STATUS arrives.
    committed: bool,
}

impl Default for AutoReplyDetector {
    fn default() -> Self { Self::new() }
}

impl AutoReplyDetector {
    pub fn new() -> Self { Self::with_config(DetectorConfig::default()) }

    pub fn with_config(config: DetectorConfig) -> Self {
        Self {
            config,
            line_buffer: VecDeque::with_capacity(BUFFER_CAP),
            line_buf: String::new(),
            status_seen_at: None,
            last_input_at: None,
            committed: false,
        }
    }

    /// Feed raw bytes. Returns None always; commits arrive via `tick()` or `flush()`.
    pub fn push_bytes(&mut self, bytes: &[u8], now: Instant) -> Option<AutoReplyEvent> {
        let text = String::from_utf8_lossy(bytes);
        for ch in text.chars() {
            if ch == '\n' {
                let line = std::mem::take(&mut self.line_buf);
                self.push_line(line, now);
            } else if ch != '\r' {
                self.line_buf.push(ch);
            }
        }
        None
    }

    fn push_line(&mut self, raw_line: String, now: Instant) {
        let stripped = strip_ansi(&raw_line);
        let line = stripped.trim_end().to_string();

        if self.line_buffer.len() >= BUFFER_CAP {
            self.line_buffer.pop_front();
        }
        self.line_buffer.push_back(line.clone());
        self.last_input_at = Some(now);

        if line.starts_with("STATUS:") {
            self.status_seen_at = Some(now);
            self.committed = false;
        }
    }

    /// Periodic check. Returns event when debounce or hard_cap fires.
    pub fn tick(&mut self, now: Instant) -> Option<AutoReplyEvent> {
        if self.committed { return None; }

        let Some(anchor) = self.status_block_start() else {
            self.status_seen_at = None;
            return None;
        };
        let Some(status) = self.scan_field_from("STATUS", anchor) else {
            self.status_seen_at = None;
            return None;
        };
        let Some(status_at) = self.status_seen_at else { return None; };

        let files = self.scan_field_from("FILES", anchor);
        let verify = self.scan_field_from("VERIFY", anchor);
        let next = self.scan_field_from("NEXT", anchor);
        let full_report = self.scan_field_from("FULL_REPORT", anchor);
        let others = [&files, &verify, &next, &full_report]
            .iter().filter(|v| v.is_some()).count();

        let last = self.last_input_at.unwrap_or(now);
        let idle = now.duration_since(last);
        let cap = now.duration_since(status_at);

        let all_present = others == 4;
        if (all_present && idle >= self.config.idle_debounce)
            || (others >= 2 && cap >= self.config.hard_cap)
        {
            return self.emit(
                status,
                files.unwrap_or_else(|| "n/a".to_string()),
                verify.unwrap_or_else(|| "n/a".to_string()),
                next.unwrap_or_else(|| "n/a".to_string()),
                full_report.unwrap_or_else(|| "n/a".to_string()),
            );
        }
        None
    }

    /// Force emit on agent exit. Requires STATUS + ≥1 other field.
    pub fn flush(&mut self) -> Option<AutoReplyEvent> {
        if self.committed { return None; }
        let anchor = self.status_block_start()?;
        let status = self.scan_field_from("STATUS", anchor)?;
        let files = self.scan_field_from("FILES", anchor);
        let verify = self.scan_field_from("VERIFY", anchor);
        let next = self.scan_field_from("NEXT", anchor);
        let full_report = self.scan_field_from("FULL_REPORT", anchor);
        let others = [&files, &verify, &next, &full_report]
            .iter().filter(|v| v.is_some()).count();
        if others == 0 { return None; }
        self.emit(
            status,
            files.unwrap_or_else(|| "n/a".to_string()),
            verify.unwrap_or_else(|| "n/a".to_string()),
            next.unwrap_or_else(|| "n/a".to_string()),
            full_report.unwrap_or_else(|| "n/a".to_string()),
        )
    }

    fn emit(&mut self, status: String, files: String, verify: String, next: String, full_report: String) -> Option<AutoReplyEvent> {
        let header_prefixes = ["STATUS:", "FILES:", "VERIFY:", "NEXT:", "FULL_REPORT:"];

        // Body starts after the LAST header line in the buffer so noise lines
        // interspersed between headers are not mistaken for body content.
        let last_header_pos = self.line_buffer
            .iter()
            .rposition(|l| header_prefixes.iter().any(|p| l.starts_with(p)))
            .unwrap_or(0);

        let status_pos = self.line_buffer
            .iter()
            .rposition(|l| l.starts_with("STATUS:"))
            .unwrap_or(0);

        let body_lines: Vec<&str> = self.line_buffer.iter()
            .skip(last_header_pos + 1)
            .map(|s| s.as_str())
            .collect();

        let body_start = body_lines.iter().position(|l| !l.is_empty()).unwrap_or(0);
        let body_end = body_lines.iter().rposition(|l| !l.is_empty()).map(|i| i + 1).unwrap_or(0);
        let body = if body_start < body_end {
            body_lines[body_start..body_end].join("\n")
        } else {
            String::new()
        };

        let raw = self.line_buffer.iter().skip(status_pos)
            .cloned().collect::<Vec<_>>().join("\n");

        self.committed = true;
        self.line_buffer.clear();
        self.status_seen_at = None;
        self.last_input_at = None;

        Some(AutoReplyEvent { status, files, verify, next, full_report, body, raw })
    }

    /// Returns the buffer index from which field scans should start.
    ///
    /// When multiple STATUS headers exist in the window, anchors to the latest
    /// STATUS position so stale fields from a prior block are not picked up.
    /// When only one STATUS exists, returns 0 to preserve out-of-order scanning.
    fn status_block_start(&self) -> Option<usize> {
        let mut latest: Option<usize> = None;
        let mut prev: Option<usize> = None;
        for (i, line) in self.line_buffer.iter().enumerate() {
            if line.starts_with("STATUS:") {
                prev = latest;
                latest = Some(i);
            }
        }
        latest?;
        if prev.is_some() { latest } else { Some(0) }
    }

    fn scan_field(&self, name: &str) -> Option<String> {
        self.scan_field_from(name, 0)
    }

    /// Like `scan_field` but only considers lines at index ≥ `from_idx`.
    fn scan_field_from(&self, name: &str, from_idx: usize) -> Option<String> {
        let prefix = format!("{name}:");
        for (idx, line) in self.line_buffer.iter().enumerate().rev() {
            if idx < from_idx { break; }
            if let Some(rest) = line.strip_prefix(&prefix) {
                let val = rest.strip_prefix(' ').unwrap_or(rest);
                if !val.is_empty() { return Some(val.to_string()); }
            }
        }
        None
    }
}

fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut iter = s.chars().peekable();
    while let Some(c) = iter.next() {
        if c == '\u{001b}' {
            match iter.peek() {
                Some('[') => {
                    iter.next();
                    while let Some(c) = iter.next() {
                        if (0x40..=0x7eu32).contains(&(c as u32)) { break; }
                    }
                }
                Some(']') => {
                    iter.next();
                    while let Some(c) = iter.next() {
                        if c == '\u{0007}' { break; }
                        if c == '\u{001b}' && iter.peek() == Some(&'\\') { iter.next(); break; }
                    }
                }
                _ => {}
            }
            continue;
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t0() -> Instant { Instant::now() }

    fn drain(d: &mut AutoReplyDetector, t: Instant) -> Option<AutoReplyEvent> {
        d.tick(t + Duration::from_secs(10))
    }

    #[test]
    fn strict_pass_done() {
        let input = "STATUS: DONE\nFILES: src/foo.rs\nVERIFY: cargo test\nNEXT: NONE\nFULL_REPORT: n/a\n\nfix landed; tests green\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        let ev = drain(&mut d, t).expect("event after debounce");
        assert_eq!(ev.status, "DONE");
        assert_eq!(ev.files, "src/foo.rs");
        assert_eq!(ev.verify, "cargo test");
        assert_eq!(ev.next, "NONE");
        assert_eq!(ev.full_report, "n/a");
        assert_eq!(ev.body, "fix landed; tests green");
    }

    #[test]
    fn out_of_order_still_commits() {
        let input = "NEXT: NONE\nFILES: src/foo.rs\nFULL_REPORT: n/a\nVERIFY: cargo test\nSTATUS: DONE\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        let ev = drain(&mut d, t).expect("out-of-order must commit with sliding window");
        assert_eq!(ev.status, "DONE");
        assert_eq!(ev.files, "src/foo.rs");
    }

    #[test]
    fn blank_and_ansi_noise_interspersed() {
        let input = "STATUS: DONE\n\x1b[1msome bold noise\x1b[0m\nFILES: src/foo.rs\n\nVERIFY: cargo test\nNEXT: NONE\nFULL_REPORT: n/a\nbody text\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        let ev = drain(&mut d, t).expect("noise-interspersed header must commit");
        assert_eq!(ev.status, "DONE");
        assert_eq!(ev.files, "src/foo.rs");
        assert_eq!(ev.body, "body text");
    }

    #[test]
    fn status_missing_no_commit() {
        let input = "FILES: src/foo.rs\nVERIFY: cargo test\nNEXT: NONE\nFULL_REPORT: n/a\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        assert!(drain(&mut d, t).is_none(), "STATUS missing must not commit");
    }

    #[test]
    fn partial_status_plus_2_commits_at_hard_cap() {
        let input = "STATUS: DONE\nFILES: none\nVERIFY: cargo test\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        let ev = drain(&mut d, t).expect("STATUS + 2 fields at hard_cap must partial commit");
        assert_eq!(ev.status, "DONE");
        assert_eq!(ev.files, "none");
        assert_eq!(ev.verify, "cargo test");
        assert_eq!(ev.next, "n/a");
        assert_eq!(ev.full_report, "n/a");
    }

    #[test]
    fn status_only_no_partial_commit() {
        let input = "STATUS: DONE\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        // STATUS + 0 others — hard_cap fires but others < 2 → no commit
        assert!(d.tick(t + Duration::from_secs(10)).is_none(), "STATUS-only must not partial commit");
    }

    #[test]
    fn body_extracted_after_status() {
        let input = "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\nfirst body line\nsecond body line\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        let ev = drain(&mut d, t).unwrap();
        assert_eq!(ev.body, "first body line\nsecond body line");
    }

    #[test]
    fn with_ansi_escapes() {
        let input = "\x1b[1mSTATUS:\x1b[0m DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\n\nshort body\n";
        let mut d = AutoReplyDetector::new();
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        let ev = drain(&mut d, t).unwrap();
        assert_eq!(ev.status, "DONE");
        assert_eq!(ev.body, "short body");
    }

    #[test]
    fn debounce_holds_then_fires() {
        let input = "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\nbody\n";
        let mut d = AutoReplyDetector::with_config(DetectorConfig {
            idle_debounce: Duration::from_millis(500),
            hard_cap: Duration::from_secs(30),
        });
        let t = t0();
        d.push_bytes(input.as_bytes(), t);
        assert!(d.tick(t + Duration::from_millis(100)).is_none());
        assert!(d.tick(t + Duration::from_millis(400)).is_none());
        assert!(d.tick(t + Duration::from_millis(600)).is_some());
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
    fn content_hash_stable() {
        let mut a = AutoReplyDetector::new();
        a.push_bytes(b"STATUS: DONE\nFILES: x\nVERIFY: y\nNEXT: z\nFULL_REPORT: n/a\nbody\n", t0());
        let ev_a = a.flush().unwrap();

        let mut b = AutoReplyDetector::new();
        b.push_bytes(b"STATUS: DONE   \nFILES: x\nVERIFY: y\nNEXT: z\nFULL_REPORT: n/a\nbody\n", t0());
        let ev_b = b.flush().unwrap();
        assert_eq!(ev_a.status, ev_b.status);
        assert_eq!(ev_a.content_hash(), ev_b.content_hash());
    }

    #[test]
    fn typewriter_chunks() {
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
    fn ansi_strip_preserves_unicode() {
        assert_eq!(strip_ansi("\x1b[31m한글\x1b[0m테스트"), "한글테스트");
    }

    #[test]
    fn parse_no_space_after_colon() {
        let input = "STATUS:DONE\nFILES:none\nVERIFY:n/a\nNEXT:NONE\nFULL_REPORT:n/a\nbody\n";
        let mut d = AutoReplyDetector::new();
        d.push_bytes(input.as_bytes(), t0());
        let ev = d.flush().unwrap();
        assert_eq!(ev.status, "DONE");
        assert_eq!(ev.files, "none");
    }
}
