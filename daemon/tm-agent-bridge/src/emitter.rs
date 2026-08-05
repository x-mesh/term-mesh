//! Everything upstream sees claude's vocabulary, whoever produced it.
//!
//! Each CLI streams, and each calls it something else: claude emits the
//! Anthropic block/delta shape wrapped in `stream_event`, codex sends
//! `item/agentMessage/delta` with a bare `delta` string, kiro sends ACP
//! `agent_message_chunk`. Measured on one 60-word answer: codex, 163 deltas.
//! An app that learns all three learns them everywhere, so the translation
//! stops here and upstream keeps one vocabulary.

// Each method finds its caller as the bridges are ported; until then the
// compiler is right that some of them have none.
#![allow(dead_code)]

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::sync::{Arc, Mutex};

use serde_json::{json, Map, Value};

pub struct Emitter {
    events_file: Option<File>,
    /// Whether a streaming content block is currently open. `message_start`
    /// matters more than it looks: it tells a reader a new message is
    /// beginning, so a complete message arriving after a streamed one is not
    /// drawn twice.
    open_block: bool,
    /// Set only by tests, which read events instead of watching a pane.
    capture: Option<Arc<Mutex<Vec<Value>>>>,
}

impl Emitter {
    pub fn new(events_path: Option<&str>) -> std::io::Result<Self> {
        let events_file = match events_path {
            Some(path) => Some(OpenOptions::new().create(true).append(true).open(path)?),
            None => None,
        };
        Ok(Self {
            events_file,
            open_block: false,
            capture: None,
        })
    }

    pub fn emit(&mut self, obj: Value) {
        let line = serde_json::to_string(&obj).unwrap_or_else(|_| "{}".to_string());
        if let Some(file) = self.events_file.as_mut() {
            let _ = writeln!(file, "{line}");
            let _ = file.flush();
        }
        if let Some(capture) = self.capture.as_ref() {
            capture.lock().unwrap().push(obj);
            return;
        }
        // stdout is the pane, and the renderer downstream reads the same shape.
        println!("{line}");
        let _ = std::io::stdout().flush();
    }

    pub fn text(&mut self, s: &str) {
        if s.trim().is_empty() {
            return;
        }
        self.emit(json!({
            "type": "assistant",
            "message": {"content": [{"type": "text", "text": s}]},
        }));
    }

    /// Open a tool row for a call that is a line of shell.
    ///
    /// The id is what lets a result land on the call it answers. Without it
    /// the row it opened never closes, and a spinner spins forever.
    pub fn tool_command(&mut self, name: &str, headline: &str, call_id: &str) {
        let mut input = Map::new();
        input.insert("command".into(), Value::String(headline.to_string()));
        self.tool_block(name, Value::Object(input), call_id);
    }

    /// Open a tool row for a call that knows more than a line of text — a
    /// path, a patch, which of add/update/delete it is.
    ///
    /// The fields go through as written, because the reader downstream picks
    /// its own field out of them rather than being handed a sentence to
    /// re-parse. Separate from [`Self::tool_command`] on purpose: the reader
    /// tries `command` first, so a `command` present at all hides the path
    /// behind it. Two methods make sending both impossible rather than merely
    /// discouraged.
    pub fn tool_fields(&mut self, name: &str, fields: Map<String, Value>, call_id: &str) {
        self.tool_block(name, Value::Object(fields), call_id);
    }

    fn tool_block(&mut self, name: &str, input: Value, call_id: &str) {
        let mut block = Map::new();
        block.insert("type".into(), Value::String("tool_use".into()));
        block.insert("name".into(), Value::String(name.to_string()));
        block.insert("input".into(), input);
        if !call_id.is_empty() {
            block.insert("id".into(), Value::String(call_id.to_string()));
        }
        self.emit(json!({
            "type": "assistant",
            "message": {"content": [Value::Object(block)]},
        }));
    }

    pub fn tool_result(&mut self, body: &str, failed: bool, call_id: &str) {
        let mut block = Map::new();
        block.insert("type".into(), Value::String("tool_result".into()));
        block.insert("content".into(), Value::String(body.to_string()));
        block.insert("is_error".into(), Value::Bool(failed));
        if !call_id.is_empty() {
            block.insert("tool_use_id".into(), Value::String(call_id.to_string()));
        }
        self.emit(json!({
            "type": "user",
            "message": {"content": [Value::Object(block)]},
        }));
    }

    pub fn turn_begins(&mut self) {
        self.emit(json!({
            "type": "stream_event",
            "event": {"type": "message_start", "message": {"role": "assistant"}},
        }));
        self.open_block = false;
    }

    pub fn delta(&mut self, text: &str, thinking: bool) {
        if text.is_empty() {
            return;
        }
        let key = if thinking { "thinking" } else { "text" };
        if !self.open_block {
            self.emit(json!({
                "type": "stream_event",
                "event": {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": key},
                },
            }));
            self.open_block = true;
        }
        self.emit(json!({
            "type": "stream_event",
            "event": {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": format!("{key}_delta"), key: text},
            },
        }));
    }

    pub fn block_done(&mut self) {
        if self.open_block {
            self.emit(json!({
                "type": "stream_event",
                "event": {"type": "content_block_stop", "index": 0},
            }));
            self.open_block = false;
        }
    }

    pub fn sent(&mut self, s: &str) {
        self.emit(json!({
            "type": "user",
            "message": {"role": "user", "content": s},
            "isReplay": true,
        }));
    }

    pub fn result(&mut self, final_text: &str, stop: &str, cost: Option<f64>, failed: bool) {
        let mut obj = Map::new();
        obj.insert("type".into(), Value::String("result".into()));
        obj.insert(
            "subtype".into(),
            Value::String(if failed { "error" } else { "success" }.into()),
        );
        obj.insert("is_error".into(), Value::Bool(failed));
        obj.insert("stop_reason".into(), Value::String(stop.to_string()));
        obj.insert("result".into(), Value::String(final_text.to_string()));
        if let Some(cost) = cost {
            if let Some(n) = serde_json::Number::from_f64(cost) {
                obj.insert("total_cost_usd".into(), Value::Number(n));
            }
        }
        self.emit(Value::Object(obj));
    }
}

#[cfg(test)]
pub mod testing {
    use super::*;

    /// An emitter that keeps what it was told instead of printing it.
    pub fn captured() -> (Emitter, Arc<Mutex<Vec<Value>>>) {
        let sink = Arc::new(Mutex::new(Vec::new()));
        let emitter = Emitter {
            events_file: None,
            open_block: false,
            capture: Some(Arc::clone(&sink)),
        };
        (emitter, sink)
    }

    /// Every content block of the given kind, across all captured events.
    pub fn blocks(events: &Arc<Mutex<Vec<Value>>>, kind: &str) -> Vec<Value> {
        let events = events.lock().unwrap();
        let mut found = Vec::new();
        for event in events.iter() {
            let Some(content) = event
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(Value::as_array)
            else {
                continue;
            };
            for block in content {
                if block.get("type").and_then(Value::as_str) == Some(kind) {
                    found.push(block.clone());
                }
            }
        }
        found
    }
}

#[cfg(test)]
mod tests {
    use super::testing::{blocks, captured};
    use super::*;

    #[test]
    fn a_headline_caller_still_gets_the_old_shape() {
        let (mut out, sink) = captured();

        out.tool_command("shell", "ls -l", "c1");

        let block = &blocks(&sink, "tool_use")[0];
        assert_eq!(block["input"], json!({"command": "ls -l"}));
        assert_eq!(block["id"], "c1");
    }

    #[test]
    fn a_structured_caller_gets_its_fields_through_unchanged() {
        let (mut out, sink) = captured();

        let mut fields = Map::new();
        fields.insert("file_path".into(), Value::String("/a.py".into()));
        out.tool_fields("edit", fields, "");

        let block = &blocks(&sink, "tool_use")[0];
        assert_eq!(block["input"], json!({"file_path": "/a.py"}));
        // No id was given, so none is invented — an id that answers nothing
        // would leave a row open forever.
        assert!(block.get("id").is_none());
    }

    #[test]
    fn a_tool_call_hands_over_its_input_rather_than_a_debug_rendering() {
        let (mut out, sink) = captured();

        let mut fields = Map::new();
        fields.insert("file_path".into(), Value::String("/repo/a.py".into()));
        fields.insert("old_string".into(), Value::String("x".into()));
        out.tool_fields("Edit File", fields, "t1");

        let block = &blocks(&sink, "tool_use")[0];
        assert_eq!(block["input"]["file_path"], "/repo/a.py");
        assert!(block["input"].get("command").is_none());
    }

    #[test]
    fn empty_text_is_not_an_event() {
        let (mut out, sink) = captured();

        out.text("   \n  ");
        out.delta("", false);

        assert!(sink.lock().unwrap().is_empty());
    }

    #[test]
    fn a_stream_opens_one_block_and_closes_it_once() {
        let (mut out, sink) = captured();

        out.turn_begins();
        out.delta("a", false);
        out.delta("b", false);
        out.block_done();
        out.block_done();

        let kinds: Vec<String> = sink
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| e["event"]["type"].as_str().map(str::to_string))
            .collect();
        assert_eq!(
            kinds,
            [
                "message_start",
                "content_block_start",
                "content_block_delta",
                "content_block_delta",
                "content_block_stop",
            ]
        );
    }

    #[test]
    fn a_new_turn_reopens_a_block_that_a_previous_turn_left_open() {
        let (mut out, sink) = captured();

        out.delta("first turn", false);
        out.turn_begins();
        out.delta("second turn", false);

        let starts = sink
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e["event"]["type"] == "content_block_start")
            .count();
        assert_eq!(starts, 2, "turn_begins has to reset the open block");
    }

    #[test]
    fn thinking_deltas_carry_their_own_key() {
        let (mut out, sink) = captured();

        out.delta("pondering", true);

        let events = sink.lock().unwrap();
        assert_eq!(events[0]["event"]["content_block"]["type"], "thinking");
        assert_eq!(events[1]["event"]["delta"]["type"], "thinking_delta");
        assert_eq!(events[1]["event"]["delta"]["thinking"], "pondering");
    }

    #[test]
    fn a_result_says_whether_it_failed_in_both_places() {
        let (mut out, sink) = captured();

        out.result("boom", "failed", None, true);
        out.result("fine", "end_turn", Some(0.25), false);

        let events = sink.lock().unwrap();
        assert_eq!(events[0]["subtype"], "error");
        assert_eq!(events[0]["is_error"], true);
        assert_eq!(events[0]["result"], "boom");
        assert!(events[0].get("total_cost_usd").is_none());
        assert_eq!(events[1]["subtype"], "success");
        assert_eq!(events[1]["total_cost_usd"], 0.25);
    }
}
