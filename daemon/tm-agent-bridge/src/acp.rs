//! kiro and gemini: ACP — `initialize` → `session/new` → `session/prompt`,
//! ending on a `stopReason`.

#![allow(dead_code)]

use std::collections::HashMap;
use std::time::Duration;

use serde_json::{json, Value};

use crate::emitter::Emitter;
use crate::jsonrpc::JsonRpc;
use crate::text::{acp_text, clamp, TEXT_LIMIT};
use crate::transport::Transport;

const INIT_TIMEOUT: Duration = Duration::from_secs(60);
const SESSION_TIMEOUT: Duration = Duration::from_secs(90);

pub struct AcpBridge<T: Transport> {
    pub rpc: JsonRpc<T>,
    pub out: Emitter,
    pub cwd: String,
    pub model: Option<String>,
    pub session: Option<String>,
}

impl<T: Transport> AcpBridge<T> {
    pub fn new(child: T, out: Emitter, cwd: &str, model: Option<String>) -> Self {
        Self {
            rpc: JsonRpc::new(child),
            out,
            cwd: cwd.to_string(),
            model,
            session: None,
        }
    }

    pub fn start(&mut self) -> bool {
        if let Some(event) = self.rpc.child.take_environment_diagnostic() {
            self.out.emit(event);
        }
        let init = self.rpc.request(
            "initialize",
            Some(json!({
                "protocolVersion": 1,
                "clientCapabilities": {"fs": {"readTextFile": false,
                                              "writeTextFile": false}},
            })),
            INIT_TIMEOUT,
            None,
        );
        match init.as_ref() {
            Some(reply) if reply.get("error").is_none() => {}
            _ => {
                crate::log(&format!("acp initialize failed: {}", describe(init.as_ref())));
                return false;
            }
        }

        let new = self.rpc.request(
            "session/new",
            Some(json!({"cwd": self.cwd, "mcpServers": []})),
            SESSION_TIMEOUT,
            None,
        );
        self.session = new
            .as_ref()
            .and_then(|r| r.get("result"))
            .and_then(|r| r.get("sessionId"))
            .and_then(Value::as_str)
            .map(str::to_string);
        if self.session.is_none() {
            crate::log(&format!("acp session/new failed: {}", describe(new.as_ref())));
            return false;
        }

        // ACP's handshake reports capabilities, not a model name, so the one
        // we were told to ask for is the only thing there is to say. Without
        // it the pane header has nothing but the agent's own name.
        self.out.emit(json!({
            "type": "system",
            "subtype": "init",
            "cwd": self.cwd,
            "model": self.model.clone().unwrap_or_default(),
            "tools": [],
        }));
        true
    }

    pub fn turn(&mut self, text: &str, timeout: Option<Duration>) {
        let Self {
            rpc, out, session, ..
        } = self;

        out.sent(text);
        out.turn_begins();

        let mut said = String::new();
        // A tool's output can arrive across several updates, before the one
        // that reports its status.
        let mut tool_output: HashMap<String, String> = HashMap::new();

        let mut notify = |o: &Value| {
            if o.get("method").and_then(Value::as_str) != Some("session/update") {
                return;
            }
            let update = o
                .get("params")
                .and_then(|p| p.get("update"))
                .cloned()
                .unwrap_or(Value::Null);
            let kind = update
                .get("sessionUpdate")
                .and_then(Value::as_str)
                .unwrap_or("");

            match kind {
                "agent_message_chunk" => {
                    // These were always chunks. Joining them and showing the
                    // result at the end threw away the one thing they were
                    // good for.
                    let chunk = update
                        .get("content")
                        .and_then(|c| c.get("text"))
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    said.push_str(chunk);
                    out.delta(chunk, false);
                }
                "tool_call" => {
                    let name = update
                        .get("title")
                        .and_then(Value::as_str)
                        .or_else(|| update.get("kind").and_then(Value::as_str))
                        .unwrap_or("tool")
                        .to_string();
                    let cid = update
                        .get("toolCallId")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    // Handing over a rendered object is what drew a debug
                    // representation where a path belongs. Give the reader the
                    // fields and let it pick its own.
                    match update.get("rawInput").and_then(Value::as_object) {
                        Some(fields) => out.tool_fields(&name, fields.clone(), &cid),
                        None => {
                            let headline = update
                                .get("rawInput")
                                .map(|v| clamp(&v.to_string(), 200))
                                .unwrap_or_default();
                            out.tool_command(&name, &headline, &cid);
                        }
                    }
                }
                "tool_call_update" => {
                    let cid = update
                        .get("toolCallId")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    // ACP's content is a list of content blocks, sometimes
                    // nested one deeper. Rendering it gave a debug string —
                    // or, when it arrived on an earlier update than the
                    // status, nothing at all, which is why these rows closed
                    // with no output.
                    let text = acp_text(update.get("content").unwrap_or(&Value::Null));
                    if !text.is_empty() {
                        tool_output.entry(cid.clone()).or_default().push_str(&text);
                    }
                    let status = update.get("status").and_then(Value::as_str);
                    if matches!(status, Some("completed") | Some("failed")) {
                        let body = tool_output.remove(&cid).unwrap_or_default();
                        out.tool_result(
                            &clamp(&body, TEXT_LIMIT),
                            status == Some("failed"),
                            &cid,
                        );
                    }
                }
                _ => {}
            }
        };

        let response = rpc.request_with_timeout(
            "session/prompt",
            Some(json!({
                "sessionId": session.clone().unwrap_or_default(),
                "prompt": [{"type": "text", "text": text}],
            })),
            timeout,
            Some(&mut notify),
        );
        out.block_done();

        let stop = response
            .as_ref()
            .and_then(|r| r.get("result"))
            .and_then(|r| r.get("stopReason"))
            .and_then(Value::as_str)
            .unwrap_or("timeout")
            .to_string();

        match (&response, &rpc.failure) {
            (None, Some(failure)) => {
                let body = if said.is_empty() {
                    failure.clone()
                } else {
                    said.clone()
                };
                out.result(&body, "process_exited", None, true);
            }
            (None, None) => out.result(&said, &stop, None, true),
            (Some(_), _) => out.result(&said, &stop, None, false),
        }
    }
}

fn describe(reply: Option<&Value>) -> String {
    match reply {
        Some(v) => clamp(&serde_json::to_string(v).unwrap_or_default(), 220),
        None => "no reply".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::emitter::testing::{blocks, captured};
    use crate::transport::testing::ScriptedChild;
    use std::sync::{Arc, Mutex};

    fn bridge(frames: Vec<Value>) -> (AcpBridge<ScriptedChild>, Arc<Mutex<Vec<Value>>>) {
        let (out, sink) = captured();
        let mut bridge = AcpBridge::new(ScriptedChild::new(frames), out, "/tmp/project", None);
        bridge.session = Some("session-1".into());
        (bridge, sink)
    }

    fn last_result(sink: &Arc<Mutex<Vec<Value>>>) -> Value {
        sink.lock()
            .unwrap()
            .iter()
            .filter(|e| e["type"] == "result")
            .next_back()
            .cloned()
            .expect("a result")
    }

    fn update(update: Value) -> Value {
        json!({"method": "session/update", "params": {"update": update}})
    }

    #[test]
    fn a_session_is_opened_before_any_turn() {
        let (mut b, _) = bridge(vec![
            json!({"id": 1, "result": {}}),
            json!({"id": 2, "result": {"sessionId": "session-42"}}),
        ]);

        assert!(b.start());
        assert_eq!(b.session.as_deref(), Some("session-42"));
    }

    #[test]
    fn remote_environment_diagnostic_is_emitted_before_acp_init() {
        let event = json!({
            "type": "system", "subtype": "environment", "shell": "zsh",
            "profile_fallback": "loaded", "agent_env": "loaded", "present_keys": []
        });
        let (out, sink) = captured();
        let child = ScriptedChild::new(vec![
            json!({"id": 1, "result": {}}),
            json!({"id": 2, "result": {"sessionId": "session-42"}}),
        ]).with_environment_diagnostic(event.clone());
        let mut bridge = AcpBridge::new(child, out, "/tmp/project", None);

        assert!(bridge.start());
        assert_eq!(sink.lock().unwrap().first(), Some(&event));
    }

    #[test]
    fn a_refused_handshake_stops_before_a_session() {
        // Deliberately not the test helper: it pre-fills a session, and what
        // is being checked here is that none is ever opened.
        let (out, _sink) = captured();
        let mut b = AcpBridge::new(
            ScriptedChild::new(vec![json!({"id": 1, "error": {"code": -1}})]),
            out,
            "/tmp/project",
            None,
        );

        assert!(!b.start());
        assert!(b.session.is_none());
    }

    #[test]
    fn a_handshake_that_opens_no_session_is_a_failure_too() {
        let (out, _sink) = captured();
        let mut b = AcpBridge::new(
            ScriptedChild::new(vec![
                json!({"id": 1, "result": {}}),
                json!({"id": 2, "result": {"somethingElse": true}}),
            ]),
            out,
            "/tmp/project",
            None,
        );

        assert!(!b.start());
        assert!(b.session.is_none());
    }

    #[test]
    fn chunks_are_streamed_rather_than_held_to_the_end() {
        let (mut b, sink) = bridge(vec![
            update(json!({"sessionUpdate": "agent_message_chunk",
                          "content": {"type": "text", "text": "SMO"}})),
            update(json!({"sessionUpdate": "agent_message_chunk",
                          "content": {"type": "text", "text": "KE_OK"}})),
            json!({"id": 1, "result": {"stopReason": "end_turn"}}),
        ]);

        b.turn("say it", Some(Duration::from_secs(2)));

        let deltas: Vec<String> = sink
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e["event"]["type"] == "content_block_delta")
            .map(|e| e["event"]["delta"]["text"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(deltas, ["SMO", "KE_OK"]);
        let result = last_result(&sink);
        assert_eq!(result["result"], "SMOKE_OK");
        assert_eq!(result["stop_reason"], "end_turn");
    }

    #[test]
    fn a_tool_call_hands_over_its_input_rather_than_a_rendering() {
        let (mut b, sink) = bridge(vec![
            update(json!({"sessionUpdate": "tool_call", "toolCallId": "t1",
                          "title": "Edit File",
                          "rawInput": {"file_path": "/repo/a.py", "old_string": "x"}})),
            json!({"id": 1, "result": {"stopReason": "end_turn"}}),
        ]);

        b.turn("edit it", Some(Duration::from_secs(2)));

        let call = &blocks(&sink, "tool_use")[0];
        assert_eq!(call["input"]["file_path"], "/repo/a.py");
        assert!(call["input"].get("command").is_none());
    }

    #[test]
    fn output_arriving_before_the_status_still_reaches_the_row() {
        // This is why these rows used to close with nothing under them: the
        // content came on an earlier update than the one carrying the status.
        let (mut b, sink) = bridge(vec![
            update(json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1",
                          "content": [{"type": "content",
                                       "content": {"type": "text", "text": "part one "}}]})),
            update(json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1",
                          "content": [{"type": "text", "text": "part two"}]})),
            update(json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1",
                          "status": "completed"})),
            json!({"id": 1, "result": {"stopReason": "end_turn"}}),
        ]);

        b.turn("run it", Some(Duration::from_secs(2)));

        let results = blocks(&sink, "tool_result");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["content"], "part one part two");
        assert_eq!(results[0]["is_error"], false);
    }

    #[test]
    fn a_failed_tool_says_so() {
        let (mut b, sink) = bridge(vec![
            update(json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1",
                          "content": [{"type": "text", "text": "no such file"}],
                          "status": "failed"})),
            json!({"id": 1, "result": {"stopReason": "end_turn"}}),
        ]);

        b.turn("run it", Some(Duration::from_secs(2)));

        assert_eq!(blocks(&sink, "tool_result")[0]["is_error"], true);
    }

    #[test]
    fn a_child_that_dies_mid_turn_reports_why() {
        let (out, sink) = captured();
        let mut child = ScriptedChild::new(vec![]);
        child.alive = false;
        child.exit = Some(3);
        let mut b = AcpBridge::new(child, out, "/tmp/project", None);
        b.session = Some("session-1".into());

        b.turn("do work", Some(Duration::from_secs(2)));

        assert_eq!(last_result(&sink)["stop_reason"], "process_exited");
    }
}
