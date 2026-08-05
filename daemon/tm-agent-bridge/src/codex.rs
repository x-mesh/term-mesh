//! codex: `thread/start` → `turn/start` … `turn/completed`.

#![allow(dead_code)]

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Map, Value};

use crate::emitter::Emitter;
use crate::jsonrpc::JsonRpc;
use crate::text::{clamp, DIFF_LIMIT, TEXT_LIMIT};
use crate::transport::Transport;

const START_TIMEOUT: Duration = Duration::from_secs(30);

/// What to say when codex asks permission, as `(field, yes, no)`.
///
/// There is nobody at this end of the pipe to ask: the pane runs an agent, not
/// a person watching for a prompt, so an unanswered request is a turn that
/// never ends.
///
/// This is not a new posture, it is the existing one said over JSON-RPC. The
/// app already hands the codex TUI `--ask-for-approval never --sandbox
/// danger-full-access`, claude `--dangerously-skip-permissions`, kiro
/// `--trust-all-tools`, gemini `--yolo`. A bridge that alone withheld consent
/// would not be safer — it would be the one CLI whose pane quietly stopped,
/// which is the symptom this is fixing.
const APPROVALS: &[(&str, &str, &str, &str)] = &[
    ("item/fileChange/requestApproval", "decision", "accept", "decline"),
    ("item/commandExecution/requestApproval", "decision", "accept", "decline"),
    // Pre-v2 names. A current server never sends these; an older one sends
    // nothing else.
    ("applyPatchApproval", "decision", "approved", "denied"),
    ("execCommandApproval", "decision", "approved", "denied"),
];

/// Answer a request codex is blocked on.
///
/// `TERMMESH_AGENT_APPROVALS=ask` declines instead. Nothing here can put the
/// question to a person, so declining is the honest other answer: the turn
/// ends and says it was refused, rather than hanging.
pub fn serve_request(obj: &Value) -> Option<Value> {
    let method = obj.get("method").and_then(Value::as_str).unwrap_or("");
    let ask = std::env::var("TERMMESH_AGENT_APPROVALS").as_deref() == Ok("ask");

    if let Some((_, key, yes, no)) = APPROVALS.iter().find(|(name, ..)| *name == method) {
        let answer = if ask { no } else { yes };
        return Some(json!({ *key: *answer }));
    }

    match method {
        "item/permissions/requestApproval" => {
            if ask {
                return Some(json!({"permissions": {}, "scope": "turn"}));
            }
            // Grant what was asked for and no more. Widening a request we did
            // not read is not ours to do.
            let asked = obj
                .get("params")
                .and_then(|p| p.get("permissions"))
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            let granted: Map<String, Value> = asked
                .into_iter()
                .filter(|(_, v)| !v.is_null())
                .collect();
            Some(json!({"permissions": granted, "scope": "session"}))
        }
        // An MCP server asking the *user* something. We cannot ask, and
        // inventing an answer would put words in their mouth. Declining is a
        // thing servers know how to handle; silence is not — and this one
        // arrives whatever the approval policy says, so it is its own way for
        // a pane to stop.
        "mcpServer/elicitation/request" => {
            Some(json!({"action": "decline", "content": null, "_meta": null}))
        }
        "currentTime/read" => {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            Some(json!({"currentTimeAt": now}))
        }
        _ => None,
    }
}

fn change_tool(kind: &str) -> &'static str {
    match kind {
        "add" => "write",
        "update" => "edit",
        "delete" => "delete",
        _ => "edit",
    }
}

/// One row per file, because that is how an edit is read.
///
/// Codex reports a *patch*: `changes` is a list, and each entry carries the
/// path, which of add/update/delete it is, and that file's unified diff. There
/// is no `path` on the item itself — which is why the row that read one drew a
/// tool name against an empty line, and why the empty result sent after it
/// took the disclosure control away too, leaving a row that announced an edit
/// and then refused to say which file, let alone what.
///
/// The diff goes out twice on purpose: in the call's input, where a reader
/// that can draw a diff finds it under `unified_diff`, and in the result,
/// where a reader that cannot still has the text.
pub fn file_change(out: &mut Emitter, item: &Value) {
    let item_id = item
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let failed = matches!(
        item.get("status").and_then(Value::as_str),
        Some("failed") | Some("declined")
    );
    let Some(changes) = item.get("changes").and_then(Value::as_array) else {
        return;
    };

    for (index, change) in changes.iter().enumerate() {
        let Some(change) = change.as_object() else {
            continue;
        };
        let path = change
            .get("path")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let kind = change.get("kind");
        let name = kind
            .and_then(|k| k.get("type"))
            .and_then(Value::as_str)
            .or_else(|| kind.and_then(Value::as_str))
            .unwrap_or("update")
            .to_string();
        let raw = change
            .get("diff")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let diff = clamp(&raw, DIFF_LIMIT);

        let mut fields = Map::new();
        fields.insert("file_path".into(), Value::String(path.clone()));
        fields.insert("kind".into(), Value::String(name.clone()));
        fields.insert("unified_diff".into(), Value::String(diff.clone()));
        if let Some(move_path) = kind.and_then(|k| k.get("move_path")).and_then(Value::as_str) {
            fields.insert("move_path".into(), Value::String(move_path.to_string()));
        }
        if diff != raw {
            fields.insert("diff_truncated".into(), Value::Bool(true));
        }

        // One item, several files, and a result has to find the row it
        // answers — so the item's own id is not enough to go around.
        let cid = if item_id.is_empty() {
            String::new()
        } else {
            format!("{item_id}#{index}")
        };
        out.tool_fields(change_tool(&name), fields, &cid);
        // An empty result closes a row with nothing under it, which is the
        // shape this was fixing. Say what happened instead.
        let body = if diff.is_empty() {
            format!("{name} {path}").trim().to_string()
        } else {
            diff
        };
        out.tool_result(&body, failed, &cid);
    }
}

/// Whether an `error` notification was the end of the turn or one attempt
/// failing along the way.
#[derive(Debug, Clone)]
pub struct TurnError {
    pub retrying: bool,
    pub detail: String,
}

/// Why `turn/completed` says the turn did not succeed, if it did not.
pub fn turn_failure(done: Option<&Value>) -> Option<String> {
    let turn = done?.get("params")?.get("turn")?;
    if turn.get("status").and_then(Value::as_str) != Some("failed") {
        return None;
    }
    let message = turn
        .get("error")
        .and_then(|e| e.get("message"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    Some(if message.is_empty() {
        "codex ended the turn as failed without saying why".to_string()
    } else {
        message
    })
}

/// The one sentence for why a turn ended, in order of finality.
///
/// A terminal `error` first: it is the only one that can carry detail the turn
/// object drops. Then the completed turn itself. A retry line ranks last and
/// is used only when nothing else accounts for the failure — reporting one as
/// the outcome describes an attempt, not an ending.
pub fn failure_reason(errors: &[TurnError], done: Option<&Value>) -> Option<String> {
    if let Some(terminal) = errors.iter().find(|e| !e.retrying) {
        return Some(terminal.detail.clone());
    }
    turn_failure(done).or_else(|| errors.last().map(|e| e.detail.clone()))
}

pub struct CodexBridge<T: Transport> {
    pub rpc: JsonRpc<T>,
    pub out: Emitter,
    pub cwd: String,
    pub model: Option<String>,
    pub thread_id: Option<String>,
}

impl<T: Transport> CodexBridge<T> {
    pub fn new(child: T, out: Emitter, cwd: &str, model: Option<String>) -> Self {
        Self {
            rpc: JsonRpc::with_on_request(child, Box::new(serve_request)),
            out,
            cwd: cwd.to_string(),
            model,
            thread_id: None,
        }
    }

    pub fn start(&mut self) -> bool {
        let init = self.rpc.request(
            "initialize",
            Some(json!({"clientInfo": {"name": "term-mesh-bridge", "version": "0.1.0"}})),
            START_TIMEOUT,
            None,
        );
        match init.as_ref() {
            Some(reply) if reply.get("error").is_none() => {}
            _ => {
                log(&format!(
                    "codex initialize failed: {}",
                    describe(init.as_ref())
                ));
                return false;
            }
        }
        self.rpc.notify("initialized", None);

        // `sandbox`, not `sandboxPolicy`: that is `turn/start`'s field, and a
        // tagged object rather than a mode name. Named wrongly it is simply
        // ignored, and the difference only shows up as an agent that cannot
        // write anything.
        let started = self.rpc.request(
            "thread/start",
            Some(json!({
                "cwd": self.cwd,
                "approvalPolicy": "never",
                "sandbox": "danger-full-access",
            })),
            START_TIMEOUT,
            None,
        );
        self.thread_id = thread_id(started.as_ref());

        if self.thread_id.is_none() {
            // Measured: codex ignores a field it does not know, but rejects a
            // *value* it does not know outright. So if these names are ever
            // retired the thread never starts at all — and a pane that has to
            // ask permission beats no pane.
            log("codex would not start with an approval policy; retrying plain");
            let plain = self.rpc.request(
                "thread/start",
                Some(json!({"cwd": self.cwd})),
                START_TIMEOUT,
                None,
            );
            self.thread_id = thread_id(plain.as_ref());
            if self.thread_id.is_none() {
                log(&format!(
                    "codex thread/start gave no id: {}",
                    describe(plain.as_ref())
                ));
                return false;
            }
        }

        self.out.emit(json!({
            "type": "system",
            "subtype": "init",
            "cwd": self.cwd,
            "model": self.model.clone().unwrap_or_default(),
            "tools": [],
        }));
        true
    }

    pub fn turn(&mut self, text: &str, timeout: Duration) {
        // Split the borrows: the notify callback writes events while the rpc
        // reads frames, and they are different fields of the same struct.
        let Self {
            rpc,
            out,
            model,
            thread_id,
            ..
        } = self;

        out.sent(text);
        out.turn_begins();

        let mut said: Vec<String> = Vec::new();
        let mut streamed = false;
        let mut errors: Vec<TurnError> = Vec::new();

        let mut params = json!({
            "threadId": thread_id.clone().unwrap_or_default(),
            "input": [{"type": "text", "text": text}],
        });
        if let Some(model) = model.as_deref() {
            params["model"] = Value::String(model.to_string());
        }

        let mut notify = |o: &Value| {
            let method = o.get("method").and_then(Value::as_str).unwrap_or("");
            let p = o.get("params").cloned().unwrap_or(Value::Null);

            if method == "error" {
                // codex says why a turn died here, and says it *before* the
                // `turn/completed` that carries no items. Dropping this left
                // the empty item list as the only evidence, which reads as
                // "the model had nothing to say" — the one thing it does not
                // mean.
                //
                // `willRetry` separates an attempt that failed from the reason
                // the turn ends, and the two are not interchangeable: an
                // unusable model reports `Reconnecting... 1/5` first, so
                // taking the earliest error names a symptom and drops the
                // account that arrives once the retries run out.
                let detail = p
                    .get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_string();
                if !detail.is_empty() {
                    errors.push(TurnError {
                        retrying: p.get("willRetry").and_then(Value::as_bool).unwrap_or(false),
                        detail,
                    });
                }
                return;
            }

            if method == "item/agentMessage/delta" {
                if let Some(chunk) = p.get("delta").and_then(Value::as_str) {
                    if !chunk.is_empty() {
                        streamed = true;
                        said.push(chunk.to_string());
                        out.delta(chunk, false);
                    }
                }
                return;
            }

            if method == "item/completed" {
                let item = p.get("item").cloned().unwrap_or(Value::Null);
                let kind = item
                    .get("type")
                    .or_else(|| item.get("itemType"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                match kind {
                    "agentMessage" | "assistant_message" | "message" => {
                        // Already drawn delta by delta; the completed item is
                        // the same text arriving whole.
                        if streamed {
                            out.block_done();
                            return;
                        }
                        let body = match item.get("text").or_else(|| item.get("content")) {
                            Some(Value::String(s)) => s.clone(),
                            Some(Value::Array(blocks)) => blocks
                                .iter()
                                .filter_map(|b| b.get("text").and_then(Value::as_str))
                                .collect::<String>(),
                            _ => String::new(),
                        };
                        if !body.is_empty() {
                            said.push(body.clone());
                            out.text(&body);
                        }
                    }
                    "commandExecution" | "command_execution" => {
                        // One event, both halves: codex reports the finished
                        // item, so opening a row and leaving it open would
                        // spin forever.
                        let cid = item.get("id").and_then(Value::as_str).unwrap_or("");
                        let command = item.get("command").and_then(Value::as_str).unwrap_or("");
                        out.tool_command("shell", command, cid);
                        let failed = item
                            .get("exitCode")
                            .or_else(|| item.get("exit_code"))
                            .and_then(Value::as_i64)
                            .is_some_and(|c| c != 0);
                        let output = item
                            .get("aggregatedOutput")
                            .or_else(|| item.get("output"))
                            .and_then(Value::as_str)
                            .unwrap_or("");
                        out.tool_result(&clamp(output, TEXT_LIMIT), failed, cid);
                    }
                    "fileChange" | "file_change" => file_change(out, &item),
                    _ => {}
                }
            }
        };

        // `turn/start` acknowledges at once; the work arrives as notifications
        // and ends with `turn/completed`. Waiting on the response alone
        // measures how fast codex says "got it".
        let ack = rpc.request("turn/start", Some(params), START_TIMEOUT, Some(&mut notify));

        // A rejected turn still completes, instantly and with nothing said.
        // The first version of this reported that as a successful empty
        // answer — the same silent-success shape this whole exercise keeps
        // turning up. An unusable `--model` is the easy way to reproduce it.
        match ack.as_ref() {
            Some(reply) if reply.get("error").is_some() => {
                let detail = serde_json::to_string(&reply["error"]).unwrap_or_default();
                let detail = clamp(&detail, 300);
                log(&format!("codex refused the turn: {detail}"));
                out.result(&detail, "rejected", None, true);
                return;
            }
            None => {
                let failure = rpc.failure.clone();
                let (body, stop) = match failure {
                    Some(f) => (f, "process_exited"),
                    None => ("codex never acknowledged the turn".to_string(), "no_ack"),
                };
                out.result(&body, stop, None, true);
                return;
            }
            _ => {}
        }

        let done = rpc.pump(None, timeout, Some(&mut notify), Some("turn/completed"));
        out.block_done();

        let final_text = if streamed {
            said.concat()
        } else {
            said.join("\n")
        };

        // A failed turn already said why — twice, as the `error` notification
        // and again in the completed turn. Measured against a peer whose login
        // shell never exported the provider's API key: codex reported
        // `Missing environment variable: AI_MESH_API_KEY` in 75ms, and this
        // reported "the turn ended without an answer", which sent the search
        // everywhere except the cause. Say the reason, and keep whatever was
        // streamed ahead of it.
        if let Some(reason) = failure_reason(&errors, done.as_ref()) {
            let body = [final_text.trim(), reason.as_str()]
                .iter()
                .filter(|p| !p.is_empty())
                .cloned()
                .collect::<Vec<_>>()
                .join("\n\n");
            out.result(&body, "failed", None, true);
            return;
        }

        if done.is_some() && final_text.trim().is_empty() {
            // Ended without saying anything. Reporting that as a success is
            // how an empty answer becomes a completed task.
            out.result("the turn ended without an answer", "empty", None, true);
            return;
        }

        // `turn/completed` carries `{threadId, turn}` and no usage at all, so
        // there is no cost to report here. Reading one out of a key that does
        // not exist looked like the number was simply always zero.
        match (&done, &rpc.failure) {
            (None, Some(failure)) => {
                let body = if final_text.is_empty() {
                    failure.clone()
                } else {
                    final_text
                };
                out.result(&body, "process_exited", None, true);
            }
            (None, None) => out.result(&final_text, "timeout", None, true),
            (Some(_), _) => out.result(&final_text, "end_turn", None, false),
        }
    }
}

/// Nested: `{"result":{"thread":{"id":…}}}` — not `result.threadId`.
fn thread_id(started: Option<&Value>) -> Option<String> {
    let result = started?.get("result")?;
    result
        .get("thread")
        .and_then(|t| t.get("id"))
        .or_else(|| result.get("threadId"))
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn describe(reply: Option<&Value>) -> String {
    match reply {
        Some(v) => clamp(&serde_json::to_string(v).unwrap_or_default(), 160),
        None => "no reply".to_string(),
    }
}

/// Colour only for a terminal. When the app hosts this there is nothing to
/// interpret the escapes, and they would arrive as literal garbage in a view
/// that draws text rather than cells.
fn log(message: &str) {
    use std::io::IsTerminal;
    if std::io::stdout().is_terminal() {
        println!("\x1b[38;5;244m[bridge] {message}\x1b[0m");
    } else {
        println!("[bridge] {message}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::emitter::testing::{blocks, captured};
    use crate::transport::testing::ScriptedChild;
    use serde_json::json;
    use std::sync::{Arc, Mutex};

    fn file_change_item() -> Value {
        json!({
            "type": "fileChange",
            "id": "item-9",
            "status": "completed",
            "changes": [
                {"path": "/repo/new.py", "kind": {"type": "add"},
                 "diff": "@@ -0,0 +1,2 @@\n+one\n+two\n"},
                {"path": "/repo/old.py",
                 "kind": {"type": "update", "move_path": "/repo/moved.py"},
                 "diff": "@@ -1,2 +1,2 @@\n-before\n+after\n context\n"},
            ],
        })
    }

    fn bridge(frames: Vec<Value>) -> (CodexBridge<ScriptedChild>, Arc<Mutex<Vec<Value>>>) {
        let (out, sink) = captured();
        let mut bridge = CodexBridge::new(ScriptedChild::new(frames), out, "/tmp/project", None);
        bridge.thread_id = Some("thread-1".into());
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

    // ── the patch shape ────────────────────────────────────────────────

    #[test]
    fn a_patch_draws_a_row_per_file_carrying_its_diff() {
        let (mut out, sink) = captured();

        file_change(&mut out, &file_change_item());

        let calls = blocks(&sink, "tool_use");
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0]["input"]["file_path"], "/repo/new.py");
        assert_eq!(calls[0]["name"], "write");
        assert!(calls[0]["input"]["unified_diff"]
            .as_str()
            .unwrap()
            .contains("+one"));
        assert_eq!(calls[1]["input"]["move_path"], "/repo/moved.py");
        // Two files under one item still need distinct ids, or a result lands
        // on the wrong row.
        assert_ne!(calls[0]["id"], calls[1]["id"]);
    }

    #[test]
    fn an_edit_carries_no_command_key() {
        let (mut out, sink) = captured();

        file_change(&mut out, &file_change_item());

        for call in blocks(&sink, "tool_use") {
            assert!(call["input"].get("command").is_none());
            assert!(call["input"]["file_path"].as_str().is_some_and(|p| !p.is_empty()));
        }
    }

    #[test]
    fn a_declined_patch_is_reported_as_a_failure() {
        let (mut out, sink) = captured();
        let mut item = file_change_item();
        item["status"] = json!("declined");

        file_change(&mut out, &item);

        assert!(blocks(&sink, "tool_result")
            .iter()
            .all(|r| r["is_error"] == true));
    }

    #[test]
    fn a_change_without_a_diff_still_says_what_happened() {
        let (mut out, sink) = captured();

        file_change(
            &mut out,
            &json!({"type": "fileChange", "id": "i", "changes": [
                {"path": "/repo/gone.py", "kind": {"type": "delete"}, "diff": ""}]}),
        );

        assert_eq!(blocks(&sink, "tool_result")[0]["content"], "delete /repo/gone.py");
    }

    #[test]
    fn a_malformed_item_is_dropped_rather_than_raised() {
        let (mut out, sink) = captured();

        file_change(&mut out, &json!({"type": "fileChange", "id": "i"}));
        file_change(&mut out, &json!({"type": "fileChange", "id": "i", "changes": "no"}));
        file_change(&mut out, &json!({"type": "fileChange", "id": "i", "changes": [null]}));

        assert!(blocks(&sink, "tool_use").is_empty());
    }

    #[test]
    fn a_truncated_patch_is_marked_as_truncated() {
        let (mut out, sink) = captured();
        let huge: String = (0..20000).map(|n| format!("+line {n}\n")).collect();

        file_change(
            &mut out,
            &json!({"type": "fileChange", "id": "i", "changes": [
                {"path": "/repo/big.py", "kind": {"type": "add"}, "diff": huge}]}),
        );

        assert_eq!(blocks(&sink, "tool_use")[0]["input"]["diff_truncated"], true);
    }

    #[test]
    fn a_completed_patch_item_reaches_the_mapping() {
        // The routing, not just the mapping: `item/completed` has to get here.
        let (mut b, sink) = bridge(vec![
            json!({"id": 1, "result": {}}),
            json!({"method": "item/completed", "params": {"item": file_change_item()}}),
            json!({"method": "turn/completed", "params": {"threadId": "t", "turn": {}}}),
        ]);

        b.turn("edit those files", Duration::from_secs(2));

        assert_eq!(blocks(&sink, "tool_use").len(), 2);
    }

    // ── approvals ──────────────────────────────────────────────────────

    #[test]
    fn an_approval_request_is_answered_not_merely_observed() {
        let answer = serve_request(&json!({
            "id": 7, "method": "item/fileChange/requestApproval",
            "params": {"itemId": "item-9"}}));

        assert_eq!(answer, Some(json!({"decision": "accept"})));
    }

    #[test]
    fn a_legacy_approval_uses_the_older_vocabulary() {
        assert_eq!(
            serve_request(&json!({"id": 3, "method": "applyPatchApproval"})),
            Some(json!({"decision": "approved"}))
        );
    }

    #[test]
    fn a_permission_request_grants_what_was_asked_and_no_more() {
        let answer = serve_request(&json!({
            "id": 5, "method": "item/permissions/requestApproval",
            "params": {"permissions": {"read": true, "write": null}}}))
        .expect("an answer");

        assert_eq!(answer["permissions"], json!({"read": true}));
        assert_eq!(answer["scope"], "session");
    }

    #[test]
    fn an_elicitation_is_declined_because_nobody_can_be_asked() {
        let answer = serve_request(&json!({"id": 2, "method": "mcpServer/elicitation/request"}))
            .expect("an answer");

        assert_eq!(answer["action"], "decline");
    }

    #[test]
    fn an_unknown_request_is_left_for_the_caller_to_refuse() {
        assert_eq!(serve_request(&json!({"id": 1, "method": "who/knows"})), None);
    }

    // ── thread start ───────────────────────────────────────────────────

    #[test]
    fn thread_start_asks_for_no_approvals() {
        let (mut b, _) = bridge(vec![
            json!({"id": 1, "result": {}}),
            json!({"id": 2, "result": {"thread": {"id": "thread-7"}}}),
        ]);

        assert!(b.start());

        let sent = b.rpc.child.sent.lock().unwrap().clone();
        let start = sent
            .iter()
            .find(|f| f["method"] == "thread/start")
            .expect("a thread/start");
        assert_eq!(start["params"]["approvalPolicy"], "never");
        // `sandbox`, not `sandboxPolicy`: named wrongly it is simply ignored.
        assert_eq!(start["params"]["sandbox"], "danger-full-access");
        assert_eq!(b.thread_id.as_deref(), Some("thread-7"));
    }

    #[test]
    fn thread_start_retries_without_the_policy_when_refused() {
        let (mut b, _) = bridge(vec![
            json!({"id": 1, "result": {}}),
            json!({"id": 2, "error": {"code": -32602, "message": "unknown value"}}),
            json!({"id": 3, "result": {"threadId": "thread-plain"}}),
        ]);

        assert!(b.start());

        let sent = b.rpc.child.sent.lock().unwrap().clone();
        let starts: Vec<&Value> = sent.iter().filter(|f| f["method"] == "thread/start").collect();
        assert_eq!(starts.len(), 2);
        assert!(starts[1]["params"].get("approvalPolicy").is_none());
        assert_eq!(b.thread_id.as_deref(), Some("thread-plain"));
    }

    // ── how a turn ends ────────────────────────────────────────────────

    #[test]
    fn a_streamed_answer_is_reported_once() {
        let (mut b, sink) = bridge(vec![
            json!({"id": 1, "result": {}}),
            json!({"method": "item/agentMessage/delta", "params": {"delta": "SMOKE"}}),
            json!({"method": "item/agentMessage/delta", "params": {"delta": "_OK"}}),
            json!({"method": "item/completed",
                   "params": {"item": {"type": "agentMessage", "text": "SMOKE_OK"}}}),
            json!({"method": "turn/completed",
                   "params": {"turn": {"status": "completed"}}}),
        ]);

        b.turn("say it", Duration::from_secs(2));

        let result = last_result(&sink);
        assert_eq!(result["result"], "SMOKE_OK");
        assert_eq!(result["stop_reason"], "end_turn");
        assert_eq!(result["is_error"], false);
    }

    #[test]
    fn an_error_notification_survives_into_the_result() {
        let (mut b, sink) = bridge(vec![
            json!({"id": 1, "result": {}}),
            json!({"method": "error",
                   "params": {"error": {"message": "Missing environment variable: `AI_MESH_API_KEY`."},
                              "willRetry": false}}),
            json!({"method": "turn/completed", "params": {"turn": {"status": "failed"}}}),
        ]);

        b.turn("do work", Duration::from_secs(2));

        let result = last_result(&sink);
        assert_eq!(result["stop_reason"], "failed");
        assert!(result["result"].as_str().unwrap().contains("AI_MESH_API_KEY"));
    }

    #[test]
    fn a_failed_turn_object_alone_is_enough() {
        let (mut b, sink) = bridge(vec![
            json!({"id": 1, "result": {}}),
            json!({"method": "turn/completed",
                   "params": {"turn": {"status": "failed",
                                       "error": {"message": "model not found"}}}}),
        ]);

        b.turn("do work", Duration::from_secs(2));

        assert_eq!(last_result(&sink)["result"], "model not found");
    }

    #[test]
    fn a_retry_line_loses_to_the_reason_the_turn_actually_ended() {
        let (mut b, sink) = bridge(vec![
            json!({"id": 1, "result": {}}),
            json!({"method": "error",
                   "params": {"error": {"message": "Reconnecting... 1/5"}, "willRetry": true}}),
            json!({"method": "turn/completed",
                   "params": {"turn": {"status": "failed",
                                       "error": {"message": "404: model not found"}}}}),
        ]);

        b.turn("do work", Duration::from_secs(2));

        assert_eq!(last_result(&sink)["result"], "404: model not found");
    }

    #[test]
    fn text_streamed_before_the_failure_is_kept() {
        let (mut b, sink) = bridge(vec![
            json!({"id": 1, "result": {}}),
            json!({"method": "item/agentMessage/delta", "params": {"delta": "got this far"}}),
            json!({"method": "error",
                   "params": {"error": {"message": "provider went away"}, "willRetry": false}}),
            json!({"method": "turn/completed", "params": {"turn": {"status": "failed"}}}),
        ]);

        b.turn("do work", Duration::from_secs(2));

        let body = last_result(&sink)["result"].as_str().unwrap().to_string();
        assert!(body.contains("got this far"));
        assert!(body.contains("provider went away"));
    }

    #[test]
    fn an_empty_turn_that_did_not_fail_still_reads_as_empty() {
        let (mut b, sink) = bridge(vec![
            json!({"id": 1, "result": {}}),
            json!({"method": "turn/completed", "params": {"turn": {"status": "completed"}}}),
        ]);

        b.turn("do work", Duration::from_secs(2));

        let result = last_result(&sink);
        assert_eq!(result["stop_reason"], "empty");
        assert_eq!(result["result"], "the turn ended without an answer");
    }

    #[test]
    fn a_rejected_turn_is_not_a_successful_empty_answer() {
        let (mut b, sink) = bridge(vec![
            json!({"id": 1, "error": {"code": -32602, "message": "unusable model"}}),
        ]);

        b.turn("do work", Duration::from_secs(2));

        let result = last_result(&sink);
        assert_eq!(result["stop_reason"], "rejected");
        assert!(result["result"].as_str().unwrap().contains("unusable model"));
    }

    #[test]
    fn a_child_that_dies_mid_turn_reports_why() {
        // Acknowledged, then gone: the stream closes with no turn/completed
        // behind it. Reporting that as a timeout would blame the clock for a
        // crash.
        let (out, sink) = captured();
        let mut child = ScriptedChild::new(vec![json!({"id": 1, "result": {}})]);
        child.alive = false;
        child.exit = Some(7);
        let mut b = CodexBridge::new(child, out, "/tmp/project", None);
        b.thread_id = Some("thread-1".into());

        b.turn("do work", Duration::from_secs(2));

        let result = last_result(&sink);
        assert_eq!(result["stop_reason"], "process_exited");
        assert_eq!(result["is_error"], true);
    }

    #[test]
    fn a_turn_that_never_completes_is_a_timeout_not_a_crash() {
        let (out, sink) = captured();
        // Still running, still silent — the other half of the pair above.
        let (child, _keep_open) = ScriptedChild::sender(vec![json!({"id": 1, "result": {}})]);
        let mut b = CodexBridge::new(child, out, "/tmp/project", None);
        b.thread_id = Some("thread-1".into());

        b.turn("do work", Duration::from_millis(150));

        assert_eq!(last_result(&sink)["stop_reason"], "timeout");
    }

    #[test]
    fn a_command_row_carries_its_output_and_exit_status() {
        let (mut b, sink) = bridge(vec![
            json!({"id": 1, "result": {}}),
            json!({"method": "item/completed", "params": {"item": {
                "type": "commandExecution", "id": "c1", "command": "ls -l",
                "exitCode": 2, "aggregatedOutput": "no such file"}}}),
            json!({"method": "turn/completed", "params": {"turn": {"status": "completed"}}}),
        ]);

        b.turn("run it", Duration::from_secs(2));

        let call = &blocks(&sink, "tool_use")[0];
        assert_eq!(call["input"]["command"], "ls -l");
        let result = &blocks(&sink, "tool_result")[0];
        assert_eq!(result["content"], "no such file");
        assert_eq!(result["is_error"], true);
    }
}
