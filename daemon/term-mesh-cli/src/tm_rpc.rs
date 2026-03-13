//! tm-rpc: Ultra-lightweight Rust RPC client for term-mesh team agents.
//!
//! ~1-3ms per call vs ~10ms for bash+nc, ~250ms for Python team.py.
//! Connects to the term-mesh app socket (not the daemon).

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;
use std::{env, process};

fn detect_socket() -> Option<PathBuf> {
    // 1. Environment variable
    if let Ok(sock) = env::var("TERMMESH_SOCKET") {
        let p = PathBuf::from(&sock);
        if p.exists() {
            return Some(p);
        }
    }

    // 2. Glob patterns (ordered by priority)
    let patterns = [
        "/tmp/term-mesh-debug-*.sock",
        "/tmp/term-mesh-debug.sock",
        "/tmp/term-mesh.sock",
        "/tmp/cmux.sock",
    ];
    for pattern in &patterns {
        if let Ok(paths) = glob::glob(pattern) {
            for entry in paths.flatten() {
                if entry.exists() {
                    return Some(entry);
                }
            }
        }
    }
    None
}

fn rpc_call(sock: &PathBuf, method: &str, params: Value) -> Result<Value, String> {
    let stream = UnixStream::connect(sock).map_err(|e| format!("connect: {e}"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .ok();
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .ok();

    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });

    let mut line = serde_json::to_string(&request).map_err(|e| format!("serialize: {e}"))?;
    line.push('\n');

    let mut writer = stream.try_clone().map_err(|e| format!("clone: {e}"))?;
    writer
        .write_all(line.as_bytes())
        .map_err(|e| format!("write: {e}"))?;
    writer.flush().map_err(|e| format!("flush: {e}"))?;

    let mut reader = BufReader::new(&stream);
    let mut response = String::new();
    reader
        .read_line(&mut response)
        .map_err(|e| format!("read: {e}"))?;

    let resp: Value =
        serde_json::from_str(&response).map_err(|e| format!("parse: {e}"))?;
    Ok(resp)
}

/// Send multiple JSON-RPC calls over a single connection.
fn rpc_batch(sock: &PathBuf, payloads: &[String]) -> Result<Vec<Value>, String> {
    let stream = UnixStream::connect(sock).map_err(|e| format!("connect: {e}"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .ok();

    let mut writer = stream.try_clone().map_err(|e| format!("clone: {e}"))?;
    for payload in payloads {
        writer
            .write_all(payload.as_bytes())
            .map_err(|e| format!("write: {e}"))?;
        writer
            .write_all(b"\n")
            .map_err(|e| format!("write: {e}"))?;
    }
    writer.flush().map_err(|e| format!("flush: {e}"))?;

    let mut reader = BufReader::new(&stream);
    let mut results = Vec::new();
    for _ in payloads {
        let mut line = String::new();
        if reader.read_line(&mut line).is_ok() && !line.is_empty() {
            if let Ok(v) = serde_json::from_str::<Value>(&line) {
                results.push(v);
            }
        }
    }
    Ok(results)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: tm-rpc <command> [args...]");
        eprintln!("Commands: report, ping, heartbeat, msg, task-start, task-done, task-block, status, inbox, tasks, batch, raw");
        process::exit(1);
    }

    let sock = match detect_socket() {
        Some(s) => s,
        None => {
            eprintln!("Error: no socket found");
            process::exit(1);
        }
    };

    let team = env::var("TERMMESH_TEAM").unwrap_or_else(|_| "live-team".into());
    let agent = env::var("TERMMESH_AGENT_NAME").unwrap_or_else(|_| "anonymous".into());

    let cmd = args[1].as_str();
    let result = match cmd {
        "report" => {
            let content = args.get(2).map(|s| s.as_str()).unwrap_or("done");
            rpc_call(
                &sock,
                "team.report",
                json!({
                    "team_name": team,
                    "agent_name": agent,
                    "content": content,
                }),
            )
        }
        "ping" | "heartbeat" => {
            let summary = args.get(2).map(|s| s.as_str()).unwrap_or("alive");
            rpc_call(
                &sock,
                "team.agent.heartbeat",
                json!({
                    "team_name": team,
                    "agent_name": agent,
                    "summary": summary,
                }),
            )
        }
        "msg" => {
            let content = args.get(2).map(|s| s.as_str()).unwrap_or("");
            let mut params = json!({
                "team_name": team,
                "from": agent,
                "content": content,
                "type": "note",
            });
            // Parse --to flag
            if let (Some(flag), Some(target)) = (args.get(3), args.get(4)) {
                if flag == "--to" {
                    params["to"] = json!(target);
                }
            }
            rpc_call(&sock, "team.message.post", params)
        }
        "task-start" => {
            let task_id = args.get(2).unwrap_or_else(|| {
                eprintln!("Usage: tm-rpc task-start <task_id>");
                process::exit(1);
            });
            rpc_call(
                &sock,
                "team.task.update",
                json!({
                    "team_name": team,
                    "task_id": task_id,
                    "status": "in_progress",
                }),
            )
        }
        "task-done" => {
            let task_id = args.get(2).unwrap_or_else(|| {
                eprintln!("Usage: tm-rpc task-done <task_id> [result]");
                process::exit(1);
            });
            let result_text = args.get(3).map(|s| s.as_str()).unwrap_or("done");
            rpc_call(
                &sock,
                "team.task.done",
                json!({
                    "team_name": team,
                    "task_id": task_id,
                    "result": result_text,
                }),
            )
        }
        "task-block" => {
            let task_id = args.get(2).unwrap_or_else(|| {
                eprintln!("Usage: tm-rpc task-block <task_id> <reason>");
                process::exit(1);
            });
            let reason = args.get(3).map(|s| s.as_str()).unwrap_or("blocked");
            rpc_call(
                &sock,
                "team.task.block",
                json!({
                    "team_name": team,
                    "task_id": task_id,
                    "blocked_reason": reason,
                }),
            )
        }
        "status" => rpc_call(
            &sock,
            "team.status",
            json!({ "team_name": team }),
        ),
        "inbox" => rpc_call(
            &sock,
            "team.inbox",
            json!({
                "team_name": team,
                "agent_name": agent,
            }),
        ),
        "tasks" => rpc_call(
            &sock,
            "team.task.list",
            json!({ "team_name": team }),
        ),
        "batch" => {
            let payloads: Vec<String> = args[2..].to_vec();
            match rpc_batch(&sock, &payloads) {
                Ok(results) => {
                    for r in &results {
                        println!("{}", serde_json::to_string(r).unwrap_or_default());
                    }
                    return;
                }
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            }
        }
        "raw" => {
            let payload = args.get(2).unwrap_or_else(|| {
                eprintln!("Usage: tm-rpc raw '<json>'");
                process::exit(1);
            });
            // Parse and re-serialize to validate JSON, then send
            match serde_json::from_str::<Value>(payload) {
                Ok(_) => {
                    // Send raw payload directly
                    let stream = UnixStream::connect(&sock).unwrap();
                    stream.set_read_timeout(Some(Duration::from_secs(2))).ok();
                    let mut writer = stream.try_clone().unwrap();
                    writer.write_all(payload.as_bytes()).unwrap();
                    writer.write_all(b"\n").unwrap();
                    writer.flush().unwrap();
                    let mut reader = BufReader::new(&stream);
                    let mut line = String::new();
                    reader.read_line(&mut line).ok();
                    print!("{}", line);
                    return;
                }
                Err(e) => {
                    eprintln!("Invalid JSON: {e}");
                    process::exit(1);
                }
            }
        }
        _ => {
            eprintln!("Unknown command: {cmd}");
            eprintln!("Commands: report, ping, heartbeat, msg, task-start, task-done, task-block, status, inbox, tasks, batch, raw");
            process::exit(1);
        }
    };

    match result {
        Ok(resp) => println!("{}", serde_json::to_string(&resp).unwrap_or_default()),
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    }
}
