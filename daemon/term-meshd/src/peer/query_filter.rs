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
    pub fn process(&mut self, input: &[u8]) -> (Vec<u8>, Vec<u8>) {
        let mut out = Vec::with_capacity(input.len());
        let mut responses = Vec::new();

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

        (out, responses)
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
            b"5" => Some(b"\x1B[0n"),    // Status: OK
            b"6" => Some(b"\x1B[1;1R"),  // Cursor Position Report: row 1, col 1
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

    fn process(filter: &mut QueryFilter, input: &[u8]) -> (Vec<u8>, Vec<u8>) {
        filter.process(input)
    }

    #[test]
    fn passes_plain_text_unchanged() {
        let mut f = QueryFilter::default();
        let (out, resp) = process(&mut f, b"hello world\n");
        assert_eq!(out, b"hello world\n");
        assert!(resp.is_empty());
    }

    #[test]
    fn passes_non_query_csi_through() {
        let mut f = QueryFilter::default();
        // Cursor up — not a query.
        let (out, resp) = process(&mut f, b"\x1B[2A");
        assert_eq!(out, b"\x1B[2A");
        assert!(resp.is_empty());
    }

    #[test]
    fn intercepts_da1_no_param() {
        let mut f = QueryFilter::default();
        let (out, resp) = process(&mut f, b"\x1B[c");
        assert!(out.is_empty(), "DA1 should be stripped");
        assert_eq!(resp, b"\x1B[?1;2c");
    }

    #[test]
    fn intercepts_da1_zero_param() {
        let mut f = QueryFilter::default();
        let (out, resp) = process(&mut f, b"\x1B[0c");
        assert!(out.is_empty());
        assert_eq!(resp, b"\x1B[?1;2c");
    }

    #[test]
    fn intercepts_da2() {
        let mut f = QueryFilter::default();
        let (out, resp) = process(&mut f, b"\x1B[>c");
        assert!(out.is_empty());
        assert_eq!(resp, b"\x1B[>1;95;0c");
    }

    #[test]
    fn intercepts_dsr_status() {
        let mut f = QueryFilter::default();
        let (out, resp) = process(&mut f, b"\x1B[5n");
        assert!(out.is_empty());
        assert_eq!(resp, b"\x1B[0n");
    }

    #[test]
    fn intercepts_dsr_cpr() {
        let mut f = QueryFilter::default();
        let (out, resp) = process(&mut f, b"\x1B[6n");
        assert!(out.is_empty());
        assert_eq!(resp, b"\x1B[1;1R");
    }

    #[test]
    fn intercepts_osc_11_with_bel() {
        let mut f = QueryFilter::default();
        let (out, resp) = process(&mut f, b"\x1B]11;?\x07");
        assert!(out.is_empty(), "OSC 11 query should be stripped");
        assert_eq!(resp, b"\x1B]11;rgb:1010/1414/1818\x07");
    }

    #[test]
    fn intercepts_osc_10_with_st() {
        let mut f = QueryFilter::default();
        let (out, resp) = process(&mut f, b"\x1B]10;?\x1B\\");
        assert!(out.is_empty());
        assert_eq!(resp, b"\x1B]10;rgb:e5e5/e5e5/e5e5\x07");
    }

    #[test]
    fn passes_osc_set_through() {
        let mut f = QueryFilter::default();
        // Window title set — OSC 0;title BEL — should not be stripped.
        let (out, resp) = process(&mut f, b"\x1B]0;hello\x07");
        assert_eq!(out, b"\x1B]0;hello\x07");
        assert!(resp.is_empty());
    }

    #[test]
    fn handles_query_split_across_chunks() {
        let mut f = QueryFilter::default();
        let (o1, r1) = process(&mut f, b"abc\x1B[");
        assert_eq!(o1, b"abc");
        assert!(r1.is_empty());
        let (o2, r2) = process(&mut f, b"6n def");
        assert_eq!(o2, b" def");
        assert_eq!(r2, b"\x1B[1;1R");
    }

    #[test]
    fn handles_osc_split_across_chunks() {
        let mut f = QueryFilter::default();
        let (o1, r1) = process(&mut f, b"\x1B]11;");
        assert!(o1.is_empty());
        assert!(r1.is_empty());
        let (o2, r2) = process(&mut f, b"?\x07");
        assert!(o2.is_empty());
        assert_eq!(r2, b"\x1B]11;rgb:1010/1414/1818\x07");
    }

    #[test]
    fn intercepts_back_to_back_queries() {
        let mut f = QueryFilter::default();
        let (out, resp) = process(&mut f, b"\x1B[c\x1B[6n");
        assert!(out.is_empty());
        assert_eq!(resp, b"\x1B[?1;2c\x1B[1;1R");
    }

    #[test]
    fn flushes_long_csi_without_swallowing() {
        let mut f = QueryFilter::default();
        let mut input = vec![0x1B, b'['];
        input.extend(std::iter::repeat(b'9').take(MAX_PENDING + 10));
        input.push(b'c');
        let (out, _resp) = process(&mut f, &input);
        // Either flushed mid-stream or recognised; just ensure nothing
        // is silently lost (length must be at least the param run).
        assert!(out.len() >= MAX_PENDING);
    }

    #[test]
    fn esc_alone_is_not_swallowed() {
        let mut f = QueryFilter::default();
        let (out, resp) = process(&mut f, b"\x1Bc");
        // ESC c is "Reset to Initial State" — emit unchanged.
        assert_eq!(out, b"\x1Bc");
        assert!(resp.is_empty());
    }
}
