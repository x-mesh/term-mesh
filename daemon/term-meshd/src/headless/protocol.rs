/// Protocol adapter for encoding messages to different CLI stdin formats.
pub trait AgentProtocol: Send + Sync {
    /// Encode a user message into the CLI's expected stdin format.
    fn encode_message(&self, text: &str) -> Vec<u8>;

    /// Optional handshake bytes to send immediately after spawn.
    /// Returns None if the CLI doesn't need a handshake.
    #[allow(dead_code)] // Trait interface for future protocol adapters
    fn handshake(&self) -> Option<Vec<u8>> {
        None
    }

    /// Whether the parent should close (drop) the child's stdin after sending a
    /// message. `codex exec -` reads the *entire* prompt from stdin and waits for
    /// EOF before it starts — so the parent must close stdin or codex hangs with
    /// no output. Stream-json CLIs (claude) keep stdin open for multi-turn input,
    /// so they return false.
    fn closes_stdin_after_message(&self) -> bool {
        false
    }

    /// Protocol name for logging/debugging.
    #[allow(dead_code)] // Trait interface for future protocol adapters
    fn name(&self) -> &'static str;
}

/// Claude Code stream-json protocol.
///
/// Input format: one JSON object per line on stdin.
/// `{"type":"user","message":{"role":"user","content":"..."}}`
pub struct ClaudeStreamJson;

impl AgentProtocol for ClaudeStreamJson {
    fn encode_message(&self, text: &str) -> Vec<u8> {
        let msg = serde_json::json!({
            "type": "user",
            "message": {
                "role": "user",
                "content": text,
            }
        });
        let mut bytes =
            serde_json::to_vec(&msg).expect("JSON serialization cannot fail for valid input");
        bytes.push(b'\n');
        bytes
    }

    fn name(&self) -> &'static str {
        "claude-stream-json"
    }
}

/// Codex `exec -` protocol.
///
/// `codex exec --json -` reads the prompt as plain text from stdin and only
/// begins once stdin hits EOF, then streams JSONL events on stdout. So the
/// adapter sends the raw prompt (no stream-json envelope) and signals that the
/// parent must close stdin after the message to deliver EOF.
pub struct CodexExecText;

impl AgentProtocol for CodexExecText {
    fn encode_message(&self, text: &str) -> Vec<u8> {
        let mut bytes = text.as_bytes().to_vec();
        bytes.push(b'\n');
        bytes
    }

    fn closes_stdin_after_message(&self) -> bool {
        true
    }

    fn name(&self) -> &'static str {
        "codex-exec-text"
    }
}

/// Create a protocol adapter for the given CLI name.
pub fn protocol_for(cli: &str) -> Box<dyn AgentProtocol> {
    match cli {
        "claude" => Box::new(ClaudeStreamJson),
        "codex" => Box::new(CodexExecText),
        // Phase 3: "kiro" | "gemini" => Box::new(AcpProtocol),
        other => {
            tracing::warn!(
                "no protocol adapter for CLI '{other}', falling back to claude-stream-json"
            );
            Box::new(ClaudeStreamJson)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_claude_encode() {
        let proto = ClaudeStreamJson;
        let bytes = proto.encode_message("hello world");
        let s = String::from_utf8(bytes).unwrap();
        assert!(s.ends_with('\n'));
        let v: serde_json::Value = serde_json::from_str(s.trim()).unwrap();
        assert_eq!(v["type"], "user");
        assert_eq!(v["message"]["role"], "user");
        assert_eq!(v["message"]["content"], "hello world");
    }

    #[test]
    fn test_claude_no_handshake() {
        let proto = ClaudeStreamJson;
        assert!(proto.handshake().is_none());
    }

    #[test]
    fn test_claude_keeps_stdin_open() {
        // claude is multi-turn stream-json: stdin must stay open.
        assert!(!ClaudeStreamJson.closes_stdin_after_message());
    }

    #[test]
    fn test_codex_encodes_raw_and_closes_stdin() {
        let proto = CodexExecText;
        let bytes = proto.encode_message("REVIEW THIS");
        // raw prompt text, no stream-json envelope
        assert_eq!(String::from_utf8(bytes).unwrap(), "REVIEW THIS\n");
        // codex exec - needs EOF before it starts
        assert!(proto.closes_stdin_after_message());
    }

    #[test]
    fn test_protocol_for_codex_is_codex_adapter() {
        assert_eq!(protocol_for("codex").name(), "codex-exec-text");
        assert_eq!(protocol_for("claude").name(), "claude-stream-json");
        // unknown falls back to claude (keeps stdin open — safe default)
        assert!(!protocol_for("mystery").closes_stdin_after_message());
    }
}
