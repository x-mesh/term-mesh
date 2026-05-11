//! Per ADR 0002 §"Control mode state machine" — parses tmux control mode output.
//!
//! tmux control mode (`tmux -CC`) produces two kinds of output:
//!
//! 1. **Command blocks**: bracketed by `%begin <n>` / `%end <n>` or `%error <n>`.
//!    These are responses to commands sent over stdin.
//!
//! 2. **Async notifications**: `%output`, `%layout-change`, `%window-add`, etc.
//!    These arrive unprompted from tmux.
//!
//! The parser is fed one line at a time via `feed_line`.

use super::octal::unescape_octal;

/// State of the control-mode line parser.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParserState {
    Idle,
    /// Inside a `%begin <cmd_number>` … `%end` / `%error` block.
    InCommandBlock { cmd_number: u32 },
    /// Inside an async notification block (not currently used by tmux but
    /// reserved for future `%notify-begin` / `%notify-end` extensions).
    InNotify,
}

/// Decoded tmux control-mode events emitted by `ControlModeParser::feed_line`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TmuxEvent {
    /// Raw PTY bytes for `pane_id`; payload has been octal-unescaped.
    Output { pane_id: String, bytes: Vec<u8> },
    /// tmux requests client to stop sending input.
    Pause { pane_id: String },
    /// tmux allows client to resume input.
    Continue { pane_id: String },
    /// The active session changed (per ADR 0002 §"Whitelisted Events").
    /// Format: `%session-changed <session-id> <name>`
    SessionChanged { session_id: String, name: String },
    /// tmux is exiting.
    Exit,
    /// Start of a command block response.
    BeginBlock(u32),
    /// End of a successful command block response.
    EndBlock(u32),
    /// End of a failed command block response.
    ErrorBlock(u32),
    /// Unrecognised notification — stored verbatim for debugging.
    Unknown(String),
}

/// Extract the command number from a `%begin`/`%end`/`%error` argument string.
///
/// Real tmux format: `"<timestamp> <cmd-number> <flags>"` → second field.
/// Simplified format (tests): `"<cmd-number>"` → first and only field.
fn parse_cmd_number(rest: &str) -> u32 {
    let mut fields = rest.split_whitespace();
    let first = fields.next().unwrap_or("0");
    if let Some(second) = fields.next() {
        second.parse().unwrap_or(0)
    } else {
        first.parse().unwrap_or(0)
    }
}

/// Per ADR 0002 §"Control mode state machine".
///
/// Feed lines from the `ssh tmux -CC` stdout one at a time.  Each call
/// returns zero or more decoded `TmuxEvent` values.
pub struct ControlModeParser {
    pub state: ParserState,
}

impl ControlModeParser {
    pub fn new() -> Self {
        Self { state: ParserState::Idle }
    }

    /// Process a single line (without trailing newline) and return any events.
    ///
    /// Per ADR 0002 §"DCS framing": tmux wraps the entire control-mode stream
    /// in a DCS string (`\x1bP1000p` … `\x1b\\`).  The opening prefix appears
    /// on the very first line before the first `%begin`; the terminator `\x1b\\`
    /// may appear on the final `%exit` line.  Both are stripped here so the
    /// rest of the parser never sees raw DCS bytes.
    pub fn feed_line(&mut self, line: &str) -> Vec<TmuxEvent> {
        let mut events = Vec::new();

        // Strip DCS opening prefix (\x1bP1000p) and/or closing ST (\x1b\).
        let line = line.strip_prefix("\x1bP1000p").unwrap_or(line);
        let line = line.strip_suffix("\x1b\\").unwrap_or(line);

        if let Some(rest) = line.strip_prefix("%begin ") {
            // Real tmux: "%begin <timestamp> <cmd-number> <flags>"
            // Simplified: "%begin <cmd-number>"
            let n = parse_cmd_number(rest);
            self.state = ParserState::InCommandBlock { cmd_number: n };
            events.push(TmuxEvent::BeginBlock(n));
            return events;
        }

        if let Some(rest) = line.strip_prefix("%end ") {
            let n = parse_cmd_number(rest);
            self.state = ParserState::Idle;
            events.push(TmuxEvent::EndBlock(n));
            return events;
        }

        if let Some(rest) = line.strip_prefix("%error ") {
            let n = parse_cmd_number(rest);
            self.state = ParserState::Idle;
            events.push(TmuxEvent::ErrorBlock(n));
            return events;
        }

        // Async notifications — only processed while Idle or InCommandBlock
        // (tmux can interleave notifications inside command blocks).
        if let Some(rest) = line.strip_prefix("%output ") {
            // Format: %output <pane-id> <escaped-payload>
            // pane-id starts with %, e.g. %1
            if let Some((pane_id, payload)) = rest.split_once(' ') {
                let bytes = unescape_octal(payload.as_bytes());
                events.push(TmuxEvent::Output { pane_id: pane_id.to_string(), bytes });
            }
            return events;
        }

        if let Some(rest) = line.strip_prefix("%pause") {
            let pane_id = rest.trim().to_string();
            events.push(TmuxEvent::Pause { pane_id });
            return events;
        }

        if let Some(rest) = line.strip_prefix("%continue") {
            let pane_id = rest.trim().to_string();
            events.push(TmuxEvent::Continue { pane_id });
            return events;
        }

        if let Some(rest) = line.strip_prefix("%session-changed ") {
            let mut parts = rest.splitn(2, ' ');
            if let (Some(id), Some(name)) = (parts.next(), parts.next()) {
                events.push(TmuxEvent::SessionChanged {
                    session_id: id.to_string(),
                    name: name.to_string(),
                });
            } else {
                events.push(TmuxEvent::Unknown(line.to_string()));
            }
            return events;
        }

        if line == "%exit" {
            events.push(TmuxEvent::Exit);
            return events;
        }

        // %layout-change and other notifications — ignore per Phase 1.0 scope.
        if line.starts_with('%') {
            events.push(TmuxEvent::Unknown(line.to_string()));
        }

        events
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_to_command_block_to_idle() {
        let mut p = ControlModeParser::new();
        assert_eq!(p.state, ParserState::Idle);

        let ev = p.feed_line("%begin 42");
        assert_eq!(ev, vec![TmuxEvent::BeginBlock(42)]);
        assert_eq!(p.state, ParserState::InCommandBlock { cmd_number: 42 });

        let ev = p.feed_line("%end 42");
        assert_eq!(ev, vec![TmuxEvent::EndBlock(42)]);
        assert_eq!(p.state, ParserState::Idle);
    }

    #[test]
    fn error_block_resets_state() {
        let mut p = ControlModeParser::new();
        p.feed_line("%begin 7");
        let ev = p.feed_line("%error 7");
        assert_eq!(ev, vec![TmuxEvent::ErrorBlock(7)]);
        assert_eq!(p.state, ParserState::Idle);
    }

    #[test]
    fn output_line_parsed_with_unescape() {
        let mut p = ControlModeParser::new();
        // %output %1 hello\012world
        let ev = p.feed_line("%output %1 hello\\012world");
        assert_eq!(ev.len(), 1);
        if let TmuxEvent::Output { pane_id, bytes } = &ev[0] {
            assert_eq!(pane_id, "%1");
            assert_eq!(bytes, b"hello\nworld");
        } else {
            panic!("expected Output event, got {:?}", ev[0]);
        }
    }

    #[test]
    fn pause_event() {
        let mut p = ControlModeParser::new();
        let ev = p.feed_line("%pause %2");
        assert_eq!(ev, vec![TmuxEvent::Pause { pane_id: "%2".to_string() }]);
    }

    #[test]
    fn unknown_notification_stored() {
        let mut p = ControlModeParser::new();
        let ev = p.feed_line("%layout-change @0 some-layout-data");
        assert_eq!(ev.len(), 1);
        assert!(matches!(&ev[0], TmuxEvent::Unknown(s) if s.contains("layout-change")));
    }

    #[test]
    fn session_changed_parsed() {
        let mut p = ControlModeParser::new();
        let ev = p.feed_line("%session-changed $0 main");
        assert_eq!(ev.len(), 1);
        assert!(
            matches!(&ev[0], TmuxEvent::SessionChanged { session_id, name }
                if session_id == "$0" && name == "main"),
            "got {:?}",
            ev[0]
        );
    }

    #[test]
    fn dcs_prefix_stripped_from_first_line() {
        let mut p = ControlModeParser::new();
        // Real tmux first line: \x1bP1000p%begin <timestamp> 0 0
        let ev = p.feed_line("\x1bP1000p%begin 1730000000 0 0");
        assert_eq!(ev.len(), 1);
        assert!(matches!(&ev[0], TmuxEvent::BeginBlock(0)));
    }

    #[test]
    fn dcs_terminator_stripped() {
        let mut p = ControlModeParser::new();
        // ST (\x1b\) appended to %exit line at session end
        let ev = p.feed_line("%exit\x1b\\");
        assert_eq!(ev.len(), 1);
        assert!(matches!(&ev[0], TmuxEvent::Exit));
    }
}
