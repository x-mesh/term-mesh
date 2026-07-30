use clap::{Args, Subcommand};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Args, Debug)]
pub struct OrchestratorCommands {
    /// Coordinator socket path. Defaults to TERMMESH_COORDINATOR_UNIX_PATH,
    /// then $TMPDIR/tm-coordinator.sock.
    #[arg(long)]
    socket: Option<PathBuf>,
    /// Emit raw JSON responses. Non-JSON mode is intentionally still compact
    /// and machine-readable enough for scripts.
    #[arg(long)]
    json: bool,
    #[command(subcommand)]
    command: OrchestratorCommand,
}

#[derive(Subcommand, Debug)]
enum OrchestratorCommand {
    /// Coordinator status.
    Status,
    /// Project operations.
    Project {
        #[command(subcommand)]
        command: ProjectCommand,
    },
    /// Host observation operations.
    Host {
        #[command(subcommand)]
        command: HostCommand,
    },
    /// Task operations.
    Task {
        #[command(subcommand)]
        command: TaskCommand,
    },
    /// Attempt operations.
    Attempt {
        #[command(subcommand)]
        command: AttemptCommand,
    },
    /// Issue a fencing token.
    Fence {
        #[arg(long)]
        request_id: Option<String>,
        #[arg(long)]
        task_id: String,
        #[arg(long)]
        attempt_id: Option<String>,
        #[arg(long)]
        holder: String,
        #[arg(long)]
        ttl_ms: Option<u64>,
    },
    /// Review operations.
    Review {
        #[command(subcommand)]
        command: ReviewCommand,
    },
    /// Approve a review snapshot and enqueue merge.
    Approve {
        #[arg(long)]
        request_id: Option<String>,
        #[arg(long)]
        task_id: String,
        #[arg(long)]
        attempt_id: String,
        #[arg(long)]
        fencing_token: String,
        #[arg(long)]
        reviewer: String,
        #[arg(long)]
        snapshot_id: String,
        #[arg(long)]
        head_sha: String,
        #[arg(long)]
        diff_digest: String,
    },
    /// Reject an attempt.
    Reject {
        #[arg(long)]
        request_id: Option<String>,
        #[arg(long)]
        task_id: String,
        #[arg(long)]
        attempt_id: String,
        #[arg(long)]
        fencing_token: String,
        #[arg(long)]
        reviewer: String,
        #[arg(long)]
        reason: String,
    },
    /// Merge queue operations.
    Merge {
        #[command(subcommand)]
        command: MergeCommand,
    },
    /// Event stream operations.
    Events {
        #[command(subcommand)]
        command: EventsCommand,
    },
}

#[derive(Subcommand, Debug)]
enum ProjectCommand {
    List,
    Add {
        root_path: PathBuf,
        #[arg(long)]
        name: Option<String>,
        #[arg(long)]
        request_id: Option<String>,
    },
}

#[derive(Subcommand, Debug)]
enum HostCommand {
    List,
    Observe {
        #[arg(long)]
        request_id: Option<String>,
        #[arg(long)]
        host_id: Option<String>,
        #[arg(long)]
        os: String,
        #[arg(long)]
        arch: String,
        #[arg(long)]
        load: f64,
        /// Omit when the caller cannot say. Absent means "unknown capacity",
        /// which stays schedulable; `0` means the host is full and blocks
        /// placement.
        #[arg(long)]
        total_slots: Option<u32>,
        #[arg(long)]
        used_slots: Option<u32>,
        #[arg(long = "project-root", num_args = 1..)]
        project_roots: Vec<String>,
        #[arg(long, default_value_t = true)]
        live: bool,
        #[arg(long, default_value_t = false)]
        quarantined: bool,
        #[arg(long)]
        observed_at_ms: Option<u64>,
    },
}

#[derive(Subcommand, Debug)]
enum TaskCommand {
    List {
        #[arg(long)]
        project_id: Option<String>,
        #[arg(long)]
        status: Option<String>,
        #[arg(long)]
        limit: Option<i64>,
    },
    Get {
        task_id: String,
    },
    Create {
        #[arg(long)]
        request_id: Option<String>,
        #[arg(long)]
        project_id: String,
        title: String,
        #[arg(long, default_value = "")]
        body: String,
        #[arg(long)]
        priority: Option<i64>,
        #[arg(long = "depends-on", num_args = 1..)]
        depends_on: Vec<String>,
    },
    Place {
        #[arg(long)]
        request_id: Option<String>,
        task_id: String,
        #[arg(long)]
        host_id: Option<String>,
        #[arg(long)]
        mode: Option<String>,
        #[arg(long)]
        agent_name: Option<String>,
        #[arg(long)]
        ttl_ms: Option<u64>,
    },
    Reassign {
        #[arg(long)]
        request_id: Option<String>,
        task_id: String,
        #[arg(long)]
        host_id: Option<String>,
        #[arg(long)]
        mode: Option<String>,
        #[arg(long)]
        agent_name: Option<String>,
        #[arg(long)]
        reason: Option<String>,
        #[arg(long)]
        ttl_ms: Option<u64>,
    },
    Suspect {
        #[arg(long)]
        request_id: Option<String>,
        task_id: String,
        #[arg(long)]
        reason: Option<String>,
    },
    Quarantine {
        #[arg(long)]
        request_id: Option<String>,
        task_id: String,
        #[arg(long)]
        reason: Option<String>,
    },
}

#[derive(Subcommand, Debug)]
enum AttemptCommand {
    List { task_id: String },
}

#[derive(Subcommand, Debug)]
enum ReviewCommand {
    Snapshot {
        #[arg(long)]
        request_id: Option<String>,
        #[arg(long)]
        task_id: String,
        #[arg(long)]
        attempt_id: String,
        #[arg(long)]
        fencing_token: String,
        #[arg(long)]
        base_sha: String,
        #[arg(long)]
        head_sha: String,
        #[arg(long)]
        diff_digest: String,
        #[arg(long)]
        summary: Option<String>,
        /// JSON array of `{path,kind,add,del}` file summaries.
        #[arg(long)]
        files_json: Option<String>,
    },
}

#[derive(Subcommand, Debug)]
enum MergeCommand {
    Queue {
        #[arg(long)]
        project_id: Option<String>,
        #[arg(long)]
        status: Option<String>,
    },
    Transition {
        #[arg(long)]
        request_id: Option<String>,
        #[arg(long)]
        queue_id: String,
        #[arg(long)]
        status: String,
        #[arg(long)]
        last_error: Option<String>,
    },
}

#[derive(Subcommand, Debug)]
enum EventsCommand {
    Subscribe,
}

pub fn run(commands: &OrchestratorCommands) -> i32 {
    match run_inner(commands) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("Error: {error}");
            1
        }
    }
}

fn run_inner(commands: &OrchestratorCommands) -> Result<(), String> {
    let socket = commands
        .socket
        .clone()
        .unwrap_or_else(default_coordinator_socket_path);
    if matches!(
        commands.command,
        OrchestratorCommand::Events {
            command: EventsCommand::Subscribe
        }
    ) {
        stream_events(&socket)?;
        return Ok(());
    }

    let (method, params) = command_to_rpc(&commands.command)?;
    let result = coordinator_call(&socket, method, params)?;
    print_value(&result, commands.json);
    Ok(())
}

fn command_to_rpc(command: &OrchestratorCommand) -> Result<(&'static str, Value), String> {
    match command {
        OrchestratorCommand::Status => Ok(("orchestration.status", json!({}))),
        OrchestratorCommand::Project { command } => match command {
            ProjectCommand::List => Ok(("project.list", json!({}))),
            ProjectCommand::Add {
                root_path,
                name,
                request_id,
            } => Ok((
                "project.add",
                json!({
                    "request_id": request_id.clone().unwrap_or_else(local_request_id),
                    "root_path": root_path.to_string_lossy(),
                    "name": name
                }),
            )),
        },
        OrchestratorCommand::Host { command } => match command {
            HostCommand::List => Ok(("host.list", json!({}))),
            HostCommand::Observe {
                request_id,
                host_id,
                os,
                arch,
                load,
                total_slots,
                used_slots,
                project_roots,
                live,
                quarantined,
                observed_at_ms,
            } => Ok((
                "host.observe",
                json!({
                    "request_id": request_id.clone().unwrap_or_else(local_request_id),
                    "host_id": host_id,
                    "os": os,
                    "arch": arch,
                    "load": load,
                    "total_slots": total_slots,
                    "used_slots": used_slots,
                    "project_roots": project_roots,
                    "live": live,
                    "quarantined": quarantined,
                    "observed_at_ms": observed_at_ms
                }),
            )),
        },
        OrchestratorCommand::Task { command } => match command {
            TaskCommand::List {
                project_id,
                status,
                limit,
            } => Ok((
                "task.list",
                json!({ "project_id": project_id, "status": status, "limit": limit }),
            )),
            TaskCommand::Get { task_id } => Ok(("task.get", json!({ "task_id": task_id }))),
            TaskCommand::Create {
                request_id,
                project_id,
                title,
                body,
                priority,
                depends_on,
            } => Ok((
                "task.create",
                json!({
                    "request_id": request_id.clone().unwrap_or_else(local_request_id),
                    "project_id": project_id,
                    "title": title,
                    "body": body,
                    "priority": priority,
                    "depends_on": depends_on
                }),
            )),
            TaskCommand::Place {
                request_id,
                task_id,
                host_id,
                mode,
                agent_name,
                ttl_ms,
            } => Ok((
                "task.place",
                json!({
                    "request_id": request_id.clone().unwrap_or_else(local_request_id),
                    "task_id": task_id,
                    "host_id": host_id,
                    "mode": mode,
                    "agent_name": agent_name,
                    "ttl_ms": ttl_ms
                }),
            )),
            TaskCommand::Reassign {
                request_id,
                task_id,
                host_id,
                mode,
                agent_name,
                reason,
                ttl_ms,
            } => Ok((
                "task.reassign",
                json!({
                    "request_id": request_id.clone().unwrap_or_else(local_request_id),
                    "task_id": task_id,
                    "host_id": host_id,
                    "mode": mode,
                    "agent_name": agent_name,
                    "reason": reason,
                    "ttl_ms": ttl_ms
                }),
            )),
            TaskCommand::Suspect {
                request_id,
                task_id,
                reason,
            } => Ok((
                "task.suspect",
                json!({
                    "request_id": request_id.clone().unwrap_or_else(local_request_id),
                    "task_id": task_id,
                    "reason": reason
                }),
            )),
            TaskCommand::Quarantine {
                request_id,
                task_id,
                reason,
            } => Ok((
                "task.quarantine",
                json!({
                    "request_id": request_id.clone().unwrap_or_else(local_request_id),
                    "task_id": task_id,
                    "reason": reason
                }),
            )),
        },
        OrchestratorCommand::Attempt { command } => match command {
            AttemptCommand::List { task_id } => Ok(("attempt.list", json!({ "task_id": task_id }))),
        },
        OrchestratorCommand::Fence {
            request_id,
            task_id,
            attempt_id,
            holder,
            ttl_ms,
        } => Ok((
            "fence",
            json!({
                "request_id": request_id.clone().unwrap_or_else(local_request_id),
                "task_id": task_id,
                "attempt_id": attempt_id,
                "holder": holder,
                "ttl_ms": ttl_ms
            }),
        )),
        OrchestratorCommand::Review { command } => match command {
            ReviewCommand::Snapshot {
                request_id,
                task_id,
                attempt_id,
                fencing_token,
                base_sha,
                head_sha,
                diff_digest,
                summary,
                files_json,
            } => Ok((
                "review.snapshot",
                json!({
                    "request_id": request_id.clone().unwrap_or_else(local_request_id),
                    "task_id": task_id,
                    "attempt_id": attempt_id,
                    "fencing_token": fencing_token,
                    "base_sha": base_sha,
                    "head_sha": head_sha,
                    "diff_digest": diff_digest,
                    "summary": summary,
                    "files": parse_optional_json(files_json, "files-json")?
                }),
            )),
        },
        OrchestratorCommand::Approve {
            request_id,
            task_id,
            attempt_id,
            fencing_token,
            reviewer,
            snapshot_id,
            head_sha,
            diff_digest,
        } => Ok((
            "approve",
            json!({
                "request_id": request_id.clone().unwrap_or_else(local_request_id),
                "task_id": task_id,
                "attempt_id": attempt_id,
                "fencing_token": fencing_token,
                "reviewer": reviewer,
                "snapshot_id": snapshot_id,
                "head_sha": head_sha,
                "diff_digest": diff_digest
            }),
        )),
        OrchestratorCommand::Reject {
            request_id,
            task_id,
            attempt_id,
            fencing_token,
            reviewer,
            reason,
        } => Ok((
            "reject",
            json!({
                "request_id": request_id.clone().unwrap_or_else(local_request_id),
                "task_id": task_id,
                "attempt_id": attempt_id,
                "fencing_token": fencing_token,
                "reviewer": reviewer,
                "reason": reason
            }),
        )),
        OrchestratorCommand::Merge { command } => match command {
            MergeCommand::Queue { project_id, status } => Ok((
                "merge.queue",
                json!({ "project_id": project_id, "status": status }),
            )),
            MergeCommand::Transition {
                request_id,
                queue_id,
                status,
                last_error,
            } => Ok((
                "merge.queue.transition",
                json!({
                    "request_id": request_id.clone().unwrap_or_else(local_request_id),
                    "queue_id": queue_id,
                    "status": status,
                    "last_error": last_error
                }),
            )),
        },
        OrchestratorCommand::Events { .. } => {
            Err("INTERNAL_ERROR: events command is streaming-only".to_string())
        }
    }
}

fn coordinator_call(sock: &PathBuf, method: &str, params: Value) -> Result<Value, String> {
    let response = coordinator_raw_call(sock, method, params)?;
    decode_coordinator_response(response)
}

fn coordinator_raw_call(sock: &PathBuf, method: &str, params: Value) -> Result<Value, String> {
    let timeout = std::env::var("TERMMESH_COORDINATOR_RPC_TIMEOUT")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(6);
    let stream = UnixStream::connect(sock)
        .map_err(|e| format!("COORDINATOR_UNAVAILABLE: {}: {e}", sock.display()))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(timeout)))
        .ok();
    stream.set_write_timeout(Some(Duration::from_secs(3))).ok();

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
    if response.trim().is_empty() {
        return Err("PROTOCOL_ERROR: empty coordinator response".to_string());
    }
    serde_json::from_str(&response).map_err(|e| format!("parse response: {e}"))
}

fn decode_coordinator_response(response: Value) -> Result<Value, String> {
    if let Some(error) = response.get("error").filter(|value| !value.is_null()) {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("RPC_ERROR: coordinator request failed");
        return Err(format!("COORDINATOR_ERROR: {message}"));
    }
    response
        .get("result")
        .cloned()
        .ok_or_else(|| "PROTOCOL_ERROR: coordinator response has no result".to_string())
}

fn stream_events(sock: &PathBuf) -> Result<(), String> {
    let stream = UnixStream::connect(sock)
        .map_err(|e| format!("COORDINATOR_UNAVAILABLE: {}: {e}", sock.display()))?;
    stream.set_read_timeout(None).ok();
    stream.set_write_timeout(Some(Duration::from_secs(3))).ok();
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "events.subscribe",
        "params": {},
    });
    let mut writer = stream.try_clone().map_err(|e| format!("clone: {e}"))?;
    writer
        .write_all(
            serde_json::to_string(&request)
                .map_err(|e| format!("serialize: {e}"))?
                .as_bytes(),
        )
        .map_err(|e| format!("write: {e}"))?;
    writer.write_all(b"\n").map_err(|e| format!("write: {e}"))?;
    writer.flush().map_err(|e| format!("flush: {e}"))?;

    let mut reader = BufReader::new(&stream);
    let mut ack = String::new();
    reader
        .read_line(&mut ack)
        .map_err(|e| format!("read ack: {e}"))?;
    let ack: Value = serde_json::from_str(&ack).map_err(|e| format!("parse ack: {e}"))?;
    let _ = decode_coordinator_response(ack)?;

    loop {
        let mut line = String::new();
        let n = reader
            .read_line(&mut line)
            .map_err(|e| format!("read event: {e}"))?;
        if n == 0 {
            return Ok(());
        }
        print!("{}", line);
        let _ = std::io::stdout().flush();
    }
}

fn print_value(value: &Value, json_mode: bool) {
    if json_mode {
        println!(
            "{}",
            serde_json::to_string_pretty(value).unwrap_or_else(|_| "null".to_string())
        );
        return;
    }
    println!(
        "{}",
        serde_json::to_string_pretty(value).unwrap_or_else(|_| "null".to_string())
    );
}

fn parse_optional_json(raw: &Option<String>, flag: &str) -> Result<Option<Value>, String> {
    raw.as_ref()
        .map(|value| {
            serde_json::from_str(value)
                .map_err(|e| format!("INVALID_PARAMS: --{flag} is not valid JSON: {e}"))
        })
        .transpose()
}

fn default_coordinator_socket_path() -> PathBuf {
    if let Ok(path) = std::env::var("TERMMESH_COORDINATOR_UNIX_PATH") {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    if let Ok(dir) = std::env::var("TMPDIR") {
        return PathBuf::from(dir).join("tm-coordinator.sock");
    }
    PathBuf::from("/tmp/tm-coordinator.sock")
}

fn local_request_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("tm-agent-orchestrator-{}-{nanos}", process::id())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;
    use std::thread;

    #[test]
    fn maps_coordinator_error_message_clearly() {
        let error = decode_coordinator_response(json!({
            "error": {"code": -32000, "message": "stale_fencing_token"}
        }))
        .unwrap_err();
        assert_eq!(error, "COORDINATOR_ERROR: stale_fencing_token");
    }

    #[test]
    fn direct_client_decodes_result_without_app_socket_wrapper() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("coord.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], "orchestration.status");
            stream
                .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n")
                .unwrap();
        });
        let result = coordinator_call(&sock, "orchestration.status", json!({})).unwrap();
        assert_eq!(result["ok"], true);
        handle.join().unwrap();
    }

    #[test]
    fn command_mapping_preserves_request_id_for_mutations() {
        let command = OrchestratorCommand::Task {
            command: TaskCommand::Create {
                request_id: Some("req-1".to_string()),
                project_id: "prj_abc".to_string(),
                title: "title".to_string(),
                body: "body".to_string(),
                priority: Some(2),
                depends_on: vec!["tsk_dep".to_string()],
            },
        };
        let (method, params) = command_to_rpc(&command).unwrap();
        assert_eq!(method, "task.create");
        assert_eq!(params["request_id"], "req-1");
        assert_eq!(params["depends_on"][0], "tsk_dep");
    }

    #[test]
    fn task_suspect_and_quarantine_map_exact_coordinator_methods() {
        let suspect = OrchestratorCommand::Task {
            command: TaskCommand::Suspect {
                request_id: Some("suspect-1".to_string()),
                task_id: "tsk_abc".to_string(),
                reason: Some("heartbeat stale".to_string()),
            },
        };
        let (method, params) = command_to_rpc(&suspect).unwrap();
        assert_eq!(method, "task.suspect");
        assert_eq!(params["request_id"], "suspect-1");
        assert_eq!(params["task_id"], "tsk_abc");
        assert_eq!(params["reason"], "heartbeat stale");

        let quarantine = OrchestratorCommand::Task {
            command: TaskCommand::Quarantine {
                request_id: Some("quarantine-1".to_string()),
                task_id: "tsk_def".to_string(),
                reason: None,
            },
        };
        let (method, params) = command_to_rpc(&quarantine).unwrap();
        assert_eq!(method, "task.quarantine");
        assert_eq!(params["request_id"], "quarantine-1");
        assert_eq!(params["task_id"], "tsk_def");
        assert!(params["reason"].is_null());
    }
}
