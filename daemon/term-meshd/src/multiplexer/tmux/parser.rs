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

use super::layout::{parse_window_layout, WindowLayout};
use super::octal::unescape_octal;

/// State of the control-mode line parser.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParserState {
    Idle,
    /// Inside a `%begin <cmd_number>` … `%end` / `%error` block.
    InCommandBlock {
        cmd_number: u32,
    },
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
    /// Per ADR 0002 §"Layout Parser" — tmux emits this on every pane
    /// split / close / resize. Format:
    ///   `%layout-change @<window-id> <layout-string> [<visible-layout> <flags>]`
    /// We keep only the canonical layout. `raw` preserves the original
    /// string for debugging when the structured `layout` parse fails.
    LayoutChange {
        window_id: String,
        raw: String,
        layout: Option<WindowLayout>,
    },
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

fn parse_cmd_number_bytes(rest: &[u8]) -> u32 {
    std::str::from_utf8(rest).map(parse_cmd_number).unwrap_or(0)
}

fn split_extended_output_metadata_bytes(rest: &[u8]) -> Option<(&[u8], &[u8])> {
    let pane_sep = rest.iter().position(|b| *b == b' ')?;
    let pane_id = &rest[..pane_sep];
    let metadata_and_payload = &rest[pane_sep + 1..];
    let separator = metadata_and_payload.iter().position(|b| *b == b':')?;
    let payload = metadata_and_payload
        .get(separator + 1..)
        .unwrap_or_default()
        .strip_prefix(b" ")
        .unwrap_or_else(|| {
            metadata_and_payload
                .get(separator + 1..)
                .unwrap_or_default()
        });
    Some((pane_id, payload))
}

fn trim_ascii(bytes: &[u8]) -> &[u8] {
    let start = bytes
        .iter()
        .position(|b| !b.is_ascii_whitespace())
        .unwrap_or(bytes.len());
    let end = bytes
        .iter()
        .rposition(|b| !b.is_ascii_whitespace())
        .map(|idx| idx + 1)
        .unwrap_or(start);
    &bytes[start..end]
}

fn lossy_string(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
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
        Self {
            state: ParserState::Idle,
        }
    }

    /// Process a single line (without trailing newline) and return any events.
    ///
    /// Per ADR 0002 §"DCS framing": tmux wraps the entire control-mode stream
    /// in a DCS string (`\x1bP1000p` … `\x1b\\`).  The opening prefix appears
    /// on the very first line before the first `%begin`; the terminator `\x1b\\`
    /// may appear on the final `%exit` line.  Both are stripped here so the
    /// rest of the parser never sees raw DCS bytes.
    pub fn feed_line(&mut self, line: &str) -> Vec<TmuxEvent> {
        self.feed_line_bytes(line.as_bytes())
    }

    pub fn feed_line_bytes(&mut self, line: &[u8]) -> Vec<TmuxEvent> {
        let mut events = Vec::new();

        // Strip DCS opening prefix (\x1bP1000p) and/or closing ST (\x1b\).
        let line = line.strip_prefix(b"\x1bP1000p").unwrap_or(line);
        let line = line.strip_suffix(b"\x1b\\").unwrap_or(line);

        if let Some(rest) = line.strip_prefix(b"%begin ") {
            // Real tmux: "%begin <timestamp> <cmd-number> <flags>"
            // Simplified: "%begin <cmd-number>"
            let n = parse_cmd_number_bytes(rest);
            self.state = ParserState::InCommandBlock { cmd_number: n };
            events.push(TmuxEvent::BeginBlock(n));
            return events;
        }

        if let Some(rest) = line.strip_prefix(b"%end ") {
            let n = parse_cmd_number_bytes(rest);
            self.state = ParserState::Idle;
            events.push(TmuxEvent::EndBlock(n));
            return events;
        }

        if let Some(rest) = line.strip_prefix(b"%error ") {
            let n = parse_cmd_number_bytes(rest);
            self.state = ParserState::Idle;
            events.push(TmuxEvent::ErrorBlock(n));
            return events;
        }

        // Async notifications — only processed while Idle or InCommandBlock
        // (tmux can interleave notifications inside command blocks).
        if let Some(rest) = line.strip_prefix(b"%output ") {
            // Format: %output <pane-id> <escaped-payload>
            // pane-id starts with %, e.g. %1
            if let Some(sep) = rest.iter().position(|b| *b == b' ') {
                let pane_id = lossy_string(&rest[..sep]);
                let payload = &rest[sep + 1..];
                let bytes = unescape_octal(payload);
                events.push(TmuxEvent::Output { pane_id, bytes });
            }
            return events;
        }

        if let Some(rest) = line.strip_prefix(b"%extended-output ") {
            // Format: %extended-output <pane-id> <age> ... : <escaped-payload>
            // Ignore age/future fields up to the single ":" separator.
            if let Some((pane_id, payload)) = split_extended_output_metadata_bytes(rest) {
                let bytes = unescape_octal(payload);
                events.push(TmuxEvent::Output {
                    pane_id: lossy_string(pane_id),
                    bytes,
                });
            }
            return events;
        }

        if let Some(rest) = line.strip_prefix(b"%pause") {
            let pane_id = lossy_string(trim_ascii(rest));
            events.push(TmuxEvent::Pause { pane_id });
            return events;
        }

        if let Some(rest) = line.strip_prefix(b"%continue") {
            let pane_id = lossy_string(trim_ascii(rest));
            events.push(TmuxEvent::Continue { pane_id });
            return events;
        }

        if let Some(rest) = line.strip_prefix(b"%session-changed ") {
            if let Some(sep) = rest.iter().position(|b| *b == b' ') {
                events.push(TmuxEvent::SessionChanged {
                    session_id: lossy_string(&rest[..sep]),
                    name: lossy_string(&rest[sep + 1..]),
                });
            } else {
                events.push(TmuxEvent::Unknown(lossy_string(line)));
            }
            return events;
        }

        if let Some(rest) = line.strip_prefix(b"%layout-change ") {
            // Format: %layout-change @<window-id> <layout> [<visible-layout> <flags>]
            // We only care about <window-id> + the first <layout> token.
            // Anything after the second space is informational and discarded.
            let mut fields = rest.splitn(3, |b| *b == b' ');
            let window_id = fields.next().map(lossy_string).unwrap_or_default();
            let raw = fields.next().map(lossy_string).unwrap_or_default();
            let layout = if raw.is_empty() {
                None
            } else {
                parse_window_layout(&raw).ok()
            };
            events.push(TmuxEvent::LayoutChange {
                window_id,
                raw,
                layout,
            });
            return events;
        }

        if line == b"%exit" {
            events.push(TmuxEvent::Exit);
            return events;
        }

        // Other Phase 1.0+ notifications fall through as Unknown.
        if line.starts_with(b"%") {
            events.push(TmuxEvent::Unknown(lossy_string(line)));
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
    fn output_line_preserves_non_utf8_payload_bytes() {
        let mut p = ControlModeParser::new();
        let ev = p.feed_line_bytes(b"%output %1 hello \xeb");
        assert_eq!(ev.len(), 1);
        if let TmuxEvent::Output { pane_id, bytes } = &ev[0] {
            assert_eq!(pane_id, "%1");
            assert_eq!(bytes, b"hello \xeb");
        } else {
            panic!("expected Output event, got {:?}", ev[0]);
        }
    }

    #[test]
    fn extended_output_line_parsed_with_unescape() {
        let mut p = ControlModeParser::new();
        let ev = p.feed_line("%extended-output %1 27 ignored future : hello\\012world");
        assert_eq!(ev.len(), 1);
        if let TmuxEvent::Output { pane_id, bytes } = &ev[0] {
            assert_eq!(pane_id, "%1");
            assert_eq!(bytes, b"hello\nworld");
        } else {
            panic!("expected Output event, got {:?}", ev[0]);
        }
    }

    #[test]
    fn extended_output_accepts_separator_without_trailing_space() {
        let mut p = ControlModeParser::new();
        let ev = p.feed_line("%extended-output %1 27:hello\\012world");
        assert_eq!(ev.len(), 1);
        if let TmuxEvent::Output { pane_id, bytes } = &ev[0] {
            assert_eq!(pane_id, "%1");
            assert_eq!(bytes, b"hello\nworld");
        } else {
            panic!("expected Output event, got {:?}", ev[0]);
        }
    }

    #[test]
    fn extended_output_accepts_separator_without_payload_space() {
        let mut p = ControlModeParser::new();
        let ev = p.feed_line("%extended-output %1 27 ignored future :hello\\012world");
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
        assert_eq!(
            ev,
            vec![TmuxEvent::Pause {
                pane_id: "%2".to_string()
            }]
        );
    }

    #[test]
    fn unknown_notification_stored() {
        let mut p = ControlModeParser::new();
        // A real notification we haven't whitelisted — the channel still
        // surfaces it so debug logs can flag it.
        let ev = p.feed_line("%window-renamed @0 dev");
        assert_eq!(ev.len(), 1);
        assert!(matches!(&ev[0], TmuxEvent::Unknown(s) if s.contains("window-renamed")));
    }

    #[test]
    fn layout_change_unparseable_payload_preserves_raw() {
        let mut p = ControlModeParser::new();
        let ev = p.feed_line("%layout-change @0 some-layout-data");
        assert_eq!(ev.len(), 1);
        match &ev[0] {
            TmuxEvent::LayoutChange {
                window_id,
                raw,
                layout,
            } => {
                assert_eq!(window_id, "@0");
                assert_eq!(raw, "some-layout-data");
                assert!(layout.is_none());
            }
            other => panic!("expected LayoutChange, got {other:?}"),
        }
    }

    #[test]
    fn layout_change_with_well_formed_layout_decodes_tree() {
        let mut p = ControlModeParser::new();
        let ev = p.feed_line("%layout-change @0 abcd,80x24,0,0,1");
        assert_eq!(ev.len(), 1);
        let TmuxEvent::LayoutChange {
            window_id,
            layout: Some(layout),
            ..
        } = &ev[0]
        else {
            panic!("expected LayoutChange with decoded layout, got {:?}", ev[0]);
        };
        assert_eq!(window_id, "@0");
        assert_eq!(layout.checksum, 0xabcd);
        assert_eq!(layout.root.pane_indices(), vec![1]);
    }

    #[test]
    fn layout_change_ignores_trailing_visible_layout_and_flags() {
        let mut p = ControlModeParser::new();
        let ev = p.feed_line(
            "%layout-change @0 abcd,80x24,0,0{40x24,0,0,0,40x24,40,0,1} efgh,80x24,0,0,1 *",
        );
        assert_eq!(ev.len(), 1);
        let TmuxEvent::LayoutChange {
            layout: Some(layout),
            ..
        } = &ev[0]
        else {
            panic!("expected LayoutChange, got {:?}", ev[0]);
        };
        assert_eq!(layout.root.pane_indices(), vec![0, 1]);
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
