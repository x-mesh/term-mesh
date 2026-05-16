#![allow(
    clippy::implicit_saturating_sub,
    clippy::manual_is_multiple_of,
    clippy::print_literal,
    clippy::ptr_arg,
    clippy::too_many_arguments,
    clippy::unused_enumerate_index,
    clippy::useless_concat,
    clippy::useless_format
)]

//! tm-agent: Unified Rust CLI for term-mesh team operations.
//!
//! Replaces both tm-rpc (agent-side) and team.py (leader-side).
//! ~1-3ms per call for all commands.

mod peer;
mod prompts;

use clap::{Parser, Subcommand};
use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use std::{env, process, thread};

// ── Constants ────────────────────────────────────────────────────────

const DEFAULT_AGENT_NAMES: &[&str] = &[
    "explorer", "executor", "reviewer", "debugger", "writer", "tester",
];
const DEFAULT_AGENT_COLORS: &[&str] = &["green", "blue", "yellow", "magenta", "cyan", "red"];

const REPORT_SUFFIX: &str = concat!(
    "\n\n[IMPORTANT] Finish via TM-PROTOCOL-v1: tm-agent reply '<5-line header plus concise summary>'.",
);

const BROADCAST_SUFFIX: &str = concat!(
    "\n\n[IMPORTANT] Finish via TM-PROTOCOL-v1: `tm-agent reply '<5-line header plus concise summary>'`.",
);

fn agent_init_prompt(agent_name: &str, agent_role: &str, team_name: &str, workdir: &str, socket: &str) -> String {
    let root = Path::new(workdir);
    let runbook_mode = env::var("TERMMESH_RUNBOOK_MODE").unwrap_or_else(|_| "digest".to_string());
    let runbook_mode = runbook_mode.trim();
    let role = selected_runbook_roles(Some(agent_role))
        .ok()
        .and_then(|mut roles| roles.pop());
    let runbook_section = if runbook_mode.eq_ignore_ascii_case("full") {
        load_runbook_content_for_role(root, agent_role)
            .map(|content| format!("\n## Role Runbook\n\n{content}\n"))
            .unwrap_or_default()
    } else if let Some(role) = role {
        format!("\n{}\n", runbook_digest_content(root, &role, agent_name, team_name))
    } else {
        format!(
            "\n{}\n",
            runbook_digest_content_for_role_name(
                root,
                agent_role,
                load_runbook_content_for_role(root, agent_role).as_deref(),
                agent_name,
                team_name
            )
        )
    };
    let identity_line = if agent_name == agent_role {
        format!("You are a team agent named \"{agent_name}\" with role \"{agent_role}\" in a term-mesh multi-agent team.")
    } else {
        format!("You are a team agent named \"{agent_name}\" with role \"{agent_role}\" in a term-mesh multi-agent team. Your identity is \"{agent_name}\"; your behavior runbook is `.agent-runbooks/{agent_role}.md`.")
    };

    format!(
        "{identity_line} \
Use `tm-agent` (Rust, ~2ms) for ALL team operations. \
Fallback: `./scripts/tm-agent.sh` (bash, ~10ms). \
NEVER use `./scripts/team.py` \u{2014} it has been removed.\n\
\n\
Task lifecycle:\n\
1. Begin task: `tm-agent task start <task_id>`\n\
2. Progress heartbeat: `tm-agent heartbeat '<short summary>'`\n\
3. If blocked: `tm-agent task block <task_id> '<reason>'`\n\
4. If ready for review: `tm-agent task review <task_id> '<summary>'`\n\
5. When done: `tm-agent reply '<full result>'` \u{2014} this auto-reports and completes your active task. Do not run `tm-agent task done` separately.\n\
\n\
## Reply Protocol\n\
\n\
This session defines `TM-PROTOCOL-v1`:\n\
- Start assigned work with `tm-agent task start <task_id>`.\n\
- Send brief progress with `tm-agent heartbeat '<short summary>'`.\n\
- Use `tm-agent task block <task_id> '<reason>'` when blocked.\n\
- Use `tm-agent task review <task_id> '<summary>'` when ready for validation.\n\
- Finish with one `tm-agent reply '<5-line header plus concise result>'`; it auto-reports and completes your active task.\n\
\n\
Begin every `tm-agent reply` body with this 5-line header (use n/a / none / NONE when not applicable):\n\
\n\
```\n\
STATUS: DONE|BLOCKED|NEEDS_REVIEW\n\
FILES: <changed paths or \"none\">\n\
VERIFY: <single shell command or \"n/a\">\n\
NEXT: <action or \"NONE\">\n\
FULL_REPORT: <absolute result path or \"n/a\">\n\
```\n\
\n\
## Reply Truncation\n\
\n\
Replies are truncated to ~1500 chars over the socket but the daemon auto-saves your full\n\
reply to ~/.term-mesh/results/<team>/<agent>-reply.md. If your reply body exceeds 1000 chars,\n\
set FULL_REPORT to that path instead of adding a separate line above the header.\n\
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
{runbook_section}\n\
When you complete any task, run: `tm-agent reply '<5-line header plus concise result>'` to report.\n\
Respond with \"Agent {agent_name} ready.\" to confirm.",
    )
}

// ── CLI definition ───────────────────────────────────────────────────

const GIT_SHA: &str = env!("TM_GIT_SHA");
const _BUILD_DATE: &str = env!("TM_BUILD_DATE");

#[derive(Parser)]
#[command(
    name = "tm-agent",
    about = "term-mesh team CLI — unified agent & leader tool",
    version
)]
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
    /// Install per-agent runbooks into local agent tool configs
    #[command(subcommand)]
    Runbook(RunbookCommands),

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
        /// Print result headers only instead of terminal text
        #[arg(long)]
        headers: bool,
        /// Print result headers plus short summaries instead of terminal text
        #[arg(long)]
        summary: bool,
    },
    /// Get agent reports
    Reports {
        /// Print only STATUS/FILES/VERIFY/NEXT/FULL_REPORT headers
        #[arg(long)]
        headers: bool,
        /// Print headers plus short summaries
        #[arg(long)]
        summary: bool,
    },
    /// Check result completion status
    ResultStatus,
    /// Collect all results
    ResultCollect {
        /// Print only STATUS/FILES/VERIFY/NEXT/FULL_REPORT headers
        #[arg(long)]
        headers: bool,
        /// Print headers plus short summaries
        #[arg(long)]
        summary: bool,
    },

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
        /// Use a named smart or workflow preset (e.g. "standard", "bug-triage")
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
    /// Add an agent to an existing team (GUI and headless teams both supported).
    ///
    /// For GUI teams: resolves the team name from TERMMESH_TEAM or the current
    /// workspace and routes to the Swift `team.add_agent` RPC.
    /// For headless teams: spawns a new daemon-managed subprocess as before.
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
    /// Attach an agent pane to the current workspace's team.
    ///
    /// Unlike `create`, this does not spawn a new workspace — it adds the
    /// agent pane as a split inside the caller's existing workspace. The
    /// caller's pane is auto-adopted as the team's leader on first attach.
    /// The team is auto-named `ws-<first8hex>` based on the workspace UUID.
    /// Must be run inside a term-mesh pane (TERMMESH_WORKSPACE_ID env required).
    Attach {
        /// Agent type/name (e.g. "executor", "reviewer", "security")
        agent_type: String,
        /// Custom agent name (defaults to agent_type). Must match `^[a-zA-Z0-9_-]{1,32}$`.
        #[arg(long)]
        name: Option<String>,
        /// Model to use (e.g. sonnet, opus, haiku)
        #[arg(long, default_value = "sonnet")]
        model: String,
        /// CLI to use (claude, codex, kiro, gemini)
        #[arg(long, default_value = "claude")]
        cli: String,
    },
    /// Detach an agent from the current workspace's team.
    ///
    /// Closes the agent's pane and removes it from the team. The leader
    /// pane (the caller's original pane) is never touched. If the detached
    /// agent was the last one, the team is automatically destroyed while
    /// the leader pane is preserved.
    Detach {
        /// Agent name to detach
        agent_name: String,
    },
    /// Remove an agent from a named GUI team by team name.
    ///
    /// Team-name–scoped: does not require TERMMESH_WORKSPACE_ID/PANEL_ID.
    /// This is the counterpart of `add` for GUI teams — use this when you
    /// know the team name but may not be running inside the workspace.
    /// Unlike `detach` (workspace-local), `remove` operates on a named team.
    Remove {
        /// Agent name to remove from the team
        agent_name: String,
        /// Force removal even if the agent is busy (default: true)
        #[arg(long, default_value_t = true)]
        force: bool,
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
        /// Run task in autonomous mode (headless subprocess, no leader approval needed for edits)
        #[arg(long)]
        autonomous: bool,
    },
    /// Stop (interrupt) agents by sending Ctrl+C to their terminals
    Stop {
        /// Agent name to interrupt, or omit for all agents
        agent: Option<String>,
        /// Interrupt all agents in the team
        #[arg(long)]
        all: bool,
    },
    /// Restart an agent CLI. Soft (default) sends Ctrl+C + retypes the launch
    /// command in-place. --hard closes the pane and respawns a fresh one in
    /// the same slot (scrollback lost; recovers stuck/IME-swallowed surfaces).
    Restart {
        /// Agent name to restart
        agent: String,
        /// Hard restart: close + respawn the pane (panelId changes; scrollback lost).
        #[arg(long, default_value_t = false)]
        hard: bool,
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
        /// Comma-separated list of task IDs to wait for (overrides agent-based tracking)
        #[arg(long)]
        tasks: Option<String>,
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
    /// Stream events from the daemon as JSONL (push channel for leader sessions)
    Watch {
        /// Comma-separated event kinds to receive (default: task_done,reply,heartbeat_stale)
        #[arg(long, value_name = "KINDS")]
        on_event: Option<String>,
        /// Stop after N seconds (default: 0 = run until Ctrl+C)
        #[arg(long, default_value_t = 0)]
        timeout: u32,
        /// Filter to events belonging to a specific leader session
        #[arg(long, value_name = "SESSION_ID")]
        leader_session: Option<String>,
    },
    /// Bridge reply events with XMB_TASK headers into xm-build tasks.json updates
    XmbBridge {
        /// Stop after N seconds (default: 0 = run until Ctrl+C)
        #[arg(long, default_value_t = 0)]
        timeout: u32,
        /// Filter to events belonging to a specific leader session
        #[arg(long, value_name = "SESSION_ID")]
        leader_session: Option<String>,
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
    /// Run a research task across idle agents
    Research {
        /// Topic to research
        topic: String,
        /// Number of agents to assign (0 = all idle)
        #[arg(long, default_value_t = 0)]
        agents: u32,
        /// Number of research rounds
        #[arg(long, default_value_t = 5)]
        budget: u32,
        /// Timeout in seconds
        #[arg(long, default_value_t = 600)]
        timeout: u64,
        /// Research depth (shallow|deep|exhaustive)
        #[arg(long, default_value = "deep")]
        depth: String,
        /// Allow web search
        #[arg(long)]
        web: bool,
        /// Focus hint for the research
        #[arg(long)]
        focus: Option<String>,
        /// Skip post-research discussion phase
        #[arg(long)]
        no_discuss: bool,
    },

    /// Solve a problem collaboratively via board stigmergy
    Solve {
        /// Problem description
        problem: String,
        /// Number of agents to assign (0 = all idle)
        #[arg(long, default_value_t = 0)]
        agents: u32,
        /// Number of solve rounds per agent
        #[arg(long, default_value_t = 5)]
        budget: u32,
        /// Timeout in seconds
        #[arg(long, default_value_t = 600)]
        timeout: u64,
        /// Verification command to check solution
        #[arg(long)]
        verify: Option<String>,
        /// Target file/directory to focus on
        #[arg(long)]
        target: Option<String>,
        /// Skip post-solve discussion phase
        #[arg(long)]
        no_discuss: bool,
    },

    /// Reach consensus on a question via board deliberation
    Consensus {
        /// Question to deliberate
        question: String,
        /// Number of agents to assign (0 = all idle)
        #[arg(long, default_value_t = 0)]
        agents: u32,
        /// Number of deliberation rounds per agent
        #[arg(long, default_value_t = 4)]
        budget: u32,
        /// Timeout in seconds
        #[arg(long, default_value_t = 600)]
        timeout: u64,
        /// Comma-separated perspectives for agents
        #[arg(long)]
        perspectives: Option<String>,
        /// Skip post-consensus discussion phase
        #[arg(long)]
        no_discuss: bool,
    },

    /// Execute emergent work via swarm task board
    Swarm {
        /// Goal to achieve
        goal: String,
        /// Number of agents to assign (0 = all idle)
        #[arg(long, default_value_t = 0)]
        agents: u32,
        /// Number of rounds per agent
        #[arg(long, default_value_t = 10)]
        budget: u32,
        /// Timeout in seconds
        #[arg(long, default_value_t = 900)]
        timeout: u64,
        /// Comma-separated seed tasks
        #[arg(long)]
        seed: Option<String>,
        /// Skip post-swarm discussion phase
        #[arg(long)]
        no_discuss: bool,
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
    TaskDone {
        task_id: String,
        result: Option<String>,
    },
    /// Alias: task-block → task block
    #[command(name = "task-block", hide = true)]
    TaskBlock {
        task_id: String,
        reason: Option<String>,
    },
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
    TaskUpdate2 {
        id: String,
        status: String,
        result: Option<String>,
    },
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

    /// Diagnose environment: sockets, daemons, teams, version mismatches
    Doctor {
        /// Show extra detail (process paths, full socket list)
        #[arg(long)]
        verbose: bool,
        /// Output as JSON instead of human-readable text
        #[arg(long)]
        json: bool,
    },

    /// Peer-federation operations (attach to a remote term-mesh host).
    Peer(PeerCommands),
}

#[derive(clap::Args)]
struct PeerCommands {
    #[command(subcommand)]
    command: PeerCommand,
}

#[derive(Subcommand)]
enum PeerCommand {
    /// List the surfaces a peer-federation host exposes.
    ///
    /// Prints one surface per line: `<title>  <cols>x<rows>  <status>  <id>`
    /// where status is "live" or "dead". Exits after printing.
    List {
        /// Path to the host's peer-federation unix socket.
        socket: PathBuf,
    },
    /// Attach to a surface exposed by a peer-federation host.
    ///
    /// Without `--name`, attaches to the first surface listed by the host.
    /// Stream PtyData from the host to stdout; relay stdin as Input.
    /// Ctrl-] detaches in interactive mode; stdin EOF detaches otherwise.
    Attach {
        /// Path to the host's peer-federation unix socket.
        socket: PathBuf,
        /// Title of the surface to attach to; defaults to the first listed.
        #[arg(long)]
        name: Option<String>,
    },
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
    Done {
        task_id: String,
        result: Option<String>,
    },
    /// Mark task as blocked with reason
    Block {
        task_id: String,
        reason: Option<String>,
    },
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

#[derive(Subcommand)]
enum RunbookCommands {
    /// Show runbook install status for this repo
    Status,
    /// Create .agent-runbooks/ source files only
    Init {
        /// Print planned changes without writing files
        #[arg(long)]
        dry_run: bool,
        /// Overwrite existing managed files
        #[arg(long)]
        force: bool,
    },
    /// Install runbooks for one tool or all supported tools
    Install {
        /// claude, codex, opencode, gemini, or all
        #[arg(long, default_value = "all")]
        tool: String,
        /// Install only one role runbook
        #[arg(long)]
        agent: Option<String>,
        /// Print planned changes without writing files
        #[arg(long)]
        dry_run: bool,
        /// Overwrite existing non-managed files
        #[arg(long)]
        force: bool,
    },
    /// Print compact runbook digest(s) for prompt-efficient agent init
    Digest {
        /// Show only one role digest
        #[arg(long)]
        agent: Option<String>,
    },
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
        title: map
            .get("title")
            .cloned()
            .unwrap_or_else(|| "{{title}}".into()),
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
                let name = p
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_string();
                if !result.iter().any(|(n, _)| n == &name) {
                    result.push((name, dir.display().to_string()));
                }
            }
        }
    }
    result
}

// ── Agent runbook installer ─────────────────────────────────────────

const RUNBOOK_MARKER: &str = "<!-- term-mesh-managed: runbook-installer v1 -->";
const RUNBOOK_SOURCE_DIR: &str = ".agent-runbooks";

#[derive(Clone, Copy)]
enum RunbookTool {
    Claude,
    Codex,
    OpenCode,
    Gemini,
}

impl RunbookTool {
    fn as_str(self) -> &'static str {
        match self {
            RunbookTool::Claude => "claude",
            RunbookTool::Codex => "codex",
            RunbookTool::OpenCode => "opencode",
            RunbookTool::Gemini => "gemini",
        }
    }
}

struct RunbookRole {
    name: &'static str,
    title: &'static str,
    description: &'static str,
    when_to_use: &'static [&'static str],
    rules: &'static [&'static str],
    verify: &'static [&'static str],
}

fn builtin_runbook_roles() -> Vec<RunbookRole> {
    vec![
        RunbookRole {
            name: "explorer",
            title: "Explorer Runbook",
            description: "Read-only codebase exploration and symbol tracing.",
            when_to_use: &[
                "The task asks where something is defined, who calls it, or how modules depend on each other.",
                "The leader needs precise context before code is changed.",
            ],
            rules: &[
                "Use rg or rg --files first for searches.",
                "Return findings as path:line plus one concise role sentence.",
                "Do not edit files unless the leader explicitly changes your role.",
                "Prefer exact call sites, ownership boundaries, and dependency edges over broad summaries.",
            ],
            verify: &[
                "Include the exact search command or pattern family you used when absence matters.",
                "If no match is found, say what paths or symbols were checked.",
            ],
        },
        RunbookRole {
            name: "executor",
            title: "Executor Runbook",
            description: "Scoped implementation work with direct file edits and verification.",
            when_to_use: &[
                "The task has a concrete implementation target and an owned file/module scope.",
                "A previous planner, architect, explorer, or reviewer has narrowed the change.",
            ],
            rules: &[
                "Own the files assigned in the task and avoid unrelated refactors.",
                "Do not revert edits made by other agents or the user.",
                "Run the narrowest useful verification command before reporting.",
                "Report changed files, verification, and remaining risk in the standard header.",
            ],
            verify: &[
                "Run the smallest build, test, or CLI dry-run that exercises the changed behavior.",
                "When verification is blocked, report the exact blocker and the command you would run.",
            ],
        },
        RunbookRole {
            name: "reviewer",
            title: "Reviewer Runbook",
            description: "Code review focused on regressions, bugs, and missing tests.",
            when_to_use: &[
                "An implementation diff is ready for quality, regression, or release gate review.",
                "The leader needs risk-ranked findings rather than another implementation pass.",
            ],
            rules: &[
                "Lead with findings ordered by severity.",
                "Ground every finding in file:line references.",
                "Prefer actionable patch snippets over style-only comments.",
                "Return VERDICT: LGTM or VERDICT: CHANGES after findings.",
            ],
            verify: &[
                "Name the tests or manual checks that would catch each material issue.",
                "If no issues are found, state residual risk and any unrun coverage.",
            ],
        },
        RunbookRole {
            name: "security",
            title: "Security Runbook",
            description: "Security review for process execution, sockets, quoting, and trust boundaries.",
            when_to_use: &[
                "The change touches Process(), shell quoting, sockets, permissions, tokens, or external input.",
                "A feature changes what agents, CLI commands, or browser automation can access.",
            ],
            rules: &[
                "Inspect Process(), shell invocation, socket authorization, allowAll paths, and external input parsing.",
                "Include severity, CWE when obvious, PoC, fix, and verify command.",
                "Flag focus stealing or privilege boundary changes when socket commands are involved.",
                "Do not suggest broad rewrites when a local validation or escaping fix is enough.",
            ],
            verify: &[
                "Provide a concrete PoC or negative test for exploitable paths.",
                "Call out when the issue is theoretical and what evidence would confirm it.",
            ],
        },
        RunbookRole {
            name: "frontend",
            title: "Frontend Runbook",
            description: "SwiftUI/AppKit interface work for term-mesh panels and dashboard UI.",
            when_to_use: &[
                "The change touches Sources/Panels, Sources/Splits, Settings, team UI, keyboard handling, or SwiftUI/AppKit layout.",
                "The user-visible behavior depends on visual hierarchy, focus, or panel state.",
            ],
            rules: &[
                "Preserve portal layering contracts for terminal and browser surfaces.",
                "Use existing design tokens and avoid nested card layouts.",
                "Add DEBUG dlog events only behind DEBUG guards when useful.",
                "Verify responsive layout and avoid overlapping text or controls.",
            ],
            verify: &[
                "Run the project xcodebuild command for Swift changes.",
                "Use reload or UI smoke coverage when the changed surface is interactive.",
            ],
        },
        RunbookRole {
            name: "backend",
            title: "Backend Runbook",
            description: "Rust daemon, JSON-RPC, IPC, and telemetry implementation.",
            when_to_use: &[
                "The change touches daemon/, tm-agent, JSON-RPC schemas, socket commands, peer relay, or telemetry paths.",
                "A UI change requires new daemon capabilities or contract updates.",
            ],
            rules: &[
                "Default new socket commands to off-main handling unless UI state requires main actor access.",
                "Parse and validate external input before scheduling UI mutation.",
                "Keep JSON response shapes backward compatible where existing clients depend on them.",
                "Run cargo test for daemon changes when feasible.",
            ],
            verify: &[
                "Run cargo fmt and cargo test for daemon changes.",
                "Exercise new or changed CLI/socket commands with a dry-run or local request.",
            ],
        },
        RunbookRole {
            name: "refactorer",
            title: "Refactorer Runbook",
            description: "Behavior-preserving refactors with small reversible steps.",
            when_to_use: &[
                "The goal is reducing duplication, moving code, or clarifying boundaries without changing behavior.",
                "The leader needs a contained cleanup before or after feature work.",
            ],
            rules: &[
                "Preserve public behavior and avoid mixed feature work.",
                "Make mechanical moves separately from semantic edits.",
                "Run focused regression checks after each meaningful batch.",
                "Report compatibility risk before broadening the refactor.",
            ],
            verify: &[
                "Run regression checks covering the moved or renamed behavior.",
                "List any behavior that intentionally changed; otherwise state behavior-preserving.",
            ],
        },
        RunbookRole {
            name: "architect",
            title: "Architect Runbook",
            description: "Design decisions for module boundaries, threading, and protocol changes.",
            when_to_use: &[
                "A change affects module boundaries, protocol shape, threading policy, focus policy, or long-lived extension points.",
                "Multiple agents or phases need a shared design before implementation.",
            ],
            rules: &[
                "Write the decision, rejected alternatives, and compatibility impact.",
                "Include Swift/Rust stubs or sequence pseudocode when it clarifies the boundary.",
                "Call out focus policy, socket threading, and panel layering impacts explicitly.",
                "Avoid abstractions that do not remove real duplication or risk.",
            ],
            verify: &[
                "Name the compatibility checks and contract tests the executor or tester should run.",
                "Flag unresolved decisions as explicit open questions, not hidden assumptions.",
            ],
        },
        RunbookRole {
            name: "tester",
            title: "Tester Runbook",
            description: "Verification planning and regression execution.",
            when_to_use: &[
                "The task needs a test matrix, regression run, smoke test, or reproduction confirmation.",
                "A change is ready but still lacks confidence across UI, CLI, daemon, or workflow contracts.",
            ],
            rules: &[
                "Map tests to user-visible risk and changed contracts.",
                "Use VM-only UI test commands for macOS UI automation.",
                "Report test case count, failures, and whether VM coverage is still needed.",
                "Prefer reproducible shell commands over prose-only validation.",
            ],
            verify: &[
                "Report commands exactly as run and summarize pass/fail counts.",
                "Separate host-only checks from required VM UI checks.",
            ],
        },
        RunbookRole {
            name: "debugger",
            title: "Debugger Runbook",
            description: "Reproduction, root cause isolation, and minimal fix guidance.",
            when_to_use: &[
                "There is a failing command, crash, flaky behavior, or user-reported symptom without a known cause.",
                "The leader needs root cause and a minimal fix path before assigning implementation.",
            ],
            rules: &[
                "Start from observed symptoms and identify a reproducible path.",
                "Separate root cause from nearby incidental failures.",
                "Prefer minimal fixes with a clear verification command.",
                "Escalate to tester when the fix needs UI or regression coverage.",
            ],
            verify: &[
                "Capture the failing command, relevant log excerpt, and expected passing command.",
                "State confidence in the root cause and what would falsify it.",
            ],
        },
        RunbookRole {
            name: "writer",
            title: "Writer Runbook",
            description: "Documentation, changelog, and release-note updates.",
            when_to_use: &[
                "A shipped or ready change needs README, docs-site, AGENTS/CLAUDE, changelog, or release note updates.",
                "User-facing CLI, Settings, workflow, or onboarding behavior changed.",
            ],
            rules: &[
                "Update the single source of truth first, then linked docs.",
                "Keep docs aligned with current CLI names and socket methods.",
                "Mention exact insertion locations and self-check consistency.",
                "Avoid documenting speculative behavior as shipped behavior.",
            ],
            verify: &[
                "Check linked docs for stale command names and mismatched behavior.",
                "Report the source document and every synchronized projection touched.",
            ],
        },
        RunbookRole {
            name: "devops",
            title: "DevOps Runbook",
            description: "Build, release, CI, packaging, and operational workflows.",
            when_to_use: &[
                "The task touches build scripts, CI, release packaging, signing, tags, artifacts, or deployment.",
                "The leader needs reproducible operational commands and rollback awareness.",
            ],
            rules: &[
                "Check scripts, signing, packaging, and environment assumptions.",
                "Keep commands reproducible and avoid host-specific hidden state.",
                "Report artifact paths, versions, and rollback considerations.",
                "Do not publish, tag, or push unless the leader explicitly requested it.",
            ],
            verify: &[
                "Prefer dry-runs or read-only status commands before publishing actions.",
                "Record artifact paths and exact versions produced or inspected.",
            ],
        },
        RunbookRole {
            name: "planner",
            title: "Planner Runbook",
            description: "Task decomposition, dependency mapping, and phase gates.",
            when_to_use: &[
                "The work spans several files, agents, phases, or dependencies.",
                "The leader needs ownership, acceptance criteria, and ordering before execution.",
            ],
            rules: &[
                "Split work into independently assignable tasks with clear owners.",
                "List inputs, outputs, dependencies, and acceptance criteria.",
                "Prefer phase gates where shared contracts or multiple agents are involved.",
                "Emit tm-agent task create lines when actionable.",
            ],
            verify: &[
                "Ensure every task has an owner, input, output, dependency, and acceptance check.",
                "Call out critical-path blockers separately from parallelizable work.",
            ],
        },
        RunbookRole {
            name: "researcher",
            title: "Researcher Runbook",
            description: "Focused research, evidence gathering, and synthesis.",
            when_to_use: &[
                "The answer depends on external facts, current docs, prior art, or uncertain project history.",
                "The leader needs evidence and tradeoffs before design or implementation.",
            ],
            rules: &[
                "State sources and confidence, and separate fact from inference.",
                "Prefer primary sources and current project artifacts.",
                "Summarize findings into decisions, risks, and next checks.",
                "Avoid implementing changes while acting as researcher.",
            ],
            verify: &[
                "Cite sources or local artifacts used for material claims.",
                "List remaining unknowns and the fastest check to resolve each.",
            ],
        },
        RunbookRole {
            name: "data",
            title: "Data Engineer Runbook",
            description: "Schema design, query optimization, migrations, and data pipeline work.",
            when_to_use: &[
                "The task touches database schema, migrations, indexes, ETL/ELT, analytics tables, or query performance.",
                "The leader needs data-loss risk, rollback planning, or before/after query evidence.",
            ],
            rules: &[
                "Read existing schema, migration, and data access patterns before proposing changes.",
                "Include rollback strategy for every schema migration.",
                "Optimize queries from measured plans, not guesses.",
                "Flag data loss, backfill, locking, and deployment-order risks explicitly.",
            ],
            verify: &[
                "Run the migration, query test, or EXPLAIN command that validates the change.",
                "Report before/after plan or timing when query performance is part of the task.",
            ],
        },
        RunbookRole {
            name: "perf",
            title: "Performance Tuner Runbook",
            description: "Profiling, bottleneck isolation, optimization, and benchmark verification.",
            when_to_use: &[
                "The task asks to reduce latency, memory, CPU, I/O, startup time, or resource usage.",
                "A change claims performance impact and needs measurement.",
            ],
            rules: &[
                "Measure baseline behavior before changing code.",
                "Identify whether the bottleneck is CPU, memory, I/O, network, rendering, or algorithmic complexity.",
                "Apply one targeted optimization at a time.",
                "Do not trade correctness or maintainability for unmeasured speed.",
            ],
            verify: &[
                "Report BOTTLENECK, CAUSE, FIX, and RESULT with units.",
                "Include the benchmark/profiling command and before/after numbers.",
            ],
        },
        RunbookRole {
            name: "syseng",
            title: "System Engineer Runbook",
            description: "OS-level debugging, shell automation, daemon configuration, and system hardening.",
            when_to_use: &[
                "The task touches launchd/systemd, shell scripts, process state, file permissions, logs, networking, or host resources.",
                "The leader needs root-cause analysis from system state rather than application code alone.",
            ],
            rules: &[
                "Start with non-destructive observation commands and logs.",
                "Avoid destructive operations unless the leader explicitly approves them.",
                "List config files, services, sockets, and processes affected by the fix.",
                "Prefer idempotent scripts and reversible config changes.",
            ],
            verify: &[
                "Report exact commands used for diagnosis and verification.",
                "Confirm the symptom is resolved, not merely hidden by a restart.",
            ],
        },
        RunbookRole {
            name: "api",
            title: "API Designer Runbook",
            description: "API contracts, endpoint design, schemas, versioning, and compatibility review.",
            when_to_use: &[
                "The task asks for REST, GraphQL, gRPC, JSON-RPC, OpenAPI, protobuf, or webhook contract work.",
                "A change may affect external or cross-module clients.",
            ],
            rules: &[
                "Read existing API contracts and naming conventions before designing new shapes.",
                "Define request, response, error, auth, and pagination semantics where applicable.",
                "Flag breaking changes and provide a migration/versioning path.",
                "Keep contracts testable and avoid ambiguous nullable/optional behavior.",
            ],
            verify: &[
                "Provide a contract test, schema validation command, or compatibility check.",
                "Include example payloads for new or changed API surfaces.",
            ],
        },
        RunbookRole {
            name: "mobile",
            title: "Mobile Developer Runbook",
            description: "iOS/Android implementation, platform APIs, adaptive layout, and mobile constraints.",
            when_to_use: &[
                "The task touches SwiftUI/UIKit, Android/Compose/Kotlin, mobile permissions, notifications, storage, camera, or location.",
                "The user-visible behavior depends on mobile layout, accessibility, battery, startup, or offline/network constraints.",
            ],
            rules: &[
                "Follow platform idioms and existing app architecture.",
                "Account for permissions, OS version support, background behavior, and accessibility.",
                "Test layout-sensitive work across relevant screen sizes when feasible.",
                "Avoid introducing platform-specific warnings or entitlement drift.",
            ],
            verify: &[
                "Run the platform build or targeted UI/unit test for changed mobile code.",
                "Report device/simulator coverage and any unverified screen-size risk.",
            ],
        },
        RunbookRole {
            name: "infra",
            title: "Infrastructure Engineer Runbook",
            description: "Cloud infrastructure, IaC, Kubernetes, networking, scaling, and operational dependencies.",
            when_to_use: &[
                "The task touches Terraform, Pulumi, CloudFormation, CDK, Kubernetes, IAM, DNS, certificates, CDN, or scaling.",
                "The leader needs cost, dependency, secret, or rollout risk before infrastructure changes.",
            ],
            rules: &[
                "Read existing IaC module structure and naming before editing.",
                "Never hardcode credentials; use IAM, secret managers, or environment references.",
                "Document cost impact, manual steps, and rollout/rollback considerations.",
                "Keep resource changes minimal and reviewable.",
            ],
            verify: &[
                "Prefer plan/diff/dry-run commands over direct apply.",
                "Report resources changed, cost impact, and manual follow-up steps.",
            ],
        },
        RunbookRole {
            name: "ux",
            title: "UX Designer Runbook",
            description: "User flows, interaction design, usability review, component states, and accessibility specs.",
            when_to_use: &[
                "The task asks for flow design, wireframes, usability review, onboarding, interaction states, or UX copy.",
                "A product surface is confusing and needs structure before implementation.",
            ],
            rules: &[
                "Map the user goal and decision points before proposing UI.",
                "Define empty, loading, error, disabled, hover, focus, and success states where relevant.",
                "Call out accessibility requirements and keyboard/focus behavior.",
                "Stay read-only unless the leader explicitly assigns implementation.",
            ],
            verify: &[
                "Check the proposed flow against visibility, feedback, consistency, and recovery heuristics.",
                "Rank usability issues by impact and name the affected user action.",
            ],
        },
        RunbookRole {
            name: "ai",
            title: "AI Engineer Runbook",
            description: "LLM integration, prompt engineering, RAG, model pipelines, guardrails, and evaluation.",
            when_to_use: &[
                "The task touches LLM prompts, tool calls, structured output, embeddings, vector search, RAG, evals, or model selection.",
                "The leader needs cost, latency, quality, safety, or hallucination risk analysis for AI behavior.",
            ],
            rules: &[
                "Read existing prompt, retrieval, tool, and model-selection code before changing behavior.",
                "Define input/output schemas and validate model output before downstream use.",
                "Document cost/latency tradeoffs and model-specific assumptions.",
                "Never hardcode API keys; use environment variables or secret managers.",
            ],
            verify: &[
                "Run or specify an eval, golden-case test, schema validation, or dry-run for changed AI behavior.",
                "Report token/request estimates, expected cost per 1K calls, and known model limitations when applicable.",
            ],
        },
    ]
}

fn find_runbook_project_root() -> Result<PathBuf, String> {
    let start = env::current_dir().map_err(|e| format!("current_dir: {e}"))?;
    let mut cur = start.as_path();
    loop {
        if cur.join(".git").exists()
            || cur.join("AGENTS.md").exists()
            || cur.join("TODO.md").exists()
        {
            return Ok(cur.to_path_buf());
        }
        match cur.parent() {
            Some(parent) => cur = parent,
            None => return Ok(start),
        }
    }
}

fn parse_runbook_tools(tool: &str) -> Result<Vec<RunbookTool>, String> {
    let mut out = Vec::new();
    for raw in tool.split(',') {
        match raw.trim().to_ascii_lowercase().as_str() {
            "" => {}
            "all" => {
                return Ok(vec![
                    RunbookTool::Claude,
                    RunbookTool::Codex,
                    RunbookTool::OpenCode,
                    RunbookTool::Gemini,
                ])
            }
            "claude" | "claude-code" | "claudecode" => out.push(RunbookTool::Claude),
            "codex" => out.push(RunbookTool::Codex),
            "opencode" | "open-code" => out.push(RunbookTool::OpenCode),
            "gemini" => out.push(RunbookTool::Gemini),
            other => return Err(format!("unknown runbook tool: {other}")),
        }
    }
    if out.is_empty() {
        return Err("no runbook tool selected".to_string());
    }
    Ok(out)
}

fn selected_runbook_roles(agent: Option<&str>) -> Result<Vec<RunbookRole>, String> {
    let roles = builtin_runbook_roles();
    if let Some(name) = agent {
        let Some(role) = roles.into_iter().find(|r| r.name == name) else {
            return Err(format!("unknown runbook agent: {name}"));
        };
        return Ok(vec![role]);
    }
    Ok(roles)
}

fn runbook_source_path(root: &Path, role: &RunbookRole) -> PathBuf {
    root.join(RUNBOOK_SOURCE_DIR)
        .join(format!("{}.md", role.name))
}

fn load_runbook_content_for_role(root: &Path, role: &str) -> Option<String> {
    if !role
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return None;
    }
    let path = root.join(RUNBOOK_SOURCE_DIR).join(format!("{role}.md"));
    fs::read_to_string(path)
        .ok()
        .filter(|content| !content.trim().is_empty())
}

fn runbook_section_bullets(content: &str, section: &str, limit: usize) -> Vec<String> {
    let mut in_section = false;
    let mut out = Vec::new();
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("## ") {
            in_section = trimmed == section;
            continue;
        }
        if in_section {
            if let Some(item) = trimmed.strip_prefix("- ") {
                out.push(item.trim().to_string());
                if out.len() >= limit {
                    break;
                }
            }
        }
    }
    out
}

fn runbook_digest_content(root: &Path, role: &RunbookRole, agent_name: &str, team_name: &str) -> String {
    let source_path = runbook_source_path(root, role);
    let source_content = effective_source_runbook_content(root, role);
    let when = runbook_section_bullets(&source_content, "## When To Use", 2);
    let rules = runbook_section_bullets(&source_content, "## Operating Rules", 3);
    let verify = runbook_section_bullets(&source_content, "## Verify", 2);

    let when = if when.is_empty() {
        role.when_to_use
            .iter()
            .take(2)
            .copied()
            .collect::<Vec<_>>()
            .join(" | ")
    } else {
        when.join(" | ")
    };
    let must = if rules.is_empty() {
        role.rules
            .iter()
            .take(3)
            .copied()
            .collect::<Vec<_>>()
            .join(" | ")
    } else {
        rules.join(" | ")
    };
    let verify = if verify.is_empty() {
        role.verify
            .iter()
            .take(2)
            .copied()
            .collect::<Vec<_>>()
            .join(" | ")
    } else {
        verify.join(" | ")
    };

    format!(
        "\
=== AGENT IDENTITY (authoritative — never infer) ===
You are agent \"{agent_name}\" (role: {role}) on team \"{team_name}\". This is your fixed identity. Whenever you identify yourself, send a message, or substitute your name into any template or placeholder, ALWAYS use \"{agent_name}\" exactly — never guess or derive it. Messages shown by `tm-agent msg list` / `tm-agent inbox` are SHARED context from OTHER agents. They are reference only. NEVER copy another agent's message content, name, or template as your own response.
===

<!-- term-mesh-runbook-digest v1 -->
## Runbook Digest
ROLE: {role}
WHEN: {when}
MUST: {must}
VERIFY: {verify}
OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT
FULL: {full}
",
        agent_name = agent_name,
        role = role.name,
        when = when,
        must = must,
        verify = verify,
        full = source_path.to_string_lossy(),
        team_name = team_name,
    )
}

fn runbook_digest_content_for_role_name(
    root: &Path,
    role_name: &str,
    source: Option<&str>,
    agent_name: &str,
    team_name: &str,
) -> String {
    let safe_role_name: String = role_name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    let safe_role_name = if safe_role_name.is_empty() {
        "agent".to_string()
    } else {
        safe_role_name
    };
    let full = root
        .join(RUNBOOK_SOURCE_DIR)
        .join(format!("{safe_role_name}.md"))
        .to_string_lossy()
        .to_string();
    let content = source.unwrap_or("");
    let when = runbook_section_bullets(content, "## When To Use", 2).join(" | ");
    let must = runbook_section_bullets(content, "## Operating Rules", 3).join(" | ");
    let verify = runbook_section_bullets(content, "## Verify", 2).join(" | ");
    format!(
        "\
=== AGENT IDENTITY (authoritative — never infer) ===
You are agent \"{agent_name}\" (role: {safe_role_name}) on team \"{team_name}\". This is your fixed identity. Whenever you identify yourself, send a message, or substitute your name into any template or placeholder, ALWAYS use \"{agent_name}\" exactly — never guess or derive it. Messages shown by `tm-agent msg list` / `tm-agent inbox` are SHARED context from OTHER agents. They are reference only. NEVER copy another agent's message content, name, or template as your own response.
===

<!-- term-mesh-runbook-digest v1 -->
## Runbook Digest
ROLE: {safe_role_name}
WHEN: {when}
MUST: {must}
VERIFY: {verify}
OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT
FULL: {full}
",
        agent_name = agent_name,
        safe_role_name = safe_role_name,
        team_name = team_name,
        when = if when.is_empty() {
            format!("Use for assigned {safe_role_name} role work.")
        } else {
            when
        },
        must = if must.is_empty() {
            "Follow the leader's task instructions and repo constraints.".to_string()
        } else {
            must
        },
        verify = if verify.is_empty() {
            "Report a concrete verify command or n/a.".to_string()
        } else {
            verify
        },
    )
}

fn runbook_readme_path(root: &Path) -> PathBuf {
    root.join(RUNBOOK_SOURCE_DIR).join("README.md")
}

fn runbook_projection_path(root: &Path, tool: RunbookTool, role: &RunbookRole) -> PathBuf {
    match tool {
        RunbookTool::Claude => root
            .join(".claude/skills")
            .join(format!("term-mesh-{}", role.name))
            .join("SKILL.md"),
        RunbookTool::Codex => root
            .join(".codex/skills")
            .join(format!("term-mesh-{}", role.name))
            .join("SKILL.md"),
        RunbookTool::OpenCode => root
            .join(".opencode/runbooks")
            .join(format!("{}.md", role.name)),
        RunbookTool::Gemini => root
            .join(".gemini/skills")
            .join(format!("term-mesh-{}", role.name))
            .join("SKILL.md"),
    }
}

fn yaml_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn source_runbook_content(role: &RunbookRole) -> String {
    let mut out = format!(
        "{RUNBOOK_MARKER}\n# {}\n\n{}\n\n## Role\n\n`{}` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.\n\n## When To Use\n",
        role.title, role.description, role.name
    );
    for item in role.when_to_use {
        out.push_str(&format!("- {item}\n"));
    }
    out.push_str("\n## Operating Rules\n");
    for rule in role.rules {
        out.push_str(&format!("- {rule}\n"));
    }
    out.push_str("\n## Verify\n");
    for item in role.verify {
        out.push_str(&format!("- {item}\n"));
    }
    out.push_str(
        "\n## Standard Reply Header\n\n```text\nSTATUS: DONE|BLOCKED|NEEDS_REVIEW\nFILES: <changed paths or none>\nVERIFY: <single shell command or n/a>\nNEXT: <leader action or NONE>\nFULL_REPORT: <absolute result path or n/a>\n```\n",
    );
    out
}

fn effective_source_runbook_content(root: &Path, role: &RunbookRole) -> String {
    fs::read_to_string(runbook_source_path(root, role))
        .ok()
        .filter(|content| !content.trim().is_empty())
        .unwrap_or_else(|| source_runbook_content(role))
}

fn tool_runbook_content(tool: RunbookTool, role: &RunbookRole, source_content: &str) -> String {
    match tool {
        RunbookTool::Claude | RunbookTool::Codex | RunbookTool::Gemini => format!(
            "---\nname: term-mesh-{}\ndescription: \"{}\"\n---\n{}",
            role.name,
            yaml_escape(&format!(
                "Use when acting as the {} agent in a term-mesh team.",
                role.name
            )),
            source_content
        ),
        RunbookTool::OpenCode => source_content.to_string(),
    }
}

fn runbook_readme_content(roles: &[RunbookRole]) -> String {
    let mut out = format!(
        "{RUNBOOK_MARKER}\n# Agent Runbooks\n\nThese files are the source of truth for term-mesh per-agent behavior. Regenerate tool-specific projections with:\n\n```bash\ntm-agent runbook install --tool all\n```\n\n## Roles\n"
    );
    for role in roles {
        out.push_str(&format!("- `{}`: {}\n", role.name, role.description));
    }
    out
}

fn is_runbook_managed(content: &str) -> bool {
    content.lines().take(30).any(|line| line == RUNBOOK_MARKER)
}

fn file_runbook_state(path: &Path) -> &'static str {
    match fs::read_to_string(path) {
        Ok(content) if is_runbook_managed(&content) => "managed",
        Ok(_) => "custom",
        Err(_) => "missing",
    }
}

fn projection_runbook_state(
    root: &Path,
    tool: RunbookTool,
    role: &RunbookRole,
    path: &Path,
) -> &'static str {
    match fs::read_to_string(path) {
        Ok(content) if !is_runbook_managed(&content) => "custom",
        Ok(content) => {
            let source_content = effective_source_runbook_content(root, role);
            let expected = tool_runbook_content(tool, role, &source_content);
            if content == expected {
                "managed"
            } else {
                "outdated"
            }
        }
        Err(_) => "missing",
    }
}

fn write_managed_runbook(
    path: &Path,
    content: &str,
    dry_run: bool,
    force: bool,
) -> Result<Value, String> {
    let existing = fs::read_to_string(path).ok();
    let action = match existing.as_deref() {
        Some(old) if old == content => "unchanged",
        Some(old) if !is_runbook_managed(old) && !force => "skipped_custom",
        Some(_) if dry_run => "would_update",
        None if dry_run => "would_create",
        Some(_) => "updated",
        None => "created",
    };

    if !dry_run && matches!(action, "created" | "updated") {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("create_dir {}: {e}", parent.display()))?;
        }
        let file_name = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("runbook");
        let tmp = path.with_file_name(format!(".tmp-{file_name}"));
        fs::write(&tmp, content).map_err(|e| format!("write {}: {e}", tmp.display()))?;
        fs::rename(&tmp, path)
            .map_err(|e| format!("rename {} -> {}: {e}", tmp.display(), path.display()))?;
    }

    Ok(json!({
        "path": path.to_string_lossy(),
        "action": action,
    }))
}

fn runbook_init(dry_run: bool, force: bool) -> Result<Value, String> {
    let root = find_runbook_project_root()?;
    let roles = builtin_runbook_roles();
    let mut files = Vec::new();
    files.push(write_managed_runbook(
        &runbook_readme_path(&root),
        &runbook_readme_content(&roles),
        dry_run,
        force,
    )?);
    for role in &roles {
        files.push(write_managed_runbook(
            &runbook_source_path(&root, role),
            &source_runbook_content(role),
            dry_run,
            force,
        )?);
    }
    Ok(json!({
        "ok": true,
        "result": {
            "project_root": root.to_string_lossy(),
            "dry_run": dry_run,
            "files": files,
        }
    }))
}

fn runbook_install(
    tool: &str,
    agent: Option<&str>,
    dry_run: bool,
    force: bool,
) -> Result<Value, String> {
    let root = find_runbook_project_root()?;
    let tools = parse_runbook_tools(tool)?;
    let roles = selected_runbook_roles(agent)?;
    let all_roles = builtin_runbook_roles();
    let mut files = Vec::new();

    files.push(write_managed_runbook(
        &runbook_readme_path(&root),
        &runbook_readme_content(&all_roles),
        dry_run,
        force,
    )?);
    for role in &roles {
        files.push(write_managed_runbook(
            &runbook_source_path(&root, role),
            &source_runbook_content(role),
            dry_run,
            force,
        )?);
    }
    for tool in tools {
        for role in &roles {
            // F1+F4 fix: use effective_source_runbook_content (the same
            // resolver projection_runbook_state uses) so user edits to
            // managed source files propagate into projections instead of
            // being silently regenerated to defaults. Eliminates the
            // status="outdated" → install → still "outdated" drift loop.
            let source_content = effective_source_runbook_content(&root, role);
            files.push(write_managed_runbook(
                &runbook_projection_path(&root, tool, role),
                &tool_runbook_content(tool, role, &source_content),
                dry_run,
                force,
            )?);
        }
    }

    Ok(json!({
        "ok": true,
        "result": {
            "project_root": root.to_string_lossy(),
            "dry_run": dry_run,
            "agent": agent.unwrap_or("all"),
            "files": files,
        }
    }))
}

fn runbook_status() -> Result<Value, String> {
    let root = find_runbook_project_root()?;
    let roles = builtin_runbook_roles();
    let source: Vec<Value> = roles
        .iter()
        .map(|role| {
            let path = runbook_source_path(&root, role);
            json!({
                "role": role.name,
                "path": path.to_string_lossy(),
                "state": file_runbook_state(&path),
            })
        })
        .collect();

    let tools: Vec<Value> = [
        RunbookTool::Claude,
        RunbookTool::Codex,
        RunbookTool::OpenCode,
        RunbookTool::Gemini,
    ]
    .iter()
    .map(|tool| {
        let mut files = Vec::new();
        let mut managed = 0;
        let mut custom = 0;
        let mut missing = 0;
        let mut outdated = 0;
        for role in &roles {
            let path = runbook_projection_path(&root, *tool, role);
            let state = projection_runbook_state(&root, *tool, role, &path);
            match state {
                "managed" => managed += 1,
                "custom" => custom += 1,
                "outdated" => outdated += 1,
                _ => missing += 1,
            }
            files.push(json!({
                "role": role.name,
                "path": path.to_string_lossy(),
                "state": state,
            }));
        }
        json!({
            "tool": tool.as_str(),
            "managed": managed,
            "custom": custom,
            "missing": missing,
            "outdated": outdated,
            "files": files,
        })
    })
    .collect();

    Ok(json!({
        "ok": true,
        "result": {
            "project_root": root.to_string_lossy(),
            "source_dir": root.join(RUNBOOK_SOURCE_DIR).to_string_lossy(),
            "roles": roles.iter().map(|r| r.name).collect::<Vec<_>>(),
            "source": source,
            "tools": tools,
        }
    }))
}

fn runbook_digest(agent: Option<&str>) -> Result<Value, String> {
    let root = find_runbook_project_root()?;
    let roles = selected_runbook_roles(agent)?;
    let digests: Vec<Value> = roles
        .iter()
        .map(|role| {
            json!({
                "role": role.name,
                "path": runbook_source_path(&root, role).to_string_lossy(),
                // CLI digest preview has no live agent/team context.
                "digest": runbook_digest_content(&root, role, agent.unwrap_or("generic"), "cli-tools"),
            })
        })
        .collect();
    Ok(json!({
        "ok": true,
        "result": {
            "project_root": root.to_string_lossy(),
            "mode": "digest",
            "agent": agent.unwrap_or("all"),
            "digests": digests,
        }
    }))
}

fn run_runbook_command(command: &RunbookCommands) -> Result<Value, String> {
    match command {
        RunbookCommands::Status => runbook_status(),
        RunbookCommands::Init { dry_run, force } => runbook_init(*dry_run, *force),
        RunbookCommands::Install {
            tool,
            agent,
            dry_run,
            force,
        } => runbook_install(tool, agent.as_deref(), *dry_run, *force),
        RunbookCommands::Digest { agent } => runbook_digest(agent.as_deref()),
    }
}

#[cfg(test)]
mod runbook_tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn runbook_parse_tools_accepts_all_and_aliases() {
        let all = parse_runbook_tools("all").unwrap();
        assert_eq!(all.len(), 4);
        let all_names: Vec<&str> = all.iter().map(|t| t.as_str()).collect();
        assert_eq!(all_names, vec!["claude", "codex", "opencode", "gemini"]);

        let tools = parse_runbook_tools("claude-code,codex,open-code").unwrap();
        let names: Vec<&str> = tools.iter().map(|t| t.as_str()).collect();
        assert_eq!(names, vec!["claude", "codex", "opencode"]);
    }

    #[test]
    fn runbook_content_has_marker_and_skill_frontmatter() {
        let role = selected_runbook_roles(Some("reviewer")).unwrap().remove(0);
        let source = source_runbook_content(&role);
        assert!(source.starts_with(RUNBOOK_MARKER));
        assert!(source.contains("Reviewer Runbook"));
        assert!(source.contains("## When To Use"));
        assert!(source.contains("## Verify"));

        let skill = tool_runbook_content(RunbookTool::Codex, &role, &source);
        assert!(skill.starts_with("---\nname: term-mesh-reviewer"));
        assert!(skill.contains(RUNBOOK_MARKER));
    }

    #[test]
    fn runbook_write_skips_custom_files_without_force() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-runbook-test-{unique}"));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("custom.md");
        fs::write(&path, "user file\n").unwrap();

        let result = write_managed_runbook(&path, RUNBOOK_MARKER, false, false).unwrap();
        assert_eq!(result["action"].as_str(), Some("skipped_custom"));
        assert_eq!(fs::read_to_string(&path).unwrap(), "user file\n");

        let forced = write_managed_runbook(&path, RUNBOOK_MARKER, false, true).unwrap();
        assert_eq!(forced["action"].as_str(), Some("updated"));
        assert_eq!(file_runbook_state(&path), "managed");

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn runbook_init_prompt_loads_matching_role_file() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-runbook-prompt-{unique}"));
        let runbook_dir = dir.join(RUNBOOK_SOURCE_DIR);
        fs::create_dir_all(&runbook_dir).unwrap();
        fs::write(runbook_dir.join("explorer.md"), "EXPLORER ONLY\n").unwrap();

        let prompt = agent_init_prompt("exp1", "explorer", "test-team", &dir.to_string_lossy(), "/tmp/socket");
        assert!(prompt.contains("## Runbook Digest"));
        assert!(prompt.contains("OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT"));
        assert!(prompt.contains("named \"exp1\" with role \"explorer\""));
        assert!(prompt.contains(".agent-runbooks/explorer.md"));

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn runbook_projection_state_detects_outdated_managed_files() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-runbook-drift-{unique}"));
        let role = selected_runbook_roles(Some("reviewer")).unwrap().remove(0);
        let source_path = runbook_source_path(&dir, &role);
        let projection_path = runbook_projection_path(&dir, RunbookTool::Codex, &role);
        fs::create_dir_all(source_path.parent().unwrap()).unwrap();
        fs::create_dir_all(projection_path.parent().unwrap()).unwrap();

        let custom_source = format!("{RUNBOOK_MARKER}\n# Custom Reviewer\n\n## Role\ncustom\n");
        fs::write(&source_path, &custom_source).unwrap();
        fs::write(
            &projection_path,
            tool_runbook_content(RunbookTool::Codex, &role, &source_runbook_content(&role)),
        )
        .unwrap();

        assert_eq!(
            projection_runbook_state(&dir, RunbookTool::Codex, &role, &projection_path),
            "outdated"
        );

        fs::write(
            &projection_path,
            tool_runbook_content(RunbookTool::Codex, &role, &custom_source),
        )
        .unwrap();
        assert_eq!(
            projection_runbook_state(&dir, RunbookTool::Codex, &role, &projection_path),
            "managed"
        );

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn runbook_digest_uses_source_sections() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-runbook-digest-{unique}"));
        let role = selected_runbook_roles(Some("executor")).unwrap().remove(0);
        let source_path = runbook_source_path(&dir, &role);
        fs::create_dir_all(source_path.parent().unwrap()).unwrap();
        fs::write(
            &source_path,
            "\
## When To Use
- Custom when

## Operating Rules
- Custom rule A
- Custom rule B

## Verify
- Custom verify
",
        )
        .unwrap();

        let digest = runbook_digest_content(&dir, &role, "test-agent", "test-team");
        assert!(digest.contains("ROLE: executor"));
        assert!(digest.contains("Custom rule A"));
        assert!(digest.contains("Custom verify"));
        assert!(digest.contains("FULL:"));

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn unknown_role_digest_does_not_inline_full_runbook() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-runbook-custom-digest-{unique}"));
        let runbook_dir = dir.join(RUNBOOK_SOURCE_DIR);
        fs::create_dir_all(&runbook_dir).unwrap();
        fs::write(
            runbook_dir.join("custom.md"),
            "## When To Use\n- Custom when\n\n## Operating Rules\n- Custom must\n\nLONG BODY SHOULD NOT INLINE\n",
        )
        .unwrap();

        let digest = runbook_digest_content_for_role_name(
            &dir,
            "custom",
            load_runbook_content_for_role(&dir, "custom").as_deref(),
            "test-agent",
            "test-team",
        );
        assert!(digest.contains("ROLE: custom"));
        assert!(digest.contains("Custom must"));
        assert!(!digest.contains("LONG BODY SHOULD NOT INLINE"));

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn truncate_summary_counts_unicode_chars() {
        assert_eq!(truncate_summary("가나다라마", 3), "가나다...");
        assert_eq!(truncate_summary("abc", 3), "abc");
    }

    #[test]
    fn reply_summary_strips_one_summary_prefix_and_keeps_first_header() {
        let (headers, summary) = reply_header_and_summary(
            "STATUS: DONE\nSTATUS: BLOCKED\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\n\nSUMMARY:SUMMARY: keep",
            200,
        );
        assert_eq!(headers["status"].as_str(), Some("DONE"));
        assert_eq!(summary, "SUMMARY: keep");
    }

    #[test]
    fn result_collect_compaction_removes_full_content() {
        let resp = json!({
            "ok": true,
            "result": {
                "results": [{
                    "agent": "executor",
                    "content": "STATUS: DONE\nFILES: a.rs\nVERIFY: cargo test\nNEXT: NONE\nFULL_REPORT: /tmp/full.md\n\nSUMMARY:\nChanged code"
                }]
            }
        });
        let compact = compact_result_collect_response(resp, true);
        let item = &compact["result"]["results"][0];
        assert!(item.get("content").is_none());
        assert_eq!(item["headers"]["status"].as_str(), Some("DONE"));
        assert_eq!(
            item["headers"]["full_report"].as_str(),
            Some("/tmp/full.md")
        );
        assert!(item["summary"].as_str().unwrap().contains("Changed code"));
    }

    #[test]
    fn atomic_write_file_replaces_content_without_temp_residue() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-atomic-result-{unique}"));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("task.md");

        atomic_write_file(&path, "first").unwrap();
        atomic_write_file(&path, "second").unwrap();

        assert_eq!(fs::read_to_string(&path).unwrap(), "second");
        let leftovers: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .filter_map(|entry| entry.ok())
            .filter(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty());

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn return_retry_policy_is_conservative_when_text_delivery_failed() {
        assert_eq!(return_retry_delays_ms(true), &[250, 400, 600, 800, 1000]);
        assert_eq!(return_retry_delays_ms(false), &[200, 500]);
    }
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
    let timeout = env::var("TERMMESH_RPC_TIMEOUT")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(6);
    rpc_call_timeout(sock, method, params, timeout)
}

fn rpc_call_timeout(
    sock: &PathBuf,
    method: &str,
    params: Value,
    timeout_secs: u64,
) -> Result<Value, String> {
    let stream = UnixStream::connect(sock).map_err(|e| format!("connect: {e}"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(timeout_secs)))
        .ok();
    stream
        .set_write_timeout(Some(Duration::from_secs(timeout_secs)))
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

    stream
        .write_all(line.as_bytes())
        .map_err(|e| format!("write: {e}"))?;

    let mut response = String::new();
    reader
        .read_line(&mut response)
        .map_err(|e| format!("read: {e}"))?;

    serde_json::from_str(&response).map_err(|e| format!("parse: {e}"))
}

/// Send multiple JSON-RPC calls over a single connection.
fn rpc_batch(sock: &PathBuf, payloads: &[String]) -> Result<Vec<Value>, String> {
    // Validate all payloads are valid JSON before sending
    for (i, payload) in payloads.iter().enumerate() {
        serde_json::from_str::<Value>(payload)
            .map_err(|e| format!("invalid JSON in payload {i}: {e}"))?;
    }

    let batch_timeout = env::var("TERMMESH_RPC_TIMEOUT")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(6);
    let stream = UnixStream::connect(sock).map_err(|e| format!("connect: {e}"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(batch_timeout)))
        .ok();
    stream.set_write_timeout(Some(Duration::from_secs(3))).ok();

    let mut writer = stream.try_clone().map_err(|e| format!("clone: {e}"))?;
    for payload in payloads {
        writer
            .write_all(payload.as_bytes())
            .map_err(|e| format!("write: {e}"))?;
        writer.write_all(b"\n").map_err(|e| format!("write: {e}"))?;
    }
    writer.flush().map_err(|e| format!("flush: {e}"))?;

    let mut reader = BufReader::new(&stream);
    let mut results = Vec::new();
    for _ in payloads {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => break, // EOF
            Ok(_) if !line.trim().is_empty() => match serde_json::from_str::<Value>(&line) {
                Ok(v) => results.push(v),
                Err(e) => {
                    eprintln!("  Warning: rpc_batch parse error: {e}");
                    results.push(json!({"error": format!("parse: {e}")}));
                }
            },
            Err(e) => {
                eprintln!("  Warning: rpc_batch read error: {e}");
                results.push(json!({"error": format!("read: {e}")}));
                break;
            }
            _ => {
                results.push(json!({"error": "empty response"}));
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
                    _ => {
                        return Err(format!(
                            "batch: unknown task subcommand '{sub}'. Supported: list"
                        ))
                    }
                }
            }
            "send" => {
                // Accept "agent:message" or "agent message" formats
                let (agent_name, text) = if let Some(colon) = rest.find(':') {
                    (&rest[..colon], rest[colon + 1..].trim())
                } else {
                    match rest.find(' ') {
                        Some(pos) => (&rest[..pos], rest[pos + 1..].trim()),
                        None => {
                            return Err(
                                "batch: send requires <agent>:<text> or <agent> <text>".to_string()
                            )
                        }
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
            _ => {
                return Err(format!(
                "batch: unsupported command '{verb}'. Supported: status, task list, send, broadcast"
            ))
            }
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
fn run_heartbeat_auto(
    sock: &PathBuf,
    team: &str,
    agent: &str,
    interval: u64,
    message: Option<&str>,
) -> Result<Value, String> {
    use std::sync::atomic::{AtomicBool, Ordering};

    static STOP: AtomicBool = AtomicBool::new(false);

    extern "C" fn handle_signal(_: libc::c_int) {
        STOP.store(true, Ordering::SeqCst);
    }
    unsafe {
        libc::signal(
            libc::SIGINT,
            handle_signal as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGTERM,
            handle_signal as *const () as libc::sighandler_t,
        );
    }

    let ppid = unsafe { libc::getppid() };
    let msg = message.unwrap_or("working...");

    eprintln!(
        "auto-heartbeat started (interval={}s, ppid={}, send SIGINT/SIGTERM to stop)",
        interval, ppid
    );

    loop {
        // Send heartbeat
        let _ = rpc_call(
            sock,
            "team.agent.heartbeat",
            json!({
                "team_name": team,
                "agent_name": agent,
                "summary": msg,
            }),
        );

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
    if no_report {
        text.to_string()
    } else {
        format!("{text}{REPORT_SUFFIX}")
    }
}

// ── Research helpers ──────────────────────────────────────────────────────────

/// Lightweight info about one agent, extracted from `team.status` response.
#[derive(Debug, Clone)]
struct AgentInfo {
    name: String,
    #[allow(dead_code)] // Parsed from status, used for future model routing
    model: String,
    cli: String,
    agent_state: String,
}

impl AgentInfo {
    fn from_value(v: &Value) -> Option<Self> {
        let name = v["name"].as_str()?.to_string();
        let model = v["model"].as_str().unwrap_or("sonnet").to_string();
        let cli = v["cli"].as_str().unwrap_or("claude").to_string();
        let agent_state = v["agent_state"].as_str().unwrap_or("").to_string();
        Some(Self {
            name,
            model,
            cli,
            agent_state,
        })
    }
}

/// Query `team.status` and return agents that are currently idle,
/// optionally restricted to those running the given CLI (e.g. "claude").
fn detect_idle_agents(sock: &PathBuf, team: &str, model_filter: Option<&str>) -> Vec<AgentInfo> {
    let status = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error querying team status: {e}");
            return Vec::new();
        }
    };

    let agents = match status["result"]["agents"].as_array() {
        Some(a) => a.clone(),
        None => return Vec::new(),
    };

    agents
        .iter()
        .filter_map(AgentInfo::from_value)
        .filter(|a| a.agent_state == "idle")
        .filter(|a| {
            if let Some(filter) = model_filter {
                a.cli == filter
            } else {
                true
            }
        })
        .collect()
}

/// Choose which agents to assign from the idle pool.
///
/// Returns `(selected, warning)`:
/// - If no idle agents → returns empty vec and an error string (caller should exit).
/// - If fewer idle agents than `requested` → returns all idle with a warning.
/// - Otherwise → returns exactly `requested` agents (or all if `requested == 0`).
fn select_agents(idle: Vec<AgentInfo>, requested: u32) -> (Vec<AgentInfo>, Option<String>) {
    if idle.is_empty() {
        return (
            Vec::new(),
            Some("No idle agents. Create a team first: tm-agent create 3".to_string()),
        );
    }

    if requested == 0 || requested as usize >= idle.len() {
        // Use all idle agents; warn if we asked for more than available.
        let warn = if requested > 0 && (requested as usize) > idle.len() {
            Some(format!(
                "Warning: requested {requested} agents but only {} idle — using all {}.",
                idle.len(),
                idle.len()
            ))
        } else {
            None
        };
        (idle, warn)
    } else {
        (idle.into_iter().take(requested as usize).collect(), None)
    }
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

/// Format instruction for autonomous mode: task context + instruction only.
/// No lifecycle commands (task start/done/reply) since the detached monitor handles completion.
fn format_autonomous_instruction(task: &Value, instruction: &str, context: Option<&str>) -> String {
    let mut lines = vec![
        format!("[TASK_ID] {}", task["id"].as_str().unwrap_or("")),
        format!("[TASK_TITLE] {}", task["title"].as_str().unwrap_or("")),
    ];
    if let Some(ctx) = context {
        let truncated = truncate_summary(ctx, 3000);
        lines.push(String::new());
        lines.push("[PRIOR_CONTEXT]".to_string());
        lines.push(truncated);
        lines.push("[/PRIOR_CONTEXT]".to_string());
    }
    lines.push(String::new());
    lines.push(instruction.trim().to_string());
    lines.join("\n")
}

fn format_task_instruction(
    sock: &PathBuf,
    team: &str,
    task: &Value,
    instruction: &str,
    no_report: bool,
    context: Option<&str>,
    fix_budget: Option<u8>,
) -> String {
    let task_id = task["id"].as_str().unwrap_or("");
    let mut lines = vec![
        "## Task Capsule".to_string(),
        format!("TASK_ID: {task_id}"),
        format!("TASK_TITLE: {}", task["title"].as_str().unwrap_or("")),
        format!(
            "TASK_STATUS: {}",
            task["status"].as_str().unwrap_or("assigned")
        ),
        "PROTOCOL: TM-PROTOCOL-v1".to_string(),
        "OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT header plus concise summary".to_string(),
    ];
    if let Some(p) = task["priority"].as_u64() {
        lines.push(format!("TASK_PRIORITY: {p}"));
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
                if let Ok(dep_resp) = rpc_call(
                    sock,
                    "team.task.get",
                    json!({
                        "team_name": team, "task_id": dep_id,
                    }),
                ) {
                    let dep_task = &dep_resp["result"];
                    if dep_task["status"].as_str() == Some("completed") {
                        let content = if let Some(path) = dep_task["result_path"].as_str() {
                            std::fs::read_to_string(path).ok()
                        } else {
                            dep_task["result"].as_str().map(String::from)
                        };
                        if let Some(text) = content {
                            let dep_ref = write_result_file(
                                team,
                                &format!("{task_id}-dep-{dep_id}.md"),
                                &text,
                            )
                            .map(|p| p.to_string_lossy().to_string());
                            let truncated = truncate_summary(&text, 600);
                            if let Ok(path) = dep_ref.as_ref() {
                                lines.push(format!("DEP_REF: {dep_id} {path}"));
                            } else if let Err(err) = dep_ref.as_ref() {
                                eprintln!(
                                    "warning: failed to write dependency result ref for {dep_id}: {err}"
                                );
                            }
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
        let context_ref = write_result_file(team, &format!("{task_id}-context.md"), ctx)
            .map(|p| p.to_string_lossy().to_string());
        let truncated = truncate_summary(ctx, if context_ref.is_ok() { 500 } else { 3000 });
        lines.push(String::new());
        match context_ref {
            Ok(path) => lines.push(format!("CONTEXT_REF: {path}")),
            Err(err) => {
                eprintln!("warning: failed to write context ref for task {task_id}: {err}");
                lines.push(format!("CONTEXT_REF_ERROR: {err}"));
            }
        }
        lines.push("[CONTEXT_SUMMARY]".to_string());
        lines.push(truncated);
        lines.push("[/CONTEXT_SUMMARY]".to_string());
    }

    lines.push(String::new());
    lines.push("[GOAL]".to_string());
    lines.push(instruction.trim().to_string());
    lines.push("[/GOAL]".to_string());

    // Inject Auto-Fix Budget rules when budget is set
    if let Some(budget) = fix_budget {
        lines.push(String::new());
        lines.push(format!("## Auto-Fix Budget: {budget} attempts"));
        lines.push(format!("BEFORE each build/test/error fix attempt, run:"));
        lines.push(format!("  tm-agent task fix-attempt {task_id}"));
        lines.push(format!(
            "If it prints BUDGET_EXHAUSTED, stop immediately — you are auto-blocked."
        ));
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
    // Sanitize filename to prevent path traversal
    let safe_filename: String = filename
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_' || *c == '.')
        .collect();
    let safe_filename = if safe_filename.is_empty() {
        "unknown.md".to_string()
    } else {
        safe_filename
    };
    let filename = safe_filename.as_str();
    let dir = results_dir(team);
    std::fs::create_dir_all(&dir).map_err(|e| format!("mkdir: {e}"))?;
    let path = dir.join(filename);
    atomic_write_file(&path, content)?;
    Ok(path)
}

fn atomic_write_file(path: &Path, content: &str) -> Result<(), String> {
    let dir = path
        .parent()
        .ok_or_else(|| format!("missing parent for {}", path.display()))?;
    std::fs::create_dir_all(dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    let filename = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("result");

    for attempt in 0..16 {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let tmp = dir.join(format!(
            ".{filename}.{}.{}.{}.tmp",
            process::id(),
            nonce,
            attempt
        ));
        let mut file = match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
        {
            Ok(file) => file,
            Err(e) if e.kind() == ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("create temp {}: {e}", tmp.display())),
        };
        if let Err(e) = file.write_all(content.as_bytes()) {
            let _ = fs::remove_file(&tmp);
            return Err(format!("write {}: {e}", tmp.display()));
        }
        if let Err(e) = file.sync_all() {
            let _ = fs::remove_file(&tmp);
            return Err(format!("sync {}: {e}", tmp.display()));
        }
        drop(file);
        if let Err(e) = fs::rename(&tmp, path) {
            let _ = fs::remove_file(&tmp);
            return Err(format!(
                "rename {} -> {}: {e}",
                tmp.display(),
                path.display()
            ));
        }
        return Ok(());
    }

    Err(format!(
        "failed to create unique temp file for {}",
        path.display()
    ))
}

fn reply_target_task_id(sock: &PathBuf, team: &str, sender: &str) -> Option<String> {
    let task_resp = rpc_call(
        sock,
        "team.task.list",
        json!({
            "team_name": team, "assignee": sender
        }),
    )
    .ok()?;
    let tasks = task_resp["result"]["tasks"].as_array()?;
    let target_task = tasks
        .iter()
        .find(|t| t["status"].as_str() == Some("in_progress"))
        .or_else(|| {
            tasks.iter().find(|t| {
                let st = t["status"].as_str().unwrap_or("");
                st != "completed" && st != "failed" && st != "abandoned"
            })
        })?;
    target_task["id"].as_str().map(str::to_string)
}

fn return_retry_delays_ms(text_delivered: bool) -> &'static [u64] {
    if text_delivered {
        // First delay raised from 20 ms → 250 ms so the Return key arrives after
        // codex has fully rendered the pasted text and is ready to accept input.
        // Swift asyncTeamSendKey also holds an additional 250 ms post-Return gate
        // before releasing the next paste, providing two layers of protection.
        //
        // Long tail (1500/2500/4000 ms) added defensively for the Layer-2
        // congestion race: during multi-agent `create`, simultaneous panel/CLI
        // startup + layout churn can keep the freshly spawned panel from being
        // key-ready well past 1 s. The common case still resolves at attempt 1
        // (250 ms); only a stubborn panel walks the tail (~11 s worst case).
        &[250, 400, 600, 800, 1000, 1500, 2500, 4000]
    } else {
        &[200, 500, 1000, 2000]
    }
}

fn send_return_key_with_retry(
    sock: &PathBuf,
    team: &str,
    target: &str,
    text_delivered: bool,
    context: &str,
) -> bool {
    let delays = return_retry_delays_ms(text_delivered);
    eprintln!(
        "send_key.skip_or_retry context={context} text_delivered={text_delivered} attempts={} delays_ms={}",
        delays.len(),
        delays
            .iter()
            .map(u64::to_string)
            .collect::<Vec<_>>()
            .join(",")
    );

    for (attempt, delay_ms) in delays.iter().enumerate() {
        if *delay_ms > 0 {
            std::thread::sleep(Duration::from_millis(*delay_ms));
        }
        eprintln!("team.send_key attempt {}/{}", attempt + 1, delays.len());
        match rpc_call(
            sock,
            "team.send_key",
            json!({
                "team_name": team,
                "agent_name": target,
                "key": "return",
            }),
        ) {
            Ok(r) if r["ok"].as_bool().unwrap_or(false) => return true,
            Ok(_) | Err(_) => {}
        }
    }

    eprintln!(
        "  Warning: Return key delivery failed after {} retries",
        delays.len()
    );
    false
}

fn truncate_summary(content: &str, max_chars: usize) -> String {
    if content.chars().count() <= max_chars {
        return content.to_string();
    }
    format!("{}...", content.chars().take(max_chars).collect::<String>())
}

fn reply_header_and_summary(content: &str, summary_chars: usize) -> (Value, String) {
    let header_keys = ["STATUS", "FILES", "VERIFY", "NEXT", "FULL_REPORT"];
    let mut headers = serde_json::Map::new();
    let mut body_lines = Vec::new();
    for line in content.lines() {
        let trimmed = line.trim();
        let mut matched = false;
        for key in header_keys {
            if let Some(value) = trimmed.strip_prefix(&format!("{key}:")) {
                headers
                    .entry(key.to_ascii_lowercase())
                    .or_insert_with(|| json!(value.trim()));
                matched = true;
                break;
            }
        }
        if !matched {
            body_lines.push(line);
        }
    }
    for key in header_keys {
        headers
            .entry(key.to_ascii_lowercase())
            .or_insert_with(|| json!("n/a"));
    }
    let joined = body_lines.join("\n");
    let body = joined.trim();
    let body = body
        .strip_prefix("SUMMARY:")
        .unwrap_or(body)
        .trim()
        .to_string();
    (
        Value::Object(headers),
        truncate_summary(&body, summary_chars),
    )
}

fn compact_result_collect_response(mut resp: Value, include_summary: bool) -> Value {
    if let Some(results) = resp
        .get_mut("result")
        .and_then(|r| r.get_mut("results"))
        .and_then(|r| r.as_array_mut())
    {
        for result in results {
            if let Some(obj) = result.as_object_mut() {
                let content = obj
                    .get("content")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let (headers, summary) = reply_header_and_summary(&content, 700);
                obj.insert("headers".to_string(), headers);
                if include_summary {
                    obj.insert("summary".to_string(), json!(summary));
                }
                obj.remove("content");
            }
        }
    }
    resp
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

// ── Board helpers ────────────────────────────────────────────────────

/// Detect the git root by walking up from `start`, falling back to `start`.
fn find_project_root(start: &std::path::Path) -> PathBuf {
    let mut dir = start.to_path_buf();
    loop {
        if dir.join(".git").exists() {
            return dir;
        }
        match dir.parent() {
            Some(p) => dir = p.to_path_buf(),
            None => return start.to_path_buf(),
        }
    }
}

/// Create `.xm/{behavior_type}/{run-id}/board.jsonl` under the project root.
/// Returns `(board_path, run_id)` where `board_path` is absolute.
fn create_board(behavior_type: &str) -> Result<(PathBuf, String), String> {
    use std::time::{SystemTime, UNIX_EPOCH};

    let cwd = env::current_dir().map_err(|e| format!("current_dir: {e}"))?;
    let project_root = find_project_root(&cwd);

    // run-id: {behavior_type}-{YYYYMMDD-HHMMSS}-{random_hex_4}
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    // Compute calendar fields from Unix timestamp (UTC, no external crate needed).
    let (year, month, day, hour, min, sec) = unix_ts_to_ymd_hms(now);
    let rand_hex = {
        // Use low bits of nanos for entropy.
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .subsec_nanos();
        format!("{:04x}", (nanos ^ (process::id() << 16)) & 0xFFFF)
    };
    let run_id =
        format!("{behavior_type}-{year:04}{month:02}{day:02}-{hour:02}{min:02}{sec:02}-{rand_hex}");

    let board_dir = project_root.join(".xm").join(behavior_type).join(&run_id);

    std::fs::create_dir_all(&board_dir)
        .map_err(|e| format!("create_dir_all {}: {e}", board_dir.display()))?;

    let board_path = board_dir.join("board.jsonl");
    std::fs::File::create(&board_path)
        .map_err(|e| format!("create board.jsonl {}: {e}", board_path.display()))?;

    Ok((board_path, run_id))
}

/// Return the absolute board path as a string suitable for template injection.
fn board_path_for_prompt(board: &std::path::Path) -> String {
    board
        .canonicalize()
        .unwrap_or_else(|_| board.to_path_buf())
        .to_string_lossy()
        .to_string()
}

/// Convert a Unix timestamp (seconds) to (year, month, day, hour, min, sec) in UTC.
/// No external crates; handles leap years.
fn unix_ts_to_ymd_hms(ts: u64) -> (u32, u32, u32, u32, u32, u32) {
    let sec = (ts % 60) as u32;
    let min = ((ts / 60) % 60) as u32;
    let hour = ((ts / 3600) % 24) as u32;
    let days = ts / 86400; // days since 1970-01-01

    // Compute year/month/day from days since epoch.
    let mut y: u32 = 1970;
    let mut d = days as u32;
    loop {
        let days_in_year = if is_leap(y) { 366 } else { 365 };
        if d < days_in_year {
            break;
        }
        d -= days_in_year;
        y += 1;
    }
    let month_days: &[u32] = if is_leap(y) {
        &[31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        &[31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut m: u32 = 1;
    for &md in month_days {
        if d < md {
            break;
        }
        d -= md;
        m += 1;
    }
    (y, m, d + 1, hour, min, sec)
}

fn is_leap(y: u32) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

// ── Main ─────────────────────────────────────────────────────────────

fn main() {
    let cli = Cli::parse();

    // Peer commands carry their own socket path — handle them before
    // the daemon-socket detection that would otherwise fail when there
    // is no running term-mesh daemon in the environment.
    if let Commands::Peer(ref peer_cmd) = cli.command {
        match &peer_cmd.command {
            PeerCommand::List { socket } => {
                if let Err(e) = peer::list_cmd(socket) {
                    eprintln!("peer list failed: {e:#}");
                    process::exit(1);
                }
                return;
            }
            PeerCommand::Attach { socket, name } => {
                if let Err(e) = peer::attach_cmd(socket, name.as_deref()) {
                    eprintln!("peer attach failed: {e:#}");
                    process::exit(1);
                }
                return;
            }
        }
    }

    // Runbook commands operate on the current repository, not the app socket.
    // They must work before term-mesh is running so onboarding can bootstrap itself.
    if let Commands::Runbook(ref runbook_cmd) = cli.command {
        print_result(run_runbook_command(runbook_cmd));
        return;
    }

    // Doctor runs without a socket (it probes all sockets itself).
    if let Commands::Doctor { verbose, json } = &cli.command {
        cmd_doctor(*verbose, *json);
        return;
    }

    if let Commands::XmbBridge {
        timeout,
        leader_session,
    } = &cli.command
    {
        let sock = detect_daemon_socket()
            .or_else(detect_socket)
            .unwrap_or_else(|| {
                eprintln!("Error: no daemon socket found");
                process::exit(1);
            });
        run_xmb_bridge(&sock, *timeout, leader_session.as_deref());
        return;
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

    let result = match cli.command {
        // ── Agent-side commands ──────────────────────────────────
        Commands::Report { content } => {
            let report_content = content.as_deref().unwrap_or("done");
            let report_params = json!({
                "team_name": team,
                "agent_name": agent,
                "content": report_content,
            });
            // team.report — retry once on failure (wait hangs permanently if this is lost)
            let report_result = rpc_call(&sock, "team.report", report_params.clone());
            if let Err(ref e) = report_result {
                eprintln!("  Warning: team.report failed: {e}, retrying...");
                let _ = rpc_call(&sock, "team.report", report_params);
            }
            // Auto-complete the active task using team.task.list (data command,
            // no MainActor) instead of team.status (UI command) to avoid timeout.
            if report_result.is_ok() {
                if let Ok(task_resp) = rpc_call(
                    &sock,
                    "team.task.list",
                    json!({
                        "team_name": &team, "assignee": &agent
                    }),
                ) {
                    if let Some(tasks) = task_resp["result"]["tasks"].as_array() {
                        let summary = truncate_summary(report_content, 1500);
                        // Prefer in_progress task (the one actively being worked on),
                        // then fall back to any non-terminal task. This prevents
                        // completing a queued/blocked task when multiple tasks exist.
                        let target_task = tasks
                            .iter()
                            .find(|t| t["status"].as_str() == Some("in_progress"))
                            .or_else(|| {
                                tasks.iter().find(|t| {
                                    let st = t["status"].as_str().unwrap_or("");
                                    st != "completed" && st != "failed" && st != "abandoned"
                                })
                            });
                        if let Some(t) = target_task {
                            if let Some(tid) = t["id"].as_str() {
                                let update = json!({
                                    "team_name": &team, "task_id": tid,
                                    "status": "completed", "result": summary,
                                });
                                // task.update — retry once on failure (task stays in_progress forever if lost)
                                let update_result =
                                    rpc_call(&sock, "team.task.update", update.clone());
                                if let Err(ref e) = update_result {
                                    eprintln!("  Warning: task.update failed: {e}, retrying...");
                                    let _ = rpc_call(&sock, "team.task.update", update);
                                }
                            }
                        }
                    }
                }
            }
            report_result
        }
        Commands::Ping {
            summary,
            auto,
            interval,
        }
        | Commands::Heartbeat {
            summary,
            auto,
            interval,
        } => {
            if auto {
                run_heartbeat_auto(&sock, &team, &agent, interval, summary.as_deref())
            } else {
                rpc_call(
                    &sock,
                    "team.agent.heartbeat",
                    json!({
                        "team_name": team,
                        "agent_name": agent,
                        "summary": summary.as_deref().unwrap_or("alive"),
                    }),
                )
            }
        }
        Commands::Msg(sub) => match sub {
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
            MsgCommands::List {
                from_agent,
                to,
                limit,
            } => {
                let mut params = json!({ "team_name": team });
                if let Some(f) = from_agent {
                    params["from"] = json!(f);
                }
                if let Some(t) = to {
                    params["to"] = json!(t);
                }
                if let Some(l) = limit {
                    params["limit"] = json!(l);
                }
                rpc_call(&sock, "team.message.list", params)
            }
            MsgCommands::Clear => {
                rpc_call(&sock, "team.message.clear", json!({ "team_name": team }))
            }
        },
        Commands::Context(sub) => match sub {
            ContextCommands::Set { key, value } => {
                let agent = agent.clone();
                rpc_call(
                    &sock,
                    "team.context.set",
                    json!({
                        "team_name": team, "key": key, "value": value, "set_by": agent,
                    }),
                )
            }
            ContextCommands::Get { key } => rpc_call(
                &sock,
                "team.context.get",
                json!({ "team_name": team, "key": key }),
            ),
            ContextCommands::List => {
                rpc_call(&sock, "team.context.list", json!({ "team_name": team }))
            }
        },
        Commands::Template(sub) => match sub {
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
            TemplateCommands::Show { name } => match load_template(&name) {
                Ok(t) => {
                    println!("name:     {}", t.name);
                    println!("title:    {}", t.title);
                    if let Some(d) = &t.description {
                        println!("desc:\n  {}", d.replace('\n', "\n  "));
                    }
                    if let Some(p) = t.priority {
                        println!("priority: {p}");
                    }
                    if let Some(a) = &t.assign {
                        println!("assign:   {a}");
                    }
                    return;
                }
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            },
        },
        Commands::Task(sub) => {
            match sub {
                TaskCommands::Start { task_id } => rpc_call(
                    &sock,
                    "team.task.update",
                    json!({
                        "team_name": team, "task_id": task_id, "status": "in_progress",
                    }),
                ),
                TaskCommands::Done { task_id, result } => {
                    let result_text = result.as_deref().unwrap_or("done");
                    // Write full result to file, send truncated summary via socket
                    let result_path =
                        write_result_file(&team, &format!("{task_id}.md"), result_text).ok();
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
                TaskCommands::Block { task_id, reason } => rpc_call(
                    &sock,
                    "team.task.block",
                    json!({
                        "team_name": team, "task_id": task_id,
                        "blocked_reason": reason.as_deref().unwrap_or("blocked"),
                    }),
                ),
                TaskCommands::Create {
                    title,
                    assign,
                    desc,
                    priority,
                    accept,
                    deps,
                    template,
                    var,
                } => {
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
                        eprintln!(
                            "Error: title required (provide as positional arg or via --template)"
                        );
                        std::process::exit(1);
                    });
                    let final_desc = desc.or(tmpl_desc);
                    let final_assign = assign.or(tmpl_assign);
                    let final_priority = priority.or(tmpl_priority);

                    let mut params = json!({ "team_name": team, "title": final_title });
                    if let Some(a) = final_assign {
                        params["assignee"] = json!(a);
                    }
                    if let Some(d) = final_desc {
                        params["description"] = json!(d);
                    }
                    if let Some(p) = final_priority {
                        params["priority"] = json!(p);
                    }
                    if !accept.is_empty() {
                        params["acceptance_criteria"] = json!(accept);
                    }
                    if !deps.is_empty() {
                        params["depends_on"] = json!(deps);
                    }
                    rpc_call(&sock, "team.task.create", params)
                }
                TaskCommands::Get { id } => rpc_call(
                    &sock,
                    "team.task.get",
                    json!({
                        "team_name": team, "task_id": id,
                    }),
                ),
                TaskCommands::List => {
                    rpc_call(&sock, "team.task.list", json!({ "team_name": team }))
                }
                TaskCommands::Update { id, status, result } => {
                    let mut params = json!({
                        "team_name": team, "task_id": id, "status": status,
                    });
                    if let Some(r) = result {
                        params["result"] = json!(r);
                    }
                    rpc_call(&sock, "team.task.update", params)
                }
                TaskCommands::Review { id, summary } => rpc_call(
                    &sock,
                    "team.task.review",
                    json!({
                        "team_name": team, "task_id": id,
                        "summary": summary.as_deref().unwrap_or(""),
                    }),
                ),
                TaskCommands::Reassign {
                    id,
                    agent: ref target,
                } => rpc_call(
                    &sock,
                    "team.task.reassign",
                    json!({
                        "team_name": team, "task_id": id, "assignee": target,
                    }),
                ),
                TaskCommands::Unblock { id } => rpc_call(
                    &sock,
                    "team.task.unblock",
                    json!({
                        "team_name": team, "task_id": id,
                    }),
                ),
                TaskCommands::FixAttempt { task_id } => {
                    match rpc_call(
                        &sock,
                        "team.task.fix_attempt",
                        json!({
                            "team_name": team, "task_id": task_id,
                        }),
                    ) {
                        Ok(ref v) => {
                            let result = &v["result"];
                            let count = result["fix_count"].as_u64().unwrap_or(0);
                            let budget = result["fix_budget"].as_u64().unwrap_or(0);
                            let blocked = result["blocked"].as_bool().unwrap_or(false);
                            if blocked {
                                eprintln!(
                                    "⚠️  Fix budget exhausted ({}/{}). Task auto-blocked.",
                                    count, budget
                                );
                            } else {
                                eprintln!("Fix attempt {}/{} recorded.", count, budget);
                            }
                            Ok(v.clone())
                        }
                        Err(e) => {
                            // If server doesn't support fix_attempt yet, warn but don't fail
                            eprintln!("Warning: fix_attempt RPC not available ({}). Continuing without budget tracking.", e);
                            Ok(
                                json!({"ok": true, "result": {"fix_count": 0, "fix_budget": 0, "blocked": false}}),
                            )
                        }
                    }
                }
                TaskCommands::Split { id, title, assign } => {
                    let mut params = json!({
                        "team_name": team, "task_id": id, "title": title,
                    });
                    if let Some(a) = assign {
                        params["assignee"] = json!(a);
                    }
                    rpc_call(&sock, "team.task.split", params)
                }
                TaskCommands::Clear => {
                    rpc_call(&sock, "team.task.clear", json!({ "team_name": team }))
                }
            }
        }
        // ── Legacy hyphenated aliases ────────────────────────────────
        Commands::TaskGet { id } => rpc_call(
            &sock,
            "team.task.get",
            json!({
                "team_name": team, "task_id": id,
            }),
        ),
        Commands::TaskStart { task_id } => rpc_call(
            &sock,
            "team.task.update",
            json!({
                "team_name": team, "task_id": task_id, "status": "in_progress",
            }),
        ),
        Commands::TaskDone { task_id, result } => rpc_call(
            &sock,
            "team.task.done",
            json!({
                "team_name": team, "task_id": task_id,
                "result": result.as_deref().unwrap_or("done"),
            }),
        ),
        Commands::TaskBlock { task_id, reason } => rpc_call(
            &sock,
            "team.task.block",
            json!({
                "team_name": team, "task_id": task_id,
                "blocked_reason": reason.as_deref().unwrap_or("blocked"),
            }),
        ),
        Commands::TaskList | Commands::Tasks => {
            rpc_call(&sock, "team.task.list", json!({ "team_name": team }))
        }
        Commands::TaskCreate2 {
            title,
            assign,
            desc,
            priority,
            accept,
            deps,
        } => {
            let mut params = json!({ "team_name": team, "title": title });
            if let Some(a) = assign {
                params["assignee"] = json!(a);
            }
            if let Some(d) = desc {
                params["description"] = json!(d);
            }
            if let Some(p) = priority {
                params["priority"] = json!(p);
            }
            if !accept.is_empty() {
                params["acceptance_criteria"] = json!(accept);
            }
            if !deps.is_empty() {
                params["depends_on"] = json!(deps);
            }
            rpc_call(&sock, "team.task.create", params)
        }
        Commands::TaskUpdate2 { id, status, result } => {
            let mut params = json!({
                "team_name": team, "task_id": id, "status": status,
            });
            if let Some(r) = result {
                params["result"] = json!(r);
            }
            rpc_call(&sock, "team.task.update", params)
        }
        Commands::TaskReview2 { id, summary } => rpc_call(
            &sock,
            "team.task.review",
            json!({
                "team_name": team, "task_id": id,
                "summary": summary.as_deref().unwrap_or(""),
            }),
        ),
        Commands::TaskReassign2 {
            id,
            agent: ref target,
        } => rpc_call(
            &sock,
            "team.task.reassign",
            json!({
                "team_name": team, "task_id": id, "assignee": target,
            }),
        ),
        Commands::TaskUnblock2 { id } => rpc_call(
            &sock,
            "team.task.unblock",
            json!({
                "team_name": team, "task_id": id,
            }),
        ),
        Commands::TaskClear2 => rpc_call(&sock, "team.task.clear", json!({ "team_name": team })),
        Commands::Peer(_) => unreachable!("peer commands exit before detect_socket()"),
        Commands::Runbook(_) => unreachable!("runbook commands exit before detect_socket()"),
        Commands::Doctor { .. } => unreachable!("doctor command exits before detect_socket()"),
        Commands::Status => {
            // Inject version info into the team.status response JSON
            let mut status = rpc_call(&sock, "team.status", json!({ "team_name": team }))
                .unwrap_or_else(|e| json!({"ok": false, "error": {"message": e}}));

            // Compact version check: "app_sha:cli_sha" + match flag
            let version_info = if let Ok(info) = rpc_call(&sock, "system.info", json!({})) {
                let app_sha = info["result"]["git_sha"].as_str().unwrap_or("?");
                let matched = if app_sha == "?" || app_sha.is_empty() {
                    Value::Null // app version unknown — can't determine match
                } else {
                    Value::Bool(app_sha == GIT_SHA)
                };
                json!({ "app": app_sha, "cli": GIT_SHA, "ok": matched })
            } else {
                json!({ "cli": GIT_SHA, "ok": null })
            };

            // Merge version into result (or top-level for error responses)
            if let Some(result) = status.get_mut("result") {
                result["version"] = version_info;
            } else {
                status["version"] = version_info;
            }
            Ok(status)
        }
        Commands::Inbox => rpc_call(
            &sock,
            "team.inbox",
            json!({
                "team_name": team, "agent_name": agent,
            }),
        ),
        Commands::Batch { commands } => {
            let payloads = match parse_batch_commands(&commands, &team) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            };
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
        Commands::Raw { payload } => {
            if let Err(e) = serde_json::from_str::<Value>(&payload) {
                eprintln!("Invalid JSON: {e}");
                process::exit(1);
            }
            let stream = UnixStream::connect(&sock).map_err(|e| format!("connect: {e}"));
            match stream {
                Ok(stream) => {
                    stream.set_read_timeout(Some(Duration::from_secs(2))).ok();
                    let mut writer = stream
                        .try_clone()
                        .map_err(|e| format!("clone: {e}"))
                        .unwrap_or_else(|e| {
                            eprintln!("Error: {e}");
                            process::exit(1);
                        });
                    if let Err(e) = writer
                        .write_all(payload.as_bytes())
                        .and_then(|_| writer.write_all(b"\n"))
                        .and_then(|_| writer.flush())
                    {
                        eprintln!("Error: write: {e}");
                        process::exit(1);
                    }
                    let mut reader = BufReader::new(&stream);
                    let mut line = String::new();
                    reader.read_line(&mut line).ok();
                    print!("{line}");
                    return;
                }
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            }
        }

        // ── Simple RPC wrappers ─────────────────────────────────
        Commands::Destroy => {
            eprintln!("Destroying team '{team}'...");
            cleanup_old_results(&team);
            // Also destroy headless team if it exists
            if let Some(daemon_sock) = detect_daemon_socket() {
                let _ = rpc_call_timeout(
                    &daemon_sock,
                    "headless.destroy_team",
                    json!({ "team_name": team }),
                    5,
                );
            }
            rpc_call(&sock, "team.destroy", json!({ "team_name": team }))
        }
        Commands::List => rpc_call(&sock, "team.list", json!({})),
        Commands::Read {
            agent: ref agent_name,
            lines,
        } => {
            // Check if agent is headless — route to daemon socket
            if let Some(daemon_sock) = detect_daemon_socket() {
                if let Some(agent_id) = is_headless_agent(&daemon_sock, &team, agent_name) {
                    print_result(rpc_call(
                        &daemon_sock,
                        "headless.read",
                        json!({
                            "agent_id": agent_id,
                            "lines": lines,
                        }),
                    ));
                    return;
                }
            }
            rpc_call(
                &sock,
                "team.read",
                json!({
                    "team_name": team, "agent_name": agent_name, "lines": lines,
                }),
            )
        }
        Commands::Collect {
            lines,
            headers,
            summary,
        } => {
            if headers || summary {
                rpc_call(&sock, "team.result.collect", json!({ "team_name": team }))
                    .map(|resp| compact_result_collect_response(resp, summary))
            } else {
                rpc_call(
                    &sock,
                    "team.collect",
                    json!({
                        "team_name": team, "lines": lines,
                    }),
                )
            }
        }
        Commands::Reports { headers, summary } => {
            rpc_call(&sock, "team.result.collect", json!({ "team_name": team })).map(|resp| {
                if headers || summary {
                    compact_result_collect_response(resp, summary)
                } else {
                    resp
                }
            })
        }
        Commands::ResultStatus => {
            rpc_call(&sock, "team.result.status", json!({ "team_name": team }))
        }
        Commands::ResultCollect { headers, summary } => {
            rpc_call(&sock, "team.result.collect", json!({ "team_name": team })).map(|resp| {
                if headers || summary {
                    compact_result_collect_response(resp, summary)
                } else {
                    resp
                }
            })
        }
        // ── Orchestration commands ──────────────────────────────
        Commands::Create {
            count,
            claude_leader,
            model,
            leader_model,
            kiro,
            codex,
            gemini,
            adopt,
            preset,
            roles,
            headless,
            resume_session,
        } => {
            if headless {
                run_create_headless(&sock, &team, count.unwrap_or(2), &model, roles.as_deref());
            } else {
                run_create(
                    &sock,
                    &team,
                    count.unwrap_or(2),
                    claude_leader,
                    &model,
                    leader_model.as_deref(),
                    &kiro,
                    &codex,
                    &gemini,
                    adopt,
                    preset.as_deref(),
                    roles.as_deref(),
                    resume_session,
                );
            }
            return;
        }
        Commands::Add {
            agent_type,
            name,
            model,
            cli,
        } => {
            let agent_name = name.unwrap_or_else(|| agent_type.clone());

            // Try headless path first
            if let Some(daemon_sock) = detect_daemon_socket() {
                // Check if the team exists as a headless team
                if let Ok(resp) = rpc_call(&daemon_sock, "headless.list_teams", json!({})) {
                    let is_headless = resp["result"]
                        .as_array()
                        .map(|teams| teams.iter().any(|t| t["name"].as_str() == Some(&team)))
                        .unwrap_or(false);
                    if is_headless {
                        run_add_headless(
                            &sock,
                            &daemon_sock,
                            &team,
                            &agent_name,
                            &agent_type,
                            &model,
                            &cli,
                        );
                        return;
                    }
                }
            }

            // GUI team: route to team.add_agent RPC
            let gui_team = resolve_workspace_team_name().unwrap_or_else(|_| team.clone());
            run_add_gui(&sock, &gui_team, &agent_type, &agent_name, &model, &cli);
            return;
        }
        Commands::Attach {
            agent_type,
            name,
            model,
            cli,
        } => {
            let agent_name = name.unwrap_or_else(|| agent_type.clone());
            if let Err(e) = validate_agent_name(&agent_name) {
                eprintln!("Error: {}", e);
                process::exit(1);
            }
            run_attach(&sock, &agent_type, &agent_name, &model, &cli);
            return;
        }
        Commands::Detach { agent_name } => {
            if let Err(e) = validate_agent_name(&agent_name) {
                eprintln!("Error: {}", e);
                process::exit(1);
            }
            run_detach(&sock, &agent_name);
            return;
        }
        Commands::Remove { agent_name, force } => {
            if let Err(e) = validate_agent_name(&agent_name) {
                eprintln!("Error: {}", e);
                process::exit(1);
            }
            let gui_team = resolve_workspace_team_name().unwrap_or_else(|_| team.clone());
            run_remove_gui(&sock, &gui_team, &agent_name, force);
            return;
        }
        Commands::Preset(sub) => match sub {
            PresetCommands::List => {
                match rpc_call(&sock, "team.preset.list", json!({})) {
                    Ok(resp) => {
                        if let Some(presets) = resp["result"]["presets"].as_array() {
                            println!(
                                "{:<18} {:<10} {:<24} {:<8} {}",
                                "ID", "Kind", "Name", "Agents", "Description"
                            );
                            println!("{}", "-".repeat(92));
                            for p in presets {
                                let id = p["id"].as_str().unwrap_or("");
                                let kind = p["type"].as_str().unwrap_or("smart");
                                let name = p["name"].as_str().unwrap_or("");
                                let desc = p["description"].as_str().unwrap_or("");
                                let agent_count =
                                    p["agents"].as_array().map(|a| a.len()).unwrap_or(0);
                                println!(
                                    "{:<18} {:<10} {:<24} {:<8} {}",
                                    id, kind, name, agent_count, desc
                                );
                            }
                        } else {
                            println!("{}", pretty(&resp));
                        }
                    }
                    Err(e) => {
                        eprintln!("Error: {e}");
                        process::exit(1);
                    }
                }
                return;
            }
        },
        Commands::Stop { agent, all } => {
            if all || agent.is_none() {
                // Interrupt all agents in the team
                print_result(rpc_call(
                    &sock,
                    "team.interrupt_all",
                    json!({
                        "team_name": team,
                    }),
                ));
            } else if let Some(ref target) = agent {
                // Interrupt a specific agent
                print_result(rpc_call(
                    &sock,
                    "team.interrupt",
                    json!({
                        "team_name": team, "agent_name": target,
                    }),
                ));
            }
            return;
        }
        Commands::Restart {
            agent: ref target,
            hard,
        } => {
            if hard {
                eprintln!(
                    "hard restart: closing pane and respawning. scrollback will be lost; panelId changes."
                );
            } else {
                eprintln!(
                    "soft restart: types the launch command after Ctrl-C. Stuck CLIs are NOT recovered. Use --hard for true panel respawn."
                );
            }
            let result = rpc_call(
                &sock,
                "team.restart",
                json!({
                    "team_name": team,
                    "agent_name": target,
                    "mode": if hard { "hard" } else { "soft" },
                }),
            );
            if let Ok(ref r) = result {
                if r["ok"].as_bool().unwrap_or(false) {
                    eprintln!("restart issued for {target}");
                }
            }
            print_result(result);
            return;
        }
        Commands::Send {
            agent: ref target,
            text,
            no_report,
        } => {
            let text = append_report_suffix(&text, no_report);
            // Check if agent is headless — route to daemon socket
            if let Some(daemon_sock) = detect_daemon_socket() {
                if let Some(agent_id) = is_headless_agent(&daemon_sock, &team, target) {
                    print_result(rpc_call(
                        &daemon_sock,
                        "headless.send",
                        json!({
                            "agent_id": agent_id,
                            "text": format!("{text}\n"),
                        }),
                    ));
                    return;
                }
            }
            let send_result = rpc_call(
                &sock,
                "team.send",
                json!({
                    "team_name": team, "agent_name": target,
                    "text": format!("{text}\n"),
                }),
            );
            // Send Return key via team.send_key (reliable sendNamedKey path)
            if let Ok(ref r) = send_result {
                let text_delivered = r["result"]["text_delivered"].as_bool().unwrap_or(false);
                if !text_delivered {
                    eprintln!("text.delivered.false reason=team.send_ack agent={target}");
                }
                let _ =
                    send_return_key_with_retry(&sock, &team, target, text_delivered, "team.send");
            }
            print_result(send_result);
            return;
        }
        Commands::Broadcast { text, no_report } => {
            let text = if no_report {
                text
            } else {
                format!("{text}{BROADCAST_SUFFIX}")
            };
            print_result(rpc_call(
                &sock,
                "team.broadcast",
                json!({
                    "team_name": team, "text": format!("{text}\n"),
                }),
            ));
            return;
        }
        Commands::Delegate {
            agent: ref target,
            text,
            title,
            priority,
            accept,
            deps,
            desc,
            no_report,
            context,
            auto_fix_budget,
            autonomous,
        } => {
            // Auto-detect comma-separated agents and route to parallel fan-out
            if target.contains(',') {
                run_fan_out(
                    &sock,
                    &team,
                    &text,
                    title,
                    priority,
                    no_report,
                    &Some(target.to_string()),
                    context.as_deref(),
                    auto_fix_budget,
                );
            } else if autonomous {
                run_delegate_autonomous(
                    &sock,
                    &team,
                    target,
                    &text,
                    title,
                    priority,
                    no_report,
                    context.as_deref(),
                    auto_fix_budget,
                );
            } else {
                run_delegate(
                    &sock,
                    &team,
                    target,
                    &text,
                    title,
                    priority,
                    &accept,
                    &deps,
                    desc,
                    no_report,
                    context.as_deref(),
                    auto_fix_budget,
                );
            }
            return;
        }
        Commands::FanOut {
            text,
            title,
            priority,
            no_report,
            agents,
            context,
            auto_fix_budget,
        } => {
            run_fan_out(
                &sock,
                &team,
                &text,
                title,
                priority,
                no_report,
                &agents,
                context.as_deref(),
                auto_fix_budget,
            );
            return;
        }
        Commands::Wait {
            timeout,
            interval,
            mode,
            task,
            tasks,
            agents,
        } => {
            let filter = parse_cli_flag(&agents);
            let task_ids: Option<std::collections::HashSet<String>> = tasks.map(|t| {
                t.split(',')
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect()
            });
            run_wait(
                &sock,
                &team,
                timeout,
                interval,
                &mode,
                task.as_deref(),
                &filter,
                task_ids.as_ref(),
            );
            return;
        }
        Commands::Watch {
            on_event,
            timeout,
            leader_session,
        } => {
            run_watch(
                &sock,
                timeout,
                on_event.as_deref(),
                leader_session.as_deref(),
            );
            return;
        }
        Commands::XmbBridge {
            timeout,
            leader_session,
        } => {
            let bridge_sock = detect_daemon_socket().unwrap_or_else(|| sock.clone());
            run_xmb_bridge(&bridge_sock, timeout, leader_session.as_deref());
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
        Commands::Warmup {
            agent: ref target,
            timeout,
        } => {
            run_warmup(&sock, &team, target.as_deref(), timeout);
            return;
        }
        Commands::Research {
            topic,
            agents,
            budget,
            timeout,
            depth,
            web,
            focus,
            no_discuss,
        } => {
            run_autonomous(
                &sock,
                &team,
                "research",
                &topic,
                agents,
                budget,
                timeout,
                &depth,
                web,
                focus.as_deref(),
                no_discuss,
                None,
                None,
                None,
            );
            return;
        }
        Commands::Solve {
            problem,
            agents,
            budget,
            timeout,
            verify,
            target,
            no_discuss,
        } => {
            run_autonomous(
                &sock,
                &team,
                "solve",
                &problem,
                agents,
                budget,
                timeout,
                "deep",
                false,
                None,
                no_discuss,
                verify.as_deref(),
                target.as_deref(),
                None,
            );
            return;
        }
        Commands::Consensus {
            question,
            agents,
            budget,
            timeout,
            perspectives,
            no_discuss,
        } => {
            run_autonomous(
                &sock,
                &team,
                "consensus",
                &question,
                agents,
                budget,
                timeout,
                "deep",
                false,
                None,
                no_discuss,
                None,
                None,
                perspectives.as_deref(),
            );
            return;
        }
        Commands::Swarm {
            goal,
            agents,
            budget,
            timeout,
            seed,
            no_discuss,
        } => {
            run_autonomous(
                &sock,
                &team,
                "swarm",
                &goal,
                agents,
                budget,
                timeout,
                "deep",
                false,
                None,
                no_discuss,
                None,
                None,
                seed.as_deref(),
            );
            return;
        }
        Commands::Brief {
            agent: ref target,
            lines,
        } => {
            run_brief(&sock, &team, target, lines);
            return;
        }
        Commands::Reply { text, from } => {
            let sender = from.unwrap_or_else(|| agent.clone());
            let content = text.join(" ");
            // Write the canonical task result when possible, plus the legacy
            // per-agent alias for compatibility with older readers.
            let reply_task_id = reply_target_task_id(&sock, &team, &sender);
            let alias_result_path =
                write_result_file(&team, &format!("{sender}-reply.md"), &content).ok();
            let task_result_path = reply_task_id
                .as_deref()
                .and_then(|tid| write_result_file(&team, &format!("{tid}.md"), &content).ok());
            let result_path = task_result_path.as_ref().or(alias_result_path.as_ref());
            let summary = truncate_summary(&content, 1500);
            let mut msg_params = json!({
                "team_name": team, "from": sender, "content": summary,
                "to": "leader", "type": "report",
            });
            if let Some(path) = result_path {
                msg_params["result_path"] = json!(path.to_string_lossy());
            }
            print_result(rpc_call(&sock, "team.message.post", msg_params));
            // Auto-submit report for wait detection (with result_path)
            let mut report_params = json!({
                "team_name": team, "agent_name": sender, "content": summary,
            });
            if let Some(path) = result_path {
                report_params["result_path"] = json!(path.to_string_lossy());
            }
            // team.report — retry once on failure (wait hangs permanently if this is lost)
            let report_result = rpc_call(&sock, "team.report", report_params.clone());
            if let Err(ref e) = report_result {
                eprintln!("  Warning: team.report failed: {e}, retrying...");
                let _ = rpc_call(&sock, "team.report", report_params);
            }
            // Auto-complete the active task for this agent.
            // Use team.task.list (data command, no MainActor) instead of team.status
            // (UI command, MainActor) to avoid timeout when main thread is busy —
            // a timeout here silently skips task completion, causing the leader's
            // `wait` to hang indefinitely.
            if let Some(tid) = reply_task_id {
                let mut update = json!({
                    "team_name": &team, "task_id": tid,
                    "status": "completed", "result": &summary,
                });
                if let Some(path) = result_path {
                    update["result_path"] = json!(path.to_string_lossy());
                }
                // task.update — retry once on failure (task stays in_progress forever if lost)
                let update_result = rpc_call(&sock, "team.task.update", update.clone());
                if let Err(ref e) = update_result {
                    eprintln!("  Warning: task.update failed: {e}, retrying...");
                    let _ = rpc_call(&sock, "team.task.update", update);
                }
            } else {
                eprintln!("  Warning: no active task found for {sender}; wrote reply alias only");
            }
            return;
        }
    };

    print_result(result);
}

fn print_result(result: Result<Value, String>) {
    match result {
        Ok(resp) => println!("{}", pretty(&resp)),
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
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
    if dir.is_dir() {
        Some(dir)
    } else {
        None
    }
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
            if !name.ends_with(".jsonl") {
                continue;
            }
            let id = name.trim_end_matches(".jsonl");
            // Quick UUID format check (8-4-4-4-12)
            if id.len() != 36 || id.chars().filter(|c| *c == '-').count() != 4 {
                continue;
            }

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
        let texts: Vec<&str> = arr
            .iter()
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
            if val["type"].as_str() != Some("user") {
                continue;
            }
            let text = extract_text_from_entry(&val);
            if text.contains("<system-reminder>")
                || text.contains("<command-name>")
                || text.contains("<local-command")
            {
                continue;
            }
            let trimmed = text.trim();
            if trimmed.is_empty() {
                continue;
            }
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
    let tail_offset = if file_len > 32768 {
        file_len - 32768
    } else {
        0
    };
    let _ = file.seek(SeekFrom::Start(tail_offset));
    let mut tail_buf = Vec::new();
    let _ = file.read_to_end(&mut tail_buf);
    let tail_text = String::from_utf8_lossy(&tail_buf);

    let mut last_message = String::new();
    for line in tail_text.lines().rev() {
        if let Ok(val) = serde_json::from_str::<Value>(line) {
            if val["type"].as_str() != Some("assistant") {
                continue;
            }
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
    if secs < 60 {
        return "just now".to_string();
    }
    if secs < 3600 {
        return format!("{}m ago", secs / 60);
    }
    if secs < 86400 {
        return format!("{}h ago", secs / 3600);
    }
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
    sock: &PathBuf,
    team: &str,
    count: u32,
    claude_leader: bool,
    model: &str,
    leader_model: Option<&str>,
    kiro: &Option<String>,
    codex: &Option<String>,
    gemini: &Option<String>,
    adopt: bool,
    preset: Option<&str>,
    roles: Option<&str>,
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
    let mut leader_mode = if adopt {
        "adopted".to_string()
    } else if claude_leader || resume_session_id.is_some() {
        "claude".to_string()
    } else {
        "repl".to_string()
    };
    let leader_model = leader_model.unwrap_or(model);
    let kiro_agents = parse_cli_flag(kiro);
    let codex_agents = parse_cli_flag(codex);
    let gemini_agents = parse_cli_flag(gemini);
    let mut preset_name: Option<String> = None;
    let mut workflow_task_templates: Vec<String> = Vec::new();
    let mut workflow_review_checkpoints: Vec<String> = Vec::new();

    // Resolve agents from preset or roles via RPC, or build from defaults
    let agents: Vec<serde_json::Value> = if let Some(preset_id) = preset {
        eprintln!("Resolving preset '{preset_id}'...");
        match rpc_call_timeout(
            sock,
            "team.preset.resolve",
            json!({
                "preset_id": preset_id,
                "model": model,
            }),
            3,
        ) {
            Ok(resp) if resp["ok"].as_bool().unwrap_or(false) => {
                let result = &resp["result"];
                preset_name = result["preset_name"].as_str().map(str::to_string);
                if !adopt && !claude_leader && resume_session_id.is_none() {
                    if let Some(resolved_leader) = result["leader_mode"].as_str() {
                        leader_mode = resolved_leader.to_string();
                    }
                }
                workflow_task_templates = result["task_templates"]
                    .as_array()
                    .map(|items| {
                        items
                            .iter()
                            .filter_map(|v| v.as_str().map(str::to_string))
                            .collect()
                    })
                    .unwrap_or_default();
                workflow_review_checkpoints = result["review_checkpoints"]
                    .as_array()
                    .map(|items| {
                        items
                            .iter()
                            .filter_map(|v| v.as_str().map(str::to_string))
                            .collect()
                    })
                    .unwrap_or_default();
                result["agents"].as_array().cloned().unwrap_or_default()
            }
            Ok(resp) => {
                eprintln!(
                    "Error: preset resolve failed: {}",
                    resp["error"]["message"].as_str().unwrap_or("unknown")
                );
                process::exit(1);
            }
            Err(e) => {
                eprintln!(
                    "Error: team.preset.resolve RPC failed (app may not support presets yet): {e}"
                );
                process::exit(1);
            }
        }
    } else if let Some(roles_str) = roles {
        eprintln!("Resolving roles '{roles_str}'...");
        // Split comma-separated roles into a JSON array (Swift expects [String], not String)
        let roles_vec: Vec<&str> = roles_str
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();
        match rpc_call_timeout(
            sock,
            "team.preset.resolve",
            json!({
                "roles": roles_vec,
                "model": model,
            }),
            3,
        ) {
            Ok(resp) if resp["ok"].as_bool().unwrap_or(false) => resp["result"]["agents"]
                .as_array()
                .cloned()
                .unwrap_or_default(),
            Ok(resp) => {
                eprintln!(
                    "Error: roles resolve failed: {}",
                    resp["error"]["message"].as_str().unwrap_or("unknown")
                );
                process::exit(1);
            }
            Err(e) => {
                eprintln!(
                    "Error: team.preset.resolve RPC failed (app may not support roles yet): {e}"
                );
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
        "runbook_init_prompt": true,
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
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };

    println!("{}", pretty(&r));
    println!();
    println!("Commands:");
    println!("  tm-agent send <agent> 'your message'");
    println!("  tm-agent broadcast 'message to all'");
    println!("  tm-agent status");
    println!("  tm-agent destroy");

    if r["ok"].as_bool().unwrap_or(false) {
        if !workflow_task_templates.is_empty() {
            let workflow_label = preset_name.as_deref().or(preset).unwrap_or("workflow");
            let checkpoint_note = if workflow_review_checkpoints.is_empty() {
                String::new()
            } else {
                format!(
                    "\nReview checkpoints: {}",
                    workflow_review_checkpoints.join(", ")
                )
            };
            eprintln!("\nCreating workflow task templates for '{workflow_label}'...");
            for (i, title) in workflow_task_templates.iter().enumerate() {
                let assignee = agents
                    .get(i % agents.len())
                    .and_then(|a| a["name"].as_str())
                    .unwrap_or("");
                let mut params = json!({
                    "team_name": team,
                    "title": title,
                    "description": format!(
                        "Created from workflow preset: {}{}",
                        workflow_label,
                        checkpoint_note
                    ),
                    "priority": 2,
                    "created_by": format!("workflow:{workflow_label}"),
                });
                if !assignee.is_empty() {
                    params["assignee"] = json!(assignee);
                }
                match rpc_call_timeout(sock, "team.task.create", params, 2) {
                    Ok(resp) if resp["ok"].as_bool().unwrap_or(false) => {
                        let suffix = if assignee.is_empty() {
                            String::new()
                        } else {
                            format!(" -> {assignee}")
                        };
                        eprintln!("  \u{2713} {title}{suffix}");
                    }
                    Ok(resp) => {
                        eprintln!(
                            "  \u{2717} {title}: {}",
                            resp["error"]["message"]
                                .as_str()
                                .unwrap_or("task create failed")
                        );
                    }
                    Err(e) => {
                        eprintln!("  \u{2717} {title}: {e}");
                    }
                }
            }
        }

        let non_kiro: Vec<&Value> = agents
            .iter()
            .filter(|a| a["cli"].as_str().unwrap_or("claude") != "kiro")
            .collect();
        if !non_kiro.is_empty() {
            // Poll until all agent panels are spawned (max 60 × 100ms = 6s)
            eprintln!("\nWaiting for agent panels to spawn...");
            let expected = non_kiro.len();
            for i in 0..60 {
                if let Ok(st) =
                    rpc_call_timeout(sock, "team.status", json!({ "team_name": team }), 2)
                {
                    if let Some(agents_arr) = st["result"]["agents"].as_array() {
                        let with_panels = agents_arr
                            .iter()
                            .filter(|a| {
                                a["panel_id"]
                                    .as_str()
                                    .map(|s| !s.is_empty())
                                    .unwrap_or(false)
                            })
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
                let role = a["agent_type"].as_str().unwrap_or(name);
                let init_text = agent_init_prompt(name, role, team, &workdir, &sock.to_string_lossy());
                match rpc_call_timeout(
                    sock,
                    "team.send",
                    json!({
                        "team_name": team, "agent_name": name,
                        "text": format!("{init_text}\n"),
                    }),
                    3,
                ) {
                    Ok(ref r) => {
                        // team.send pastes text with withReturn=false; the trailing "\n"
                        // is stripped by sendTextToPanel, so the Enter must be delivered
                        // separately via team.send_key — same follow-up as `tm-agent send`
                        // and `tm-agent delegate`. Without this the init prompt sits
                        // unsubmitted in the freshly spawned agent pane (enter-swallow).
                        let text_delivered =
                            r["result"]["text_delivered"].as_bool().unwrap_or(false);
                        let _ = send_return_key_with_retry(
                            sock, team, name, text_delivered, "team.create.init",
                        );
                        eprintln!("  \u{2713} {name}: init prompt sent");
                    }
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

/// Validate agent name against the whitelist regex `^[a-zA-Z0-9_-]{1,32}$`.
///
/// Used by `attach` and `detach` subcommands to prevent env var injection and
/// filename escape via agent_name. Returns `Err(message)` if invalid.
/// Implemented as a manual char scan (no `regex` crate dep).
fn validate_agent_name(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("agent name must not be empty".to_string());
    }
    if name.len() > 32 {
        return Err(format!(
            "agent name '{}' is too long ({}>32 chars)",
            name,
            name.len()
        ));
    }
    for ch in name.chars() {
        let ok = ch.is_ascii_alphanumeric() || ch == '_' || ch == '-';
        if !ok {
            return Err(format!(
                "agent name '{}' contains invalid character '{}'; only [a-zA-Z0-9_-] allowed",
                name, ch
            ));
        }
    }
    Ok(())
}

/// Resolve the team name for workspace-local attach/detach operations.
///
/// Priority:
/// 1. `TERMMESH_TEAM` env var (explicit override)
/// 2. `ws-<first8hex>` derived from `TERMMESH_WORKSPACE_ID`
///
/// Returns `Err` if neither is available.
#[allow(dead_code)] // used by run_attach/run_detach (t8/t9)
fn resolve_workspace_team_name() -> Result<String, String> {
    if let Ok(explicit) = env::var("TERMMESH_TEAM") {
        if !explicit.is_empty() {
            return Ok(explicit);
        }
    }
    let ws = env::var("TERMMESH_WORKSPACE_ID").map_err(|_| {
        "TERMMESH_WORKSPACE_ID env var not set. Not running inside a term-mesh workspace?"
            .to_string()
    })?;
    if ws.is_empty() {
        return Err("TERMMESH_WORKSPACE_ID is empty".to_string());
    }
    // Strip dashes, take first 8 hex chars, lowercase
    let hex: String = ws
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .take(8)
        .collect::<String>()
        .to_lowercase();
    if hex.len() < 8 {
        return Err(format!(
            "TERMMESH_WORKSPACE_ID '{}' does not contain 8 hex chars",
            ws
        ));
    }
    Ok(format!("ws-{}", hex))
}

/// Validate that the caller is running inside a term-mesh pane.
/// Returns the tuple of env vars needed for workspace-local attach/detach.
fn require_termmesh_context() -> Result<(String, String, Option<String>), String> {
    let workspace_id = env::var("TERMMESH_WORKSPACE_ID").map_err(|_| {
        "Not running inside a term-mesh workspace. Use tm-agent create instead.".to_string()
    })?;
    if workspace_id.is_empty() {
        return Err(
            "Not running inside a term-mesh workspace. Use tm-agent create instead.".to_string(),
        );
    }
    let panel_id = env::var("TERMMESH_PANEL_ID").map_err(|_| {
        "TERMMESH_PANEL_ID not set. Caller pane cannot be identified for attach.".to_string()
    })?;
    if panel_id.is_empty() {
        return Err(
            "TERMMESH_PANEL_ID is empty. Caller pane cannot be identified for attach.".to_string(),
        );
    }
    let window_id = env::var("TERMMESH_WINDOW_ID")
        .ok()
        .filter(|s| !s.is_empty());
    Ok((workspace_id, panel_id, window_id))
}

/// Attach a single agent pane to the caller's current workspace via `team.attach` RPC.
fn run_attach(sock: &PathBuf, agent_type: &str, agent_name: &str, model: &str, cli: &str) {
    let (workspace_id, panel_id, window_id) = match require_termmesh_context() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };
    let team_name = match resolve_workspace_team_name() {
        Ok(name) => name,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };

    eprintln!(
        "Attaching agent '{}' (type={}, cli={}, model={}) to team '{}' in current workspace...",
        agent_name, agent_type, cli, model, team_name
    );

    let mut params = json!({
        "agent_type": agent_type,
        "agent_name": agent_name,
        "agent_cli": cli,
        "agent_model": model,
        "workspace_id": workspace_id,
        "surface_id": panel_id,
    });
    if let Some(wid) = window_id {
        params["window_id"] = json!(wid);
    }

    let resp = match rpc_call_timeout(sock, "team.attach", params, 10) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };

    if resp["ok"].as_bool().unwrap_or(false) {
        println!("{}", pretty(&resp));
        if let Some(result) = resp["result"].as_object() {
            eprintln!();
            eprintln!(
                "  \u{2713} agent '{}' attached ({} total in team '{}')",
                result
                    .get("agent_name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(agent_name),
                result
                    .get("agent_count")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0),
                result
                    .get("team_name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&team_name),
            );
        }
    } else {
        let code = resp["error"]["code"].as_str().unwrap_or("unknown");
        let msg = resp["error"]["message"].as_str().unwrap_or("attach failed");
        eprintln!("Error [{}]: {}", code, msg);
        process::exit(1);
    }
}

/// Detach a single agent from the caller's workspace-local team via `team.detach` RPC.
fn run_detach(sock: &PathBuf, agent_name: &str) {
    let (workspace_id, _panel_id, window_id) = match require_termmesh_context() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };
    let team_name = match resolve_workspace_team_name() {
        Ok(name) => name,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };

    eprintln!(
        "Detaching agent '{}' from team '{}'...",
        agent_name, team_name
    );

    let mut params = json!({
        "agent_name": agent_name,
        "team_name": team_name,
        "workspace_id": workspace_id,
    });
    if let Some(wid) = window_id {
        params["window_id"] = json!(wid);
    }

    let resp = match rpc_call_timeout(sock, "team.detach", params, 10) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };

    if resp["ok"].as_bool().unwrap_or(false) {
        println!("{}", pretty(&resp));
        if let Some(result) = resp["result"].as_object() {
            let remaining = result
                .get("remaining_agents")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            let team_destroyed = result
                .get("team_destroyed")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            eprintln!();
            if team_destroyed {
                eprintln!(
                    "  \u{2713} agent '{}' detached. Team '{}' destroyed (leader pane preserved).",
                    agent_name, team_name
                );
            } else {
                eprintln!(
                    "  \u{2713} agent '{}' detached ({} remaining)",
                    agent_name, remaining
                );
            }
        }
    } else {
        let code = resp["error"]["code"].as_str().unwrap_or("unknown");
        let msg = resp["error"]["message"].as_str().unwrap_or("detach failed");
        eprintln!("Error [{}]: {}", code, msg);
        process::exit(1);
    }
}

/// Add a single agent pane to a named GUI team via `team.add_agent` RPC.
///
/// Team-name–scoped: does not require TERMMESH_WORKSPACE_ID or PANEL_ID.
fn run_add_gui(
    sock: &PathBuf,
    team_name: &str,
    agent_type: &str,
    agent_name: &str,
    model: &str,
    cli: &str,
) {
    eprintln!(
        "Adding agent '{}' (type={}, cli={}, model={}) to GUI team '{}'...",
        agent_name, agent_type, cli, model, team_name
    );

    let params = json!({
        "team_name": team_name,
        "agent_type": agent_type,
        "name": agent_name,
        "model": model,
        "cli": cli,
    });

    let resp = match rpc_call_timeout(sock, "team.add_agent", params, 10) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };

    if resp["ok"].as_bool().unwrap_or(false) {
        println!("{}", pretty(&resp));
        if let Some(result) = resp["result"].as_object() {
            eprintln!();
            eprintln!(
                "  \u{2713} agent '{}' added ({} total in team '{}')",
                result
                    .get("agent_name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(agent_name),
                result
                    .get("agent_count")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0),
                result
                    .get("team_name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(team_name),
            );
        }
    } else {
        let code = resp["error"]["code"].as_str().unwrap_or("unknown");
        let msg = resp["error"]["message"]
            .as_str()
            .unwrap_or("add_agent failed");
        let hint = match code {
            "duplicate_name" => format!(
                "\nHint: An agent named '{}' already exists in team '{}'. Use --name to pick a unique name.",
                agent_name, team_name
            ),
            "team_not_found" => format!(
                "\nHint: Team '{}' not found. Run 'tm-agent status' to see active teams.",
                team_name
            ),
            "workspace_gone" => "\nHint: The team's workspace is no longer open. Recreate the team with 'tm-agent create'.".to_string(),
            "cli_not_found" => "\nHint: CLI executable not found — check Settings → CLI Paths or the cliPath.<cli> UserDefaults key.".to_string(),
            "pane_creation_failed" => "\nHint: Pane creation failed — check term-mesh logs at /tmp/term-mesh-debug.log.".to_string(),
            _ => String::new(),
        };
        eprintln!("Error [{}]: {}{}", code, msg, hint);
        process::exit(1);
    }
}

/// Remove an agent from a named GUI team via `team.detach` RPC (team-name–scoped).
///
/// Unlike `run_detach` (workspace-local), this variant looks up the team by name
/// and does not require TERMMESH_WORKSPACE_ID or PANEL_ID.
fn run_remove_gui(sock: &PathBuf, team_name: &str, agent_name: &str, force: bool) {
    eprintln!(
        "Removing agent '{}' from GUI team '{}'...",
        agent_name, team_name
    );

    let params = json!({
        "team_name": team_name,
        "agent_name": agent_name,
        "force": force,
    });

    let resp = match rpc_call_timeout(sock, "team.detach", params, 10) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };

    if resp["ok"].as_bool().unwrap_or(false) {
        println!("{}", pretty(&resp));
        if let Some(result) = resp["result"].as_object() {
            let remaining = result
                .get("remaining_agents")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            let team_destroyed = result
                .get("team_destroyed")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            eprintln!();
            if team_destroyed {
                eprintln!(
                    "  \u{2713} agent '{}' removed. Team '{}' destroyed (leader pane preserved).",
                    agent_name, team_name
                );
            } else {
                eprintln!(
                    "  \u{2713} agent '{}' removed ({} remaining in team '{}')",
                    agent_name, remaining, team_name
                );
            }
        }
    } else {
        let code = resp["error"]["code"].as_str().unwrap_or("unknown");
        let msg = resp["error"]["message"]
            .as_str()
            .unwrap_or("remove failed");
        let hint = match code {
            "agent_busy" => "\nHint: Agent has an active task — pass --force to close anyway, or finish/block the task first.".to_string(),
            _ => String::new(),
        };
        eprintln!("Error [{}]: {}{}", code, msg, hint);
        process::exit(1);
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
    let dir = env::var("TMPDIR")
        .ok()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    let path = dir.join("term-meshd.sock");
    if is_socket_alive(&path) {
        Some(path)
    } else {
        None
    }
}

fn discover_term_mesh_sockets() -> Vec<Value> {
    let patterns = [
        "/tmp/term-mesh-debug-*.sock",
        "/tmp/term-mesh-debug.sock",
        "/tmp/term-mesh*.sock",
        "/tmp/cmux.sock",
    ];
    let mut sockets = Vec::new();
    let mut seen = std::collections::BTreeSet::new();

    for pattern in patterns {
        if let Ok(paths) = glob::glob(pattern) {
            for path in paths.flatten() {
                let display = path.to_string_lossy().to_string();
                if !seen.insert(display.clone()) {
                    continue;
                }
                sockets.push(json!({
                    "path": display,
                    "alive": is_socket_alive(&path),
                }));
            }
        }
    }

    sockets
}

fn cmd_doctor(verbose: bool, json_output: bool) {
    let app_socket = detect_socket();
    let daemon_socket = detect_daemon_socket();
    let sockets = discover_term_mesh_sockets();
    let team = env::var("TERMMESH_TEAM").unwrap_or_else(|_| "live-team".into());
    let agent = env::var("TERMMESH_AGENT_NAME").unwrap_or_else(|_| "anonymous".into());

    let app_status = app_socket
        .as_ref()
        .and_then(|sock| rpc_call(sock, "team.status", json!({ "team_name": &team })).ok());
    let daemon_status = daemon_socket
        .as_ref()
        .and_then(|sock| rpc_call(sock, "daemon.status", json!({})).ok());

    let result = json!({
        "ok": app_socket.is_some() || daemon_socket.is_some(),
        "team": team,
        "agent": agent,
        "app_socket": app_socket.as_ref().map(|p| p.to_string_lossy().to_string()),
        "daemon_socket": daemon_socket.as_ref().map(|p| p.to_string_lossy().to_string()),
        "app_status": app_status,
        "daemon_status": daemon_status,
        "sockets": if verbose { Value::Array(sockets.clone()) } else { json!(sockets.iter().filter(|s| s["alive"].as_bool().unwrap_or(false)).count()) },
    });

    if json_output {
        println!("{}", pretty(&result));
        return;
    }

    println!("tm-agent doctor");
    println!("team: {}", result["team"].as_str().unwrap_or("unknown"));
    println!("agent: {}", result["agent"].as_str().unwrap_or("unknown"));
    println!(
        "app socket: {}",
        result["app_socket"].as_str().unwrap_or("not found")
    );
    println!(
        "daemon socket: {}",
        result["daemon_socket"].as_str().unwrap_or("not found")
    );
    if verbose {
        println!("sockets:");
        for socket in sockets {
            println!(
                "  {} {}",
                if socket["alive"].as_bool().unwrap_or(false) {
                    "alive"
                } else {
                    "dead"
                },
                socket["path"].as_str().unwrap_or("")
            );
        }
    } else {
        println!("alive sockets: {}", result["sockets"].as_u64().unwrap_or(0));
    }
    println!(
        "status: {}",
        if result["ok"].as_bool().unwrap_or(false) {
            "ok"
        } else {
            "no live sockets found"
        }
    );
}

/// Check if an agent is headless by querying the daemon's headless.resolve RPC.
fn is_headless_agent(daemon_sock: &PathBuf, team: &str, agent_name: &str) -> Option<String> {
    if let Ok(resp) = rpc_call(
        daemon_sock,
        "headless.resolve",
        json!({
            "team_name": team,
            "agent_name": agent_name,
        }),
    ) {
        if resp["result"]["headless"].as_bool().unwrap_or(false) {
            return resp["result"]["agent_id"].as_str().map(String::from);
        }
    }
    None
}

fn run_create_headless(
    app_sock: &PathBuf,
    team: &str,
    count: u32,
    model: &str,
    roles: Option<&str>,
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
        roles_str
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .enumerate()
            .map(|(_i, name)| json!({ "name": name, "agent_type": name, "cli": "claude", "model": model }))
            .collect()
    } else {
        (0..count as usize)
            .map(|i| {
                let name = if i < DEFAULT_AGENT_NAMES.len() {
                    DEFAULT_AGENT_NAMES[i].to_string()
                } else {
                    format!("agent-{i}")
                };
                json!({ "name": name, "agent_type": name, "cli": "claude", "model": model })
            })
            .collect()
    };

    let workdir = env::current_dir()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| ".".to_string());

    // Destroy existing headless team first
    let _ = rpc_call_timeout(
        &daemon_sock,
        "headless.destroy_team",
        json!({ "team_name": team }),
        3,
    );

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
                let role = spec["agent_type"].as_str().unwrap_or(name);
                let agent_id = format!("{name}@{team}");
                let init_text = agent_init_prompt(name, role, team, &workdir, &app_sock_str);
                match rpc_call_timeout(
                    &daemon_sock,
                    "headless.send",
                    json!({
                        "agent_id": agent_id,
                        "text": init_text,
                    }),
                    5,
                ) {
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
    app_sock: &PathBuf,
    daemon_sock: &PathBuf,
    team: &str,
    agent_name: &str,
    agent_type: &str,
    model: &str,
    cli: &str,
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
            let init_text = agent_init_prompt(agent_name, agent_type, team, &workdir, &app_sock_str);

            match rpc_call_timeout(
                daemon_sock,
                "headless.send",
                json!({
                    "agent_id": agent_id,
                    "text": init_text,
                }),
                5,
            ) {
                Ok(_) => eprintln!("  \u{2713} {agent_name}: init prompt sent"),
                Err(e) => eprintln!("  \u{2717} {agent_name}: init prompt FAILED: {e}"),
            }

            // Register the agent with the Swift app's team data store
            // Use agent_type (role) separately from agent_name (display name)
            match rpc_call(
                app_sock,
                "team.register_agent",
                json!({
                    "team_name": team,
                    "agent_name": agent_name,
                    "agent_type": agent_type,
                    "model": model,
                    "cli": cli,
                }),
            ) {
                Ok(_) => {}
                Err(e) => {
                    eprintln!("  Warning: failed to register agent with app: {e}");
                    eprintln!(
                        "  (agent process is running on daemon but may not appear in app UI)"
                    );
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
    sock: &PathBuf,
    team: &str,
    target: &str,
    text: &str,
    title: Option<String>,
    priority: Option<u32>,
    accept: &[String],
    deps: &[String],
    desc: Option<String>,
    no_report: bool,
    context: Option<&str>,
    fix_budget: Option<u8>,
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
            let mut text_delivered = v["result"]["text_delivered"].as_bool().unwrap_or(true);
            if !text_delivered {
                eprintln!("text.delivered.false reason=team.delegate_ack agent={target}");
                let task_ref = &v["result"]["task"];
                let instruction = format_task_instruction(
                    sock, team, task_ref, text, no_report, context, fix_budget,
                );

                // Headless agent path: route via daemon socket if available
                if let Some(daemon_sock) = detect_daemon_socket() {
                    if let Some(agent_id) = is_headless_agent(&daemon_sock, team, target) {
                        let headless_ok = match rpc_call(
                            &daemon_sock,
                            "headless.send",
                            json!({
                                "agent_id": agent_id,
                                "text": format!("{instruction}\n"),
                            }),
                        ) {
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
                eprintln!(
                    "  Warning: text not delivered to agent '{target}', retrying via team.send..."
                );
                std::thread::sleep(std::time::Duration::from_millis(300));
                let retry = rpc_call(
                    sock,
                    "team.send",
                    json!({
                        "team_name": team, "agent_name": target,
                        "text": format!("{instruction}\n"),
                    }),
                );
                match &retry {
                    Ok(rv) if rv["ok"].as_bool().unwrap_or(false) => {
                        // team.send succeeded — text was delivered. Update the response.
                        let mut patched = v.clone();
                        patched["result"]["text_delivered"] = json!(true);
                        text_delivered = true;
                        let _ = send_return_key_with_retry(
                            sock,
                            team,
                            target,
                            text_delivered,
                            "team.delegate.retry",
                        );
                        return Ok(patched);
                    }
                    _ => {
                        eprintln!("  Warning: retry also failed — task created but text may not have been delivered.");
                    }
                }
            }

            // Send Return key separately via team.send_key RPC.
            // delegateToAgent sends text WITHOUT Return (paste only). Return is sent
            // through the reliable sendNamedKey path (same as surface.send_key RPC).
            // Swift ack-based completion is the primary ordering guarantee;
            // this sleep is a minimal safety margin only.
            let _ = send_return_key_with_retry(sock, team, target, text_delivered, "team.delegate");

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
    if let Some(d) = desc {
        params["description"] = json!(d);
    }
    if !accept.is_empty() {
        params["acceptance_criteria"] = json!(accept);
    }
    if !deps.is_empty() {
        params["depends_on"] = json!(deps);
    }
    if let Some(fb) = fix_budget {
        params["fix_budget"] = json!(fb);
    }

    // Open one connection for both task.create and team.send.
    let fallback_stream = UnixStream::connect(sock).map_err(|e| format!("connect: {e}"))?;
    fallback_stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .ok();
    fallback_stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .ok();

    // Use one shared BufReader for both sequential RPC calls so its internal
    // read-ahead buffer is preserved between calls.  Creating a new BufReader
    // per call (as rpc_call_on_stream does) risks losing bytes that the first
    // BufReader pre-fetched from the OS socket buffer when it is dropped.
    let mut fallback_reader = BufReader::new(&fallback_stream);

    let created = rpc_call_with_reader(
        &fallback_stream,
        &mut fallback_reader,
        "team.task.create",
        params,
    )
    .map_err(|e| format!("task.create: {e}"))?;

    let task = &created["result"];
    let task_id = task["id"].as_str().unwrap_or("");
    if !created["ok"].as_bool().unwrap_or(false) || task_id.is_empty() {
        return Err(format!("task.create failed: {}", pretty(&created)));
    }

    let instruction =
        format_task_instruction(sock, team, task, text, no_report, context, fix_budget);
    let send_text = format!("{instruction}\n");

    // Headless agent path: route via daemon socket for 2-RPC fallback too
    if let Some(daemon_sock) = detect_daemon_socket() {
        if let Some(agent_id) = is_headless_agent(&daemon_sock, team, target) {
            let sent_ok = match rpc_call(
                &daemon_sock,
                "headless.send",
                json!({
                    "agent_id": agent_id,
                    "text": &send_text,
                }),
            ) {
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
    let sent = rpc_call_with_reader(
        &fallback_stream,
        &mut fallback_reader,
        "team.send",
        json!({
            "team_name": team, "agent_name": target,
            "text": &send_text,
        }),
    )
    .map_err(|e| format!("team.send: {e}"))?;

    if !sent["ok"].as_bool().unwrap_or(false) {
        // Retry once after 300ms — task is already created, so we must not abandon it.
        // Server-side team.send already retries internally (150ms + 400ms).
        eprintln!("  Warning: team.send failed for '{target}', retrying in 300ms...");
        std::thread::sleep(std::time::Duration::from_millis(300));
        let retry = rpc_call(
            sock,
            "team.send",
            json!({
                "team_name": team, "agent_name": target,
                "text": &send_text,
            }),
        );
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
    sock: &PathBuf,
    team: &str,
    target: &str,
    text: &str,
    title: Option<String>,
    priority: Option<u32>,
    accept: &[String],
    deps: &[String],
    desc: Option<String>,
    no_report: bool,
    context: Option<&str>,
    fix_budget: Option<u8>,
) {
    match run_delegate_result(
        sock, team, target, text, title, priority, accept, deps, desc, no_report, context,
        fix_budget,
    ) {
        Ok(v) => println!("{}", pretty(&v)),
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    }
}

/// Delegate a task in autonomous mode: spawn a temporary Claude subprocess
/// directly from the CLI (no daemon required). The subprocess runs without
/// team flags (--agent-id etc.), so no leader approval is needed for edits.
/// It uses `claude -p` (print mode) for single-shot execution.
fn run_delegate_autonomous(
    sock: &PathBuf,
    team: &str,
    target: &str,
    text: &str,
    title: Option<String>,
    priority: Option<u32>,
    _no_report: bool,
    context: Option<&str>,
    _fix_budget: Option<u8>,
) {
    let resolved_title = title.unwrap_or_else(|| task_title_from_text(text));
    let resolved_priority = priority.unwrap_or(2);

    // Step 1: Create the task (same as normal delegate)
    let task_params = json!({
        "team_name": team,
        "title": resolved_title,
        "assignee": target,
        "priority": resolved_priority,
    });
    let task = match rpc_call(sock, "team.task.create", task_params) {
        Ok(v) if v["ok"].as_bool().unwrap_or(false) => v["result"].clone(),
        Ok(v) => {
            eprintln!("Error creating task: {}", pretty(&v));
            process::exit(1);
        }
        Err(e) => {
            eprintln!("Error creating task: {e}");
            process::exit(1);
        }
    };
    let task_id = task["id"].as_str().unwrap_or("").to_string();

    // Step 2: Format instruction for autonomous mode (no lifecycle commands, no report suffix).
    // The monitor process handles task completion and result reporting.
    let instruction = format_autonomous_instruction(&task, text, context);

    // Step 3: Get agent model from team status
    let model = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(v) => v["result"]["agents"]
            .as_array()
            .and_then(|arr| arr.iter().find(|a| a["name"].as_str() == Some(target)))
            .and_then(|a| a["model"].as_str())
            .unwrap_or("sonnet")
            .to_string(),
        Err(_) => "sonnet".to_string(),
    };

    // Step 4: Resolve claude binary path
    let claude_path = env::var("CLAUDE_PATH")
        .ok()
        .or_else(|| {
            // Check versioned installs
            let versions_dir = format!(
                "{}/.local/share/claude/versions",
                env::var("HOME").unwrap_or_default()
            );
            if let Ok(entries) = std::fs::read_dir(&versions_dir) {
                let mut paths: Vec<_> = entries
                    .filter_map(|e| e.ok())
                    .filter(|e| e.path().join("claude").exists())
                    .collect();
                paths.sort_by_key(|e| e.path());
                paths
                    .last()
                    .map(|e| e.path().join("claude").to_string_lossy().to_string())
            } else {
                None
            }
        })
        .unwrap_or_else(|| "claude".to_string());

    // Step 5: Spawn claude subprocess directly (no team flags → no leader approval)
    // stdout goes to a temp file so a detached monitor process can read it after tm-agent exits.
    let app_socket = env::var("TERMMESH_SOCKET").unwrap_or_default();
    let working_dir = env::current_dir().unwrap_or_default();

    eprintln!(
        "  Autonomous mode: spawning claude subprocess for task {}",
        &task_id[..8.min(task_id.len())]
    );

    // Create temp file for capturing stdout
    let results_dir = format!(
        "{}/.term-mesh/results/{}",
        env::var("HOME").unwrap_or_default(),
        team
    );
    let _ = std::fs::create_dir_all(&results_dir);
    let stdout_file_path = format!(
        "{}/autonomous-{}.stdout",
        results_dir,
        &task_id[..8.min(task_id.len())]
    );
    let stdout_file = match std::fs::File::create(&stdout_file_path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("Error creating stdout file: {e}");
            process::exit(1);
        }
    };

    let child = std::process::Command::new(&claude_path)
        .arg("-p") // print mode: single-shot execution
        .arg("--dangerously-skip-permissions")
        .arg("--model")
        .arg(&model)
        .arg(&instruction)
        .env("TERMMESH_SOCKET", &app_socket)
        .env("TERMMESH_TEAM", team)
        .env("TERMMESH_AGENT_NAME", target)
        .env("TERMMESH_AGENT_ID", format!("{target}@{team}"))
        .env_remove("CLAUDECODE")
        .env_remove("CLAUDE_CODE_ENTRYPOINT")
        .current_dir(&working_dir)
        .stdout(stdout_file)
        .stderr(std::process::Stdio::null())
        .spawn();

    let child = match child {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: failed to spawn claude: {e}");
            eprintln!("  Tried path: {claude_path}");
            let _ = std::fs::remove_file(&stdout_file_path);
            process::exit(1);
        }
    };

    let child_pid = child.id();

    // Output task info immediately (don't wait for subprocess to finish)
    println!(
        "{}",
        pretty(&json!({
            "ok": true,
            "result": {
                "task": task,
                "sent": true,
                "text_delivered": true,
                "autonomous": true,
                "pid": child_pid,
            }
        }))
    );

    // Step 6: Wait for claude subprocess in a background thread, then auto-complete the task.
    // The thread runs inside this tm-agent process (which is a descendant of term-mesh),
    // so RPC calls pass the socket's isDescendant() access check.
    // The caller should invoke `tm-agent delegate --autonomous &` to avoid blocking.
    let sock_path = sock.clone();
    let team_str = team.to_string();
    let target_str = target.to_string();
    let task_id_clone = task_id.clone();
    let stdout_path_clone = stdout_file_path.clone();

    let handle = std::thread::spawn(move || {
        // Wait for the claude subprocess to finish
        let mut child_inner = child;
        let status = child_inner.wait();
        let exit_code = status
            .as_ref()
            .map(|s| s.code().unwrap_or(-1))
            .unwrap_or(-1);

        // Copy stdout file to result files
        let stdout_content = std::fs::read_to_string(&stdout_path_clone).unwrap_or_default();
        if !stdout_content.trim().is_empty() {
            let _ = write_result_file(&team_str, &format!("{task_id_clone}.md"), &stdout_content);
            let _ = write_result_file(
                &team_str,
                &format!("{target_str}-reply.md"),
                &stdout_content,
            );
        }
        let _ = std::fs::remove_file(&stdout_path_clone);

        // Auto-complete the task via RPC
        let completion_msg = format!(
            "autonomous task {} completed (exit={})",
            task_id_clone, exit_code
        );
        let _ = rpc_call(
            &sock_path,
            "team.report",
            json!({
                "team_name": team_str,
                "agent_name": target_str,
                "content": &completion_msg,
            }),
        );
        let _ = rpc_call(
            &sock_path,
            "team.task.update",
            json!({
                "team_name": team_str,
                "task_id": task_id_clone,
                "status": "completed",
                "result": &completion_msg,
            }),
        );

        eprintln!(
            "  Autonomous task {} completed (exit={})",
            &task_id_clone[..8.min(task_id_clone.len())],
            exit_code
        );
    });

    // Wait for the background thread to finish.
    // This means tm-agent stays alive until claude -p exits.
    // The caller should use `tm-agent delegate --autonomous &` to avoid blocking.
    let _ = handle.join();
}

fn run_fan_out(
    sock: &PathBuf,
    team: &str,
    text: &str,
    title: Option<String>,
    priority: Option<u32>,
    no_report: bool,
    agents_flag: &Option<String>,
    context: Option<&str>,
    fix_budget: Option<u8>,
) {
    // Get all agent names from team status
    let all_agents: Vec<String> = match rpc_call(sock, "team.status", json!({ "team_name": team }))
    {
        Ok(r) => r["result"]["agents"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|a| a["name"].as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default(),
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };

    // Filter agents if --agents flag provided
    let filter = parse_cli_flag(agents_flag);
    let targets: Vec<&str> = if filter.is_empty() {
        all_agents.iter().map(|s| s.as_str()).collect()
    } else {
        all_agents
            .iter()
            .filter(|a| filter.contains(a.as_str()))
            .map(|s| s.as_str())
            .collect()
    };

    if targets.is_empty() {
        eprintln!("Error: no matching agents found");
        process::exit(1);
    }

    eprintln!(
        "Fan-out: delegating to {} agents in parallel: {}",
        targets.len(),
        targets.join(", ")
    );

    // L2: compute task title once outside the thread scope to avoid repeated calls per thread.
    let base_title = title.unwrap_or_else(|| task_title_from_text(text));

    // Run all delegate calls in parallel using scoped threads.
    // rpc_call_timeout() opens a new UnixStream per call, so threads don't share connections.
    let results: Vec<(&str, Result<Value, String>)> = thread::scope(|s| {
        let handles: Vec<_> = targets
            .iter()
            .map(|target| {
                let t = base_title.clone();
                s.spawn(move || {
                    let result = run_delegate_result(
                        sock,
                        team,
                        target,
                        text,
                        Some(t),
                        priority,
                        &[],
                        &[],
                        None,
                        no_report,
                        context,
                        fix_budget,
                    );
                    (*target, result)
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().expect("thread panicked"))
            .collect()
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
        succeeded.len(),
        failed.len()
    );
    println!(
        "{}",
        pretty(&json!({
            "fan_out": {
                "team_name": team,
                "agents": succeeded,
                "count": succeeded.len(),
                "failed": failed,
            }
        }))
    );

    // M1: exit with error if all delegates failed.
    if succeeded.is_empty() && !failed.is_empty() {
        process::exit(1);
    }
}

/// Connect to the daemon's `events.subscribe` streaming endpoint and print
/// each received JSONL event to stdout until timeout or Ctrl+C.
fn run_watch(
    sock: &PathBuf,
    timeout_secs: u32,
    on_event: Option<&str>,
    leader_session: Option<&str>,
) {
    let kinds: Vec<&str> = on_event
        .unwrap_or("task_done,reply,heartbeat_stale")
        .split(',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();

    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "events.subscribe",
        "params": {
            "kinds": kinds,
            "timeout": if timeout_secs > 0 { Some(timeout_secs as u64) } else { None::<u64> },
            "leader_session_id": leader_session,
        },
    });

    let stream = match UnixStream::connect(sock) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: cannot connect to daemon socket: {e}");
            process::exit(1);
        }
    };

    // Read timeout must outlast the daemon's keepalive interval (30 s) with margin.
    // When a user-specified timeout is active, the daemon closes the connection,
    // so the client's read will return EOF naturally.
    let read_timeout_secs: u64 = if timeout_secs > 0 {
        (timeout_secs as u64).saturating_add(10)
    } else {
        90
    };
    stream
        .set_read_timeout(Some(Duration::from_secs(read_timeout_secs)))
        .ok();
    stream.set_write_timeout(Some(Duration::from_secs(10))).ok();

    let mut writer = match stream.try_clone() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: socket clone failed: {e}");
            process::exit(1);
        }
    };

    let mut payload = serde_json::to_string(&request).expect("request serialization cannot fail");
    payload.push('\n');
    if let Err(e) = writer.write_all(payload.as_bytes()) {
        eprintln!("error: failed to send subscribe request: {e}");
        process::exit(1);
    }
    writer.flush().ok();

    eprintln!(
        "[watch] subscribed (kinds: {}, timeout: {}s)",
        kinds.join(","),
        timeout_secs
    );

    let mut reader = BufReader::new(&stream);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break, // EOF — daemon closed the connection (timeout or shutdown)
            Ok(_) => {
                let trimmed = line.trim_end_matches('\n').trim_end_matches('\r');
                if !trimmed.is_empty() {
                    println!("{trimmed}");
                }
            }
            Err(e) => {
                use std::io::ErrorKind;
                match e.kind() {
                    ErrorKind::WouldBlock | ErrorKind::TimedOut => {
                        // No data within read timeout — daemon may be quiet.
                        // Continue waiting unless a hard timeout has been set.
                        if timeout_secs > 0 {
                            eprintln!("[watch] read timeout; exiting");
                            break;
                        }
                        continue;
                    }
                    _ => {
                        eprintln!("[watch] stream error: {e}");
                        break;
                    }
                }
            }
        }
    }
}

fn run_xmb_bridge(sock: &PathBuf, timeout_secs: u32, leader_session: Option<&str>) {
    eprintln!("[xmb-bridge] starting (timeout: {timeout_secs}s)");
    let mut handled = 0_u64;
    stream_events(sock, timeout_secs, &["reply"], leader_session, |event| {
        if let Err(e) = handle_xmb_reply_event(event, &mut handled) {
            eprintln!("[xmb-bridge] warning: {e}");
        }
    });
    eprintln!("[xmb-bridge] stopped (updates: {handled})");
}

fn handle_xmb_reply_event(event: Value, handled: &mut u64) -> Result<(), String> {
    if event.get("kind").and_then(Value::as_str) != Some("reply") {
        return Ok(());
    }
    let Some(header) = event.get("header").and_then(Value::as_str) else {
        return Ok(());
    };
    let Some(parsed) = parse_xmb_header(header) else {
        return Ok(());
    };
    let Some(xmb_status) = xmb_status_for_protocol_status(&parsed.status) else {
        eprintln!(
            "[xmb-bridge] skip {} / {}: unsupported STATUS {}",
            parsed.project, parsed.task_id, parsed.status
        );
        return Ok(());
    };

    let tasks_path = resolve_xmb_tasks_path(&parsed.project)?;
    let outcome = update_xmb_task_status(&tasks_path, &parsed.task_id, xmb_status)?;
    match outcome {
        XmbUpdateOutcome::Updated { old_status } => {
            *handled += 1;
            eprintln!(
                "[xmb-bridge] {} / {}: {} -> {}",
                parsed.project, parsed.task_id, old_status, xmb_status
            );
        }
        XmbUpdateOutcome::SkippedSameStatus => {
            eprintln!(
                "[xmb-bridge] {} / {}: already {}",
                parsed.project, parsed.task_id, xmb_status
            );
        }
    }
    Ok(())
}

fn stream_events<F>(
    sock: &PathBuf,
    timeout_secs: u32,
    kinds: &[&str],
    leader_session: Option<&str>,
    mut on_event: F,
) where
    F: FnMut(Value),
{
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "events.subscribe",
        "params": {
            "kinds": kinds,
            "timeout": if timeout_secs > 0 { Some(timeout_secs as u64) } else { None::<u64> },
            "leader_session_id": leader_session,
        },
    });

    let stream = match UnixStream::connect(sock) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: cannot connect to daemon socket: {e}");
            process::exit(1);
        }
    };

    let read_timeout_secs: u64 = if timeout_secs > 0 {
        (timeout_secs as u64).saturating_add(10)
    } else {
        90
    };
    stream
        .set_read_timeout(Some(Duration::from_secs(read_timeout_secs)))
        .ok();
    stream.set_write_timeout(Some(Duration::from_secs(10))).ok();

    let mut writer = match stream.try_clone() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: socket clone failed: {e}");
            process::exit(1);
        }
    };

    let mut payload = serde_json::to_string(&request).expect("request serialization cannot fail");
    payload.push('\n');
    if let Err(e) = writer.write_all(payload.as_bytes()) {
        eprintln!("error: failed to send subscribe request: {e}");
        process::exit(1);
    }
    writer.flush().ok();

    let mut reader = BufReader::new(&stream);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {
                let trimmed = line.trim_end_matches('\n').trim_end_matches('\r');
                if trimmed.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(trimmed) {
                    Ok(value) if value.get("kind").is_some() => on_event(value),
                    Ok(_) => {}
                    Err(e) => eprintln!("[events] invalid JSONL event: {e}"),
                }
            }
            Err(e) => {
                use std::io::ErrorKind;
                match e.kind() {
                    ErrorKind::WouldBlock | ErrorKind::TimedOut => {
                        if timeout_secs > 0 {
                            eprintln!("[events] read timeout; exiting");
                            break;
                        }
                        continue;
                    }
                    _ => {
                        eprintln!("[events] stream error: {e}");
                        break;
                    }
                }
            }
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
struct XmbHeader {
    status: String,
    project: String,
    task_id: String,
}

fn parse_xmb_header(header: &str) -> Option<XmbHeader> {
    let mut status = None;
    let mut task = None;
    for line in header.lines() {
        let trimmed = line.trim();
        if let Some(value) = trimmed.strip_prefix("STATUS:") {
            status = Some(value.trim().to_ascii_uppercase());
        } else if let Some(value) = trimmed.strip_prefix("XMB_TASK:") {
            task = parse_xmb_task_ref(value.trim());
        }
    }
    let (project, task_id) = task?;
    Some(XmbHeader {
        status: status?,
        project,
        task_id,
    })
}

fn parse_xmb_task_ref(value: &str) -> Option<(String, String)> {
    let (project, task_id) = value.split_once('/')?;
    if !is_valid_xmb_project(project) || !is_valid_xmb_task_id(task_id) {
        return None;
    }
    Some((project.to_string(), task_id.to_string()))
}

fn is_valid_xmb_project(project: &str) -> bool {
    !project.is_empty()
        && project
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn is_valid_xmb_task_id(task_id: &str) -> bool {
    let Some(rest) = task_id.strip_prefix('t') else {
        return false;
    };
    !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit())
}

fn xmb_status_for_protocol_status(status: &str) -> Option<&'static str> {
    match status {
        "DONE" => Some("completed"),
        "BLOCKED" => Some("blocked"),
        "NEEDS_REVIEW" => Some("review_ready"),
        "FAILED" => Some("failed"),
        _ => None,
    }
}

fn resolve_xmb_tasks_path(project: &str) -> Result<PathBuf, String> {
    let cwd = env::current_dir().map_err(|e| format!("current_dir: {e}"))?;
    let rel = Path::new(".xm")
        .join("build")
        .join("projects")
        .join(project)
        .join("phases")
        .join("02-plan")
        .join("tasks.json");
    let local = cwd.join(&rel);
    if local.exists() {
        return Ok(local);
    }
    if let Some(root) = git_root(&cwd) {
        let rooted = root.join(&rel);
        if rooted.exists() {
            return Ok(rooted);
        }
    }
    Err(format!(
        "tasks.json not found for project {project} from {}",
        cwd.display()
    ))
}

fn git_root(cwd: &Path) -> Option<PathBuf> {
    let output = std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(cwd)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let root = String::from_utf8(output.stdout).ok()?;
    let root = root.trim();
    if root.is_empty() {
        None
    } else {
        Some(PathBuf::from(root))
    }
}

#[derive(Debug, PartialEq, Eq)]
enum XmbUpdateOutcome {
    Updated { old_status: String },
    SkippedSameStatus,
}

fn update_xmb_task_status(
    tasks_path: &Path,
    task_id: &str,
    status: &str,
) -> Result<XmbUpdateOutcome, String> {
    let text = fs::read_to_string(tasks_path)
        .map_err(|e| format!("read {}: {e}", tasks_path.display()))?;
    let mut doc: Value =
        serde_json::from_str(&text).map_err(|e| format!("parse {}: {e}", tasks_path.display()))?;
    let tasks = doc
        .get_mut("tasks")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| format!("{}: missing tasks array", tasks_path.display()))?;
    let task = tasks
        .iter_mut()
        .find(|task| task.get("id").and_then(Value::as_str) == Some(task_id))
        .ok_or_else(|| format!("task {task_id} not found in {}", tasks_path.display()))?;

    let old_status = task
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    if old_status == status {
        return Ok(XmbUpdateOutcome::SkippedSameStatus);
    }

    task["status"] = json!(status);
    let now = iso8601_utc_now();
    match status {
        "completed" => task["completed_at"] = json!(now),
        "blocked" | "review_ready" | "failed" => task["updated_at"] = json!(now),
        _ => {}
    }

    let rendered = serde_json::to_string_pretty(&doc)
        .map_err(|e| format!("serialize {}: {e}", tasks_path.display()))?;
    write_atomic(tasks_path, &(rendered + "\n"))?;
    Ok(XmbUpdateOutcome::Updated { old_status })
}

fn write_atomic(path: &Path, content: &str) -> Result<(), String> {
    let dir = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    let filename = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("tasks.json");
    let tmp = dir.join(format!(".{filename}.tmp"));
    fs::write(&tmp, content).map_err(|e| format!("write {}: {e}", tmp.display()))?;
    fs::rename(&tmp, path)
        .map_err(|e| format!("rename {} -> {}: {e}", tmp.display(), path.display()))
}

fn iso8601_utc_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let (year, month, day, hour, min, sec) = unix_ts_to_ymd_hms(now);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{min:02}:{sec:02}Z")
}

#[cfg(test)]
mod xmb_bridge_tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn parse_xmb_header_extracts_status_project_and_task() {
        let parsed = parse_xmb_header(
            "STATUS: NEEDS_REVIEW\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\nXMB_TASK: agent-feedback-loop/t3\n",
        )
        .unwrap();

        assert_eq!(
            parsed,
            XmbHeader {
                status: "NEEDS_REVIEW".into(),
                project: "agent-feedback-loop".into(),
                task_id: "t3".into(),
            }
        );
        assert_eq!(
            xmb_status_for_protocol_status(&parsed.status),
            Some("review_ready")
        );
    }

    #[test]
    fn parse_xmb_header_rejects_invalid_task_ref() {
        assert!(parse_xmb_header("STATUS: DONE\nXMB_TASK: ../bad/t3\n").is_none());
        assert!(parse_xmb_header("STATUS: DONE\nXMB_TASK: project/task3\n").is_none());
    }

    #[test]
    fn update_xmb_task_status_is_idempotent() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-xmb-bridge-test-{unique}"));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tasks.json");
        fs::write(
            &path,
            r#"{"tasks":[{"id":"t3","name":"demo","status":"running"}]}"#,
        )
        .unwrap();

        let first = update_xmb_task_status(&path, "t3", "completed").unwrap();
        assert!(
            matches!(first, XmbUpdateOutcome::Updated { old_status } if old_status == "running")
        );

        let second = update_xmb_task_status(&path, "t3", "completed").unwrap();
        assert_eq!(second, XmbUpdateOutcome::SkippedSameStatus);

        let doc: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(doc["tasks"][0]["status"].as_str(), Some("completed"));
        assert!(doc["tasks"][0]["completed_at"].as_str().is_some());

        fs::remove_dir_all(dir).ok();
    }
}

fn run_wait(
    sock: &PathBuf,
    team: &str,
    timeout: u32,
    interval: u32,
    mode: &str,
    task_id: Option<&str>,
    agent_filter: &std::collections::HashSet<String>,
    explicit_task_ids: Option<&std::collections::HashSet<String>>,
) {
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
                agent_names = agents
                    .iter()
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
    // For report mode: snapshot task IDs on first poll so we can track them
    // even after agents drop active_task_id on completion.
    // If explicit --tasks are provided, use those directly (no auto-discovery).
    let mut tracked_task_ids: std::collections::HashSet<String> =
        explicit_task_ids.cloned().unwrap_or_default();
    let mut tracked_initialized = explicit_task_ids.is_some() && !tracked_task_ids.is_empty();
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
            // On first poll, snapshot the task IDs we want to track.
            // This is immune to agents dropping active_task_id on completion.
            if !tracked_initialized {
                if let Ok(r) = rpc_call(sock, "team.status", json!({ "team_name": team })) {
                    if let Some(agents) = r["result"]["agents"].as_array() {
                        for a in agents {
                            let name = a["name"].as_str().unwrap_or("");
                            if !agent_filter.is_empty() && !agent_filter.contains(name) {
                                continue;
                            }
                            if let Some(tid) = a["active_task_id"].as_str() {
                                let status = a["active_task_status"].as_str().unwrap_or("");
                                // Only track tasks that are currently active (not already done)
                                if matches!(status, "completed" | "failed" | "abandoned") {
                                    continue;
                                }
                                // Skip stale tasks from previous sessions — they'll never
                                // complete and would cause wait to hang forever.
                                let is_stale = a["active_task_is_stale"].as_bool().unwrap_or(false);
                                if is_stale {
                                    continue;
                                }
                                tracked_task_ids.insert(tid.to_string());
                            }
                        }
                        if !tracked_task_ids.is_empty() {
                            tracked_initialized = true;
                        }
                    }
                }
            }

            if tracked_initialized && !tracked_task_ids.is_empty() {
                // Track by task IDs — immune to agents dropping active_task_id on completion
                if let Ok(r) = rpc_call(sock, "team.task.list", json!({ "team_name": team })) {
                    if let Some(tasks) = r["result"]["tasks"].as_array() {
                        let total = tracked_task_ids.len() as u64;
                        let done = tasks
                            .iter()
                            .filter(|t| {
                                let tid = t["id"].as_str().unwrap_or("");
                                tracked_task_ids.contains(tid)
                                    && matches!(
                                        t["status"].as_str(),
                                        Some("completed") | Some("review_ready")
                                    )
                            })
                            .count() as u64;
                        report_done = total > 0 && done >= total;
                        report_progress = format!("{done}/{total}");
                    }
                }
            } else {
                // Fallback: legacy result.status (no tasks assigned yet)
                if let Ok(rs) = rpc_call(sock, "team.result.status", json!({ "team_name": team })) {
                    let done = rs["result"]["completed"].as_u64().unwrap_or(0);
                    let total = rs["result"]["total"].as_u64().unwrap_or(0);
                    report_done = rs["result"]["all_done"].as_bool().unwrap_or(false);
                    report_progress = format!("{done}/{total}");
                }
            }
        }

        if mode == "msg" || mode == "any" {
            match rpc_call(sock, "team.message.list", json!({ "team_name": team })) {
                Ok(r) => {
                    if let Some(messages) = r["result"]["messages"].as_array() {
                        let senders: std::collections::HashSet<&str> =
                            messages.iter().filter_map(|m| m["from"].as_str()).collect();
                        let reported = agent_names
                            .iter()
                            .filter(|a| senders.contains(a.as_str()))
                            .count();
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
                }))
                .unwrap_or_default();
                let p_task_get = serde_json::to_string(&json!({
                    "jsonrpc": "2.0", "id": 2,
                    "method": "team.task.get", "params": { "team_name": team, "task_id": tid }
                }))
                .unwrap_or_default();
                let (inbox_r, task_r) = match rpc_batch(sock, &[p_inbox, p_task_get]) {
                    Ok(mut results) if results.len() >= 2 => {
                        let tr = results.remove(1);
                        let ir = results.remove(0);
                        (Ok(ir), Ok(tr))
                    }
                    Ok(_) | Err(_) => (
                        rpc_call(sock, "team.inbox", json!({ "team_name": team })),
                        rpc_call(
                            sock,
                            "team.task.get",
                            json!({ "team_name": team, "task_id": tid }),
                        ),
                    ),
                };
                match inbox_r {
                    Ok(r) => {
                        if let Some(items) = r["result"]["items"].as_array() {
                            inbox_blocked = items
                                .iter()
                                .filter(|i| {
                                    i["kind"].as_str() == Some("task")
                                        && i["status"].as_str() == Some("blocked")
                                })
                                .cloned()
                                .collect();
                            inbox_review = items
                                .iter()
                                .filter(|i| {
                                    i["kind"].as_str() == Some("task")
                                        && i["status"].as_str() == Some("review_ready")
                                })
                                .cloned()
                                .collect();
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
                            inbox_blocked = items
                                .iter()
                                .filter(|i| {
                                    i["kind"].as_str() == Some("task")
                                        && i["status"].as_str() == Some("blocked")
                                })
                                .cloned()
                                .collect();
                            inbox_review = items
                                .iter()
                                .filter(|i| {
                                    i["kind"].as_str() == Some("task")
                                        && i["status"].as_str() == Some("review_ready")
                                })
                                .cloned()
                                .collect();
                        }
                    }
                    Err(e) => eprintln!("  Warning: inbox RPC failed: {e}"),
                }
            }
        }

        if let Some(tid) = task_id {
            let st = task_status.as_deref().unwrap_or("unknown");
            eprintln!("  [{elapsed}/{timeout}s] task={tid} status={st}");
            if matches!(
                st,
                "blocked" | "review_ready" | "completed" | "failed" | "abandoned"
            ) {
                println!(
                    "{}",
                    pretty(&json!({ "result": { "team_name": team, "task": task_obj } }))
                );
                return;
            }
        }

        match mode {
            "report" => {
                eprintln!("  [{elapsed}/{timeout}s] {report_progress} agents reported (report)");
                if report_done {
                    eprintln!("All agents have reported results.");
                    if let Ok(r) =
                        rpc_call(sock, "team.result.collect", json!({ "team_name": team }))
                    {
                        println!("{}", pretty(&r));
                    }
                    return;
                }
            }
            "msg" => {
                eprintln!("  [{elapsed}/{timeout}s] {msg_progress} agents messaged (msg)");
                if msg_done {
                    eprintln!("All agents have posted messages.");
                    if let Ok(r) = rpc_call(sock, "team.message.list", json!({ "team_name": team }))
                    {
                        println!("{}", pretty(&r));
                    }
                    return;
                }
            }
            "any" => {
                eprintln!(
                    "  [{elapsed}/{timeout}s] report={report_progress} msg={msg_progress} (any)"
                );
                if report_done {
                    eprintln!("All agents have reported results.");
                    if let Ok(r) =
                        rpc_call(sock, "team.result.collect", json!({ "team_name": team }))
                    {
                        println!("{}", pretty(&r));
                    }
                    return;
                }
                if msg_done {
                    eprintln!("All agents have posted messages.");
                    if let Ok(r) = rpc_call(sock, "team.message.list", json!({ "team_name": team }))
                    {
                        println!("{}", pretty(&r));
                    }
                    return;
                }
            }
            "blocked" => {
                eprintln!("  [{elapsed}/{timeout}s] blocked={}", inbox_blocked.len());
                if !inbox_blocked.is_empty() {
                    eprintln!("A task is blocked.");
                    println!(
                        "{}",
                        pretty(&json!({
                            "result": { "team_name": team, "items": inbox_blocked, "count": inbox_blocked.len() }
                        }))
                    );
                    return;
                }
            }
            "review_ready" => {
                eprintln!(
                    "  [{elapsed}/{timeout}s] review_ready={}",
                    inbox_review.len()
                );
                if !inbox_review.is_empty() {
                    eprintln!("A task is ready for review.");
                    println!(
                        "{}",
                        pretty(&json!({
                            "result": { "team_name": team, "items": inbox_review, "count": inbox_review.len() }
                        }))
                    );
                    return;
                }
            }
            "idle" => {
                if let Ok(r) = rpc_call(sock, "team.status", json!({ "team_name": team })) {
                    if let Some(agents) = r["result"]["agents"].as_array() {
                        let filtered: Vec<&Value> = if agent_filter.is_empty() {
                            agents.iter().collect()
                        } else {
                            agents
                                .iter()
                                .filter(|a| {
                                    a["name"]
                                        .as_str()
                                        .map(|n| agent_filter.contains(n))
                                        .unwrap_or(false)
                                })
                                .collect()
                        };
                        let idle_count = filtered
                            .iter()
                            .filter(|a| a["agent_state"].as_str() == Some("idle"))
                            .count();
                        let active_count = filtered
                            .iter()
                            .filter(|a| {
                                matches!(
                                    a["agent_state"].as_str(),
                                    Some("running" | "blocked" | "review_ready")
                                )
                            })
                            .count();
                        let total = idle_count + active_count;
                        eprintln!("  [{elapsed}/{timeout}s] idle={idle_count}/{total}");
                        if total > 0 && idle_count == total {
                            let idle_agents: Vec<&&Value> = filtered
                                .iter()
                                .filter(|a| a["agent_state"].as_str() == Some("idle"))
                                .collect();
                            println!(
                                "{}",
                                pretty(&json!({
                                    "result": { "team_name": team, "agents": idle_agents, "count": idle_count }
                                }))
                            );
                            return;
                        }
                    }
                }
            }
            _ => {
                eprintln!("Unknown wait mode: {mode}");
                process::exit(1);
            }
        }

        // Adaptive polling: speed up on progress, slow down on idle
        let current_progress_count: usize = {
            let r = report_progress
                .split('/')
                .next()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0usize);
            let m = msg_progress
                .split('/')
                .next()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0usize);
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
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };
    let agents = status["result"]["agents"]
        .as_array()
        .unwrap_or(&vec![])
        .clone();
    if agents.is_empty() {
        eprintln!("No agents in team '{team}'");
        process::exit(1);
    }

    // Filter to specific agent if requested
    let targets: Vec<&Value> = if let Some(name) = target {
        let filtered: Vec<&Value> = agents
            .iter()
            .filter(|a| a["name"].as_str() == Some(name))
            .collect();
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
            sock,
            team,
            name,
            "Reply with exactly one word: pong",
            Some("warmup-ping".to_string()),
            Some(3),
            &[],
            &[],
            None,
            true,
            None,
            None,
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
            if let Ok(v) = rpc_call(
                sock,
                "team.task.get",
                json!({
                    "team_name": team, "task_id": tid,
                }),
            ) {
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
        let icon = if result.to_lowercase().contains("pong") {
            "✓"
        } else {
            "?"
        };
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
    let result = rpc_call(
        sock,
        "team.task.claim",
        json!({
            "team_name": team,
            "agent_name": agent,
        }),
    );
    match result {
        Ok(ref v) if v["ok"].as_bool().unwrap_or(false) => {
            if v["result"].is_null() {
                println!(
                    "{}",
                    pretty(
                        &json!({ "ok": true, "result": null, "message": "No claimable tasks available" })
                    )
                );
            } else {
                println!("{}", pretty(v));
            }
        }
        Ok(ref v) => println!("{}", pretty(v)),
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    }
}

/// Returns capabilities (keywords) for a given agent_type.
/// Used by `tm-agent suggest` to match task descriptions to agents.
fn capabilities_for_agent_type(agent_type: &str) -> Vec<&'static str> {
    match agent_type.to_lowercase().as_str() {
        "architect" => vec![
            "architecture",
            "design",
            "system",
            "review",
            "structure",
            "plan",
            "interface",
            "boundary",
        ],
        "executor" => vec![
            "implement",
            "code",
            "coding",
            "refactor",
            "fix",
            "build",
            "develop",
            "feature",
        ],
        "explorer" => vec![
            "explore",
            "discover",
            "search",
            "analyze",
            "investigate",
            "map",
            "find",
        ],
        "reviewer" => vec![
            "review",
            "check",
            "audit",
            "quality",
            "lint",
            "standards",
            "critique",
        ],
        "tester" => vec![
            "test",
            "testing",
            "qa",
            "verification",
            "unit",
            "integration",
            "e2e",
            "spec",
        ],
        "debugger" => vec![
            "debug",
            "trace",
            "crash",
            "error",
            "bug",
            "fix",
            "diagnose",
            "root cause",
        ],
        "writer" => vec![
            "document",
            "docs",
            "readme",
            "guide",
            "migration",
            "notes",
            "write",
        ],
        "security" => vec![
            "security",
            "auth",
            "vulnerability",
            "pentest",
            "owasp",
            "injection",
            "xss",
        ],
        "ai" => vec![
            "ai",
            "ml",
            "llm",
            "model",
            "inference",
            "prompt",
            "embedding",
            "rag",
        ],
        "backend" => vec![
            "api", "server", "database", "backend", "service", "schema", "query", "rest",
        ],
        "frontend" => vec![
            "ui",
            "frontend",
            "component",
            "react",
            "swiftui",
            "css",
            "layout",
            "ux",
        ],
        _ => vec![],
    }
}

/// Score how well a task description matches an agent's capabilities.
fn capability_score(description_lower: &str, capabilities: &[&str]) -> usize {
    capabilities
        .iter()
        .filter(|kw| description_lower.contains(*kw))
        .count()
}

/// Suggest the best agent for a task description based on capability mapping.
fn run_suggest(sock: &PathBuf, team: &str, description: &str) {
    let status = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };

    let agents = match status["result"]["agents"].as_array() {
        Some(a) => a.clone(),
        None => {
            eprintln!("Error: no agents in team");
            process::exit(1);
        }
    };

    let desc_lower = description.to_lowercase();
    let mut scored: Vec<(String, String, Vec<&'static str>, usize)> = agents
        .iter()
        .filter_map(|a| {
            let name = a["name"].as_str()?.to_string();
            let agent_type = a["agent_type"].as_str().unwrap_or(&name).to_string();
            let caps = capabilities_for_agent_type(&agent_type);
            let score = capability_score(&desc_lower, &caps);
            Some((name, agent_type, caps, score))
        })
        .collect();

    scored.sort_by(|a, b| b.3.cmp(&a.3));

    let suggestions: Vec<Value> = scored
        .iter()
        .map(|(name, agent_type, caps, score)| {
            json!({
                "agent": name,
                "agent_type": agent_type,
                "capabilities": caps,
                "score": score,
            })
        })
        .collect();

    let best = scored
        .first()
        .map(|(name, _, _, _)| name.as_str())
        .unwrap_or("none");
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "ok": true,
            "result": {
                "task": description,
                "best_match": best,
                "ranking": suggestions,
            }
        }))
        .unwrap_or_default()
    );
}

fn run_brief(sock: &PathBuf, team: &str, target: &str, lines: u32) {
    let status = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };

    let agents = status["result"]["agents"].as_array();
    let agent_info = agents.and_then(|arr| arr.iter().find(|a| a["name"].as_str() == Some(target)));
    let agent_info = match agent_info {
        Some(a) => a.clone(),
        None => {
            eprintln!("Error: agent '{target}' not found in team '{team}'");
            process::exit(1);
        }
    };

    // Get active task
    let mut active_task = json!(null);
    if let Some(task_id) = agent_info["active_task_id"].as_str() {
        if let Ok(r) = rpc_call(
            sock,
            "team.task.get",
            json!({ "team_name": team, "task_id": task_id }),
        ) {
            if r["ok"].as_bool().unwrap_or(false) {
                active_task = r["result"].clone();
            }
        }
    }

    // Get recent messages
    let mut messages = json!([]);
    if let Ok(r) = rpc_call(
        sock,
        "team.message.list",
        json!({ "team_name": team, "from": target, "limit": 5 }),
    ) {
        if r["ok"].as_bool().unwrap_or(false) {
            messages = r["result"]["messages"].clone();
        }
    }

    // Read terminal output (3-level fallback)
    let mut terminal_tail = String::new();

    // 1: team.read
    if let Ok(r) = rpc_call(
        sock,
        "team.read",
        json!({ "team_name": team, "agent_name": target, "lines": lines }),
    ) {
        if r["ok"].as_bool().unwrap_or(false) {
            terminal_tail = r["result"]["text"].as_str().unwrap_or("").to_string();
        }
    }

    // 2: pane.read
    if terminal_tail.trim().is_empty() {
        if let Some(panel_id) = agent_info["panel_id"].as_str() {
            if let Ok(r) = rpc_call(
                sock,
                "pane.read",
                json!({ "panel_id": panel_id, "lines": lines }),
            ) {
                if r["ok"].as_bool().unwrap_or(false) {
                    terminal_tail = r["result"]["text"].as_str().unwrap_or("").to_string();
                }
            }
        }
    }

    // 3: last report
    if terminal_tail.trim().is_empty() {
        if let Ok(r) = rpc_call(
            sock,
            "team.reports",
            json!({ "team_name": team, "agent_name": target, "limit": 1 }),
        ) {
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

    println!(
        "{}",
        pretty(&json!({
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
        }))
    );
}

/// Read board.jsonl and print a human-readable synthesis to stderr.
/// Each line in board.jsonl is expected to be a JSON object with fields:
///   agent, round, finding, source, implication
/// Missing fields are tolerated — raw JSON is used as fallback.
/// Poll task IDs until all are completed/failed/abandoned, or timeout.
/// Returns the set of task IDs that completed successfully.
fn wait_for_tasks(
    sock: &PathBuf,
    team: &str,
    task_ids: &[String],
    timeout_secs: u64,
    label: &str,
) -> Vec<String> {
    if task_ids.is_empty() {
        return Vec::new();
    }
    eprintln!(
        "Waiting for {} task(s) to complete ({}, timeout: {}s)...",
        task_ids.len(),
        label,
        timeout_secs
    );
    let poll_interval = Duration::from_secs(3);
    let start = std::time::Instant::now();
    let deadline = start + Duration::from_secs(timeout_secs);
    let mut completed_ids: Vec<String> = Vec::new();
    loop {
        if std::time::Instant::now() >= deadline {
            eprintln!(
                "Timeout: {}/{} tasks completed within {}s",
                completed_ids.len(),
                task_ids.len(),
                timeout_secs
            );
            break;
        }
        thread::sleep(poll_interval);
        let mut all_done = true;
        let mut done_count = 0usize;
        if let Ok(r) = rpc_call(sock, "team.task.list", json!({ "team_name": team })) {
            if let Some(tasks) = r["result"]["tasks"].as_array() {
                completed_ids.clear();
                for tid in task_ids {
                    let task_status = tasks
                        .iter()
                        .find(|t| t["id"].as_str() == Some(tid.as_str()))
                        .and_then(|t| t["status"].as_str());
                    match task_status {
                        Some("completed") => {
                            done_count += 1;
                            completed_ids.push(tid.clone());
                        }
                        Some("failed") | Some("abandoned") => {
                            done_count += 1;
                        }
                        _ => {
                            all_done = false;
                        }
                    }
                }
            }
        }
        let elapsed = start.elapsed().as_secs();
        eprintln!(
            "  [{}/{}s] {}/{} done ({})",
            elapsed,
            timeout_secs,
            done_count,
            task_ids.len(),
            label
        );
        if all_done {
            break;
        }
    }
    completed_ids
}

/// Dispatch delegates with stagger and wait for completion.
/// Returns (agent_name, task_id) for dispatched tasks.
fn dispatch_and_wait(
    sock: &PathBuf,
    team: &str,
    timeout_secs: u64,
    agents_and_prompts: Vec<(String, String, String)>, // (agent_name, prompt, title)
    label: &str,
) -> Vec<(String, String)> {
    // (agent_name, task_id) for dispatched tasks
    let mut handles = Vec::new();
    for (i, (name, prompt, title)) in agents_and_prompts.into_iter().enumerate() {
        if i > 0 {
            thread::sleep(Duration::from_secs(2)); // stagger to avoid pane contention
        }
        let sock_clone = sock.clone();
        let team_owned = team.to_string();
        let h = thread::spawn(move || {
            let result = run_delegate_result(
                &sock_clone,
                &team_owned,
                &name,
                &prompt,
                Some(title),
                None,
                &[],
                &[],
                None,
                false,
                None,
                None,
            );
            (name, result)
        });
        handles.push(h);
    }

    let results: Vec<(String, Result<Value, String>)> = handles
        .into_iter()
        .map(|h| h.join().expect("thread panicked"))
        .collect();

    let mut agent_task_pairs: Vec<(String, String)> = Vec::new();
    let mut task_ids: Vec<String> = Vec::new();
    for (name, result) in &results {
        match result {
            Ok(v) => {
                if let Some(tid) = v["result"]["task"]["id"].as_str() {
                    task_ids.push(tid.to_string());
                    agent_task_pairs.push((name.clone(), tid.to_string()));
                }
            }
            Err(e) => {
                eprintln!("  {name}: delegate failed: {e}");
            }
        }
    }

    // Wait for all tasks to complete
    wait_for_tasks(sock, team, &task_ids, timeout_secs, label);
    agent_task_pairs
}

/// Read a task's result from the result file (task_id.md or agent-reply.md fallback).
fn read_task_result(team: &str, task_id: &str, agent_name: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let result_file = format!("{}/.term-mesh/results/{}/{}.md", home, team, task_id);
    std::fs::read_to_string(&result_file)
        .or_else(|_| {
            let reply_file = format!(
                "{}/.term-mesh/results/{}/{}-reply.md",
                home, team, agent_name
            );
            std::fs::read_to_string(&reply_file)
        })
        .unwrap_or_else(|_| "(no response)".to_string())
}

fn synthesize_board(board_path: &PathBuf, board_path_str: &str) {
    use std::collections::HashMap;
    use std::fs::File;
    use std::io::{BufRead, BufReader};

    let file = match File::open(board_path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("\n══ Research Results ══");
            eprintln!("(Could not read board.jsonl: {e})");
            eprintln!("Board path: {board_path_str}");
            return;
        }
    };

    let reader = BufReader::new(file);
    let mut entries: Vec<Value> = Vec::new();
    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        match serde_json::from_str::<Value>(trimmed) {
            Ok(v) => entries.push(v),
            Err(_) => {
                // Keep malformed lines as raw string values so they appear in output
                entries.push(Value::String(trimmed.to_string()));
            }
        }
    }

    eprintln!("\n══ Research Results ══");

    if entries.is_empty() {
        eprintln!("No board entries found. Check agent outputs above for results.");
        eprintln!("Board path: {board_path_str}");
        return;
    }

    // Count entries per agent and rounds covered
    let mut per_agent: HashMap<String, usize> = HashMap::new();
    let mut rounds: std::collections::BTreeSet<u64> = std::collections::BTreeSet::new();
    for entry in &entries {
        let agent = entry
            .get("agent")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();
        *per_agent.entry(agent).or_insert(0) += 1;
        if let Some(r) = entry.get("round").and_then(|v| v.as_u64()) {
            rounds.insert(r);
        }
    }

    let rounds_str = if rounds.is_empty() {
        "unknown".to_string()
    } else {
        let v: Vec<String> = rounds.iter().map(|r| r.to_string()).collect();
        v.join(", ")
    };

    eprintln!(
        "Board statistics: {} entries | {} agent(s) | rounds: {}",
        entries.len(),
        per_agent.len(),
        rounds_str
    );
    for (agent, count) in &per_agent {
        eprintln!("  {agent}: {count} finding(s)");
    }
    eprintln!();

    // Print each entry in readable format
    for (i, entry) in entries.iter().enumerate() {
        match entry {
            Value::Object(_) => {
                let agent = entry
                    .get("agent")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown");
                let round = entry
                    .get("round")
                    .and_then(|v| v.as_u64())
                    .map(|r| r.to_string())
                    .unwrap_or_else(|| "?".to_string());
                let finding = entry
                    .get("finding")
                    .and_then(|v| v.as_str())
                    .unwrap_or("(no finding field)");
                let source = entry.get("source").and_then(|v| v.as_str()).unwrap_or("");
                let implication = entry
                    .get("implication")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");

                eprintln!("[{}] (round {}): {}", agent, round, finding);
                if !source.is_empty() {
                    eprintln!("  source: {source}");
                }
                if !implication.is_empty() {
                    eprintln!("  implication: {implication}");
                }
            }
            Value::String(raw) => {
                eprintln!("[entry {}]: {}", i + 1, raw);
            }
            other => {
                eprintln!("[entry {}]: {}", i + 1, other);
            }
        }
    }

    eprintln!("\nBoard path: {board_path_str}");
}

fn run_autonomous(
    sock: &PathBuf,
    team: &str,
    mode: &str,  // "research", "solve", "consensus", "swarm"
    topic: &str, // topic/problem/question/goal
    agents_requested: u32,
    budget: u32,
    timeout: u64,
    depth: &str,
    web: bool,
    focus: Option<&str>,
    no_discuss: bool,
    // Mode-specific options:
    verify_cmd: Option<&str>, // solve only
    target: Option<&str>,     // solve only
    extra: Option<&str>,      // consensus: perspectives, swarm: seed tasks
) {
    let idle = detect_idle_agents(sock, team, None);
    let (selected, warn_or_err) = select_agents(idle, agents_requested);

    if selected.is_empty() {
        eprintln!("Error: {}", warn_or_err.unwrap_or_default());
        process::exit(1);
    }
    if let Some(ref w) = warn_or_err {
        eprintln!("{w}");
    }

    let agent_names: Vec<&str> = selected.iter().map(|a| a.name.as_str()).collect();
    let total_agents = agent_names.len() as u32;
    eprintln!(
        "{}: topic='{}' agents={} budget={} timeout={}s",
        mode.to_uppercase(),
        topic,
        agent_names.join(","),
        budget,
        timeout
    );

    let (board_path, run_id) = match create_board(mode) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error creating {mode} board: {e}");
            process::exit(1);
        }
    };
    let board_path_str = board_path_for_prompt(&board_path);
    eprintln!("Board: {board_path_str} (run: {run_id})");

    // For swarm mode: seed initial tasks to board
    if mode == "swarm" {
        let seed_tasks: Vec<&str> = extra
            .map(|s| s.split(',').map(|t| t.trim()).collect::<Vec<_>>())
            .unwrap_or_default();
        if seed_tasks.is_empty() {
            // Auto-generate 3 generic seed tasks
            let seeds = vec![
                format!(
                    r#"{{"type":"task","id":1,"desc":"Analyze scope and requirements for: {}","status":"open","added_by":"leader"}}"#,
                    topic
                ),
                format!(
                    r#"{{"type":"task","id":2,"desc":"Identify key components and dependencies","status":"open","added_by":"leader"}}"#
                ),
                format!(
                    r#"{{"type":"task","id":3,"desc":"Create implementation plan with priorities","status":"open","added_by":"leader"}}"#
                ),
            ];
            let mut content = String::new();
            for s in &seeds {
                content.push_str(s);
                content.push('\n');
            }
            let _ = std::fs::write(&board_path, &content);
        } else {
            let mut content = String::new();
            for (i, task) in seed_tasks.iter().enumerate() {
                content.push_str(&format!(
                    r#"{{"type":"task","id":{},"desc":"{}","status":"open","added_by":"leader"}}"#,
                    i + 1,
                    task
                ));
                content.push('\n');
            }
            let _ = std::fs::write(&board_path, &content);
        }
    }

    // Build per-agent instructions
    let instructions: Vec<String> = agent_names
        .iter()
        .enumerate()
        .map(|(i, _name)| {
            let n = (i + 1) as u32;
            match mode {
                "research" => prompts::research_prompt(
                    topic,
                    &board_path_str,
                    n,
                    total_agents,
                    depth,
                    budget,
                    web,
                    focus,
                ),
                "solve" => prompts::solve_prompt(
                    topic,
                    &board_path_str,
                    n,
                    total_agents,
                    budget,
                    verify_cmd,
                    target,
                ),
                "consensus" => {
                    // Parse perspectives if provided, assign round-robin
                    let perspectives: Vec<&str> = extra
                        .map(|s| s.split(',').map(|t| t.trim()).collect::<Vec<_>>())
                        .unwrap_or_default();
                    let perspective = if perspectives.is_empty() {
                        None
                    } else {
                        Some(perspectives[i % perspectives.len()])
                    };
                    prompts::consensus_prompt(
                        topic,
                        &board_path_str,
                        n,
                        total_agents,
                        budget,
                        perspective,
                    )
                }
                "swarm" => {
                    prompts::swarm_prompt(topic, &board_path_str, n, total_agents, budget, extra)
                }
                _ => unreachable!(),
            }
        })
        .collect();

    // Stagger timing per mode
    let stagger_secs: u64 = match mode {
        "consensus" => 8,
        _ => 3,
    };

    // Dispatch to each agent
    let truncated_topic = match topic.char_indices().nth(60) {
        Some((idx, _)) => &topic[..idx],
        None => topic,
    };
    let task_title = format!("{}: {}", mode, truncated_topic);
    let mut handles = Vec::new();
    for (i, (name, instr)) in agent_names.iter().zip(instructions.iter()).enumerate() {
        if i > 0 {
            thread::sleep(Duration::from_secs(stagger_secs));
        }
        let instr = instr.clone();
        let title = task_title.clone();
        let sock_clone = sock.clone();
        let team_owned = team.to_string();
        let name_owned = name.to_string();
        let h = thread::spawn(move || {
            let result = run_delegate_result(
                &sock_clone,
                &team_owned,
                &name_owned,
                &instr,
                Some(title),
                None,
                &[],
                &[],
                None,
                false,
                None,
                None,
            );
            (name_owned, result)
        });
        handles.push(h);
    }

    let results: Vec<(String, Result<Value, String>)> = handles
        .into_iter()
        .map(|h| h.join().expect("thread panicked"))
        .collect();

    let mut succeeded: Vec<String> = Vec::new();
    let mut failed: Vec<String> = Vec::new();
    let mut task_ids: Vec<String> = Vec::new();
    for (name, result) in &results {
        match result {
            Ok(v) => {
                println!("{}", pretty(v));
                if let Some(tid) = v["result"]["task"]["id"].as_str() {
                    task_ids.push(tid.to_string());
                }
                succeeded.push(name.clone());
            }
            Err(e) => {
                eprintln!("Error delegating {mode} to {name}: {e}");
                failed.push(name.clone());
            }
        }
    }

    wait_for_tasks(sock, team, &task_ids, timeout, mode);
    synthesize_board(&board_path, &board_path_str);

    // === Discussion Phase (same for all modes) ===
    if !no_discuss && succeeded.len() >= 2 {
        let board_text = std::fs::read_to_string(&board_path).unwrap_or_default();
        if !board_text.trim().is_empty() {
            thread::sleep(Duration::from_secs(5));
            eprintln!("\n══ Discussion Phase ══");
            let discuss_timeout = 180u64;

            eprintln!("Phase 1: Cross-Review — agents examining each other's findings...");
            let cross_tasks: Vec<(String, String, String)> = succeeded
                .iter()
                .map(|name| {
                    let prompt = prompts::cross_review_prompt(topic, &board_text, name, &succeeded);
                    (
                        name.clone(),
                        prompt,
                        format!("{mode}-discuss: cross-review"),
                    )
                })
                .collect();
            let cross_pairs =
                dispatch_and_wait(sock, team, discuss_timeout, cross_tasks, "cross-review");

            let cross_texts: Vec<(String, String)> = cross_pairs
                .iter()
                .map(|(name, tid)| (name.clone(), read_task_result(team, tid, name)))
                .collect();

            for (name, text) in &cross_texts {
                let truncated = match text.char_indices().nth(500) {
                    Some((idx, _)) => &text[..idx],
                    None => text,
                };
                eprintln!("[{name}] cross-review:\n{truncated}\n");
            }

            if cross_texts.len() >= 2 {
                eprintln!("Phase 2: Synthesis — converging on consensus...");
                let cross_summary: String = cross_texts
                    .iter()
                    .map(|(name, text)| format!("### {name}의 교차 검토\n{text}"))
                    .collect::<Vec<_>>()
                    .join("\n\n");

                let synth_tasks: Vec<(String, String, String)> = succeeded
                    .iter()
                    .map(|name| {
                        let prompt = prompts::synthesis_prompt(topic, &cross_summary);
                        (name.clone(), prompt, format!("{mode}-discuss: synthesis"))
                    })
                    .collect();
                let synth_pairs =
                    dispatch_and_wait(sock, team, discuss_timeout, synth_tasks, "synthesis");

                eprintln!("\n══ Discussion Results ══");
                for (name, tid) in &synth_pairs {
                    let text = read_task_result(team, tid, name);
                    eprintln!("[{name}] synthesis:\n{text}\n");
                }
            }
        }
    }

    println!(
        "{}",
        pretty(&json!({
            "ok": !succeeded.is_empty(),
            "result": {
                "mode": mode,
                "topic": topic,
                "budget": budget,
                "timeout_secs": timeout,
                "assigned": succeeded,
                "failed": failed,
                "agent_count": succeeded.len(),
                "board_path": board_path_str,
                "run_id": run_id,
            }
        }))
    );

    if succeeded.is_empty() {
        process::exit(1);
    }
}
