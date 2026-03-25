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
    "\n\n[IMPORTANT] When done, run: tm-agent reply '<one-paragraph summary of your result>' to report your result.",
);

const BROADCAST_SUFFIX: &str = concat!(
    "\n\n[IMPORTANT] When done, run: `tm-agent reply '<one-paragraph summary>'` to report your result.",
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
When you complete any task, run: `tm-agent reply '<one-paragraph summary>'` to report.\n\
Respond with \"Agent {agent} ready.\" to confirm.",
    )
}

// ── CLI definition ───────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "tm-agent", about = "term-mesh team CLI — unified agent & leader tool", version)]
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
    Ping {
        summary: Option<String>,
        /// Run heartbeat automatically every N seconds until parent process exits or Ctrl+C
        #[arg(long)]
        auto: bool,
        /// Interval in seconds for auto mode (default: 30)
        #[arg(long, default_value_t = 30)]
        interval: u64,
    },
    /// Send heartbeat
    Heartbeat {
        summary: Option<String>,
        /// Run heartbeat automatically every N seconds until parent process exits or Ctrl+C
        #[arg(long)]
        auto: bool,
        /// Interval in seconds for auto mode (default: 30)
        #[arg(long, default_value_t = 30)]
        interval: u64,
    },
    /// Show team status
    Status,
    /// Check agent inbox
    Inbox,
    /// Execute multiple commands in a single socket roundtrip
    Batch {
        /// Commands separated by semicolons (e.g., "send a:msg1; send b:msg2; status")
        #[arg(required = true)]
        commands: String,
    },
    /// Send raw JSON-RPC payload
    Raw { payload: String },

    // ── Grouped subcommands ────────────────────────────────────────
    /// Task operations (create, start, done, block, review, list, ...)
    #[command(subcommand)]
    Task(TaskCommands),
    /// Message operations (send, list, clear)
    #[command(subcommand)]
    Msg(MsgCommands),
    /// Shared context store
    #[command(subcommand)]
    Context(ContextCommands),
    /// Task template operations (list, show)
    #[command(subcommand)]
    Template(TemplateCommands),

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
        /// Set model for the leader (e.g. opus, sonnet, haiku)
        #[arg(long)]
        leader_model: Option<String>,
        #[arg(long)]
        kiro: Option<String>,
        #[arg(long)]
        codex: Option<String>,
        #[arg(long)]
        gemini: Option<String>,
        /// Adopt current terminal as leader pane (skip leader pane creation)
        #[arg(long)]
        adopt: bool,
        /// Use a named preset (e.g. "standard", "architect")
        #[arg(long)]
        preset: Option<String>,
        /// Comma-separated roles to create (e.g. "explorer,executor,reviewer")
        #[arg(long)]
        roles: Option<String>,
        /// Spawn headless agents (no GUI panes, daemon-managed subprocesses)
        #[arg(long)]
        headless: bool,
        /// Resume a previous Claude Code session for the leader.
        /// Without a value: shows interactive session picker.
        /// With a session ID: resumes that specific session.
        #[arg(long)]
        resume_session: Option<Option<String>>,
    },
    /// Add an agent to an existing team
    Add {
        /// Agent type/name (e.g. "security", "executor", "reviewer")
        agent_type: String,
        /// Custom agent name (defaults to agent_type)
        #[arg(long)]
        name: Option<String>,
        /// Model to use (e.g. sonnet, opus, haiku)
        #[arg(long, default_value = "sonnet")]
        model: String,
        /// CLI to use (claude, codex, kiro, gemini)
        #[arg(long, default_value = "claude")]
        cli: String,
    },
    /// Preset operations (list)
    #[command(subcommand)]
    Preset(PresetCommands),
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
        /// Prior context (e.g. previous attempts, errors) to inject into agent instruction
        #[arg(long)]
        context: Option<String>,
        /// Auto-fix budget: max number of fix attempts before auto-blocking
        #[arg(long)]
        auto_fix_budget: Option<u8>,
    },
    /// Stop (interrupt) agents by sending Ctrl+C to their terminals
    Stop {
        /// Agent name to interrupt, or omit for all agents
        agent: Option<String>,
        /// Interrupt all agents in the team
        #[arg(long)]
        all: bool,
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
        /// Comma-separated list of agent names to wait for (default: all agents)
        #[arg(long)]
        agents: Option<String>,
    },
    /// Delegate a task to all agents (broadcast with task tracking)
    FanOut {
        text: String,
        #[arg(long)]
        title: Option<String>,
        #[arg(long)]
        priority: Option<u32>,
        #[arg(long)]
        no_report: bool,
        /// Comma-separated list of agents to target (default: all)
        #[arg(long)]
        agents: Option<String>,
        /// Prior context (e.g. previous attempts, errors) to inject into agent instruction
        #[arg(long)]
        context: Option<String>,
        /// Auto-fix budget: max number of fix attempts before auto-blocking
        #[arg(long)]
        auto_fix_budget: Option<u8>,
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
    /// Claim the next available pending task (work-stealing)
    Claim,
    /// Suggest the best agent for a task description based on capability mapping
    Suggest {
        /// Task description to match against agent capabilities
        task: Vec<String>,
    },
    /// Warm up agents (send pong task, wait for response, print latency)
    Warmup {
        /// Specific agent to warm up (default: all agents)
        agent: Option<String>,
        /// Timeout in seconds (default: 30)
        #[arg(long, default_value_t = 30)]
        timeout: u32,
    },

    // ── Legacy hyphenated aliases (hidden) ───────────────────────────
    /// Alias: task-get → task get
    #[command(name = "task-get", hide = true)]
    TaskGet { id: String },
    /// Alias: task-start → task start
    #[command(name = "task-start", hide = true)]
    TaskStart { task_id: String },
    /// Alias: task-done → task done
    #[command(name = "task-done", hide = true)]
    TaskDone { task_id: String, result: Option<String> },
    /// Alias: task-block → task block
    #[command(name = "task-block", hide = true)]
    TaskBlock { task_id: String, reason: Option<String> },
    /// Alias: task-list → task list
    #[command(name = "task-list", hide = true)]
    TaskList,
    /// Alias: tasks → task list
    #[command(name = "tasks", hide = true)]
    Tasks,
    /// Alias: task-create → task create
    #[command(name = "task-create", hide = true)]
    TaskCreate2 {
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
    /// Alias: task-update → task update
    #[command(name = "task-update", hide = true)]
    TaskUpdate2 { id: String, status: String, result: Option<String> },
    /// Alias: task-review → task review
    #[command(name = "task-review", hide = true)]
    TaskReview2 { id: String, summary: Option<String> },
    /// Alias: task-reassign → task reassign
    #[command(name = "task-reassign", hide = true)]
    TaskReassign2 { id: String, agent: String },
    /// Alias: task-unblock → task unblock
    #[command(name = "task-unblock", hide = true)]
    TaskUnblock2 { id: String },
    /// Alias: task-clear → task clear
    #[command(name = "task-clear", hide = true)]
    TaskClear2,
}

#[derive(Subcommand)]
enum TaskCommands {
    /// Create a task (use --template <name> to load from a template)
    Create {
        /// Task title (optional when --template is used)
        title: Option<String>,
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
        /// Load task from a template (builtin: analysis, review, implement)
        #[arg(long)]
        template: Option<String>,
        /// Template variable substitution: --var key=value (repeatable)
        #[arg(long, value_parser = parse_template_var)]
        var: Vec<(String, String)>,
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
    /// Record a fix attempt (increments fix counter, auto-blocks when budget exhausted)
    #[command(name = "fix-attempt")]
    FixAttempt { task_id: String },
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

#[derive(Subcommand)]
enum ContextCommands {
    /// Set a context key-value pair
    Set { key: String, value: String },
    /// Get a context value by key
    Get { key: String },
    /// List all context entries
    List,
}

#[derive(Subcommand)]
enum PresetCommands {
    /// List all available presets
    List,
}

#[derive(Subcommand)]
enum TemplateCommands {
    /// List available task templates (builtin + ~/.term-mesh/templates/)
    List,
    /// Show template details
    Show { name: String },
}

// ── Task template system ─────────────────────────────────────────────

/// Parse `key=value` CLI arg for `--var`.
fn parse_template_var(s: &str) -> Result<(String, String), String> {
    s.split_once('=')
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .ok_or_else(|| format!("expected key=value, got: {s}"))
}

/// A task template with optional variable placeholders (`{{var}}`).
struct TaskTemplate {
    name: String,
    title: String,
    description: Option<String>,
    priority: Option<u32>,
    assign: Option<String>,
}

impl TaskTemplate {
    fn substitute(&self, vars: &[(String, String)]) -> TaskTemplate {
        let apply = |s: &str| {
            let mut out = s.to_string();
            for (k, v) in vars {
                out = out.replace(&format!("{{{{{k}}}}}"), v);
            }
            out
        };
        TaskTemplate {
            name: self.name.clone(),
            title: apply(&self.title),
            description: self.description.as_deref().map(apply),
            priority: self.priority,
            assign: self.assign.clone(),
        }
    }
}

/// Built-in templates hardcoded in binary (no file needed).
fn builtin_templates() -> Vec<TaskTemplate> {
    vec![
        TaskTemplate {
            name: "analysis".into(),
            title: "코드 분석: {{target}}".into(),
            description: Some(
                "{{target}}을 분석하고 다음을 보고하라:\n\
                 - 구조 및 의존성\n\
                 - 잠재적 이슈\n\
                 - 개선 제안"
                    .into(),
            ),
            priority: Some(2),
            assign: Some("explorer".into()),
        },
        TaskTemplate {
            name: "review".into(),
            title: "코드 리뷰: {{target}}".into(),
            description: Some(
                "{{target}}을 리뷰하라:\n\
                 - 버그 및 엣지 케이스\n\
                 - 성능 문제\n\
                 - 보안 취약점\n\
                 - 가독성 및 유지보수성"
                    .into(),
            ),
            priority: Some(2),
            assign: Some("reviewer".into()),
        },
        TaskTemplate {
            name: "implement".into(),
            title: "구현: {{feature}}".into(),
            description: Some(
                "{{feature}}을 구현하라:\n\
                 1. 설계 확인\n\
                 2. 코드 구현\n\
                 3. 테스트 작성\n\
                 4. 결과 보고"
                    .into(),
            ),
            priority: Some(2),
            assign: Some("executor".into()),
        },
    ]
}

/// Parse a minimal YAML template file (key: value / multiline |).
fn parse_template_yaml(content: &str) -> TaskTemplate {
    let mut map: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    let mut current_key = String::new();
    let mut multiline: Vec<String> = Vec::new();
    let mut in_multiline = false;

    for line in content.lines() {
        if in_multiline {
            if line.starts_with("  ") || line.starts_with('\t') {
                multiline.push(line.trim_start().to_string());
                continue;
            } else {
                map.insert(current_key.clone(), multiline.join("\n"));
                multiline.clear();
                in_multiline = false;
            }
        }
        if let Some((k, v)) = line.split_once(':') {
            let k = k.trim().to_string();
            let v = v.trim();
            if v == "|" {
                current_key = k;
                in_multiline = true;
            } else if !v.is_empty() {
                let unquoted = v.trim_matches('"').trim_matches('\'').to_string();
                map.insert(k, unquoted);
            }
        }
    }
    if in_multiline && !multiline.is_empty() {
        map.insert(current_key, multiline.join("\n"));
    }

    TaskTemplate {
        name: map.get("name").cloned().unwrap_or_default(),
        title: map.get("title").cloned().unwrap_or_else(|| "{{title}}".into()),
        description: map.get("description").cloned(),
        priority: map.get("priority").and_then(|s| s.parse().ok()),
        assign: map.get("assign").cloned(),
    }
}

/// Load a template: builtin first, then ~/.term-mesh/templates/{name}.yaml.
fn load_template(name: &str) -> Result<TaskTemplate, String> {
    // 1. Check builtin templates
    for t in builtin_templates() {
        if t.name == name {
            return Ok(t);
        }
    }
    // 2. Try user templates dir
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let path = PathBuf::from(home)
        .join(".term-mesh/templates")
        .join(format!("{name}.yaml"));
    let content = std::fs::read_to_string(&path)
        .map_err(|_| format!("template '{}' not found (checked builtin + {path:?})", name))?;
    Ok(parse_template_yaml(&content))
}

/// List all available templates (builtin + files in ~/.term-mesh/templates/).
fn list_all_templates() -> Vec<(String, String)> {
    let mut result: Vec<(String, String)> = builtin_templates()
        .into_iter()
        .map(|t| (t.name, "(builtin)".into()))
        .collect();

    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let dir = PathBuf::from(home).join(".term-mesh/templates");
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.extension().and_then(|e| e.to_str()) == Some("yaml") {
                let name = p.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
                if !result.iter().any(|(n, _)| n == &name) {
                    result.push((name, dir.display().to_string()));
                }
            }
        }
    }
    result
}

// ── Socket / RPC infrastructure ──────────────────────────────────────

fn detect_socket() -> Option<PathBuf> {
    // Priority 1: Explicit environment variable (always wins)
    if let Ok(sock) = env::var("TERMMESH_SOCKET") {
        let p = PathBuf::from(&sock);
        if is_socket_alive(&p) {
            return Some(p);
        }
    }

    // Priority 2: Last-used socket path recorded by reload.sh / reloads.sh
    // This avoids ambiguity when multiple tagged debug sockets exist.
    let last_socket_path = PathBuf::from("/tmp/term-mesh-last-socket-path");
    if last_socket_path.exists() {
        if let Ok(contents) = std::fs::read_to_string(&last_socket_path) {
            let p = PathBuf::from(contents.trim());
            if is_socket_alive(&p) {
                return Some(p);
            }
            // Stale/dead socket — fall through to glob detection
        }
    }

    // Priority 3: Glob fallback — try each, skip dead sockets
    let patterns = [
        "/tmp/term-mesh-debug-*.sock",
        "/tmp/term-mesh-debug.sock",
        "/tmp/term-mesh.sock",
        "/tmp/cmux.sock",
    ];
    for pattern in &patterns {
        if let Ok(paths) = glob::glob(pattern) {
            for entry in paths.flatten() {
                if is_socket_alive(&entry) {
                    return Some(entry);
                }
            }
        }
    }
    None
}

/// Test if a Unix socket is actually listening (not just a stale file).
fn is_socket_alive(path: &PathBuf) -> bool {
    if !path.exists() {
        return false;
    }
    use std::os::unix::net::UnixStream;
    use std::time::Duration;
    match UnixStream::connect(path) {
        Ok(stream) => {
            let _ = stream.set_read_timeout(Some(Duration::from_millis(100)));
            let _ = stream.shutdown(std::net::Shutdown::Both);
            true
        }
        Err(_) => false,
    }
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

/// Send a JSON-RPC call using a caller-provided BufReader.
///
/// Use this when making sequential calls on the same connection so that one
/// shared BufReader is reused across both reads.  A fresh BufReader per call
/// (as in `rpc_call_on_stream`) can over-buffer: the internal 8 KB read-ahead
/// may pull bytes from the *next* response out of the OS socket buffer and then
/// lose them when the BufReader is dropped, causing the next read to see garbage
/// or EOF.  Sharing one BufReader eliminates that race.
fn rpc_call_with_reader(
    mut stream: &UnixStream,
    reader: &mut BufReader<&UnixStream>,
    method: &str,
    params: Value,
) -> Result<Value, String> {
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });
    let mut line = serde_json::to_string(&request).map_err(|e| format!("serialize: {e}"))?;
    line.push('\n');

    stream.write_all(line.as_bytes()).map_err(|e| format!("write: {e}"))?;

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

/// Parse human-readable semicolon-separated commands into JSON-RPC payload strings
/// for use with `rpc_batch`. Supported verbs: status, task list, send, broadcast.
fn parse_batch_commands(commands: &str, team: &str) -> Result<Vec<String>, String> {
    let mut payloads = Vec::new();
    for raw in commands.split(';') {
        let cmd = raw.trim();
        if cmd.is_empty() {
            continue;
        }
        let (verb, rest) = match cmd.find(' ') {
            Some(pos) => (&cmd[..pos], cmd[pos + 1..].trim()),
            None => (cmd, ""),
        };
        let rpc = match verb {
            "status" => json!({
                "jsonrpc": "2.0", "id": 1,
                "method": "team.status",
                "params": { "team_name": team }
            }),
            "task" => {
                let sub = match rest.find(' ') {
                    Some(pos) => &rest[..pos],
                    None => rest,
                };
                match sub {
                    "list" => json!({
                        "jsonrpc": "2.0", "id": 1,
                        "method": "team.task.list",
                        "params": { "team_name": team }
                    }),
                    _ => return Err(format!("batch: unknown task subcommand '{sub}'. Supported: list")),
                }
            }
            "send" => {
                // Accept "agent:message" or "agent message" formats
                let (agent_name, text) = if let Some(colon) = rest.find(':') {
                    (&rest[..colon], rest[colon + 1..].trim())
                } else {
                    match rest.find(' ') {
                        Some(pos) => (&rest[..pos], rest[pos + 1..].trim()),
                        None => return Err(
                            "batch: send requires <agent>:<text> or <agent> <text>".to_string()
                        ),
                    }
                };
                json!({
                    "jsonrpc": "2.0", "id": 1,
                    "method": "team.send",
                    "params": {
                        "team_name": team,
                        "agent_name": agent_name,
                        "text": format!("{text}\n")
                    }
                })
            }
            "broadcast" => {
                if rest.is_empty() {
                    return Err("batch: broadcast requires <text>".to_string());
                }
                json!({
                    "jsonrpc": "2.0", "id": 1,
                    "method": "team.broadcast",
                    "params": { "team_name": team, "text": format!("{rest}\n") }
                })
            }
            _ => return Err(format!(
                "batch: unsupported command '{verb}'. Supported: status, task list, send, broadcast"
            )),
        };
        payloads.push(serde_json::to_string(&rpc).map_err(|e| format!("batch: serialize: {e}"))?);
    }
    if payloads.is_empty() {
        return Err("batch: no commands provided".to_string());
    }
    Ok(payloads)
}

fn pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

/// Run heartbeat in a loop every `interval` seconds.
/// Stops when the parent process exits (detected via kill -0) or SIGINT/SIGTERM.
fn run_heartbeat_auto(sock: &PathBuf, team: &str, agent: &str, interval: u64, message: Option<&str>) -> Result<Value, String> {
    use std::sync::atomic::{AtomicBool, Ordering};

    static STOP: AtomicBool = AtomicBool::new(false);

    extern "C" fn handle_signal(_: libc::c_int) {
        STOP.store(true, Ordering::SeqCst);
    }
    unsafe {
        libc::signal(libc::SIGINT, handle_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, handle_signal as *const () as libc::sighandler_t);
    }

    let ppid = unsafe { libc::getppid() };
    let msg = message.unwrap_or("working...");

    eprintln!("auto-heartbeat started (interval={}s, ppid={}, send SIGINT/SIGTERM to stop)", interval, ppid);

    loop {
        // Send heartbeat
        let _ = rpc_call(sock, "team.agent.heartbeat", json!({
            "team_name": team,
            "agent_name": agent,
            "summary": msg,
        }));

        // Sleep in 100ms chunks to react to signals quickly
        let ticks = interval * 10;
        for _ in 0..ticks {
            if STOP.load(Ordering::SeqCst) {
                eprintln!("auto-heartbeat stopped (signal).");
                return Ok(json!({"ok": true, "stopped": "signal"}));
            }
            thread::sleep(Duration::from_millis(100));
        }

        // Check if parent process is still alive (kill -0)
        let alive = unsafe { libc::kill(ppid, 0) == 0 };
        if !alive {
            eprintln!("auto-heartbeat stopped (parent exited).");
            return Ok(json!({"ok": true, "stopped": "parent_exited"}));
        }
    }
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

fn format_task_instruction(
    sock: &PathBuf, team: &str,
    task: &Value, instruction: &str, no_report: bool,
    context: Option<&str>, fix_budget: Option<u8>,
) -> String {
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
            // Inject dependency results for completed deps
            for dep_id in &dep_strs {
                if let Ok(dep_resp) = rpc_call(sock, "team.task.get", json!({
                    "team_name": team, "task_id": dep_id,
                })) {
                    let dep_task = &dep_resp["result"];
                    if dep_task["status"].as_str() == Some("completed") {
                        let content = if let Some(path) = dep_task["result_path"].as_str() {
                            std::fs::read_to_string(path).ok()
                        } else {
                            dep_task["result"].as_str().map(String::from)
                        };
                        if let Some(text) = content {
                            let truncated = truncate_summary(&text, 2000);
                            lines.push(format!("\n[DEP_RESULT: {dep_id}]"));
                            lines.push(truncated);
                            lines.push(format!("[/DEP_RESULT]"));
                        }
                    }
                }
            }
        }
    }
    if let Some(desc) = task["description"].as_str() {
        if !desc.is_empty() {
            lines.push(format!("[TASK_DESCRIPTION] {desc}"));
        }
    }
    if let Some(ctx) = context {
        let truncated = truncate_summary(ctx, 3000);
        lines.push(String::new());
        lines.push("[PRIOR_CONTEXT]".to_string());
        lines.push(truncated);
        lines.push("[/PRIOR_CONTEXT]".to_string());
    }

    let task_id = task["id"].as_str().unwrap_or("");
    lines.push(String::new());
    lines.push("[FORMAT COMPLIANCE] Follow the leader's instructions EXACTLY as given. \
If a specific output format is requested, reproduce it precisely — \
do not paraphrase, summarize, or restructure the format.".to_string());
    lines.push(String::new());
    lines.push(instruction.trim().to_string());
    lines.push(String::new());
    lines.push("You MUST follow this task lifecycle:".to_string());
    lines.push(format!("- tm-agent task start {task_id}"));
    lines.push("- tm-agent heartbeat '<short progress summary>'".to_string());
    lines.push(format!("- tm-agent task block {task_id} '<reason>'"));
    lines.push(format!("- tm-agent task review {task_id} '<summary>'"));
    lines.push(format!("- tm-agent task done {task_id} '<result>'"));

    // Inject Auto-Fix Budget rules when budget is set
    if let Some(budget) = fix_budget {
        lines.push(String::new());
        lines.push(format!("## Auto-Fix Budget: {budget} attempts"));
        lines.push(format!("BEFORE each build/test/error fix attempt, run:"));
        lines.push(format!("  tm-agent task fix-attempt {task_id}"));
        lines.push(format!("If it prints BUDGET_EXHAUSTED, stop immediately — you are auto-blocked."));
        lines.push(format!("Architecture decisions (new deps, API/schema changes) require immediate block regardless of budget."));
    }

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

// ── Hybrid result delivery helpers ────────────────────────────────────

fn results_dir(team: &str) -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join(".term-mesh/results").join(team)
}

fn write_result_file(team: &str, filename: &str, content: &str) -> Result<PathBuf, String> {
    let dir = results_dir(team);
    std::fs::create_dir_all(&dir).map_err(|e| format!("mkdir: {e}"))?;
    let path = dir.join(filename);
    let tmp = dir.join(format!(".{filename}.tmp"));
    std::fs::write(&tmp, content).map_err(|e| format!("write: {e}"))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("rename: {e}"))?;
    Ok(path)
}

fn truncate_summary(content: &str, max_chars: usize) -> String {
    if content.len() <= max_chars { return content.to_string(); }
    let mut end = max_chars;
    while end > 0 && !content.is_char_boundary(end) { end -= 1; }
    format!("{}...", &content[..end])
}

fn cleanup_old_results(team: &str) {
    let dir = results_dir(team);
    if let Ok(entries) = std::fs::read_dir(&dir) {
        let cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(24 * 3600);
        for entry in entries.flatten() {
            if let Ok(meta) = entry.metadata() {
                if let Ok(modified) = meta.modified() {
                    if modified < cutoff {
                        let _ = std::fs::remove_file(entry.path());
                    }
                }
            }
        }
    }
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
            let report_content = content.as_deref().unwrap_or("done");
            let report_result = rpc_call(&sock, "team.report", json!({
                "team_name": team,
                "agent_name": agent,
                "content": report_content,
            }));
            // Auto-complete the active task (same logic as `reply`)
            if report_result.is_ok() {
                if let Ok(status_resp) = rpc_call(&sock, "team.status", json!({"team_name": &team})) {
                    if let Some(agents) = status_resp["result"]["agents"].as_array() {
                        for a in agents {
                            if a["name"].as_str() == Some(agent.as_str()) {
                                if let Some(tid) = a["active_task_id"].as_str() {
                                    if !matches!(a["active_task_status"].as_str(), Some("completed") | Some("failed") | Some("abandoned")) {
                                        let summary = truncate_summary(report_content, 1500);
                                        let _ = rpc_call(&sock, "team.task.update", json!({
                                            "team_name": &team, "task_id": tid,
                                            "status": "completed", "result": summary,
                                        }));
                                    }
                                }
                                break;
                            }
                        }
                    }
                }
            }
            report_result
        }
        Commands::Ping { summary, auto, interval } | Commands::Heartbeat { summary, auto, interval } => {
            if auto {
                run_heartbeat_auto(&sock, &team, &agent, interval, summary.as_deref())
            } else {
                rpc_call(&sock, "team.agent.heartbeat", json!({
                    "team_name": team,
                    "agent_name": agent,
                    "summary": summary.as_deref().unwrap_or("alive"),
                }))
            }
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
        Commands::Context(sub) => {
            match sub {
                ContextCommands::Set { key, value } => {
                    let agent = agent.clone();
                    rpc_call(&sock, "team.context.set", json!({
                        "team_name": team, "key": key, "value": value, "set_by": agent,
                    }))
                }
                ContextCommands::Get { key } => {
                    rpc_call(&sock, "team.context.get", json!({ "team_name": team, "key": key }))
                }
                ContextCommands::List => {
                    rpc_call(&sock, "team.context.list", json!({ "team_name": team }))
                }
            }
        }
        Commands::Template(sub) => {
            match sub {
                TemplateCommands::List => {
                    let templates = list_all_templates();
                    if templates.is_empty() {
                        println!("No templates found.");
                    } else {
                        println!("{:<20} {}", "NAME", "SOURCE");
                        println!("{}", "-".repeat(50));
                        for (name, source) in &templates {
                            println!("{:<20} {}", name, source);
                        }
                    }
                    return;
                }
                TemplateCommands::Show { name } => {
                    match load_template(&name) {
                        Ok(t) => {
                            println!("name:     {}", t.name);
                            println!("title:    {}", t.title);
                            if let Some(d) = &t.description {
                                println!("desc:\n  {}", d.replace('\n', "\n  "));
                            }
                            if let Some(p) = t.priority { println!("priority: {p}"); }
                            if let Some(a) = &t.assign { println!("assign:   {a}"); }
                            return;
                        }
                        Err(e) => {
                            eprintln!("Error: {e}");
                            process::exit(1);
                        }
                    }
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
                    let result_text = result.as_deref().unwrap_or("done");
                    // Write full result to file, send truncated summary via socket
                    let result_path = write_result_file(&team, &format!("{task_id}.md"), result_text).ok();
                    let summary = truncate_summary(result_text, 1500);
                    let mut params = json!({
                        "team_name": team, "task_id": task_id,
                        "result": summary,
                    });
                    if let Some(ref path) = result_path {
                        params["result_path"] = json!(path.to_string_lossy());
                    }
                    rpc_call(&sock, "team.task.done", params)
                }
                TaskCommands::Block { task_id, reason } => {
                    rpc_call(&sock, "team.task.block", json!({
                        "team_name": team, "task_id": task_id,
                        "blocked_reason": reason.as_deref().unwrap_or("blocked"),
                    }))
                }
                TaskCommands::Create { title, assign, desc, priority, accept, deps, template, var } => {
                    // Resolve template (if provided), CLI args take precedence over template values
                    let (tmpl_title, tmpl_desc, tmpl_assign, tmpl_priority) =
                        if let Some(ref tname) = template {
                            match load_template(tname) {
                                Ok(t) => {
                                    let t = t.substitute(&var);
                                    (Some(t.title), t.description, t.assign, t.priority)
                                }
                                Err(e) => {
                                    eprintln!("Error loading template '{tname}': {e}");
                                    std::process::exit(1);
                                }
                            }
                        } else {
                            (None, None, None, None)
                        };

                    let final_title = title.or(tmpl_title).unwrap_or_else(|| {
                        eprintln!("Error: title required (provide as positional arg or via --template)");
                        std::process::exit(1);
                    });
                    let final_desc = desc.or(tmpl_desc);
                    let final_assign = assign.or(tmpl_assign);
                    let final_priority = priority.or(tmpl_priority);

                    let mut params = json!({ "team_name": team, "title": final_title });
                    if let Some(a) = final_assign { params["assignee"] = json!(a); }
                    if let Some(d) = final_desc { params["description"] = json!(d); }
                    if let Some(p) = final_priority { params["priority"] = json!(p); }
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
                TaskCommands::FixAttempt { task_id } => {
                    match rpc_call(&sock, "team.task.fix_attempt", json!({
                        "team_name": team, "task_id": task_id,
                    })) {
                        Ok(ref v) => {
                            let result = &v["result"];
                            let count = result["fix_count"].as_u64().unwrap_or(0);
                            let budget = result["fix_budget"].as_u64().unwrap_or(0);
                            let blocked = result["blocked"].as_bool().unwrap_or(false);
                            if blocked {
                                eprintln!("⚠️  Fix budget exhausted ({}/{}). Task auto-blocked.", count, budget);
                            } else {
                                eprintln!("Fix attempt {}/{} recorded.", count, budget);
                            }
                            Ok(v.clone())
                        }
                        Err(e) => {
                            // If server doesn't support fix_attempt yet, warn but don't fail
                            eprintln!("Warning: fix_attempt RPC not available ({}). Continuing without budget tracking.", e);
                            Ok(json!({"ok": true, "result": {"fix_count": 0, "fix_budget": 0, "blocked": false}}))
                        }
                    }
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
        // ── Legacy hyphenated aliases ────────────────────────────────
        Commands::TaskGet { id } => {
            rpc_call(&sock, "team.task.get", json!({
                "team_name": team, "task_id": id,
            }))
        }
        Commands::TaskStart { task_id } => {
            rpc_call(&sock, "team.task.update", json!({
                "team_name": team, "task_id": task_id, "status": "in_progress",
            }))
        }
        Commands::TaskDone { task_id, result } => {
            rpc_call(&sock, "team.task.done", json!({
                "team_name": team, "task_id": task_id,
                "result": result.as_deref().unwrap_or("done"),
            }))
        }
        Commands::TaskBlock { task_id, reason } => {
            rpc_call(&sock, "team.task.block", json!({
                "team_name": team, "task_id": task_id,
                "blocked_reason": reason.as_deref().unwrap_or("blocked"),
            }))
        }
        Commands::TaskList | Commands::Tasks => {
            rpc_call(&sock, "team.task.list", json!({ "team_name": team }))
        }
        Commands::TaskCreate2 { title, assign, desc, priority, accept, deps } => {
            let mut params = json!({ "team_name": team, "title": title });
            if let Some(a) = assign { params["assignee"] = json!(a); }
            if let Some(d) = desc { params["description"] = json!(d); }
            if let Some(p) = priority { params["priority"] = json!(p); }
            if !accept.is_empty() { params["acceptance_criteria"] = json!(accept); }
            if !deps.is_empty() { params["depends_on"] = json!(deps); }
            rpc_call(&sock, "team.task.create", params)
        }
        Commands::TaskUpdate2 { id, status, result } => {
            let mut params = json!({
                "team_name": team, "task_id": id, "status": status,
            });
            if let Some(r) = result { params["result"] = json!(r); }
            rpc_call(&sock, "team.task.update", params)
        }
        Commands::TaskReview2 { id, summary } => {
            rpc_call(&sock, "team.task.review", json!({
                "team_name": team, "task_id": id,
                "summary": summary.as_deref().unwrap_or(""),
            }))
        }
        Commands::TaskReassign2 { id, agent: ref target } => {
            rpc_call(&sock, "team.task.reassign", json!({
                "team_name": team, "task_id": id, "assignee": target,
            }))
        }
        Commands::TaskUnblock2 { id } => {
            rpc_call(&sock, "team.task.unblock", json!({
                "team_name": team, "task_id": id,
            }))
        }
        Commands::TaskClear2 => {
            rpc_call(&sock, "team.task.clear", json!({ "team_name": team }))
        }
        Commands::Status => {
            rpc_call(&sock, "team.status", json!({ "team_name": team }))
        }
        Commands::Inbox => {
            rpc_call(&sock, "team.inbox", json!({
                "team_name": team, "agent_name": agent,
            }))
        }
        Commands::Batch { commands } => {
            let payloads = match parse_batch_commands(&commands, &team) {
                Ok(p) => p,
                Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
            };
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
            cleanup_old_results(&team);
            // Also destroy headless team if it exists
            if let Some(daemon_sock) = detect_daemon_socket() {
                let _ = rpc_call_timeout(&daemon_sock, "headless.destroy_team", json!({ "team_name": team }), 5);
            }
            rpc_call(&sock, "team.destroy", json!({ "team_name": team }))
        }
        Commands::List => {
            rpc_call(&sock, "team.list", json!({}))
        }
        Commands::Read { agent: ref agent_name, lines } => {
            // Check if agent is headless — route to daemon socket
            if let Some(daemon_sock) = detect_daemon_socket() {
                if let Some(agent_id) = is_headless_agent(&daemon_sock, &team, agent_name) {
                    print_result(rpc_call(&daemon_sock, "headless.read", json!({
                        "agent_id": agent_id,
                        "lines": lines,
                    })));
                    return;
                }
            }
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
        Commands::Create { count, claude_leader, model, leader_model, kiro, codex, gemini, adopt, preset, roles, headless, resume_session } => {
            if headless {
                run_create_headless(&sock, &team, count.unwrap_or(2), &model, roles.as_deref());
            } else {
                run_create(&sock, &team, count.unwrap_or(2), claude_leader, &model, leader_model.as_deref(), &kiro, &codex, &gemini, adopt, preset.as_deref(), roles.as_deref(), resume_session);
            }
            return;
        }
        Commands::Add { agent_type, name, model, cli } => {
            let agent_name = name.unwrap_or_else(|| agent_type.clone());

            // Try headless path first
            if let Some(daemon_sock) = detect_daemon_socket() {
                // Check if the team exists as a headless team
                if let Ok(resp) = rpc_call(&daemon_sock, "headless.list_teams", json!({})) {
                    let is_headless = resp["result"].as_array()
                        .map(|teams| teams.iter().any(|t| t["name"].as_str() == Some(&team)))
                        .unwrap_or(false);
                    if is_headless {
                        run_add_headless(&sock, &daemon_sock, &team, &agent_name, &agent_type, &model, &cli);
                        return;
                    }
                }
            }

            // GUI team: not yet supported
            eprintln!("Error: 'tm-agent add' for GUI teams is not yet supported.");
            eprintln!("Hint: Use 'tm-agent destroy' then 'tm-agent create' to recreate with different agents.");
            eprintln!("      Headless team support: 'tm-agent create --headless ...' then 'tm-agent add ...'");
            process::exit(1);
        }
        Commands::Preset(sub) => {
            match sub {
                PresetCommands::List => {
                    match rpc_call(&sock, "team.preset.list", json!({})) {
                        Ok(resp) => {
                            if let Some(presets) = resp["result"]["presets"].as_array() {
                                println!("{:<20} {:<30} {:<8} {}", "ID", "Name", "Agents", "Description");
                                println!("{}", "-".repeat(80));
                                for p in presets {
                                    let id = p["id"].as_str().unwrap_or("");
                                    let name = p["name"].as_str().unwrap_or("");
                                    let desc = p["description"].as_str().unwrap_or("");
                                    let agent_count = p["agents"].as_array().map(|a| a.len()).unwrap_or(0);
                                    println!("{:<20} {:<30} {:<8} {}", id, name, agent_count, desc);
                                }
                            } else {
                                println!("{}", pretty(&resp));
                            }
                        }
                        Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
                    }
                    return;
                }
            }
        }
        Commands::Stop { agent, all } => {
            if all || agent.is_none() {
                // Interrupt all agents in the team
                print_result(rpc_call(&sock, "team.interrupt_all", json!({
                    "team_name": team,
                })));
            } else if let Some(ref target) = agent {
                // Interrupt a specific agent
                print_result(rpc_call(&sock, "team.interrupt", json!({
                    "team_name": team, "agent_name": target,
                })));
            }
            return;
        }
        Commands::Send { agent: ref target, text, no_report } => {
            let text = append_report_suffix(&text, no_report);
            // Check if agent is headless — route to daemon socket
            if let Some(daemon_sock) = detect_daemon_socket() {
                if let Some(agent_id) = is_headless_agent(&daemon_sock, &team, target) {
                    print_result(rpc_call(&daemon_sock, "headless.send", json!({
                        "agent_id": agent_id,
                        "text": format!("{text}\n"),
                    })));
                    return;
                }
            }
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
        Commands::Delegate { agent: ref target, text, title, priority, accept, deps, desc, no_report, context, auto_fix_budget } => {
            // Auto-detect comma-separated agents and route to parallel fan-out
            if target.contains(',') {
                run_fan_out(&sock, &team, &text, title, priority, no_report, &Some(target.to_string()), context.as_deref(), auto_fix_budget);
            } else {
                run_delegate(&sock, &team, target, &text, title, priority, &accept, &deps, desc, no_report, context.as_deref(), auto_fix_budget);
            }
            return;
        }
        Commands::FanOut { text, title, priority, no_report, agents, context, auto_fix_budget } => {
            run_fan_out(&sock, &team, &text, title, priority, no_report, &agents, context.as_deref(), auto_fix_budget);
            return;
        }
        Commands::Wait { timeout, interval, mode, task, agents } => {
            let filter = parse_cli_flag(&agents);
            run_wait(&sock, &team, timeout, interval, &mode, task.as_deref(), &filter);
            return;
        }
        Commands::Claim => {
            run_claim(&sock, &team, &agent);
            return;
        }
        Commands::Suggest { task } => {
            let description = task.join(" ");
            run_suggest(&sock, &team, &description);
            return;
        }
        Commands::Warmup { agent: ref target, timeout } => {
            run_warmup(&sock, &team, target.as_deref(), timeout);
            return;
        }
        Commands::Brief { agent: ref target, lines } => {
            run_brief(&sock, &team, target, lines);
            return;
        }
        Commands::Reply { text, from } => {
            let sender = from.unwrap_or_else(|| agent.clone());
            let content = text.join(" ");
            // Write full result to file, send truncated summary via socket
            let result_path = write_result_file(&team, &format!("{sender}-reply.md"), &content).ok();
            let summary = truncate_summary(&content, 1500);
            let mut msg_params = json!({
                "team_name": team, "from": sender, "content": summary,
                "to": "leader", "type": "report",
            });
            if let Some(ref path) = result_path {
                msg_params["result_path"] = json!(path.to_string_lossy());
            }
            print_result(rpc_call(&sock, "team.message.post", msg_params));
            // Auto-submit report for wait detection (with result_path)
            let mut report_params = json!({
                "team_name": team, "agent_name": sender, "content": summary,
            });
            if let Some(ref path) = result_path {
                report_params["result_path"] = json!(path.to_string_lossy());
            }
            let _ = rpc_call(&sock, "team.report", report_params);
            // Auto-complete the active task for this agent.
            // Use team.task.list (data command, no MainActor) instead of team.status
            // (UI command, MainActor) to avoid timeout when main thread is busy —
            // a timeout here silently skips task completion, causing the leader's
            // `wait` to hang indefinitely.
            if let Ok(task_resp) = rpc_call(&sock, "team.task.list", json!({
                "team_name": &team, "assignee": &sender
            })) {
                if let Some(tasks) = task_resp["result"]["tasks"].as_array() {
                    for t in tasks {
                        let status = t["status"].as_str().unwrap_or("");
                        if status != "completed" && status != "failed" && status != "abandoned" {
                            if let Some(tid) = t["id"].as_str() {
                                let mut update = json!({
                                    "team_name": &team, "task_id": tid,
                                    "status": "completed", "result": &summary,
                                });
                                if let Some(ref path) = result_path {
                                    update["result_path"] = json!(path.to_string_lossy());
                                }
                                let _ = rpc_call(&sock, "team.task.update", update);
                            }
                        }
                    }
                }
            }
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

// ── Session picker ──────────────────────────────────────────────────

/// A Claude Code session entry parsed from the project session directory.
struct SessionEntry {
    id: String,
    modified: std::time::SystemTime,
    first_message: String,
    last_message: String,
}

/// Discover the Claude Code sessions directory for the current working directory.
fn claude_sessions_dir() -> Option<PathBuf> {
    let home = env::var("HOME").ok()?;
    let cwd = env::current_dir().ok()?;
    // Claude Code encodes the project path as dash-separated: /Users/foo/bar → -Users-foo-bar
    let encoded = cwd.to_string_lossy().replace('/', "-");
    let dir = PathBuf::from(format!("{home}/.claude/projects/{encoded}"));
    if dir.is_dir() { Some(dir) } else { None }
}

/// List recent sessions from the Claude Code sessions directory.
fn list_recent_sessions(limit: usize) -> Vec<SessionEntry> {
    let dir = match claude_sessions_dir() {
        Some(d) => d,
        None => return vec![],
    };

    let mut entries: Vec<SessionEntry> = vec![];
    if let Ok(read_dir) = std::fs::read_dir(&dir) {
        for entry in read_dir.flatten() {
            let path = entry.path();
            let name = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) => n.to_string(),
                None => continue,
            };
            // Only .jsonl session files with UUID names
            if !name.ends_with(".jsonl") { continue; }
            let id = name.trim_end_matches(".jsonl");
            // Quick UUID format check (8-4-4-4-12)
            if id.len() != 36 || id.chars().filter(|c| *c == '-').count() != 4 { continue; }

            let modified = match entry.metadata().and_then(|m| m.modified()) {
                Ok(t) => t,
                Err(_) => continue,
            };

            // Extract first user message and last assistant message
            let (first_message, last_message) = extract_messages(&path);

            entries.push(SessionEntry {
                id: id.to_string(),
                modified,
                first_message,
                last_message,
            });
        }
    }

    // Sort by modification time, newest first
    entries.sort_by(|a, b| b.modified.cmp(&a.modified));
    entries.truncate(limit);
    entries
}

/// Extract text content from a session JSONL entry.
/// User messages: `message.content` is a string.
/// Assistant messages: `message.content` is `[{"type":"text","text":"..."}]`.
fn extract_text_from_entry(val: &Value) -> String {
    // Try message.content first (current format)
    let msg = &val["message"]["content"];
    if let Some(s) = msg.as_str() {
        return s.to_string();
    }
    if let Some(arr) = msg.as_array() {
        let texts: Vec<&str> = arr.iter()
            .filter(|b| b["type"].as_str() == Some("text"))
            .filter_map(|b| b["text"].as_str())
            .collect();
        if !texts.is_empty() {
            return texts.join(" ");
        }
    }
    // Fallback: top-level content (older format)
    val["content"].as_str().unwrap_or("").to_string()
}

/// Extract the first user message and last assistant message from a session JSONL file.
fn extract_messages(path: &PathBuf) -> (String, String) {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return (String::new(), String::new()),
    };

    // First message: read first ~16KB
    let mut head_buf = vec![0u8; 16384];
    let head_n = file.read(&mut head_buf).unwrap_or(0);
    head_buf.truncate(head_n);
    let head_text = String::from_utf8_lossy(&head_buf);

    let mut first_message = String::new();
    for line in head_text.lines().take(50) {
        if let Ok(val) = serde_json::from_str::<Value>(line) {
            if val["type"].as_str() != Some("user") { continue; }
            let text = extract_text_from_entry(&val);
            if text.contains("<system-reminder>") || text.contains("<command-name>")
                || text.contains("<local-command") {
                continue;
            }
            let trimmed = text.trim();
            if trimmed.is_empty() { continue; }
            // Label commit generator sessions clearly
            if trimmed.starts_with("You are a commit message generator") {
                first_message = "[commit message]".to_string();
                break;
            }
            let display: String = trimmed.chars().take(80).collect();
            first_message = if trimmed.chars().count() > 80 {
                format!("{display}...")
            } else {
                display
            };
            break;
        }
    }

    // Last message: read last ~32KB
    let file_len = file.metadata().map(|m| m.len()).unwrap_or(0);
    let tail_offset = if file_len > 32768 { file_len - 32768 } else { 0 };
    let _ = file.seek(SeekFrom::Start(tail_offset));
    let mut tail_buf = Vec::new();
    let _ = file.read_to_end(&mut tail_buf);
    let tail_text = String::from_utf8_lossy(&tail_buf);

    let mut last_message = String::new();
    for line in tail_text.lines().rev() {
        if let Ok(val) = serde_json::from_str::<Value>(line) {
            if val["type"].as_str() != Some("assistant") { continue; }
            let text = extract_text_from_entry(&val);
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                let display: String = trimmed.chars().take(80).collect();
                last_message = if trimmed.chars().count() > 80 {
                    format!("{display}...")
                } else {
                    display
                };
                break;
            }
        }
    }

    (first_message, last_message)
}

/// Format a SystemTime as a relative time string (e.g. "2h ago", "3d ago").
fn format_relative_time(time: std::time::SystemTime) -> String {
    let elapsed = time.elapsed().unwrap_or_default();
    let secs = elapsed.as_secs();
    if secs < 60 { return "just now".to_string(); }
    if secs < 3600 { return format!("{}m ago", secs / 60); }
    if secs < 86400 { return format!("{}h ago", secs / 3600); }
    format!("{}d ago", secs / 86400)
}

/// Interactive session picker. Returns a session ID or exits.
fn pick_session() -> String {
    let sessions = list_recent_sessions(15);
    if sessions.is_empty() {
        eprintln!("No recent sessions found for this project.");
        eprintln!("Hint: enter a session ID directly with --resume-session=<uuid>");
        process::exit(1);
    }

    eprintln!("\n  Recent sessions:\n");
    for (i, s) in sessions.iter().enumerate() {
        let time_str = format_relative_time(s.modified);
        let preview = if s.first_message.is_empty() {
            s.id[..8].to_string()
        } else {
            s.first_message.clone()
        };
        eprintln!("  {:>2}) {:<10} Q: {}", i + 1, time_str, preview);
        if !s.last_message.is_empty() {
            eprintln!("      {:<10} A: {}", "", s.last_message);
        }
    }
    eprintln!();
    eprint!("  Select [1-{}] or paste session ID: ", sessions.len());
    std::io::stderr().flush().ok();

    let mut input = String::new();
    if std::io::stdin().read_line(&mut input).is_err() || input.trim().is_empty() {
        eprintln!("No selection made.");
        process::exit(1);
    }
    let input = input.trim();

    // Try as number first
    if let Ok(num) = input.parse::<usize>() {
        if num >= 1 && num <= sessions.len() {
            return sessions[num - 1].id.clone();
        }
        eprintln!("Invalid selection: {num}");
        process::exit(1);
    }

    // Otherwise treat as session ID
    input.to_string()
}

/// Resolve --resume-session: None means not requested, Some(None) means interactive picker,
/// Some(Some(id)) means specific session ID.
fn resolve_resume_session(flag: Option<Option<String>>) -> Option<String> {
    match flag {
        None => None,
        Some(None) => Some(pick_session()),
        Some(Some(id)) if id.is_empty() => Some(pick_session()),
        Some(Some(id)) => Some(id),
    }
}

// ── Orchestration implementations ────────────────────────────────────

fn run_create(
    sock: &PathBuf, team: &str, count: u32, claude_leader: bool,
    model: &str, leader_model: Option<&str>, kiro: &Option<String>, codex: &Option<String>, gemini: &Option<String>,
    adopt: bool, preset: Option<&str>, roles: Option<&str>,
    resume_session: Option<Option<String>>,
) {
    // Guard: --adopt and --claude-leader are mutually exclusive
    if adopt && claude_leader {
        eprintln!("Error: --adopt and --claude-leader cannot be used together. In --adopt mode the current terminal is already the leader.");
        process::exit(1);
    }
    // Guard: --roles and count together — roles wins, count is ignored
    if roles.is_some() && count != 2 {
        eprintln!("Warning: --roles is specified; --count ({count}) will be ignored.");
    }
    // Resolve resume session before team creation (may show interactive picker)
    let resume_session_id = resolve_resume_session(resume_session);
    if resume_session_id.is_some() && adopt {
        eprintln!("Error: --resume-session and --adopt cannot be used together.");
        process::exit(1);
    }

    cleanup_old_results(team);
    // --resume-session implies claude leader mode (need Claude CLI to pass --resume)
    let leader_mode = if adopt {
        "adopted"
    } else if claude_leader || resume_session_id.is_some() {
        "claude"
    } else {
        "repl"
    };
    let leader_model = leader_model.unwrap_or(model);
    let kiro_agents = parse_cli_flag(kiro);
    let codex_agents = parse_cli_flag(codex);
    let gemini_agents = parse_cli_flag(gemini);

    // Resolve agents from preset or roles via RPC, or build from defaults
    let agents: Vec<serde_json::Value> = if let Some(preset_id) = preset {
        eprintln!("Resolving preset '{preset_id}'...");
        match rpc_call_timeout(sock, "team.preset.resolve", json!({
            "preset_id": preset_id,
            "model": model,
        }), 3) {
            Ok(resp) if resp["ok"].as_bool().unwrap_or(false) => {
                resp["result"]["agents"].as_array()
                    .cloned()
                    .unwrap_or_default()
            }
            Ok(resp) => {
                eprintln!("Error: preset resolve failed: {}", resp["error"]["message"].as_str().unwrap_or("unknown"));
                process::exit(1);
            }
            Err(e) => {
                eprintln!("Error: team.preset.resolve RPC failed (app may not support presets yet): {e}");
                process::exit(1);
            }
        }
    } else if let Some(roles_str) = roles {
        eprintln!("Resolving roles '{roles_str}'...");
        // Split comma-separated roles into a JSON array (Swift expects [String], not String)
        let roles_vec: Vec<&str> = roles_str.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
        match rpc_call_timeout(sock, "team.preset.resolve", json!({
            "roles": roles_vec,
            "model": model,
        }), 3) {
            Ok(resp) if resp["ok"].as_bool().unwrap_or(false) => {
                resp["result"]["agents"].as_array()
                    .cloned()
                    .unwrap_or_default()
            }
            Ok(resp) => {
                eprintln!("Error: roles resolve failed: {}", resp["error"]["message"].as_str().unwrap_or("unknown"));
                process::exit(1);
            }
            Err(e) => {
                eprintln!("Error: team.preset.resolve RPC failed (app may not support roles yet): {e}");
                process::exit(1);
            }
        }
    } else {
        // Default: build from DEFAULT_AGENT_NAMES up to count
        let mut default_agents = Vec::new();
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
            default_agents.push(json!({
                "name": name, "cli": cli, "model": model,
                "agent_type": name, "color": color,
            }));
        }
        default_agents
    };

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

    let agent_count = agents.len();
    if let Some(ref sid) = resume_session_id {
        eprintln!("Creating team '{team}' with {agent_count} agent(s) [leader: {leader_mode}, resume: {}]...", &sid[..8.min(sid.len())]);
    } else {
        eprintln!("Creating team '{team}' with {agent_count} agent(s) [leader: {leader_mode}]...");
    }
    eprintln!("Socket: {}", sock.display());

    // Pass caller's panel ID so the app can route team creation to the correct window
    let mut create_params = json!({
        "team_name": team,
        "working_directory": workdir,
        "leader_session_id": format!("leader-{}", process::id()),
        "leader_mode": leader_mode,
        "leader_model": leader_model,
        "agents": agents,
    });
    if let Some(ref sid) = resume_session_id {
        create_params["resume_session_id"] = json!(sid);
    }
    if let Ok(panel_id) = env::var("TERMMESH_PANEL_ID") {
        create_params["surface_id"] = json!(panel_id);
    }
    if let Ok(window_id) = env::var("TERMMESH_WINDOW_ID") {
        create_params["window_id"] = json!(window_id);
    }
    if let Ok(workspace_id) = env::var("TERMMESH_WORKSPACE_ID") {
        create_params["workspace_id"] = json!(workspace_id);
    }
    let r = match rpc_call_timeout(sock, "team.create", create_params, 5) {
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

fn detect_daemon_socket() -> Option<PathBuf> {
    // Priority 1: TERMMESH_DAEMON_SOCKET (injected by daemon into headless agent env)
    if let Ok(p) = env::var("TERMMESH_DAEMON_SOCKET") {
        if !p.is_empty() {
            let path = PathBuf::from(&p);
            if is_socket_alive(&path) {
                return Some(path);
            }
        }
    }
    // Priority 2: TERMMESH_DAEMON_UNIX_PATH (tagged build override)
    if let Ok(p) = env::var("TERMMESH_DAEMON_UNIX_PATH") {
        if !p.is_empty() {
            let path = PathBuf::from(&p);
            if is_socket_alive(&path) {
                return Some(path);
            }
        }
    }
    // Default daemon socket path
    let dir = env::var("TMPDIR").ok().map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    let path = dir.join("term-meshd.sock");
    if is_socket_alive(&path) {
        Some(path)
    } else {
        None
    }
}

/// Check if an agent is headless by querying the daemon's headless.resolve RPC.
fn is_headless_agent(daemon_sock: &PathBuf, team: &str, agent_name: &str) -> Option<String> {
    if let Ok(resp) = rpc_call(daemon_sock, "headless.resolve", json!({
        "team_name": team,
        "agent_name": agent_name,
    })) {
        if resp["result"]["headless"].as_bool().unwrap_or(false) {
            return resp["result"]["agent_id"].as_str().map(String::from);
        }
    }
    None
}

fn run_create_headless(
    app_sock: &PathBuf, team: &str, count: u32, model: &str, roles: Option<&str>,
) {
    let daemon_sock = match detect_daemon_socket() {
        Some(s) => s,
        None => {
            eprintln!("Error: daemon socket not found (is term-meshd running?)");
            process::exit(1);
        }
    };

    // Build agent list from roles or defaults
    let agent_specs: Vec<Value> = if let Some(roles_str) = roles {
        roles_str.split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .enumerate()
            .map(|(_i, name)| json!({ "name": name, "cli": "claude", "model": model }))
            .collect()
    } else {
        (0..count as usize)
            .map(|i| {
                let name = if i < DEFAULT_AGENT_NAMES.len() {
                    DEFAULT_AGENT_NAMES[i].to_string()
                } else {
                    format!("agent-{i}")
                };
                json!({ "name": name, "cli": "claude", "model": model })
            })
            .collect()
    };

    let workdir = env::current_dir()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| ".".to_string());

    // Destroy existing headless team first
    let _ = rpc_call_timeout(&daemon_sock, "headless.destroy_team", json!({ "team_name": team }), 3);

    let agent_count = agent_specs.len();
    eprintln!("Creating headless team '{team}' with {agent_count} agent(s) on daemon...");
    eprintln!("Daemon socket: {}", daemon_sock.display());

    let create_params = json!({
        "team_name": team,
        "working_directory": workdir,
        "leader_session_id": format!("leader-{}", process::id()),
        "agents": agent_specs,
        "app_socket_path": app_sock.to_string_lossy(),
    });

    match rpc_call_timeout(&daemon_sock, "headless.create_team", create_params, 30) {
        Ok(resp) => {
            if let Some(err) = resp.get("error") {
                eprintln!("Error: {}", err["message"].as_str().unwrap_or("unknown"));
                process::exit(1);
            }
            println!("{}", pretty(&resp));

            // Send init prompts to all agents
            eprintln!("\nSending init prompts to headless agents...");
            let app_sock_str = app_sock.to_string_lossy();
            for spec in &agent_specs {
                let name = spec["name"].as_str().unwrap_or("");
                let agent_id = format!("{name}@{team}");
                let init_text = agent_init_prompt(name, &workdir, &app_sock_str);
                match rpc_call_timeout(&daemon_sock, "headless.send", json!({
                    "agent_id": agent_id,
                    "text": init_text,
                }), 5) {
                    Ok(_) => eprintln!("  \u{2713} {name}: init prompt sent"),
                    Err(e) => eprintln!("  \u{2717} {name}: init prompt FAILED: {e}"),
                }
            }
        }
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    }

    println!();
    println!("Commands:");
    println!("  tm-agent send <agent> 'your message'");
    println!("  tm-agent read <agent> --lines 50");
    println!("  tm-agent status");
    println!("  tm-agent destroy");
}

fn run_add_headless(
    app_sock: &PathBuf, daemon_sock: &PathBuf, team: &str, agent_name: &str,
    agent_type: &str, model: &str, cli: &str,
) {
    eprintln!("Adding agent '{agent_name}' (type={agent_type}, cli={cli}, model={model}) to headless team '{team}'...");

    let app_sock_str = app_sock.to_string_lossy().to_string();

    let add_params = json!({
        "team_name": team,
        "name": agent_name,
        "cli": cli,
        "model": model,
        "app_socket_path": app_sock_str,
    });

    match rpc_call_timeout(daemon_sock, "headless.add_agent", add_params, 15) {
        Ok(resp) => {
            if let Some(err) = resp.get("error") {
                eprintln!("Error: {}", err["message"].as_str().unwrap_or("unknown"));
                process::exit(1);
            }

            println!("{}", pretty(&resp));

            // Send init prompt to the new agent
            let workdir = env::current_dir()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|_| ".".to_string());
            let agent_id = format!("{agent_name}@{team}");
            let init_text = agent_init_prompt(agent_name, &workdir, &app_sock_str);

            match rpc_call_timeout(daemon_sock, "headless.send", json!({
                "agent_id": agent_id,
                "text": init_text,
            }), 5) {
                Ok(_) => eprintln!("  \u{2713} {agent_name}: init prompt sent"),
                Err(e) => eprintln!("  \u{2717} {agent_name}: init prompt FAILED: {e}"),
            }

            // Register the agent with the Swift app's team data store
            // Use agent_type (role) separately from agent_name (display name)
            match rpc_call(app_sock, "team.register_agent", json!({
                "team_name": team,
                "agent_name": agent_name,
                "agent_type": agent_type,
                "model": model,
                "cli": cli,
            })) {
                Ok(_) => {},
                Err(e) => {
                    eprintln!("  Warning: failed to register agent with app: {e}");
                    eprintln!("  (agent process is running on daemon but may not appear in app UI)");
                }
            }

            eprintln!("\nAgent '{agent_name}' added to team '{team}'.");
        }
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    }
}

fn run_delegate_result(
    sock: &PathBuf, team: &str, target: &str, text: &str,
    title: Option<String>, priority: Option<u32>,
    accept: &[String], deps: &[String], desc: Option<String>, no_report: bool,
    context: Option<&str>, fix_budget: Option<u8>,
) -> Result<Value, String> {
    let resolved_title = title.unwrap_or_else(|| task_title_from_text(text));
    let resolved_priority = priority.unwrap_or(2);

    // Try unified team.delegate RPC first (single round-trip)
    let mut delegate_params = json!({
        "team": team,
        "agent": target,
        "text": text,
        "task_title": resolved_title,
        "priority": resolved_priority,
    });
    if let Some(ctx) = context {
        delegate_params["context"] = json!(ctx);
    }
    if let Some(fb) = fix_budget {
        delegate_params["fix_budget"] = json!(fb);
    }
    if let Ok(v) = rpc_call(sock, "team.delegate", delegate_params) {
        if v["ok"].as_bool().unwrap_or(false) {
            // Check if text was actually delivered to the agent's terminal
            let text_delivered = v["result"]["text_delivered"].as_bool().unwrap_or(true);
            if !text_delivered {
                let task_ref = &v["result"]["task"];
                let instruction = format_task_instruction(sock, team, task_ref, text, no_report, context, fix_budget);

                // Headless agent path: route via daemon socket if available
                if let Some(daemon_sock) = detect_daemon_socket() {
                    if let Some(agent_id) = is_headless_agent(&daemon_sock, team, target) {
                        let headless_ok = match rpc_call(&daemon_sock, "headless.send", json!({
                            "agent_id": agent_id,
                            "text": format!("{instruction}\n"),
                        })) {
                            Ok(ref hr) => !hr["result"].is_null(),
                            Err(_) => false,
                        };
                        if !headless_ok {
                            eprintln!("  Warning: headless.send failed for {target}");
                        }
                        return Ok(v);
                    }
                }

                // In-app panel retry: agent is not headless, retry via team.send.
                // The server-side already retried twice (150ms + 400ms). Give one final
                // CLI-side attempt after a short pause for late panel init.
                eprintln!("  Warning: text not delivered to agent '{target}', retrying via team.send...");
                std::thread::sleep(std::time::Duration::from_millis(300));
                let retry = rpc_call(sock, "team.send", json!({
                    "team_name": team, "agent_name": target,
                    "text": format!("{instruction}\n"),
                }));
                match &retry {
                    Ok(rv) if rv["ok"].as_bool().unwrap_or(false) => {
                        // team.send succeeded — text was delivered. Update the response.
                        let mut patched = v.clone();
                        patched["result"]["text_delivered"] = json!(true);
                        return Ok(patched);
                    }
                    _ => {
                        eprintln!("  Warning: retry also failed — task created but text may not have been delivered.");
                    }
                }
            }

            // Send Return key separately after a delay.
            // The Swift app sends text WITHOUT Return via ghostty_surface_text (paste).
            // A Return key sent in the same MainActor turn as the paste is silently
            // dropped by ghostty. Sending Return via a separate team.send RPC (which
            // creates a fresh MainActor.run invocation) reliably delivers Enter.
            // 1 second delay gives TUI apps (Claude Code) time to process the paste.
            if text_delivered {
                std::thread::sleep(Duration::from_secs(1));
                let _ = rpc_call(sock, "team.send", json!({
                    "team_name": team, "agent_name": target,
                    "text": "\n",
                }));
            }

            return Ok(v);
        }
    }

    // Fallback: 2-RPC path (server may not support team.delegate yet).
    // Reuse a single UnixStream connection for task.create → team.send to avoid
    // two separate connect() calls. task_id from create is needed for the send
    // instruction, so requests remain sequential but share one connection.
    let mut params = json!({
        "team_name": team,
        "title": resolved_title,
        "assignee": target,
        "priority": resolved_priority,
    });
    if let Some(d) = desc { params["description"] = json!(d); }
    if !accept.is_empty() { params["acceptance_criteria"] = json!(accept); }
    if !deps.is_empty() { params["depends_on"] = json!(deps); }
    if let Some(fb) = fix_budget { params["fix_budget"] = json!(fb); }

    // Open one connection for both task.create and team.send.
    let fallback_stream = UnixStream::connect(sock).map_err(|e| format!("connect: {e}"))?;
    fallback_stream.set_read_timeout(Some(Duration::from_secs(2))).ok();
    fallback_stream.set_write_timeout(Some(Duration::from_secs(2))).ok();

    // Use one shared BufReader for both sequential RPC calls so its internal
    // read-ahead buffer is preserved between calls.  Creating a new BufReader
    // per call (as rpc_call_on_stream does) risks losing bytes that the first
    // BufReader pre-fetched from the OS socket buffer when it is dropped.
    let mut fallback_reader = BufReader::new(&fallback_stream);

    let created = rpc_call_with_reader(&fallback_stream, &mut fallback_reader, "team.task.create", params)
        .map_err(|e| format!("task.create: {e}"))?;

    let task = &created["result"];
    let task_id = task["id"].as_str().unwrap_or("");
    if !created["ok"].as_bool().unwrap_or(false) || task_id.is_empty() {
        return Err(format!("task.create failed: {}", pretty(&created)));
    }

    let instruction = format_task_instruction(sock, team, task, text, no_report, context, fix_budget);
    let send_text = format!("{instruction}\n");

    // Headless agent path: route via daemon socket for 2-RPC fallback too
    if let Some(daemon_sock) = detect_daemon_socket() {
        if let Some(agent_id) = is_headless_agent(&daemon_sock, team, target) {
            let sent_ok = match rpc_call(&daemon_sock, "headless.send", json!({
                "agent_id": agent_id,
                "text": &send_text,
            })) {
                Ok(ref hr) => !hr["result"].is_null(),
                Err(_) => false,
            };
            if !sent_ok {
                eprintln!("  Warning: headless.send failed in 2-RPC fallback");
            }
            return Ok(json!({ "task": task, "send": { "ok": sent_ok } }));
        }
    }

    // In-app panel path: reuse the same connection and BufReader for team.send.
    let sent = rpc_call_with_reader(&fallback_stream, &mut fallback_reader, "team.send", json!({
        "team_name": team, "agent_name": target,
        "text": &send_text,
    })).map_err(|e| format!("team.send: {e}"))?;

    if !sent["ok"].as_bool().unwrap_or(false) {
        // Retry once after 300ms — task is already created, so we must not abandon it.
        // Server-side team.send already retries internally (150ms + 400ms).
        eprintln!("  Warning: team.send failed for '{target}', retrying in 300ms...");
        std::thread::sleep(std::time::Duration::from_millis(300));
        let retry = rpc_call(sock, "team.send", json!({
            "team_name": team, "agent_name": target,
            "text": &send_text,
        }));
        match retry {
            Ok(ref rv) if rv["ok"].as_bool().unwrap_or(false) => {
                eprintln!("  Retry succeeded.");
                return Ok(json!({ "task": task, "send": rv }));
            }
            _ => return Err(format!("team.send failed after retry: {}", pretty(&sent))),
        }
    }

    Ok(json!({ "task": task, "send": sent }))
}

fn run_delegate(
    sock: &PathBuf, team: &str, target: &str, text: &str,
    title: Option<String>, priority: Option<u32>,
    accept: &[String], deps: &[String], desc: Option<String>, no_report: bool,
    context: Option<&str>, fix_budget: Option<u8>,
) {
    match run_delegate_result(sock, team, target, text, title, priority, accept, deps, desc, no_report, context, fix_budget) {
        Ok(v) => println!("{}", pretty(&v)),
        Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
    }
}

fn run_fan_out(
    sock: &PathBuf, team: &str, text: &str,
    title: Option<String>, priority: Option<u32>, no_report: bool,
    agents_flag: &Option<String>, context: Option<&str>, fix_budget: Option<u8>,
) {
    // Get all agent names from team status
    let all_agents: Vec<String> = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(r) => {
            r["result"]["agents"].as_array()
                .map(|arr| arr.iter().filter_map(|a| a["name"].as_str().map(String::from)).collect())
                .unwrap_or_default()
        }
        Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
    };

    // Filter agents if --agents flag provided
    let filter = parse_cli_flag(agents_flag);
    let targets: Vec<&str> = if filter.is_empty() {
        all_agents.iter().map(|s| s.as_str()).collect()
    } else {
        all_agents.iter().filter(|a| filter.contains(a.as_str())).map(|s| s.as_str()).collect()
    };

    if targets.is_empty() {
        eprintln!("Error: no matching agents found");
        process::exit(1);
    }

    eprintln!("Fan-out: delegating to {} agents in parallel: {}", targets.len(), targets.join(", "));

    // L2: compute task title once outside the thread scope to avoid repeated calls per thread.
    let base_title = title.unwrap_or_else(|| task_title_from_text(text));

    // Run all delegate calls in parallel using scoped threads.
    // rpc_call_timeout() opens a new UnixStream per call, so threads don't share connections.
    let results: Vec<(&str, Result<Value, String>)> = thread::scope(|s| {
        let handles: Vec<_> = targets.iter().map(|target| {
            let t = base_title.clone();
            s.spawn(move || {
                let result = run_delegate_result(
                    sock, team, target, text, Some(t), priority, &[], &[], None, no_report, context, fix_budget,
                );
                (*target, result)
            })
        }).collect();
        handles.into_iter().map(|h| h.join().expect("thread panicked")).collect()
    });

    let mut succeeded: Vec<String> = Vec::new();
    let mut failed: Vec<String> = Vec::new();
    for (agent, result) in &results {
        match result {
            Ok(v) => {
                println!("{}", pretty(v));
                succeeded.push(agent.to_string());
            }
            Err(e) => {
                eprintln!("Error delegating to {agent}: {e}");
                failed.push(agent.to_string());
            }
        }
    }

    eprintln!(
        "Fan-out complete: {} succeeded, {} failed.",
        succeeded.len(), failed.len()
    );
    println!("{}", pretty(&json!({
        "fan_out": {
            "team_name": team,
            "agents": succeeded,
            "count": succeeded.len(),
            "failed": failed,
        }
    })));

    // M1: exit with error if all delegates failed.
    if succeeded.is_empty() && !failed.is_empty() {
        process::exit(1);
    }
}

fn run_wait(sock: &PathBuf, team: &str, timeout: u32, interval: u32, mode: &str, task_id: Option<&str>, agent_filter: &std::collections::HashSet<String>) {
    // Prevent infinite loop: clamp interval to at least 1 second
    let interval = interval.max(1);
    let filter_label = if agent_filter.is_empty() {
        "all".to_string()
    } else {
        agent_filter.iter().cloned().collect::<Vec<_>>().join(",")
    };
    eprintln!("Waiting for agents in team '{team}' (timeout: {timeout}s, mode: {mode}, agents: {filter_label})...");

    let mut agent_names: Vec<String> = Vec::new();
    if mode == "msg" || mode == "any" {
        if let Ok(r) = rpc_call(sock, "team.status", json!({ "team_name": team })) {
            if let Some(agents) = r["result"]["agents"].as_array() {
                agent_names = agents.iter()
                    .filter_map(|a| a["name"].as_str().map(String::from))
                    .filter(|n| agent_filter.is_empty() || agent_filter.contains(n))
                    .collect();
            }
        }
    }

    let mut elapsed: u32 = 0;
    let mut current_interval: u64 = 0; // first poll is immediate (no sleep)
    let min_interval: u64 = 1;
    let max_interval: u64 = interval as u64;
    let mut prev_progress_count: usize = 0;
    while elapsed < timeout {
        if current_interval > 0 {
            thread::sleep(Duration::from_secs(current_interval));
            elapsed += current_interval as u32;
        }
        let mut report_done = false;
        let mut report_progress = "0/0".to_string();
        let mut msg_done = false;
        let mut msg_progress = "0/0".to_string();

        if mode == "report" || mode == "any" {
            // Primary: check task completion status (immune to stale reports)
            // Batch team.status + team.result.status into a single socket connection
            let p_status = serde_json::to_string(&json!({
                "jsonrpc": "2.0", "id": 1,
                "method": "team.status", "params": { "team_name": team }
            })).unwrap_or_default();
            let p_result_status = serde_json::to_string(&json!({
                "jsonrpc": "2.0", "id": 2,
                "method": "team.result.status", "params": { "team_name": team }
            })).unwrap_or_default();
            let (status_r, result_status_r) = match rpc_batch(sock, &[p_status, p_result_status]) {
                Ok(mut results) if results.len() >= 2 => {
                    let rs = results.remove(1);
                    let r = results.remove(0);
                    (Ok(r), Ok(rs))
                }
                Ok(_) | Err(_) => (
                    rpc_call(sock, "team.status", json!({ "team_name": team })),
                    rpc_call(sock, "team.result.status", json!({ "team_name": team })),
                ),
            };
            match status_r {
                Ok(r) => {
                    if let Some(agents) = r["result"]["agents"].as_array() {
                        let filtered: Vec<&Value> = agents.iter()
                            .filter(|a| {
                                let name = a["name"].as_str().unwrap_or("");
                                agent_filter.is_empty() || agent_filter.contains(name)
                            })
                            .collect();
                        // Only count agents that have an active task (assigned by leader)
                        let with_tasks: Vec<&&Value> = filtered.iter()
                            .filter(|a| a["active_task_id"].as_str().is_some())
                            .collect();
                        if with_tasks.is_empty() {
                            // Fallback: no tasks assigned, use legacy result.status
                            if let Ok(rs) = result_status_r {
                                let done = rs["result"]["completed"].as_u64().unwrap_or(0);
                                let total = rs["result"]["total"].as_u64().unwrap_or(0);
                                report_done = rs["result"]["all_done"].as_bool().unwrap_or(false);
                                report_progress = format!("{done}/{total}");
                            }
                        } else {
                            let total = with_tasks.len() as u64;
                            let done = with_tasks.iter()
                                .filter(|a| matches!(
                                    a["active_task_status"].as_str(),
                                    Some("completed") | Some("review_ready")
                                ))
                                .count() as u64;
                            report_done = total > 0 && done >= total;
                            report_progress = format!("{done}/{total}");
                        }
                    }
                }
                Err(e) => {
                    eprintln!("  Warning: team.status RPC failed: {e}");
                    // Fallback to result.status when team.status (UI command) times out
                    if let Ok(rs) = result_status_r {
                        let done = rs["result"]["completed"].as_u64().unwrap_or(0);
                        let total = rs["result"]["total"].as_u64().unwrap_or(0);
                        report_done = rs["result"]["all_done"].as_bool().unwrap_or(false);
                        report_progress = format!("{done}/{total}");
                    }
                }
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
            if let Some(tid) = task_id {
                // Batch team.inbox + team.task.get into a single socket connection
                let p_inbox = serde_json::to_string(&json!({
                    "jsonrpc": "2.0", "id": 1,
                    "method": "team.inbox", "params": { "team_name": team }
                })).unwrap_or_default();
                let p_task_get = serde_json::to_string(&json!({
                    "jsonrpc": "2.0", "id": 2,
                    "method": "team.task.get", "params": { "team_name": team, "task_id": tid }
                })).unwrap_or_default();
                let (inbox_r, task_r) = match rpc_batch(sock, &[p_inbox, p_task_get]) {
                    Ok(mut results) if results.len() >= 2 => {
                        let tr = results.remove(1);
                        let ir = results.remove(0);
                        (Ok(ir), Ok(tr))
                    }
                    Ok(_) | Err(_) => (
                        rpc_call(sock, "team.inbox", json!({ "team_name": team })),
                        rpc_call(sock, "team.task.get", json!({ "team_name": team, "task_id": tid })),
                    ),
                };
                match inbox_r {
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
                match task_r {
                    Ok(r) => {
                        if r["ok"].as_bool().unwrap_or(false) {
                            task_obj = r["result"].clone();
                            task_status = task_obj["status"].as_str().map(String::from);
                        }
                    }
                    Err(e) => eprintln!("  Warning: task.get RPC failed for {tid}: {e}"),
                }
            } else {
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
                        let filtered: Vec<&Value> = if agent_filter.is_empty() {
                            agents.iter().collect()
                        } else {
                            agents.iter()
                                .filter(|a| a["name"].as_str().map(|n| agent_filter.contains(n)).unwrap_or(false))
                                .collect()
                        };
                        let idle_count = filtered.iter()
                            .filter(|a| a["agent_state"].as_str() == Some("idle")).count();
                        let active_count = filtered.iter()
                            .filter(|a| matches!(a["agent_state"].as_str(), Some("running" | "blocked" | "review_ready")))
                            .count();
                        let total = idle_count + active_count;
                        eprintln!("  [{elapsed}/{timeout}s] idle={idle_count}/{total}");
                        if total > 0 && idle_count == total {
                            let idle_agents: Vec<&&Value> = filtered.iter()
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

        // Adaptive polling: speed up on progress, slow down on idle
        let current_progress_count: usize = {
            let r = report_progress.split('/').next().and_then(|s| s.parse().ok()).unwrap_or(0usize);
            let m = msg_progress.split('/').next().and_then(|s| s.parse().ok()).unwrap_or(0usize);
            r + m + inbox_blocked.len() + inbox_review.len()
        };
        if current_progress_count > prev_progress_count {
            current_interval = min_interval;
            prev_progress_count = current_progress_count;
        } else {
            current_interval = (current_interval + 1).min(max_interval);
        }
    }

    eprintln!("Timeout: not all agents reported within {timeout}s");
    if let Ok(r) = rpc_call(sock, "team.result.status", json!({ "team_name": team })) {
        println!("{}", pretty(&r));
    }
    process::exit(1);
}

fn run_warmup(sock: &PathBuf, team: &str, target: Option<&str>, timeout: u32) {
    use std::time::Instant;

    // Get agent list
    let status = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(v) => v,
        Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
    };
    let agents = status["result"]["agents"].as_array().unwrap_or(&vec![]).clone();
    if agents.is_empty() {
        eprintln!("No agents in team '{team}'");
        process::exit(1);
    }

    // Filter to specific agent if requested
    let targets: Vec<&Value> = if let Some(name) = target {
        let filtered: Vec<&Value> = agents.iter().filter(|a| a["name"].as_str() == Some(name)).collect();
        if filtered.is_empty() {
            eprintln!("Agent '{name}' not found in team '{team}'");
            process::exit(1);
        }
        filtered
    } else {
        agents.iter().collect()
    };

    let count = targets.len();
    eprintln!("Warming up {count} agent(s) in team '{team}'...");

    // Delegate pong task to each agent
    let mut task_ids: Vec<(String, String, Instant)> = Vec::new(); // (agent_name, task_id, start_time)
    for agent_val in &targets {
        let name = agent_val["name"].as_str().unwrap_or("?");
        let start = Instant::now();
        let result = run_delegate_result(
            sock, team, name, "Reply with exactly one word: pong",
            Some("warmup-ping".to_string()), Some(3), &[], &[], None, true, None, None,
        );
        match result {
            Ok(v) => {
                if let Some(tid) = v["result"]["task"]["id"].as_str() {
                    task_ids.push((name.to_string(), tid.to_string(), start));
                } else {
                    eprintln!("  {name}: failed to create task");
                }
            }
            Err(e) => eprintln!("  {name}: delegate error: {e}"),
        }
    }

    if task_ids.is_empty() {
        eprintln!("No warmup tasks created");
        process::exit(1);
    }

    // Poll for completion
    let deadline = Instant::now() + Duration::from_secs(timeout as u64);
    let mut completed: Vec<(String, u128, String)> = Vec::new(); // (agent, ms, result)
    let mut pending = task_ids.clone();

    while !pending.is_empty() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(500));
        let mut still_pending = Vec::new();
        for (agent_name, tid, start) in &pending {
            if let Ok(v) = rpc_call(sock, "team.task.get", json!({
                "team_name": team, "task_id": tid,
            })) {
                let status = v["result"]["status"].as_str().unwrap_or("");
                if status == "completed" || status == "review_ready" {
                    let ms = start.elapsed().as_millis();
                    let result = v["result"]["result"].as_str().unwrap_or("").to_string();
                    completed.push((agent_name.clone(), ms, result));
                    continue;
                }
            }
            still_pending.push((agent_name.clone(), tid.clone(), *start));
        }
        pending = still_pending;
    }

    // Print results
    let pass = completed.len();
    let fail = task_ids.len() - pass;
    println!();
    for (name, ms, result) in &completed {
        let icon = if result.to_lowercase().contains("pong") { "✓" } else { "?" };
        println!("  {icon} {name}: {ms}ms");
    }
    for (name, _, start) in &pending {
        let ms = start.elapsed().as_millis();
        println!("  ✗ {name}: timeout ({ms}ms)");
    }
    println!();
    if fail == 0 {
        println!("All {pass} agent(s) warm ✓");
    } else {
        println!("{pass} warm, {fail} timed out");
        process::exit(1);
    }
}

/// Work-stealing: claim the next available pending/unassigned task for this agent.
fn run_claim(sock: &PathBuf, team: &str, agent: &str) {
    let result = rpc_call(sock, "team.task.claim", json!({
        "team_name": team,
        "agent_name": agent,
    }));
    match result {
        Ok(ref v) if v["ok"].as_bool().unwrap_or(false) => {
            if v["result"].is_null() {
                println!("{}", pretty(&json!({ "ok": true, "result": null, "message": "No claimable tasks available" })));
            } else {
                println!("{}", pretty(v));
            }
        }
        Ok(ref v) => println!("{}", pretty(v)),
        Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
    }
}

/// Returns capabilities (keywords) for a given agent_type.
/// Used by `tm-agent suggest` to match task descriptions to agents.
fn capabilities_for_agent_type(agent_type: &str) -> Vec<&'static str> {
    match agent_type.to_lowercase().as_str() {
        "architect" => vec!["architecture", "design", "system", "review", "structure", "plan", "interface", "boundary"],
        "executor"  => vec!["implement", "code", "coding", "refactor", "fix", "build", "develop", "feature"],
        "explorer"  => vec!["explore", "discover", "search", "analyze", "investigate", "map", "find"],
        "reviewer"  => vec!["review", "check", "audit", "quality", "lint", "standards", "critique"],
        "tester"    => vec!["test", "testing", "qa", "verification", "unit", "integration", "e2e", "spec"],
        "debugger"  => vec!["debug", "trace", "crash", "error", "bug", "fix", "diagnose", "root cause"],
        "writer"    => vec!["document", "docs", "readme", "guide", "migration", "notes", "write"],
        "security"  => vec!["security", "auth", "vulnerability", "pentest", "owasp", "injection", "xss"],
        "ai"        => vec!["ai", "ml", "llm", "model", "inference", "prompt", "embedding", "rag"],
        "backend"   => vec!["api", "server", "database", "backend", "service", "schema", "query", "rest"],
        "frontend"  => vec!["ui", "frontend", "component", "react", "swiftui", "css", "layout", "ux"],
        _ => vec![],
    }
}

/// Score how well a task description matches an agent's capabilities.
fn capability_score(description_lower: &str, capabilities: &[&str]) -> usize {
    capabilities.iter().filter(|kw| description_lower.contains(*kw)).count()
}

/// Suggest the best agent for a task description based on capability mapping.
fn run_suggest(sock: &PathBuf, team: &str, description: &str) {
    let status = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(v) => v,
        Err(e) => { eprintln!("Error: {e}"); process::exit(1); }
    };

    let agents = match status["result"]["agents"].as_array() {
        Some(a) => a.clone(),
        None => { eprintln!("Error: no agents in team"); process::exit(1); }
    };

    let desc_lower = description.to_lowercase();
    let mut scored: Vec<(String, String, Vec<&'static str>, usize)> = agents.iter().filter_map(|a| {
        let name = a["name"].as_str()?.to_string();
        let agent_type = a["agent_type"].as_str().unwrap_or(&name).to_string();
        let caps = capabilities_for_agent_type(&agent_type);
        let score = capability_score(&desc_lower, &caps);
        Some((name, agent_type, caps, score))
    }).collect();

    scored.sort_by(|a, b| b.3.cmp(&a.3));

    let suggestions: Vec<Value> = scored.iter().map(|(name, agent_type, caps, score)| {
        json!({
            "agent": name,
            "agent_type": agent_type,
            "capabilities": caps,
            "score": score,
        })
    }).collect();

    let best = scored.first().map(|(name, _, _, _)| name.as_str()).unwrap_or("none");
    println!("{}", serde_json::to_string_pretty(&json!({
        "ok": true,
        "result": {
            "task": description,
            "best_match": best,
            "ranking": suggestions,
        }
    })).unwrap_or_default());
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
