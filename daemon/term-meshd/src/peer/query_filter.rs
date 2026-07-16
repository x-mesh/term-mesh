//! Intercepts terminal-control queries inside PTY output bytes.
//!
//! Why this exists: in the relay path, PTY output travels remote daemon →
//! SSH tunnel → local Ghostty. When the remote shell or a TUI emits a
//! query like `CSI 6n` ("where's the cursor?") or `OSC 11 ?` ("what's
//! the background color?"), the local Ghostty answers per spec. The
//! answer then has to make the round trip back: local Ghostty → relay
//! binary stdin → SSH tunnel → daemon → remote PTY master. Over a
//! 50–500 ms link, the originating program has long since exited by the
//! time the answer arrives, so the bytes land in zsh's prompt and zsh
//! tries to execute them as commands ("zsh: command not found: 11").
//!
//! Fix: the daemon — which sits between PTY and clients — answers the
//! queries itself with synthesized responses written straight back to
//! the PTY master, and strips the queries from the broadcast so the
//! local terminal never sees them and never replies.

const MAX_PENDING: usize = 256;

/// DEC private modes the peer relay cares about (mouse-tracking
/// protocols). `CSI ? Pm h` (DECSET) and `CSI ? Pm l` (DECRST) toggle
/// these; every other private mode is ignored.
fn is_tracked_mode(mode: u16) -> bool {
    matches!(mode, 1000 | 1002 | 1003 | 1005 | 1006 | 1015 | 1016)
}

/// A DECSET/DECRST transition for a mode the relay tracks (mouse
/// reporting). Surfaced from `process()` alongside the filtered bytes
/// so callers can mirror mouse-mode state without re-parsing the
/// stream themselves.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModeEvent {
    /// `CSI ? Pm h` — mode `Pm` enabled.
    Set(u16),
    /// `CSI ? Pm l` — mode `Pm` disabled.
    Reset(u16),
}

#[derive(Debug)]
enum State {
    Ground,
    Escape,
    Csi,
    Osc,
    OscEsc,
}

/// Streaming filter for PTY output. State persists across `process()`
/// calls so a query split across read boundaries is still recognised.
#[derive(Debug)]
pub struct QueryFilter {
    state: State,
    pending: Vec<u8>,
}

impl Default for QueryFilter {
    fn default() -> Self {
        Self {
            state: State::Ground,
            pending: Vec::with_capacity(64),
        }
    }
}

impl QueryFilter {
    /// Process PTY output bytes. Returns:
    /// - `out`: bytes safe to broadcast to clients (queries removed).
    /// - `responses`: bytes to write back to the PTY master so the
    ///   originating program sees a synthesized reply on its stdin.
    /// - `mode_events`: DECSET/DECRST transitions for tracked mouse
    ///   modes, in the order their terminating `h`/`l` byte completed
    ///   reassembly. A sequence split across `process()` calls only
    ///   yields its event(s) once the final byte lands.
    pub fn process(&mut self, input: &[u8]) -> (Vec<u8>, Vec<u8>, Vec<ModeEvent>) {
        let mut out = Vec::with_capacity(input.len());
        let mut responses = Vec::new();
        let mut mode_events = Vec::new();

        for &b in input {
            match self.state {
                State::Ground => {
                    if b == 0x1B {
                        self.pending.clear();
                        self.pending.push(b);
                        self.state = State::Escape;
                    } else {
                        out.push(b);
                    }
                }
                State::Escape => {
                    self.pending.push(b);
                    match b {
                        b'[' => self.state = State::Csi,
                        b']' => self.state = State::Osc,
                        _ => {
                            // ESC followed by something we don't model
                            // (keypad mode, charset select, etc.). Pass
                            // it through unchanged.
                            out.extend_from_slice(&self.pending);
                            self.pending.clear();
                            self.state = State::Ground;
                        }
                    }
                }
                State::Csi => {
                    self.pending.push(b);
                    if (0x40..=0x7E).contains(&b) {
                        if let Some(reply) = csi_query_reply(&self.pending) {
                            responses.extend_from_slice(reply);
                        } else {
                            out.extend_from_slice(&self.pending);
                            // DECSET/DECRST are never intercepted above
                            // (csi_query_reply only matches 'c'/'n'), so
                            // this is the one place a fully-reassembled
                            // mode toggle can be recognised — never on
                            // the overflow-flush path below, which is
                            // not a complete sequence.
                            parse_mode_events(&self.pending, &mut mode_events);
                        }
                        self.pending.clear();
                        self.state = State::Ground;
                    } else if !(0x20..=0x3F).contains(&b) || self.pending.len() > MAX_PENDING {
                        // Invalid byte inside CSI parameter region, or
                        // sequence is suspiciously long. Flush so we
                        // don't silently swallow content.
                        out.extend_from_slice(&self.pending);
                        self.pending.clear();
                        self.state = State::Ground;
                    }
                }
                State::Osc => {
                    if b == 0x07 {
                        if let Some(reply) = osc_query_reply(&self.pending) {
                            responses.extend_from_slice(&reply);
                        } else {
                            out.extend_from_slice(&self.pending);
                            out.push(0x07);
                        }
                        self.pending.clear();
                        self.state = State::Ground;
                    } else if b == 0x1B {
                        self.state = State::OscEsc;
                    } else {
                        self.pending.push(b);
                        if self.pending.len() > MAX_PENDING {
                            out.extend_from_slice(&self.pending);
                            self.pending.clear();
                            self.state = State::Ground;
                        }
                    }
                }
                State::OscEsc => {
                    if b == b'\\' {
                        if let Some(reply) = osc_query_reply(&self.pending) {
                            responses.extend_from_slice(&reply);
                        } else {
                            out.extend_from_slice(&self.pending);
                            out.extend_from_slice(b"\x1B\\");
                        }
                        self.pending.clear();
                        self.state = State::Ground;
                    } else {
                        // ESC inside OSC was not a String Terminator.
                        // Flush what we have and let the next iteration
                        // re-evaluate `b` (don't try to recover further).
                        out.extend_from_slice(&self.pending);
                        out.push(0x1B);
                        out.push(b);
                        self.pending.clear();
                        self.state = State::Ground;
                    }
                }
            }
        }

        (out, responses, mode_events)
    }
}

/// Recognises `CSI ? Pm h|l` (DECSET/DECRST) in a fully-reassembled CSI
/// sequence and pushes a [`ModeEvent`] for each tracked mode among the
/// (possibly `;`-separated) parameters. `pending` holds the full
/// sequence: ESC '[' params... final. Non-DEC-private sequences
/// (missing the leading `?`), non-`h`/`l` finals, and untracked modes
/// are silently ignored — this only adds events, it never changes what
/// the caller does with the bytes themselves.
fn parse_mode_events(pending: &[u8], events: &mut Vec<ModeEvent>) {
    if pending.len() < 3 {
        return;
    }
    let final_byte = pending[pending.len() - 1];
    let is_set = match final_byte {
        b'h' => true,
        b'l' => false,
        _ => return,
    };
    let body = &pending[2..pending.len() - 1];
    let Some(params) = body.strip_prefix(b"?") else {
        return; // not a DEC private-mode sequence
    };
    for param in params.split(|&b| b == b';') {
        // Non-numeric or out-of-u16-range parameters are ignored rather
        // than treated as errors — a malformed/unknown param shouldn't
        // stop the rest of the (independent) params from being parsed.
        if let Ok(mode) = std::str::from_utf8(param)
            .unwrap_or_default()
            .parse::<u16>()
        {
            if is_tracked_mode(mode) {
                events.push(if is_set {
                    ModeEvent::Set(mode)
                } else {
                    ModeEvent::Reset(mode)
                });
            }
        }
    }
}

/// `pending` holds the full CSI sequence: ESC '[' params... final.
fn csi_query_reply(pending: &[u8]) -> Option<&'static [u8]> {
    if pending.len() < 3 {
        return None;
    }
    let body = &pending[2..pending.len() - 1];
    let final_byte = pending[pending.len() - 1];

    match final_byte {
        b'c' => {
            // Device Attributes.
            if body.is_empty() || body == b"0" {
                // DA1 — VT100 with Advanced Video Option. Minimal reply
                // that every reasonable TUI accepts.
                Some(b"\x1B[?1;2c")
            } else if body.starts_with(b">") {
                // DA2 — xterm patch level 95 is widely accepted as
                // "modern xterm-compatible".
                Some(b"\x1B[>1;95;0c")
            } else if body.starts_with(b"=") {
                // DA3 — report a fixed all-zero unit ID via DECRPTUI.
                Some(b"\x1BP!|00000000\x1B\\")
            } else {
                None
            }
        }
        b'n' => match body {
            b"5" => Some(b"\x1B[0n"),   // Status: OK
            b"6" => Some(b"\x1B[1;1R"), // Cursor Position Report: row 1, col 1
            _ => None,
        },
        _ => None,
    }
}

/// `body` holds the OSC introducer plus its payload: ESC ']' Ps ; Pt.
fn osc_query_reply(body: &[u8]) -> Option<Vec<u8>> {
    if body.len() < 4 {
        return None;
    }
    let payload = &body[2..];
    let semi = payload.iter().position(|&b| b == b';')?;
    let ps = &payload[..semi];
    let pt = &payload[semi + 1..];
    if pt != b"?" {
        return None;
    }
    match ps {
        b"10" => Some(b"\x1B]10;rgb:e5e5/e5e5/e5e5\x07".to_vec()),
        b"11" => Some(b"\x1B]11;rgb:1010/1414/1818\x07".to_vec()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(filter: &mut QueryFilter, input: &[u8]) -> (Vec<u8>, Vec<u8>, Vec<ModeEvent>) {
        filter.process(input)
    }

    #[test]
    fn passes_plain_text_unchanged() {
        let mut f = QueryFilter::default();
        let (out, resp, _events) = process(&mut f, b"hello world\n");
        assert_eq!(out, b"hello world\n");
        assert!(resp.is_empty());
    }

    #[test]
    fn passes_non_query_csi_through() {
        let mut f = QueryFilter::default();
        // Cursor up — not a query.
        let (out, resp, _events) = process(&mut f, b"\x1B[2A");
        assert_eq!(out, b"\x1B[2A");
        assert!(resp.is_empty());
    }

    #[test]
    fn intercepts_da1_no_param() {
        let mut f = QueryFilter::default();
        let (out, resp, _events) = process(&mut f, b"\x1B[c");
        assert!(out.is_empty(), "DA1 should be stripped");
        assert_eq!(resp, b"\x1B[?1;2c");
    }

    #[test]
    fn intercepts_da1_zero_param() {
        let mut f = QueryFilter::default();
        let (out, resp, _events) = process(&mut f, b"\x1B[0c");
        assert!(out.is_empty());
        assert_eq!(resp, b"\x1B[?1;2c");
    }

    #[test]
    fn intercepts_da2() {
        let mut f = QueryFilter::default();
        let (out, resp, _events) = process(&mut f, b"\x1B[>c");
        assert!(out.is_empty());
        assert_eq!(resp, b"\x1B[>1;95;0c");
    }

    #[test]
    fn intercepts_dsr_status() {
        let mut f = QueryFilter::default();
        let (out, resp, _events) = process(&mut f, b"\x1B[5n");
        assert!(out.is_empty());
        assert_eq!(resp, b"\x1B[0n");
    }

    #[test]
    fn intercepts_dsr_cpr() {
        let mut f = QueryFilter::default();
        let (out, resp, _events) = process(&mut f, b"\x1B[6n");
        assert!(out.is_empty());
        assert_eq!(resp, b"\x1B[1;1R");
    }

    #[test]
    fn intercepts_osc_11_with_bel() {
        let mut f = QueryFilter::default();
        let (out, resp, _events) = process(&mut f, b"\x1B]11;?\x07");
        assert!(out.is_empty(), "OSC 11 query should be stripped");
        assert_eq!(resp, b"\x1B]11;rgb:1010/1414/1818\x07");
    }

    #[test]
    fn intercepts_osc_10_with_st() {
        let mut f = QueryFilter::default();
        let (out, resp, _events) = process(&mut f, b"\x1B]10;?\x1B\\");
        assert!(out.is_empty());
        assert_eq!(resp, b"\x1B]10;rgb:e5e5/e5e5/e5e5\x07");
    }

    #[test]
    fn passes_osc_set_through() {
        let mut f = QueryFilter::default();
        // Window title set — OSC 0;title BEL — should not be stripped.
        let (out, resp, _events) = process(&mut f, b"\x1B]0;hello\x07");
        assert_eq!(out, b"\x1B]0;hello\x07");
        assert!(resp.is_empty());
    }

    #[test]
    fn handles_query_split_across_chunks() {
        let mut f = QueryFilter::default();
        let (o1, r1, _events) = process(&mut f, b"abc\x1B[");
        assert_eq!(o1, b"abc");
        assert!(r1.is_empty());
        let (o2, r2, _events) = process(&mut f, b"6n def");
        assert_eq!(o2, b" def");
        assert_eq!(r2, b"\x1B[1;1R");
    }

    #[test]
    fn handles_osc_split_across_chunks() {
        let mut f = QueryFilter::default();
        let (o1, r1, _events) = process(&mut f, b"\x1B]11;");
        assert!(o1.is_empty());
        assert!(r1.is_empty());
        let (o2, r2, _events) = process(&mut f, b"?\x07");
        assert!(o2.is_empty());
        assert_eq!(r2, b"\x1B]11;rgb:1010/1414/1818\x07");
    }

    #[test]
    fn intercepts_back_to_back_queries() {
        let mut f = QueryFilter::default();
        let (out, resp, _events) = process(&mut f, b"\x1B[c\x1B[6n");
        assert!(out.is_empty());
        assert_eq!(resp, b"\x1B[?1;2c\x1B[1;1R");
    }

    #[test]
    fn flushes_long_csi_without_swallowing() {
        let mut f = QueryFilter::default();
        let mut input = vec![0x1B, b'['];
        input.extend(std::iter::repeat(b'9').take(MAX_PENDING + 10));
        input.push(b'c');
        let (out, _resp, _events) = process(&mut f, &input);
        // Either flushed mid-stream or recognised; just ensure nothing
        // is silently lost (length must be at least the param run).
        assert!(out.len() >= MAX_PENDING);
    }

    #[test]
    fn esc_alone_is_not_swallowed() {
        let mut f = QueryFilter::default();
        let (out, resp, _events) = process(&mut f, b"\x1Bc");
        // ESC c is "Reset to Initial State" — emit unchanged.
        assert_eq!(out, b"\x1Bc");
        assert!(resp.is_empty());
    }

    #[test]
    fn tracks_decset_mouse_modes() {
        let mut f = QueryFilter::default();
        // SGR mouse reporting (1006) alongside button-event tracking
        // (1002) — a common pair TUIs enable together. Each `;`-separated
        // parameter must be judged independently.
        let (out, resp, events) = process(&mut f, b"\x1B[?1002;1006h");
        assert_eq!(
            out, b"\x1B[?1002;1006h",
            "DECSET is not a query reply — bytes must still pass through"
        );
        assert!(resp.is_empty());
        assert_eq!(events, vec![ModeEvent::Set(1002), ModeEvent::Set(1006)]);
    }

    #[test]
    fn tracks_decrst_mouse_mode() {
        let mut f = QueryFilter::default();
        let (out, resp, events) = process(&mut f, b"\x1B[?1000l");
        assert_eq!(
            out, b"\x1B[?1000l",
            "DECRST is not a query reply — bytes must still pass through"
        );
        assert!(resp.is_empty());
        assert_eq!(events, vec![ModeEvent::Reset(1000)]);
    }

    #[test]
    fn tracks_mode_split_across_chunks() {
        let mut f = QueryFilter::default();
        // Split mid-parameter, mirroring handles_query_split_across_chunks:
        // no event may surface until the final `h`/`l` byte reassembles
        // the whole sequence.
        let (o1, r1, e1) = process(&mut f, b"\x1B[?100");
        assert!(o1.is_empty());
        assert!(r1.is_empty());
        assert!(
            e1.is_empty(),
            "must not report an event before reassembly completes"
        );
        let (o2, r2, e2) = process(&mut f, b"6h");
        assert_eq!(o2, b"\x1B[?1006h", "reassembled bytes still pass through");
        assert!(r2.is_empty());
        assert_eq!(e2, vec![ModeEvent::Set(1006)]);
    }
}
