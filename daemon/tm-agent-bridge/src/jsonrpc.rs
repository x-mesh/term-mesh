//! JSON-RPC over the child's stdio, in both directions.

#![allow(dead_code)]

use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::location::remote_launch_failure;
use crate::transport::{Inbound, Transport};

/// How long a single read waits before checking whether the child is still
/// there. A dead child stops producing frames without closing anything the
/// reader would notice promptly, so the wait is chopped up rather than spent
/// in one block.
const POLL_SLICE: Duration = Duration::from_millis(250);

/// Answers a request coming the other way. `None` refuses it.
pub type OnRequest = Box<dyn FnMut(&Value) -> Option<Value> + Send>;

pub struct JsonRpc<T: Transport> {
    pub child: T,
    next_id: u64,
    /// Why the session ended, once it has. Read by the bridge to turn a dead
    /// child into a result a person can act on.
    pub failure: Option<String>,
    on_request: Option<OnRequest>,
}

impl<T: Transport> JsonRpc<T> {
    pub fn new(child: T) -> Self {
        Self {
            child,
            next_id: 0,
            failure: None,
            on_request: None,
        }
    }

    pub fn with_on_request(child: T, on_request: OnRequest) -> Self {
        Self {
            child,
            next_id: 0,
            failure: None,
            on_request: Some(on_request),
        }
    }

    fn record_exit_failure(&mut self) {
        let code = self.child.exit_code();
        let failure = remote_launch_failure(code).map(str::to_string).or_else(|| {
            (code.is_some() || !self.child.alive()).then(|| self.child.failure_message())
        });
        self.failure = failure;
    }

    fn send(&mut self, payload: &Value) -> bool {
        match self.child.send(payload) {
            Ok(()) => true,
            Err(e) => {
                let message = e.to_string();
                self.failure = Some(if message.is_empty() {
                    "agent process exited".to_string()
                } else {
                    message
                });
                false
            }
        }
    }

    pub fn request(
        &mut self,
        method: &str,
        params: Option<Value>,
        timeout: Duration,
        on_notify: Option<&mut dyn FnMut(&Value)>,
    ) -> Option<Value> {
        self.next_id += 1;
        let rid = self.next_id;
        let mut payload = json!({"jsonrpc": "2.0", "id": rid, "method": method});
        if let Some(params) = params {
            payload["params"] = params;
        }
        if !self.send(&payload) {
            return None;
        }
        self.pump(Some(rid), timeout, on_notify, None)
    }

    pub fn notify(&mut self, method: &str, params: Option<Value>) {
        let mut payload = json!({"jsonrpc": "2.0", "method": method});
        if let Some(params) = params {
            payload["params"] = params;
        }
        self.send(&payload);
    }

    pub fn respond(&mut self, rid: Value, result: Option<Value>, error: Option<Value>) {
        let mut frame = json!({"jsonrpc": "2.0", "id": rid});
        match error {
            Some(error) => frame["error"] = error,
            None => frame["result"] = result.unwrap_or_else(|| json!({})),
        }
        self.send(&frame);
    }

    /// Answer a frame carrying *both* an id and a method.
    ///
    /// That is a request coming the other way, and a request is the one thing
    /// that cannot be dropped: the peer is blocked on the answer. Codex asks
    /// for approval this way, so a bridge that only ever listened left the
    /// patch unapplied — and with no patch applied there is no `item/completed`
    /// to draw, which is why an edit that plainly happened showed up as
    /// nothing at all.
    ///
    /// Anything the caller does not claim gets an error back rather than
    /// silence. A refused request fails a turn; an unanswered one hangs it,
    /// and a hung turn is the harder failure to read.
    fn serve(&mut self, obj: &Value) {
        let rid = obj.get("id").cloned().unwrap_or(Value::Null);
        let answer = self.on_request.as_mut().and_then(|handler| handler(obj));
        match answer {
            Some(result) => self.respond(rid, Some(result), None),
            None => {
                let method = obj.get("method").and_then(Value::as_str).unwrap_or("");
                self.respond(
                    rid,
                    None,
                    Some(json!({
                        "code": -32601,
                        "message": format!("unsupported request: {method}"),
                    })),
                );
            }
        }
    }

    /// Read until the answer we want, handing notifications to a callback.
    ///
    /// Every incoming frame is offered to `on_notify` — a streaming protocol
    /// says most of what it has to say there, and dropping notifications while
    /// waiting for a response would throw the session away.
    pub fn pump(
        &mut self,
        until_id: Option<u64>,
        timeout: Duration,
        mut on_notify: Option<&mut dyn FnMut(&Value)>,
        until_method: Option<&str>,
    ) -> Option<Value> {
        let deadline = Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return None;
            }
            let obj = match self.child.recv_timeout(remaining.min(POLL_SLICE)) {
                Ok(Inbound::Frame(obj)) => obj,
                Ok(Inbound::Eof) => {
                    self.record_exit_failure();
                    return None;
                }
                Err(RecvTimeoutError::Timeout) => {
                    if !self.child.alive() {
                        self.record_exit_failure();
                        return None;
                    }
                    continue;
                }
                Err(RecvTimeoutError::Disconnected) => {
                    self.record_exit_failure();
                    return None;
                }
            };

            let has_id = obj.get("id").is_some();
            let is_answer = has_id && (obj.get("result").is_some() || obj.get("error").is_some());
            if is_answer {
                if let Some(want) = until_id {
                    if obj.get("id").and_then(Value::as_u64) == Some(want) {
                        return Some(obj);
                    }
                }
                continue;
            }

            if let Some(method) = obj.get("method").and_then(Value::as_str) {
                let method = method.to_string();
                // A request is answered before anything else, because
                // everything queued behind one is waiting too.
                if has_id {
                    self.serve(&obj);
                }
                if let Some(notify) = on_notify.as_mut() {
                    notify(&obj);
                }
                if until_method == Some(method.as_str()) {
                    return Some(obj);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::location::AGENT_ENV_LOAD_EXIT;
    use crate::transport::testing::ScriptedChild;
    use crate::transport::{ChildExited, Inbound};
    use std::sync::mpsc::RecvTimeoutError;

    fn answered(child: &ScriptedChild) -> Vec<Value> {
        child
            .sent
            .lock()
            .unwrap()
            .iter()
            .filter(|f| f.get("result").is_some() || f.get("error").is_some())
            .cloned()
            .collect()
    }

    /// A child that is already gone before anything was asked of it.
    struct FailedChild {
        exit: i32,
    }

    impl Transport for FailedChild {
        fn send(&mut self, _obj: &Value) -> Result<(), ChildExited> {
            Err(ChildExited("agent process exited".into()))
        }
        fn recv_timeout(&self, _t: Duration) -> Result<Inbound, RecvTimeoutError> {
            Ok(Inbound::Eof)
        }
        fn alive(&self) -> bool {
            false
        }
        fn exit_code(&self) -> Option<i32> {
            Some(self.exit)
        }
        fn failure_message(&self) -> String {
            "agent process exited".into()
        }
    }

    #[test]
    fn remote_environment_exit_is_preserved_for_ui_result() {
        let mut rpc = JsonRpc::new(FailedChild {
            exit: AGENT_ENV_LOAD_EXIT,
        });

        assert!(rpc
            .pump(Some(1), Duration::from_millis(100), None, None)
            .is_none());
        assert_eq!(
            rpc.failure.as_deref(),
            Some("remote agent could not load ~/.config/term-mesh/agent-env")
        );
    }

    #[test]
    fn a_dead_child_turns_a_request_into_a_failure() {
        let mut rpc = JsonRpc::new(ScriptedChild::dead(9, "agent process exited with code 9"));

        assert!(rpc
            .request("turn/start", Some(json!({})), Duration::from_secs(1), None)
            .is_none());
        assert_eq!(
            rpc.failure.as_deref(),
            Some("agent process exited with code 9")
        );
    }

    #[test]
    fn a_request_gets_its_own_answer_and_not_another() {
        let mut rpc = JsonRpc::new(ScriptedChild::new(vec![
            json!({"id": 99, "result": {"wrong": true}}),
            json!({"id": 1, "result": {"right": true}}),
        ]));

        let answer = rpc
            .request("initialize", None, Duration::from_secs(1), None)
            .expect("an answer");

        assert_eq!(answer["result"]["right"], true);
    }

    #[test]
    fn notifications_reach_the_callback_while_waiting_for_an_answer() {
        let mut rpc = JsonRpc::new(ScriptedChild::new(vec![
            json!({"method": "item/started", "params": {}}),
            json!({"method": "item/completed", "params": {}}),
            json!({"id": 1, "result": {}}),
        ]));

        let mut seen: Vec<String> = Vec::new();
        let mut collect = |o: &Value| {
            seen.push(o["method"].as_str().unwrap_or("").to_string());
        };
        rpc.request(
            "turn/start",
            None,
            Duration::from_secs(1),
            Some(&mut collect),
        )
        .expect("an answer");

        assert_eq!(seen, ["item/started", "item/completed"]);
    }

    #[test]
    fn pump_can_stop_on_a_method_instead_of_an_id() {
        let mut rpc = JsonRpc::new(ScriptedChild::new(vec![
            json!({"method": "item/started"}),
            json!({"method": "turn/completed", "params": {"turn": {"status": "completed"}}}),
            json!({"method": "never/reached"}),
        ]));

        let done = rpc
            .pump(
                None,
                Duration::from_secs(1),
                None,
                Some("turn/completed"),
            )
            .expect("the completion");

        assert_eq!(done["params"]["turn"]["status"], "completed");
    }

    #[test]
    fn an_incoming_request_is_answered_not_merely_observed() {
        let mut rpc = JsonRpc::with_on_request(
            ScriptedChild::new(vec![
                json!({"id": 7, "method": "item/fileChange/requestApproval"}),
                json!({"id": 1, "result": {}}),
            ]),
            Box::new(|_| Some(json!({"decision": "accept"}))),
        );

        rpc.request("turn/start", None, Duration::from_secs(1), None);

        assert_eq!(
            answered(&rpc.child),
            [json!({"jsonrpc": "2.0", "id": 7, "result": {"decision": "accept"}})]
        );
    }

    #[test]
    fn an_unclaimed_request_gets_an_error_rather_than_silence() {
        // Silence hangs the peer, which is the harder failure to read.
        let mut rpc = JsonRpc::new(ScriptedChild::new(vec![
            json!({"id": 4, "method": "mcpServer/elicitation/request"}),
            json!({"id": 1, "result": {}}),
        ]));

        rpc.request("turn/start", None, Duration::from_secs(1), None);

        let answers = answered(&rpc.child);
        assert_eq!(answers.len(), 1);
        assert_eq!(answers[0]["error"]["code"], -32601);
        assert!(answers[0]["error"]["message"]
            .as_str()
            .unwrap()
            .contains("mcpServer/elicitation/request"));
    }

    #[test]
    fn a_notification_is_only_observed() {
        let mut rpc = JsonRpc::with_on_request(
            ScriptedChild::new(vec![
                json!({"method": "configWarning", "params": {}}),
                json!({"id": 1, "result": {}}),
            ]),
            Box::new(|_| Some(json!({"decision": "accept"}))),
        );

        rpc.request("turn/start", None, Duration::from_secs(1), None);

        // No id means nobody is waiting on an answer; sending one would be a
        // frame the peer never asked for.
        assert!(answered(&rpc.child).is_empty());
    }

    #[test]
    fn a_stream_that_ends_stops_the_wait_rather_than_burning_the_timeout() {
        let mut rpc = JsonRpc::new(ScriptedChild::new(vec![]));

        let started = Instant::now();
        let answer = rpc.pump(Some(1), Duration::from_secs(30), None, None);

        assert!(answer.is_none());
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "EOF has to end the wait, not wait it out"
        );
    }
}
