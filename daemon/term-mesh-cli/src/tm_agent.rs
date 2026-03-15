//! tm-agent: Unified Rust CLI for term-mesh team operations.
//!
//! Replaces both tm-rpc (agent-side) and team.py (leader-side).
//! ~1-3ms per call for all commands.

use clap::{Parser, Subcommand};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;
use std::{env, process, thread};

// ── Constants ────────────────────────────────────────────────────────

const DEFAULT_AGENT_NAMES: &[&str] = &["explorer", "executor", "reviewer", "debugger", "writer", "tester"];
const DEFAULT_AGENT_COLORS: &[&str] = &["green", "blue", "yellow", "magenta", "cyan", "red"];

const REPORT_SUFFIX: &str = concat!(
    "\n\n[IMPORTANT] Use the team task lifecycle while you work:\n",
    "1. If you are starting assigned work, run `tm-agent task start <task_id>`.\n",
    "2. While you are actively working, periodically run `tm-agent heartbeat '<short progress summary>'`.\n",
    "3. If you are blocked, run `tm-agent task block <task_id> '<reason>'`.\n",
    "4. If you are ready for leader validation, run `tm-agent task review <task_id> '<summary>'`.\n",
    "5. When the task is actually done, run `tm-agent task done <task_id> '<result>'`.\n",
    "If the leader did not give you a task id, report that and ask for one.\n",
    "\n",
    "[IMPORTANT] When you finish this task, you MUST use your bash/execute tool to run this SINGLE command:\n",
    "```\n",
    "tm-agent reply '<one-paragraph summary of your result>'\n",
    "```\n",
    "This sends the result to the leader AND registers it as a report in one step.\n",
    "Do NOT run separate msg send + report commands. Just use `reply` once.",
);

const BROADCAST_SUFFIX: &str = concat!(
    "\n\n[IMPORTANT] When you finish this task, you MUST run this SINGLE command to report your result:\n",
    "tm-agent reply '<one-paragraph summary of your result>'\n",
    "This sends the result to the leader AND registers it as a report in one step.\n",
    "Do NOT run separate msg send + report commands. Just use `reply` once.",
);

fn agent_init_prompt(agent: &str, workdir: &str, socket: &str) -> String {
    format!(
        "You are a team agent named \"{agent}\" in a term-mesh multi-agent team. \
Use `tm-agent` (Rust, ~2ms) for ALL team operations. \
Fallback: `./scripts/tm-agent.sh` (bash, ~10ms). \
NEVER use `./scripts/team.py` \u{2014} it has been removed.\n\
\n\
Task lifecycle:\n\
1. Begin task: `tm-agent task start <task_id>`\n\
2. Progress heartbeat: `tm-agent heartbeat '<short summary>'`\n\
3. If blocked: `tm-agent task block <task_id> '<reason>'`\n\
4. If ready for review: `tm-agent task review <task_id> '<summary>'`\n\
5. When done: `tm-agent task done <task_id> '<result>'`\n\
\n\
Communication:\n\
- Send message to leader: `tm-agent msg send '<text>'`\n\
- Send message to another agent: `tm-agent msg send '<text>' --to <agent_name>`\n\
- Check your inbox: `tm-agent inbox`\n\
- Check team status: `tm-agent status`\n\
- Check tasks: `tm-agent task list`\n\
\n\
Environment:\n\
- Working directory: {workdir}\n\
- Socket: {socket}\n\
- Project: term-mesh (Swift/macOS terminal multiplexer)\n\
\n\
When you complete any task assigned by the leader, you MUST use your bash/execute tool to run:\n\
tm-agent reply '<one-paragraph summary of your result>'\n\
This sends the result to the leader AND registers it as a report in one step.\n\
Do NOT run separate msg send + report commands. Just use `reply` once.\n\
Do NOT just write the result as text \u{2014} actually execute the shell command using your tool. \
This allows the leader to detect task completion automatically. \
Respond with \"Agent {agent} ready.\" to confirm.",
    )
}

// ── CLI definition ───────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "tm-agent", about = "term-mesh team CLI — unified agent & leader tool")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    // ── Agent-side ─────────────────────────────────────────────────
    /// Submit a result report
    Report { content: Option<String> },
    /// Send heartbeat (alias: ping)
    Ping { summary: Option<String> },
    /// Send heartbeat
    Heartbeat { summary: Option<String> },
    /// Show team status
    Status,
    /// Check agent inbox
    Inbox,
    /// Send multiple JSON-RPC payloads over a single connection
    Batch { payloads: Vec<String> },
    /// Send raw JSON-RPC payload
    Raw { payload: String },

    // ── Grouped subcommands ────────────────────────────────────────
    /// Task operations (create, start, done, block, review, list, ...)
    #[command(subcommand)]
    Task(TaskCommands),
    /// Message operations (send, list, clear)
    #[command(subcommand)]
    Msg(MsgCommands),

    // ── Simple RPC wrappers ────────────────────────────────────────
    /// Destroy the current team
    Destroy,
    /// List all teams
    List,
    /// Read an agent's terminal output
    Read {
        agent: String,
        #[arg(long, default_value_t = 50)]
        lines: u32,
    },
    /// Read all agents' terminal output
    Collect {
        #[arg(long, default_value_t = 50)]
        lines: u32,
    },
    /// Get agent reports
    Reports,
    /// Check result completion status
    ResultStatus,
    /// Collect all results
    ResultCollect,

    // ── Orchestration ──────────────────────────────────────────────
    /// Create a new agent team
    Create {
        count: Option<u32>,
        #[arg(long)]
        claude_leader: bool,
        /// Set model for all agents (e.g. sonnet, opus, haiku)
        #[arg(long, default_value = "sonnet")]
        model: String,
        #[arg(long)]
        kiro: Option<String>,
        #[arg(long)]
        codex: Option<String>,
        #[arg(long)]
        gemini: Option<String>,
    },
    /// Send instruction to an agent (with report suffix)
    Send {
        agent: String,
        text: String,
        #[arg(long)]
        no_report: bool,
    },
    /// Broadcast instruction to all agents
    Broadcast {
        text: String,
        #[arg(long)]
        no_report: bool,
    },
    /// Create task and send instruction to agent
    Delegate {
        agent: String,
        text: String,
        #[arg(long)]
        title: Option<String>,
        #[arg(long)]
        priority: Option<u32>,
        #[arg(long, num_args = 1..)]
        accept: Vec<String>,
        #[arg(long, num_args = 1..)]
        deps: Vec<String>,
        #[arg(long)]
        desc: Option<String>,
        #[arg(long)]
        no_report: bool,
    },
    /// Wait for agent signals (report, msg, blocked, review_ready, idle, any)
    Wait {
        #[arg(long, default_value_t = 120)]
        timeout: u32,
        #[arg(long, default_value_t = 3)]
        interval: u32,
        #[arg(long, default_value = "report")]
        mode: String,
        #[arg(long)]
        task: Option<String>,
    },
    /// Get concise agent status (status + task + messages + terminal)
    Brief {
        agent: String,
        #[arg(long, default_value_t = 30)]
        lines: u32,
    },
    /// Reply to leader with auto-report
    Reply {
        text: Vec<String>,
        #[arg(long)]
        from: Option<String>,
    },
}

#[derive(Subcommand)]
enum TaskCommands {
    /// Create a task
    Create {
        title: String,
        #[arg(long)]
        assign: Option<String>,
        #[arg(long)]
        desc: Option<String>,
        #[arg(long)]
        priority: Option<u32>,
        #[arg(long, num_args = 1..)]
        accept: Vec<String>,
        #[arg(long, num_args = 1..)]
        deps: Vec<String>,
    },
    /// Mark task as in_progress
    Start { task_id: String },
    /// Mark task as done with optional result
    Done { task_id: String, result: Option<String> },
    /// Mark task as blocked with reason
    Block { task_id: String, reason: Option<String> },
    /// Submit task for review
    Review { id: String, summary: Option<String> },
    /// Get task details
    Get { id: String },
    /// List all tasks
    List,
    /// Update task status
    Update {
        id: String,
        status: String,
        result: Option<String>,
    },
    /// Reassign task to another agent
    Reassign { id: String, agent: String },
    /// Unblock a task
    Unblock { id: String },
    /// Split a task into subtasks
    Split {
        id: String,
        title: String,
        #[arg(long)]
        assign: Option<String>,
    },
    /// Clear all tasks
    Clear,
}

#[derive(Subcommand)]
enum MsgCommands {
    /// Send a message (to leader by default, --to for specific agent)
    Send {
        content: String,
        #[arg(long)]
        to: Option<String>,
    },
    /// List messages
    List {
        #[arg(long, name = "from")]
        from_agent: Option<String>,
        #[arg(long)]
        to: Option<String>,
        #[arg(long)]
        limit: Option<u32>,
    },
    /// Clear message queue
    Clear,
}

// ── Socket / RPC infrastructure ──────────────────────────────────────

fn detect_socket() -> Option<PathBuf> {
    // Priority 1: Explicit environment variable (always wins)
    if let Ok(sock) = env::var("TERMMESH_SOCKET") {
        let p = PathBuf::from(&sock);
        if p.exists() {
            return Some(p);
        }
    }

    // Priority 2: Last-used socket path recorded by reload.sh / reloads.sh
    // This avoids ambiguity when multiple tagged debug sockets exist.
    let last_socket_path = PathBuf::from("/tmp/term-mesh-last-socket-path");
    if last_socket_path.exists() {
        if let Ok(contents) = std::fs::read_to_string(&last_socket_path) {
            let p = PathBuf::from(contents.trim());
            if p.exists() {
                return Some(p);
            }
            // Stale path — fall through to glob detection
        }
    }

    // Priority 3: Glob fallback (first match)
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
    rpc_call_timeout(sock, method, params, 2)
}

fn rpc_call_timeout(sock: &PathBuf, method: &str, params: Value, timeout_secs: u64) -> Result<Value, String> {
    let stream = UnixStream::connect(sock).map_err(|e| format!("connect: {e}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(timeout_secs))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(timeout_secs))).ok();

    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });

    let mut line = serde_json::to_string(&request).map_err(|e| format!("serialize: {e}"))?;
    line.push('\n');

    let mut writer = stream.try_clone().map_err(|e| format!("clone: {e}"))?;
    writer.write_all(line.as_bytes()).map_err(|e| format!("write: {e}"))?;
    writer.flush().map_err(|e| format!("flush: {e}"))?;

    let mut reader = BufReader::new(&stream);
    let mut response = String::new();
    reader.read_line(&mut response).map_err(|e| format!("read: {e}"))?;

    serde_json::from_str(&response).map_err(|e| format!("parse: {e}"))
}

/// Send multiple JSON-RPC calls over a single connection.
fn rpc_batch(sock: &PathBuf, payloads: &[String]) -> Result<Vec<Value>, String> {
    // Validate all payloads are valid JSON before sending
    for (i, payload) in payloads.iter().enumerate() {
        serde_json::from_str::<Value>(payload)
            .map_err(|e| format!("invalid JSON in payload {i}: {e}"))?;
    }

    let stream = UnixStream::connect(sock).map_err(|e| format!("connect: {e}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(2))).ok();

    let mut writer = stream.try_clone().map_err(|e| format!("clone: {e}"))?;
    for payload in payloads {
        writer.write_all(payload.as_bytes()).map_err(|e| format!("write: {e}"))?;
        writer.write_all(b"\n").map_err(|e| format!("write: {e}"))?;
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

fn pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

// ── Helpers ──────────────────────────────────────────────────────────

fn append_report_suffix(text: &str, no_report: bool) -> String {
    if no_report { text.to_string() } else { format!("{text}{REPORT_SUFFIX}") }
}

fn task_title_from_text(text: &str) -> String {
    let compact: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.is_empty() {
        "Untitled task".to_string()
    } else if compact.len() > 80 {
        // Find a valid char boundary at or before byte 80
        let mut end = 80;
        while end > 0 && !compact.is_char_boundary(end) {
            end -= 1;
        }
        compact[..end].to_string()
    } else {
        compact
    }
}

fn format_task_instruction(task: &Value, instruction: &str, no_report: bool) -> String {
    let mut lines = vec![
        format!("[TASK_ID] {}", task["id"].as_str().unwrap_or("")),
        format!("[TASK_TITLE] {}", task["title"].as_str().unwrap_or("")),
        format!("[TASK_STATUS] {}", task["status"].as_str().unwrap_or("assigned")),
    ];
    if let Some(p) = task["priority"].as_u64() {
        lines.push(format!("[TASK_PRIORITY] {p}"));
    }
    if let Some(ac) = task["acceptance_criteria"].as_array() {
        if !ac.is_empty() {
            lines.push("[ACCEPTANCE]".to_string());
            for item in ac {
                lines.push(format!("- {}", item.as_str().unwrap_or("")));
            }
        }
    }
    if let Some(deps) = task["depends_on"].as_array() {
        if !deps.is_empty() {
            let dep_strs: Vec<&str> = deps.iter().filter_map(|d| d.as_str()).collect();
            lines.push(format!("[DEPS] {}", dep_strs.join(", ")));
        }
    }
    if let Some(desc) = task["description"].as_str() {
        if !desc.is_empty() {
            lines.push(format!("[TASK_DESCRIPTION] {desc}"));
        }
    }
    let task_id = task["id"].as_str().unwrap_or("");
    lines.push(String::new());
    lines.push(instruction.trim().to_string());
    lines.push(String::new());
    lines.push("Use the task lifecycle commands with this task id:".to_string());
    lines.push(format!("- tm-agent task start {task_id}"));
    lines.push("- tm-agent heartbeat '<short progress summary>'".to_string());
    lines.push(format!("- tm-agent task block {task_id} '<reason>'"));
    lines.push(format!("- tm-agent task review {task_id} '<summary>'"));
    lines.push(format!("- tm-agent task done {task_id} '<result>'"));

    let body = lines.join("\n");
    append_report_suffix(body.trim(), no_report)
}

fn parse_cli_flag(flag: &Option<String>) -> std::collections::HashSet<String> {
    let mut result = std::collections::HashSet::new();
    if let Some(val) = flag {
        for item in val.split(',') {
            let item = item.trim();
            if !item.is_empty() {
                result.insert(item.to_string());
            }
        }
    }
    result
}

// ── Main ─────────────────────────────────────────────────────────────

fn main() {
    let cli = Cli::parse();

    let sock = match detect_socket() {
        Some(s) => s,
        None => {
            eprintln!("Error: no socket found");
            process::exit(1);
        }
    };

    let team = env::var("TERMMESH_TEAM").unwrap_or_else(|_| "live-team".into());
    let agent = env::var("TERMMESH_AGENT_NAME").unwrap_or_else(|_| "anonymous".into());

    let result = match cli.command {
        // ── Agent-side commands ──────────────────────────────────
        Commands::Report { content } => {
            rpc_call(&sock, "team.report", json!({
                "team_name": team,
                "agent_name": agent,
                "content": content.as_deref().unwrap_or("done"),
            }))
        }
        Commands::Ping { summary } | Commands::Heartbeat { summary } => {
            rpc_call(&sock, "team.agent.heartbeat", json!({
                "team_name": team,
                "agent_name": agent,
                "summary": summary.as_deref().unwrap_or("alive"),
            }))
        }
        Commands::Msg(sub) => {
            match sub {
                MsgCommands::Send { content, to } => {
                    let mut params = json!({
                        "team_name": team,
                        "from": agent,
                        "content": content,
                        "type": "note",
                    });
                    if let Some(target) = to {
                        params["to"] = json!(target);
                    }
                    rpc_call(&sock, "team.message.post", params)
                }
                MsgCommands::List { from_agent, to, limit } => {
                    let mut params = json!({ "team_name": team });
                    if let Some(f) = from_agent { params["from"] = json!(f); }
                    if let Some(t) = to { params["to"] = json!(t); }
                    if let Some(l) = limit { params["limit"] = json!(l); }
                    rpc_call(&sock, "team.message.list", params)
                }
                MsgCommands::Clear => {
                    rpc_call(&sock, "team.message.clear", json!({ "team_name": team }))
                }
            }
        }
        Commands::Task(sub) => {
            match sub {
                TaskCommands::Start { task_id } => {
                    rpc_call(&sock, "team.task.update", json!({
                        "team_name": team, "task_id": task_id, "status": "in_progress",
                    }))
                }
                TaskCommands::Done { task_id, result } => {
                    rpc_call(&sock, "team.task.done", json!({
                        "team_name": team, "task_id": task_id,
                        "result": result.as_deref().unwrap_or("done"),
                    }))
                }
                TaskCommands::Block { task_id, reason } => {
                    rpc_call(&sock, "team.task.block", json!({
                        "team_name": team, "task_id": task_id,
                        "blocked_reason": reason.as_deref().unwrap_or("blocked"),
                    }))
                }
                TaskCommands::Create { title, assign, desc, priority, accept, deps } => {
                    let mut params = json!({ "team_name": team, "title": title });
                    if let Some(a) = assign { params["assignee"] = json!(a); }
                    if let Some(d) = desc { params["description"] = json!(d); }
                    if let Some(p) = priority { params["priority"] = json!(p); }
                    if !accept.is_empty() { params["acceptance_criteria"] = json!(accept); }
                    if !deps.is_empty() { params["depends_on"] = json!(deps); }
                    rpc_call(&sock, "team.task.create", params)
                }
                TaskCommands::Get { id } => {
                    rpc_call(&sock, "team.task.get", json!({
                        "team_name": team, "task_id": id,
                    }))
                }
                TaskCommands::List => {
                    rpc_call(&sock, "team.task.list", json!({ "team_name": team }))
                }
                TaskCommands::Update { id, status, result } => {
                    let mut params = json!({
                        "team_name": team, "task_id": id, "status": status,
                    });
                    if let Some(r) = result { params["result"] = json!(r); }
                    rpc_call(&sock, "team.task.update", params)
                }
                TaskCommands::Review { id, summary } => {
                    rpc_call(&sock, "team.task.review", json!({
                        "team_name": team, "task_id": id,
                        "summary": summary.as_deref().unwrap_or(""),
                    }))
                }
                TaskCommands::Reassign { id, agent: ref target } => {
                    rpc_call(&sock, "team.task.reassign", json!({
                        "team_name": team, "task_id": id, "assignee": target,
                    }))
                }
                TaskCommands::Unblock { id } => {
                    rpc_call(&sock, "team.task.unblock", json!({
                        "team_name": team, "task_id": id,
                    }))
                }
                TaskCommands::Split { id, title, assign } => {
                    let mut params = json!({
                        "team_name": team, "task_id": id, "title": title,
                    });
                    if let Some(a) = assign { params["assignee"] = json!(a); }
                    rpc_call(&sock, "team.task.split", params)
                }
                TaskCommands::Clear => {
                    rpc_call(&sock, "team.task.clear", json!({ "team_name": team }))
                }
            }
        }
        Commands::Status => {
            rpc_call(&sock, "team.status", json!({ "team_name": team }))
        }
        Commands::Inbox => {
            rpc_call(&sock, "team.inbox", json!({
                "team_name": team, "agent_name": agent,
            }))
        }
        Commands::Batch { payloads } => {
            match rpc_batch(&sock, &payloads) {
                Ok(results) => {
                    for r in &results {
                        println!("{}", serde_json::to_string(r).unwrap_or_default());
                    }
                    return;
                }
                Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
            }
        }
        Commands::Raw { payload } => {
            if let Err(e) = serde_json::from_str::<Value>(&payload) {
                eprintln!("Invalid JSON: {e}");
                process::exit(1);
            }
            let stream = UnixStream::connect(&sock).map_err(|e| format!("connect: {e}"));
            match stream {
                Ok(stream) => {
                    stream.set_read_timeout(Some(Duration::from_secs(2))).ok();
                    let mut writer = stream.try_clone().map_err(|e| format!("clone: {e}")).unwrap_or_else(|e| { eprintln!("Error: {e}"); process::exit(1); });
                    if let Err(e) = writer.write_all(payload.as_bytes()).and_then(|_| writer.write_all(b"\n")).and_then(|_| writer.flush()) {
                        eprintln!("Error: write: {e}");
                        process::exit(1);
                    }
                    let mut reader = BufReader::new(&stream);
                    let mut line = String::new();
                    reader.read_line(&mut line).ok();
                    print!("{line}");
                    return;
                }
                Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
            }
        }

        // ── Simple RPC wrappers ─────────────────────────────────
        Commands::Destroy => {
            eprintln!("Destroying team '{team}'...");
            rpc_call(&sock, "team.destroy", json!({ "team_name": team }))
        }
        Commands::List => {
            rpc_call(&sock, "team.list", json!({}))
        }
        Commands::Read { agent: ref agent_name, lines } => {
            rpc_call(&sock, "team.read", json!({
                "team_name": team, "agent_name": agent_name, "lines": lines,
            }))
        }
        Commands::Collect { lines } => {
            rpc_call(&sock, "team.collect", json!({
                "team_name": team, "lines": lines,
            }))
        }
        Commands::Reports => {
            rpc_call(&sock, "team.result.collect", json!({ "team_name": team }))
        }
        Commands::ResultStatus => {
            rpc_call(&sock, "team.result.status", json!({ "team_name": team }))
        }
        Commands::ResultCollect => {
            rpc_call(&sock, "team.result.collect", json!({ "team_name": team }))
        }
        // ── Orchestration commands ──────────────────────────────
        Commands::Create { count, claude_leader, model, kiro, codex, gemini } => {
            run_create(&sock, &team, count.unwrap_or(2), claude_leader, &model, &kiro, &codex, &gemini);
            return;
        }
        Commands::Send { agent: ref target, text, no_report } => {
            let text = append_report_suffix(&text, no_report);
            print_result(rpc_call(&sock, "team.send", json!({
                "team_name": team, "agent_name": target,
                "text": format!("{text}\n"),
            })));
            return;
        }
        Commands::Broadcast { text, no_report } => {
            let text = if no_report { text } else { format!("{text}{BROADCAST_SUFFIX}") };
            print_result(rpc_call(&sock, "team.broadcast", json!({
                "team_name": team, "text": format!("{text}\n"),
            })));
            return;
        }
        Commands::Delegate { agent: ref target, text, title, priority, accept, deps, desc, no_report } => {
            run_delegate(&sock, &team, target, &text, title, priority, &accept, &deps, desc, no_report);
            return;
        }
        Commands::Wait { timeout, interval, mode, task } => {
            run_wait(&sock, &team, timeout, interval, &mode, task.as_deref());
            return;
        }
        Commands::Brief { agent: ref target, lines } => {
            run_brief(&sock, &team, target, lines);
            return;
        }
        Commands::Reply { text, from } => {
            let sender = from.unwrap_or_else(|| agent.clone());
            let content = text.join(" ");
            print_result(rpc_call(&sock, "team.message.post", json!({
                "team_name": team, "from": sender, "content": content,
                "to": "leader", "type": "report",
            })));
            // Auto-submit report for wait detection
            let _ = rpc_call(&sock, "team.report", json!({
                "team_name": team, "agent_name": sender, "content": content,
            }));
            return;
        }
    };

    print_result(result);
}

fn print_result(result: Result<Value, String>) {
    match result {
        Ok(resp) => println!("{}", pretty(&resp)),
        Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
    }
}

// ── Orchestration implementations ────────────────────────────────────

fn run_create(
    sock: &PathBuf, team: &str, count: u32, claude_leader: bool,
    model: &str, kiro: &Option<String>, codex: &Option<String>, gemini: &Option<String>,
) {
    let leader_mode = if claude_leader { "claude" } else { "repl" };
    let kiro_agents = parse_cli_flag(kiro);
    let codex_agents = parse_cli_flag(codex);
    let gemini_agents = parse_cli_flag(gemini);

    let mut agents = Vec::new();
    for i in 0..count as usize {
        let name = if i < DEFAULT_AGENT_NAMES.len() {
            DEFAULT_AGENT_NAMES[i].to_string()
        } else {
            format!("agent-{i}")
        };
        let color = DEFAULT_AGENT_COLORS[i % DEFAULT_AGENT_COLORS.len()];
        let cli = if codex_agents.contains(&name) || codex_agents.contains("all") {
            "codex"
        } else if gemini_agents.contains(&name) || gemini_agents.contains("all") {
            "gemini"
        } else if kiro_agents.contains(&name) || kiro_agents.contains("all") {
            "kiro"
        } else {
            "claude"
        };
        agents.push(json!({
            "name": name, "cli": cli, "model": model,
            "agent_type": name, "color": color,
        }));
    }

    // Destroy existing team first, then poll until gone (max 10 × 50ms = 500ms)
    let _ = rpc_call_timeout(sock, "team.destroy", json!({ "team_name": team }), 2);
    for i in 0..10 {
        if rpc_call_timeout(sock, "team.status", json!({ "team_name": team }), 1).is_err() {
            break;
        }
        // team.status returns ok even if team exists but is being torn down;
        // check if the response indicates the team no longer exists
        if let Ok(r) = rpc_call_timeout(sock, "team.status", json!({ "team_name": team }), 1) {
            if !r["ok"].as_bool().unwrap_or(false) {
                break;
            }
        }
        if i == 9 {
            eprintln!("Warning: previous team may still be tearing down");
        }
        thread::sleep(Duration::from_millis(50));
    }

    let workdir = env::current_dir()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| ".".to_string());

    eprintln!("Creating team '{team}' with {count} agent(s) [leader: {leader_mode}]...");
    eprintln!("Socket: {}", sock.display());

    let r = match rpc_call_timeout(sock, "team.create", json!({
        "team_name": team,
        "working_directory": workdir,
        "leader_session_id": format!("leader-{}", process::id()),
        "leader_mode": leader_mode,
        "agents": agents,
    }), 5) {
        Ok(v) => v,
        Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
    };

    println!("{}", pretty(&r));
    println!();
    println!("Commands:");
    println!("  tm-agent send <agent> 'your message'");
    println!("  tm-agent broadcast 'message to all'");
    println!("  tm-agent status");
    println!("  tm-agent destroy");

    if r["ok"].as_bool().unwrap_or(false) {
        let non_kiro: Vec<&Value> = agents.iter()
            .filter(|a| a["cli"].as_str().unwrap_or("claude") != "kiro")
            .collect();
        if !non_kiro.is_empty() {
            // Poll until all agent panels are spawned (max 60 × 100ms = 6s)
            eprintln!("\nWaiting for agent panels to spawn...");
            let expected = non_kiro.len();
            for i in 0..60 {
                if let Ok(st) = rpc_call_timeout(sock, "team.status", json!({ "team_name": team }), 2) {
                    if let Some(agents_arr) = st["result"]["agents"].as_array() {
                        let with_panels = agents_arr.iter()
                            .filter(|a| a["panel_id"].as_str().map(|s| !s.is_empty()).unwrap_or(false))
                            .count();
                        if with_panels >= expected {
                            eprintln!("  All {expected} agent panels ready ({} ms)", (i + 1) * 100);
                            break;
                        }
                        if i % 10 == 9 {
                            eprintln!("  ... {with_panels}/{expected} panels ready");
                        }
                    }
                }
                if i == 59 {
                    eprintln!("  Warning: timed out waiting for all panels (proceeding anyway)");
                }
                thread::sleep(Duration::from_millis(100));
            }

            eprintln!("Sending init prompts to non-kiro agents...");
            for a in &non_kiro {
                let name = a["name"].as_str().unwrap_or("");
                let init_text = agent_init_prompt(name, &workdir, &sock.to_string_lossy());
                match rpc_call_timeout(sock, "team.send", json!({
                    "team_name": team, "agent_name": name,
                    "text": format!("{init_text}\n"),
                }), 3) {
                    Ok(_) => eprintln!("  \u{2713} {name}: init prompt sent"),
                    Err(e) => eprintln!("  \u{2717} {name}: init prompt FAILED: {e}"),
                }
                // Keep 1s delay between sends: this is NOT state synchronization but
                // main-thread congestion relief. The Swift app processes sendTextToPanel
                // on DispatchQueue.main — sending too fast causes Enter key events to be
                // dropped because the TUI (Claude Code) hasn't processed the previous
                // text input before the next arrives. DO NOT remove this delay.
                thread::sleep(Duration::from_secs(1));
            }
        }
        let kiro_count = agents.len() - non_kiro.len();
        if kiro_count > 0 {
            eprintln!("\n  \u{2713} {kiro_count} kiro agent(s): prompt loaded via agent profile (no delay)");
        }
    }
}

fn run_delegate(
    sock: &PathBuf, team: &str, target: &str, text: &str,
    title: Option<String>, priority: Option<u32>,
    accept: &[String], deps: &[String], desc: Option<String>, no_report: bool,
) {
    let mut params = json!({
        "team_name": team,
        "title": title.unwrap_or_else(|| task_title_from_text(text)),
        "assignee": target,
        "priority": priority.unwrap_or(2),
    });
    if let Some(d) = desc { params["description"] = json!(d); }
    if !accept.is_empty() { params["acceptance_criteria"] = json!(accept); }
    if !deps.is_empty() { params["depends_on"] = json!(deps); }

    let created = match rpc_call(sock, "team.task.create", params) {
        Ok(v) => v,
        Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
    };

    let task = &created["result"];
    let task_id = task["id"].as_str().unwrap_or("");
    if !created["ok"].as_bool().unwrap_or(false) || task_id.is_empty() {
        println!("{}", pretty(&created));
        if !created["ok"].as_bool().unwrap_or(false) { process::exit(1); }
        return;
    }

    let instruction = format_task_instruction(task, text, no_report);
    let sent = match rpc_call(sock, "team.send", json!({
        "team_name": team, "agent_name": target,
        "text": format!("{instruction}\n"),
    })) {
        Ok(v) => v,
        Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
    };

    println!("{}", pretty(&json!({ "task": task, "send": sent })));
    if !sent["ok"].as_bool().unwrap_or(false) { process::exit(1); }
}

fn run_wait(sock: &PathBuf, team: &str, timeout: u32, interval: u32, mode: &str, task_id: Option<&str>) {
    // Prevent infinite loop: clamp interval to at least 1 second
    let interval = interval.max(1);
    eprintln!("Waiting for agents in team '{team}' (timeout: {timeout}s, mode: {mode})...");

    let mut agent_names: Vec<String> = Vec::new();
    if mode == "msg" || mode == "any" {
        if let Ok(r) = rpc_call(sock, "team.status", json!({ "team_name": team })) {
            if let Some(agents) = r["result"]["agents"].as_array() {
                agent_names = agents.iter()
                    .filter_map(|a| a["name"].as_str().map(String::from))
                    .collect();
            }
        }
    }

    let mut elapsed: u32 = 0;
    while elapsed < timeout {
        let mut report_done = false;
        let mut report_progress = "0/0".to_string();
        let mut msg_done = false;
        let mut msg_progress = "0/0".to_string();

        if mode == "report" || mode == "any" {
            match rpc_call(sock, "team.result.status", json!({ "team_name": team })) {
                Ok(r) => {
                    let res = &r["result"];
                    let done = res["completed"].as_u64().unwrap_or(0);
                    let total = res["total"].as_u64().unwrap_or(0);
                    report_done = res["all_done"].as_bool().unwrap_or(false);
                    report_progress = format!("{done}/{total}");
                }
                Err(e) => eprintln!("  Warning: result.status RPC failed: {e}"),
            }
        }

        if mode == "msg" || mode == "any" {
            match rpc_call(sock, "team.message.list", json!({ "team_name": team })) {
                Ok(r) => {
                    if let Some(messages) = r["result"]["messages"].as_array() {
                        let senders: std::collections::HashSet<&str> = messages.iter()
                            .filter_map(|m| m["from"].as_str()).collect();
                        let reported = agent_names.iter().filter(|a| senders.contains(a.as_str())).count();
                        let total = agent_names.len();
                        msg_done = reported >= total && total > 0;
                        msg_progress = format!("{reported}/{total}");
                    }
                }
                Err(e) => eprintln!("  Warning: message.list RPC failed: {e}"),
            }
        }

        let mut inbox_blocked: Vec<Value> = Vec::new();
        let mut inbox_review: Vec<Value> = Vec::new();
        let mut task_status: Option<String> = None;
        let mut task_obj = json!(null);

        if mode == "blocked" || mode == "review_ready" || mode == "idle" || task_id.is_some() {
            match rpc_call(sock, "team.inbox", json!({ "team_name": team })) {
                Ok(r) => {
                    if let Some(items) = r["result"]["items"].as_array() {
                        inbox_blocked = items.iter()
                            .filter(|i| i["kind"].as_str() == Some("task") && i["status"].as_str() == Some("blocked"))
                            .cloned().collect();
                        inbox_review = items.iter()
                            .filter(|i| i["kind"].as_str() == Some("task") && i["status"].as_str() == Some("review_ready"))
                            .cloned().collect();
                    }
                }
                Err(e) => eprintln!("  Warning: inbox RPC failed: {e}"),
            }
            if let Some(tid) = task_id {
                match rpc_call(sock, "team.task.get", json!({ "team_name": team, "task_id": tid })) {
                    Ok(r) => {
                        if r["ok"].as_bool().unwrap_or(false) {
                            task_obj = r["result"].clone();
                            task_status = task_obj["status"].as_str().map(String::from);
                        }
                    }
                    Err(e) => eprintln!("  Warning: task.get RPC failed for {tid}: {e}"),
                }
            }
        }

        if let Some(tid) = task_id {
            let st = task_status.as_deref().unwrap_or("unknown");
            eprintln!("  [{elapsed}/{timeout}s] task={tid} status={st}");
            if matches!(st, "blocked" | "review_ready" | "completed" | "failed" | "abandoned") {
                println!("{}", pretty(&json!({ "result": { "team_name": team, "task": task_obj } })));
                return;
            }
        }

        match mode {
            "report" => {
                eprintln!("  [{elapsed}/{timeout}s] {report_progress} agents reported (report)");
                if report_done {
                    eprintln!("All agents have reported results.");
                    if let Ok(r) = rpc_call(sock, "team.result.collect", json!({ "team_name": team })) {
                        println!("{}", pretty(&r));
                    }
                    return;
                }
            }
            "msg" => {
                eprintln!("  [{elapsed}/{timeout}s] {msg_progress} agents messaged (msg)");
                if msg_done {
                    eprintln!("All agents have posted messages.");
                    if let Ok(r) = rpc_call(sock, "team.message.list", json!({ "team_name": team })) {
                        println!("{}", pretty(&r));
                    }
                    return;
                }
            }
            "any" => {
                eprintln!("  [{elapsed}/{timeout}s] report={report_progress} msg={msg_progress} (any)");
                if report_done {
                    eprintln!("All agents have reported results.");
                    if let Ok(r) = rpc_call(sock, "team.result.collect", json!({ "team_name": team })) {
                        println!("{}", pretty(&r));
                    }
                    return;
                }
                if msg_done {
                    eprintln!("All agents have posted messages.");
                    if let Ok(r) = rpc_call(sock, "team.message.list", json!({ "team_name": team })) {
                        println!("{}", pretty(&r));
                    }
                    return;
                }
            }
            "blocked" => {
                eprintln!("  [{elapsed}/{timeout}s] blocked={}", inbox_blocked.len());
                if !inbox_blocked.is_empty() {
                    eprintln!("A task is blocked.");
                    println!("{}", pretty(&json!({
                        "result": { "team_name": team, "items": inbox_blocked, "count": inbox_blocked.len() }
                    })));
                    return;
                }
            }
            "review_ready" => {
                eprintln!("  [{elapsed}/{timeout}s] review_ready={}", inbox_review.len());
                if !inbox_review.is_empty() {
                    eprintln!("A task is ready for review.");
                    println!("{}", pretty(&json!({
                        "result": { "team_name": team, "items": inbox_review, "count": inbox_review.len() }
                    })));
                    return;
                }
            }
            "idle" => {
                if let Ok(r) = rpc_call(sock, "team.status", json!({ "team_name": team })) {
                    if let Some(agents) = r["result"]["agents"].as_array() {
                        let idle_count = agents.iter()
                            .filter(|a| a["agent_state"].as_str() == Some("idle")).count();
                        let active_count = agents.iter()
                            .filter(|a| matches!(a["agent_state"].as_str(), Some("running" | "blocked" | "review_ready")))
                            .count();
                        let total = idle_count + active_count;
                        eprintln!("  [{elapsed}/{timeout}s] idle={idle_count}/{total}");
                        if total > 0 && idle_count == total {
                            let idle_agents: Vec<&Value> = agents.iter()
                                .filter(|a| a["agent_state"].as_str() == Some("idle")).collect();
                            println!("{}", pretty(&json!({
                                "result": { "team_name": team, "agents": idle_agents, "count": idle_count }
                            })));
                            return;
                        }
                    }
                }
            }
            _ => { eprintln!("Unknown wait mode: {mode}"); process::exit(1); }
        }

        thread::sleep(Duration::from_secs(interval as u64));
        elapsed += interval;
    }

    eprintln!("Timeout: not all agents reported within {timeout}s");
    if let Ok(r) = rpc_call(sock, "team.result.status", json!({ "team_name": team })) {
        println!("{}", pretty(&r));
    }
    process::exit(1);
}

fn run_brief(sock: &PathBuf, team: &str, target: &str, lines: u32) {
    let status = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(v) => v,
        Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
    };

    let agents = status["result"]["agents"].as_array();
    let agent_info = agents.and_then(|arr| arr.iter().find(|a| a["name"].as_str() == Some(target)));
    let agent_info = match agent_info {
        Some(a) => a.clone(),
        None => { eprintln!("Error: agent '{target}' not found in team '{team}'"); process::exit(1); }
    };

    // Get active task
    let mut active_task = json!(null);
    if let Some(task_id) = agent_info["active_task_id"].as_str() {
        if let Ok(r) = rpc_call(sock, "team.task.get", json!({ "team_name": team, "task_id": task_id })) {
            if r["ok"].as_bool().unwrap_or(false) {
                active_task = r["result"].clone();
            }
        }
    }

    // Get recent messages
    let mut messages = json!([]);
    if let Ok(r) = rpc_call(sock, "team.message.list", json!({ "team_name": team, "from": target, "limit": 5 })) {
        if r["ok"].as_bool().unwrap_or(false) {
            messages = r["result"]["messages"].clone();
        }
    }

    // Read terminal output (3-level fallback)
    let mut terminal_tail = String::new();

    // 1: team.read
    if let Ok(r) = rpc_call(sock, "team.read", json!({ "team_name": team, "agent_name": target, "lines": lines })) {
        if r["ok"].as_bool().unwrap_or(false) {
            terminal_tail = r["result"]["text"].as_str().unwrap_or("").to_string();
        }
    }

    // 2: pane.read
    if terminal_tail.trim().is_empty() {
        if let Some(panel_id) = agent_info["panel_id"].as_str() {
            if let Ok(r) = rpc_call(sock, "pane.read", json!({ "panel_id": panel_id, "lines": lines })) {
                if r["ok"].as_bool().unwrap_or(false) {
                    terminal_tail = r["result"]["text"].as_str().unwrap_or("").to_string();
                }
            }
        }
    }

    // 3: last report
    if terminal_tail.trim().is_empty() {
        if let Ok(r) = rpc_call(sock, "team.reports", json!({ "team_name": team, "agent_name": target, "limit": 1 })) {
            if r["ok"].as_bool().unwrap_or(false) {
                if let Some(reports) = r["result"]["reports"].as_array() {
                    if let Some(first) = reports.first() {
                        let content = first["content"].as_str().unwrap_or("");
                        let trunc = if content.len() > 500 {
                            let mut end = 500;
                            while end > 0 && !content.is_char_boundary(end) {
                                end -= 1;
                            }
                            &content[..end]
                        } else {
                            content
                        };
                        terminal_tail = format!("[Last report] {trunc}");
                    }
                }
            }
        }
    }

    println!("{}", pretty(&json!({
        "team_name": team,
        "agent": {
            "name": agent_info["name"],
            "status": agent_info["status"],
            "agent_type": agent_info["agent_type"],
            "panel_id": agent_info["panel_id"],
            "active_task_id": agent_info["active_task_id"],
            "active_task_status": agent_info["active_task_status"],
            "active_task_title": agent_info["active_task_title"],
            "attention_reason": agent_info["attention_reason"],
            "last_heartbeat_at": agent_info["last_heartbeat_at"],
            "last_heartbeat_summary": agent_info["last_heartbeat_summary"],
            "heartbeat_age_seconds": agent_info["heartbeat_age_seconds"],
            "heartbeat_is_stale": agent_info["heartbeat_is_stale"],
        },
        "active_task": active_task,
        "recent_messages": messages,
        "terminal_tail": terminal_tail,
    })));
}
