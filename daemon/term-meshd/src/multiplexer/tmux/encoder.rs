//! Per ADR 0002 §"Encoder contract" — builds tmux control-mode command strings.
//!
//! All functions return `String` values ready to be written to the tmux stdin
//! followed by a newline character.

/// Per ADR 0002: encode `bytes` as a `send-keys -t <pane_id> -H <hex...>` command.
///
/// `-H` instructs tmux to interpret the argument as a sequence of hex octets,
/// bypassing key-name lookup.  This is the safest way to send arbitrary bytes.
///
/// Example: `send_keys_hex("%1", b"ABC")` → `"send-keys -t %1 -H 41 42 43"`
pub fn send_keys_hex(pane_id: &str, bytes: &[u8]) -> String {
    let hex = bytes
        .iter()
        .map(|b| format!("{:02X}", b))
        .collect::<Vec<_>>()
        .join(" ");
    format!("send-keys -t {} -H {}", pane_id, hex)
}

/// Per ADR 0002: send a `refresh-client -C <cols>x<rows>` resize command.
///
/// This notifies tmux of the client terminal dimensions so it can reflow
/// pane layouts accordingly.
pub fn refresh_client_size(cols: u16, rows: u16) -> String {
    format!("refresh-client -C {}x{}", cols, rows)
}

/// Per ADR 0002: respond to a `%pause` notification by suspending or resuming
/// tmux's output to this client.
///
/// `paused = true`  → `refresh-client -A <pane_id>:on`   (pause acknowledged)
/// `paused = false` → `refresh-client -A <pane_id>:off`  (resume acknowledged)
pub fn refresh_client_pause(pane_id: &str, paused: bool) -> String {
    let flag = if paused { "on" } else { "off" };
    format!("refresh-client -A {}:{}", pane_id, flag)
}

/// Lift the global pause for all panes (`refresh-client -A :off`).
pub fn refresh_client_resume_all() -> String {
    "refresh-client -A :off".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn send_keys_hex_encodes_bytes() {
        assert_eq!(send_keys_hex("%1", b"ABC"), "send-keys -t %1 -H 41 42 43");
    }

    #[test]
    fn send_keys_hex_empty() {
        assert_eq!(send_keys_hex("%0", b""), "send-keys -t %0 -H ");
    }

    #[test]
    fn refresh_client_size_format() {
        assert_eq!(refresh_client_size(80, 24), "refresh-client -C 80x24");
        assert_eq!(refresh_client_size(220, 50), "refresh-client -C 220x50");
    }

    #[test]
    fn refresh_client_pause_on() {
        assert_eq!(refresh_client_pause("%1", true), "refresh-client -A %1:on");
    }

    #[test]
    fn refresh_client_pause_off() {
        assert_eq!(refresh_client_pause("%1", false), "refresh-client -A %1:off");
    }

    #[test]
    fn refresh_client_resume_all_format() {
        assert_eq!(refresh_client_resume_all(), "refresh-client -A :off");
    }
}
