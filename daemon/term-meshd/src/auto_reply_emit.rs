//! Bridge from [`crate::auto_reply::AutoReplyEvent`] to the Swift app's team
//! RPCs. When the detector observes a 5-line header in agent terminal output
//! but the agent never invoked `tm-agent reply` itself, we synthesise the
//! equivalent here so the leader's `tm-agent wait` resolves.
//!
//! Sequence (mirrors what `tm-agent reply` does in Rust CLI):
//! 1. `team.report` — writes the result file + posts a message
//! 2. `team.task.list assignee=<agent>` — pick in_progress, else first non-terminal
//! 3. `team.task.update` — set status (completed | blocked | review_ready) + result/reason
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

/// Send the synthesised reply to the Swift app socket. Returns `Ok(true)`
/// when the task was matched and updated, `Ok(false)` when no matching task
/// existed (still a partial success — report was written), `Err` on RPC failure.
pub async fn emit(
    socket_path: &str,
    team_name: &str,
    agent_name: &str,
    event: &AutoReplyEvent,
) -> Result<bool, String> {
    let reply_text = format_reply_text(event);

    // 1. team.report (writes file + posts message)
    let mut report_params = json!({
        "team_name": team_name,
        "agent_name": agent_name,
        "content": reply_text,
    });
    if let Some(rp) = normalize_full_report_path(&event.full_report) {
        report_params["result_path"] = json!(rp);
    }
    rpc_call(socket_path, "team.report", report_params)
        .await
        .map_err(|e| format!("team.report failed: {e}"))?;

    // 2. team.task.list — find target task for this assignee
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

    let target = tasks
        .iter()
        .find(|t| t.get("status").and_then(|s| s.as_str()) == Some("in_progress"))
        .or_else(|| {
            tasks.iter().find(|t| {
                let st = t.get("status").and_then(|s| s.as_str()).unwrap_or("");
                !matches!(st, "completed" | "failed" | "abandoned" | "cancelled")
            })
        });

    let Some(task) = target else {
        return Ok(false);
    };
    let Some(task_id) = task.get("id").and_then(|i| i.as_str()) else {
        return Ok(false);
    };

    // 3. team.task.update with status derived from STATUS line
    let task_status = match event.status.as_str() {
        "BLOCKED" => "blocked",
        "NEEDS_REVIEW" => "review_ready",
        _ => "completed",
    };
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
}
