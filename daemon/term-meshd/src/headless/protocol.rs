/// Protocol adapter for encoding messages to different CLI stdin formats.
pub trait AgentProtocol: Send + Sync {
    /// Encode a user message into the CLI's expected stdin format.
    fn encode_message(&self, text: &str) -> Vec<u8>;

    /// Optional handshake bytes to send immediately after spawn.
    /// Returns None if the CLI doesn't need a handshake.
    fn handshake(&self) -> Option<Vec<u8>> {
        None
    }

    /// Protocol name for logging/debugging.
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
        let mut bytes = serde_json::to_vec(&msg).expect("JSON serialization cannot fail for valid input");
        bytes.push(b'\n');
        bytes
    }

    fn name(&self) -> &'static str {
        "claude-stream-json"
    }
}

/// Create a protocol adapter for the given CLI name.
pub fn protocol_for(cli: &str) -> Box<dyn AgentProtocol> {
    match cli {
        "claude" => Box::new(ClaudeStreamJson),
        // Phase 3: "codex" => Box::new(CodexJsonRpc),
        // Phase 3: "kiro" | "gemini" => Box::new(AcpProtocol),
        other => {
            tracing::warn!("no protocol adapter for CLI '{other}', falling back to claude-stream-json");
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
}
