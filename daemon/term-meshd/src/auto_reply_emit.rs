//! Bridge from [`crate::auto_reply::AutoReplyEvent`] to the Swift app's team
//! RPCs. When the detector observes a 5-line header in agent terminal output
//! but the agent never invoked `tm-agent reply` itself, we synthesise the
//! equivalent here so the leader's `tm-agent wait` resolves.
//!
//! Sequence:
//! 0. STATUS must be exactly DONE | BLOCKED | NEEDS_REVIEW, else nothing is sent
//! 1. `team.task.list assignee=<agent>` — select the task (see [`select_task`]);
//!    when none is eligible nothing is written
//! 2. `team.report task_id=<id>` — writes the result file + posts a message
//! 3. `team.task.update` — set status (completed | blocked | review_ready) + result/reason;
//!    skipped when `team.report` failed
//!
//! Errors are logged but never propagate up — auto-reply is a best-effort
//! safety net; failure must not break the agent's PTY reader loop.

use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::time::timeout;

use crate::auto_reply::AutoReplyEvent;

const RPC_TIMEOUT: Duration = Duration::from_secs(5);
const RESULT_TRUNC_CHARS: usize = 1500;

/// Maps an agent STATUS verdict to the task status it sets. Exact match only —
/// a template echo such as `DONE|BLOCKED|NEEDS_REVIEW`, a lowercase or padded
/// value must not close a task (mirrors `AutoReplyDetector.validatedStatus`).
pub fn validated_status(status: &str) -> Option<&'static str> {
    match status {
        "DONE" => Some("completed"),
        "BLOCKED" => Some("blocked"),
        "NEEDS_REVIEW" => Some("review_ready"),
        _ => None,
    }
}

/// The task id named by a delegated task capsule: the first `TASK_ID:` line.
/// The autonomous `[TASK_ID] <id>` form is deliberately not recognised
/// (mirrors `AgentPipeCompletion.taskId(in:)`).
pub fn capsule_task_id(text: &str) -> Option<String> {
    let line = text
        .lines()
        .map(str::trim)
        .find(|l| l.starts_with("TASK_ID:"))?;
    let id = line["TASK_ID:".len()..].trim();
    (!id.is_empty()).then(|| id.to_string())
}

/// Picks the task an auto-reply may close. A known dispatched id is
/// authoritative: if it is gone from the assignee's list or already terminal,
/// nothing is selected rather than guessing another task. Without one, the
/// newest in_progress task wins, else the newest open task that is not
/// blocked or review_ready. Ties on `created_at` go to the later list entry.
pub fn select_task<'a>(tasks: &'a [Value], preferred: Option<&str>) -> Option<&'a Value> {
    fn field<'v>(t: &'v Value, key: &str) -> &'v str {
        t.get(key).and_then(Value::as_str).unwrap_or("")
    }
    let is_terminal = |t: &Value| {
        matches!(
            field(t, "status"),
            "completed" | "failed" | "abandoned" | "cancelled"
        )
    };
    let newest = |a: &&Value, b: &&Value| field(a, "created_at").cmp(field(b, "created_at"));

    if let Some(id) = preferred {
        return tasks
            .iter()
            .find(|t| field(t, "id") == id)
            .filter(|t| !is_terminal(t));
    }
    tasks
        .iter()
        .filter(|t| field(t, "status") == "in_progress")
        .max_by(newest)
        .or_else(|| {
            tasks
                .iter()
                .filter(|t| {
                    !is_terminal(t) && !matches!(field(t, "status"), "blocked" | "review_ready")
                })
                .max_by(newest)
        })
}

/// Send the synthesised reply to the Swift app socket. Returns `Ok(true)`
/// when a task was selected, reported and updated; `Ok(false)` when nothing
/// was written (invalid STATUS, or no eligible task); `Err` on RPC failure.
pub async fn emit(
    socket_path: &str,
    team_name: &str,
    agent_name: &str,
    event: &AutoReplyEvent,
    preferred_task_id: Option<&str>,
) -> Result<bool, String> {
    let Some(task_status) = validated_status(&event.status) else {
        return Ok(false);
    };
    let reply_text = format_reply_text(event);

    let tasks_resp = rpc_call(
        socket_path,
        "team.task.list",
        json!({
            "team_name": team_name,
            "assignee": agent_name,
        }),
    )
    .await
    .map_err(|e| format!("team.task.list failed: {e}"))?;

    let tasks = tasks_resp
        .get("tasks")
        .and_then(|t| t.as_array())
        .cloned()
        .unwrap_or_default();

    let Some(task) = select_task(&tasks, preferred_task_id) else {
        return Ok(false);
    };
    let Some(task_id) = task.get("id").and_then(|i| i.as_str()) else {
        return Ok(false);
    };

    // task_id makes the app enforce assignee identity when writing the result.
    let mut report_params = json!({
        "team_name": team_name,
        "agent_name": agent_name,
        "task_id": task_id,
        "content": reply_text,
    });
    if let Some(rp) = normalize_full_report_path(&event.full_report) {
        report_params["result_path"] = json!(rp);
    }
    rpc_call(socket_path, "team.report", report_params)
        .await
        .map_err(|e| format!("team.report failed: {e}"))?;

    let summary: String = reply_text.chars().take(RESULT_TRUNC_CHARS).collect();
    let mut update_params = json!({
        "team_name": team_name,
        "task_id": task_id,
        "status": task_status,
        "result": summary,
    });
    if event.status == "BLOCKED" && !event.body.is_empty() {
        update_params["blocked_reason"] = json!(event.body.clone());
    } else if event.status == "NEEDS_REVIEW" && !event.body.is_empty() {
        update_params["review_summary"] = json!(event.body.clone());
    }
    if let Some(rp) = normalize_full_report_path(&event.full_report) {
        update_params["result_path"] = json!(rp);
    }
    rpc_call(socket_path, "team.task.update", update_params)
        .await
        .map_err(|e| format!("team.task.update failed: {e}"))?;

    Ok(true)
}

fn format_reply_text(event: &AutoReplyEvent) -> String {
    let body = if event.body.is_empty() {
        String::new()
    } else {
        format!("\n\n{}", event.body)
    };
    format!(
        "STATUS: {}\nFILES: {}\nVERIFY: {}\nNEXT: {}\nFULL_REPORT: {}{body}",
        event.status, event.files, event.verify, event.next, event.full_report
    )
}

/// Minimal JSON-RPC v2 call over Unix socket. Mirrors the pattern in
/// `http::rpc_team_socket` but lives here to keep auto-reply self-contained.
async fn rpc_call(socket_path: &str, method: &str, params: Value) -> Result<Value, String> {
    let mut stream = UnixStream::connect(socket_path)
        .await
        .map_err(|e| format!("connect: {e}"))?;
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });
    let payload = format!("{request}\n");
    stream
        .write_all(payload.as_bytes())
        .await
        .map_err(|e| format!("write: {e}"))?;

    let mut reader = BufReader::new(stream);
    let mut attempts = 0u8;
    let response_line = loop {
        let mut line = String::new();
        let bytes = timeout(RPC_TIMEOUT, reader.read_line(&mut line))
            .await
            .map_err(|_| "read timeout".to_string())?
            .map_err(|e| format!("read: {e}"))?;
        if bytes == 0 {
            return Err("closed without response".into());
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            attempts += 1;
            if attempts >= 8 {
                return Err("only empty lines".into());
            }
            continue;
        }
        if !trimmed.starts_with('{') {
            return Err(trimmed.to_string());
        }
        break trimmed.to_string();
    };
    let response: Value = serde_json::from_str(&response_line)
        .map_err(|e| format!("parse: {e}; raw={response_line}"))?;
    if let Some(err) = response.get("error") {
        return Err(err
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or("rpc error")
            .to_string());
    }
    Ok(response.get("result").cloned().unwrap_or_else(|| json!({})))
}

/// Normalize FULL_REPORT field value: strip whitespace, return None for empty/"n/a".
fn normalize_full_report_path(s: &str) -> Option<&str> {
    let t = s.trim();
    if t.is_empty() || t.eq_ignore_ascii_case("n/a") {
        None
    } else {
        Some(t)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(status: &str, body: &str) -> AutoReplyEvent {
        AutoReplyEvent {
            status: status.to_string(),
            files: "src/foo.rs".to_string(),
            verify: "cargo test".to_string(),
            next: "NONE".to_string(),
            full_report: "n/a".to_string(),
            body: body.to_string(),
            raw: format!(
                "STATUS: {status}\nFILES: src/foo.rs\nVERIFY: cargo test\nNEXT: NONE\nFULL_REPORT: n/a\n\n{body}"
            ),
        }
    }

    #[test]
    fn format_reply_includes_header_and_body() {
        let text = format_reply_text(&ev("DONE", "shipped"));
        assert!(text.starts_with("STATUS: DONE\n"));
        assert!(text.contains("FULL_REPORT: n/a"));
        assert!(text.ends_with("shipped"));
    }

    #[test]
    fn format_reply_omits_body_separator_when_empty() {
        let text = format_reply_text(&ev("DONE", ""));
        assert!(text.ends_with("FULL_REPORT: n/a"));
        assert!(!text.contains("\n\n"));
    }

    #[test]
    fn validated_status_accepts_only_exact_verdicts() {
        assert_eq!(validated_status("DONE"), Some("completed"));
        assert_eq!(validated_status("BLOCKED"), Some("blocked"));
        assert_eq!(validated_status("NEEDS_REVIEW"), Some("review_ready"));
        for rejected in [
            "DONE|BLOCKED|NEEDS_REVIEW",
            "IN_PROGRESS",
            "done",
            " DONE",
            "DONE ",
            "",
        ] {
            assert_eq!(validated_status(rejected), None, "{rejected:?}");
        }
    }

    #[test]
    fn capsule_task_id_reads_first_task_id_line() {
        assert_eq!(
            capsule_task_id("do the thing\nTASK_ID: t-1\nTEAM: x"),
            Some("t-1".to_string())
        );
        assert_eq!(
            capsule_task_id("  TASK_ID:   t-2  \n"),
            Some("t-2".to_string())
        );
        assert_eq!(
            capsule_task_id("TASK_ID: first\nTASK_ID: second"),
            Some("first".to_string())
        );
        assert_eq!(capsule_task_id("TASK_ID:\nmore"), None);
        assert_eq!(capsule_task_id("[TASK_ID] t-3"), None);
        assert_eq!(capsule_task_id("no task here"), None);
    }

    fn task(id: &str, status: &str, created_at: &str) -> Value {
        json!({"id": id, "status": status, "created_at": created_at})
    }

    fn selected_id(tasks: &[Value], preferred: Option<&str>) -> Option<String> {
        select_task(tasks, preferred)
            .and_then(|t| t.get("id").and_then(Value::as_str))
            .map(str::to_string)
    }

    #[test]
    fn select_task_never_guesses_blocked_or_review_ready() {
        let tasks = vec![
            task("b", "blocked", "2026-10-16T00:00:01Z"),
            task("r", "review_ready", "2026-10-16T00:00:02Z"),
            task("c", "completed", "2026-10-16T00:00:03Z"),
        ];
        assert_eq!(selected_id(&tasks, None), None);
    }

    #[test]
    fn select_task_prefers_newest_in_progress_and_later_entry_on_tie() {
        let tasks = vec![
            task("old", "in_progress", "2026-10-16T00:00:01Z"),
            task("new", "in_progress", "2026-10-16T00:00:05Z"),
            task("open", "pending", "2026-10-16T00:00:09Z"),
        ];
        assert_eq!(selected_id(&tasks, None).as_deref(), Some("new"));

        let tied = vec![
            task("first", "in_progress", "2026-10-16T00:00:05Z"),
            task("second", "in_progress", "2026-10-16T00:00:05Z"),
        ];
        assert_eq!(selected_id(&tied, None).as_deref(), Some("second"));

        let no_running = vec![
            task("p1", "pending", "2026-10-16T00:00:01Z"),
            task("p2", "pending", "2026-10-16T00:00:02Z"),
            task("b", "blocked", "2026-10-16T00:00:03Z"),
        ];
        assert_eq!(selected_id(&no_running, None).as_deref(), Some("p2"));
    }

    #[test]
    fn select_task_named_id_is_authoritative() {
        let tasks = vec![
            task("running", "in_progress", "2026-10-16T00:00:05Z"),
            task("done", "completed", "2026-10-16T00:00:01Z"),
            task("stuck", "blocked", "2026-10-16T00:00:02Z"),
        ];
        assert_eq!(selected_id(&tasks, Some("done")), None);
        assert_eq!(selected_id(&tasks, Some("reassigned")), None);
        assert_eq!(selected_id(&tasks, Some("stuck")).as_deref(), Some("stuck"));
    }

    type Recorded = std::sync::Arc<std::sync::Mutex<Vec<(String, Value)>>>;

    async fn fake_app_socket(
        path: &std::path::Path,
        tasks: Value,
        report_fails: bool,
    ) -> (Recorded, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::UnixListener::bind(path).expect("bind fake app socket");
        let recorded: Recorded = Default::default();
        let sink = recorded.clone();
        let handle = tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let (read, mut write) = stream.into_split();
                let mut line = String::new();
                if BufReader::new(read).read_line(&mut line).await.is_err() {
                    continue;
                }
                let request: Value = serde_json::from_str(line.trim()).expect("request json");
                let method = request["method"].as_str().unwrap_or("").to_string();
                sink.lock()
                    .unwrap()
                    .push((method.clone(), request["params"].clone()));
                let response = match method.as_str() {
                    "team.task.list" => {
                        json!({"id": 1, "ok": true, "result": {"tasks": tasks.clone()}})
                    }
                    "team.report" if report_fails => json!({
                        "id": 1,
                        "ok": false,
                        "error": {
                            "code": "result_identity_mismatch",
                            "message": "Result task assignment does not match agent_instance_id",
                        },
                    }),
                    _ => json!({"id": 1, "ok": true, "result": {}}),
                };
                let _ = write.write_all(format!("{response}\n").as_bytes()).await;
            }
        });
        (recorded, handle)
    }

    fn methods(recorded: &Recorded) -> Vec<String> {
        recorded
            .lock()
            .unwrap()
            .iter()
            .map(|(m, _)| m.clone())
            .collect()
    }

    #[tokio::test]
    async fn emit_validates_then_selects_then_reports_then_updates() {
        let dir = tempfile::tempdir().expect("tempdir");
        let tasks = json!([
            task("other", "in_progress", "2026-10-16T00:00:09Z"),
            task("t-1", "in_progress", "2026-10-16T00:00:01Z"),
        ]);

        let ok_sock = dir.path().join("ok.sock");
        let (recorded, server) = fake_app_socket(&ok_sock, tasks.clone(), false).await;
        let sock = ok_sock.to_str().unwrap();

        let invalid = emit(
            sock,
            "team",
            "agent",
            &ev("DONE|BLOCKED|NEEDS_REVIEW", ""),
            Some("t-1"),
        )
        .await;
        assert_eq!(invalid, Ok(false));
        assert!(
            methods(&recorded).is_empty(),
            "invalid STATUS must send nothing"
        );

        let unmatched = emit(sock, "team", "agent", &ev("DONE", ""), Some("reassigned")).await;
        assert_eq!(unmatched, Ok(false));
        assert_eq!(methods(&recorded), ["team.task.list"], "no task, no report");
        recorded.lock().unwrap().clear();

        let done = emit(sock, "team", "agent", &ev("DONE", "shipped"), Some("t-1")).await;
        assert_eq!(done, Ok(true));
        assert_eq!(
            methods(&recorded),
            ["team.task.list", "team.report", "team.task.update"]
        );
        {
            let rec = recorded.lock().unwrap();
            assert_eq!(rec[1].1["task_id"], "t-1");
            assert_eq!(rec[2].1["task_id"], "t-1");
            assert_eq!(rec[2].1["status"], "completed");
        }
        server.abort();

        let fail_sock = dir.path().join("fail.sock");
        let (recorded, server) = fake_app_socket(&fail_sock, tasks, true).await;
        let refused = emit(
            fail_sock.to_str().unwrap(),
            "team",
            "agent",
            &ev("DONE", "shipped"),
            Some("t-1"),
        )
        .await;
        assert!(refused.is_err(), "{refused:?}");
        assert_eq!(methods(&recorded), ["team.task.list", "team.report"]);
        server.abort();
    }
}
