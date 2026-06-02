pub mod buffer;
pub mod cli_builder;
pub mod meta;
pub mod one_shot;
pub mod protocol;

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::Mutex;

use buffer::OutputBuffer;
use protocol::AgentProtocol;

fn validated_signal_pid(pid: u32) -> Result<libc::pid_t, String> {
    if pid <= 1 || pid > i32::MAX as u32 {
        return Err(format!("invalid pid for signal target: {pid}"));
    }
    Ok(pid as libc::pid_t)
}

fn signal_agent_process_group(pid: u32, signal: libc::c_int) -> Result<(), String> {
    let pid_i32 = validated_signal_pid(pid)?;
    let pgid = unsafe { libc::getpgid(pid_i32) };
    if pgid > 1 {
        unsafe {
            libc::killpg(pgid, signal);
        }
        return Ok(());
    }

    if pgid == 0 {
        tracing::warn!(
            "getpgid returned invalid pgid=0 for headless pid {pid}; falling back to pid kill"
        );
    } else {
        let err = std::io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::ESRCH) {
            tracing::warn!(
                "getpgid failed with ESRCH for headless pid {pid}; process may already be gone"
            );
            return Ok(());
        }
        tracing::warn!("getpgid failed for headless pid {pid}: {err}; falling back to pid kill");
    }

    unsafe {
        libc::kill(pid_i32, signal);
    }
    Ok(())
}

/// Status of a headless agent subprocess.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentStatus {
    #[allow(dead_code)] // Part of status protocol
    Spawning,
    Running,
    Terminated,
    /// Phase 2: subprocess terminated, metadata preserved on disk.
    Parked,
}

/// A headless agent: a subprocess managed by the daemon with stdin/stdout pipes.
pub struct HeadlessAgent {
    pub id: String,
    pub name: String,
    pub cli: String,
    pub model: String,
    pub team_name: String,
    #[allow(dead_code)] // back-reference; future RPCs may need it
    pub team_uuid: String,
    pub working_directory: String,
    pub child: Option<Child>,
    pub stdin: Option<ChildStdin>,
    pub stdout_buffer: Arc<Mutex<OutputBuffer>>,
    pub protocol: Box<dyn AgentProtocol>,
    pub status: AgentStatus,
    pub pid: u32,
    pub created_at: u64,
    /// Phase 2: claude session UUID (None for kiro/codex/gemini).
    pub session_id: Option<String>,
    /// Phase 2: idle-park tracking — last stream-json event timestamp (unix ms).
    pub last_activity_ms: Arc<std::sync::atomic::AtomicU64>,
    /// Phase 2: when true, the subprocess is intentionally absent.
    pub parked: bool,
    /// Phase 2.5: per-agent cumulative token usage. Updated lock-free by the
    /// stdout reader task and broadcast/flushed on a timer. Survives
    /// park/unpark and destroy/resume cycles by being seeded from
    /// `agent.json:usage_total` at spawn time.
    pub usage: Arc<UsageCounters>,
    /// Auto-recycle threshold: recycle every N completed tasks (None = off).
    pub auto_recycle_every: Option<u32>,
    /// Running count of completed tasks since last recycle.
    pub completed_task_count: u32,
}

/// Phase 2.5: lock-free cumulative token counters for one headless agent.
///
/// Incremented from the stdout reader task as `assistant`/`result` stream-json
/// events arrive. The `dirty` bit is set by writers and cleared by:
///   - the 1s broadcast task (after emitting `agent.usage_tick`)
///   - the 30s disk flush task (after rewriting `agent.json`)
///
/// Reading the four totals is non-atomic across fields — a broadcast may
/// observe slightly inconsistent snapshots (e.g. input bumped but output
/// not). That's fine; the next tick converges.
#[derive(Debug, Default)]
pub struct UsageCounters {
    pub input_total: AtomicU64,
    pub output_total: AtomicU64,
    pub cache_read_total: AtomicU64,
    pub cache_creation_total: AtomicU64,
    pub last_updated_ms: AtomicU64,
    /// Set whenever any total is incremented. Cleared by the broadcast
    /// emitter (so each tick reflects "changed since last tick") and by the
    /// disk flusher independently. Both consumers use distinct semantics —
    /// see `take_dirty_for_broadcast` and `take_dirty_for_flush`.
    pub broadcast_dirty: AtomicBool,
    pub flush_dirty: AtomicBool,
}

impl UsageCounters {
    /// Construct from a persisted `UsageTotals` snapshot (resume / unpark
    /// path). Returns counters with no dirty bits set.
    pub fn from_persisted(t: &meta::UsageTotals) -> Arc<Self> {
        Arc::new(Self {
            input_total: AtomicU64::new(t.input_tokens),
            output_total: AtomicU64::new(t.output_tokens),
            cache_read_total: AtomicU64::new(t.cache_read_input_tokens),
            cache_creation_total: AtomicU64::new(t.cache_creation_input_tokens),
            last_updated_ms: AtomicU64::new(t.last_updated_ms),
            broadcast_dirty: AtomicBool::new(false),
            flush_dirty: AtomicBool::new(false),
        })
    }

    /// Apply a single usage observation. Each field is `fetch_add` (cumulative).
    /// Marks both dirty bits.
    pub fn observe(&self, u: &ParsedUsage, now_ms: u64) {
        if u.input_tokens == 0
            && u.output_tokens == 0
            && u.cache_read_input_tokens == 0
            && u.cache_creation_input_tokens == 0
        {
            return;
        }
        if u.input_tokens > 0 {
            self.input_total
                .fetch_add(u.input_tokens, Ordering::Relaxed);
        }
        if u.output_tokens > 0 {
            self.output_total
                .fetch_add(u.output_tokens, Ordering::Relaxed);
        }
        if u.cache_read_input_tokens > 0 {
            self.cache_read_total
                .fetch_add(u.cache_read_input_tokens, Ordering::Relaxed);
        }
        if u.cache_creation_input_tokens > 0 {
            self.cache_creation_total
                .fetch_add(u.cache_creation_input_tokens, Ordering::Relaxed);
        }
        self.last_updated_ms.store(now_ms, Ordering::Relaxed);
        self.broadcast_dirty.store(true, Ordering::Release);
        self.flush_dirty.store(true, Ordering::Release);
    }

    /// Snapshot the current totals without mutating dirty bits.
    pub fn snapshot(&self) -> meta::UsageTotals {
        meta::UsageTotals {
            input_tokens: self.input_total.load(Ordering::Relaxed),
            output_tokens: self.output_total.load(Ordering::Relaxed),
            cache_read_input_tokens: self.cache_read_total.load(Ordering::Relaxed),
            cache_creation_input_tokens: self.cache_creation_total.load(Ordering::Relaxed),
            last_updated_ms: self.last_updated_ms.load(Ordering::Relaxed),
        }
    }

    /// Atomically clear the broadcast-dirty bit. Returns the previous value.
    pub fn take_broadcast_dirty(&self) -> bool {
        self.broadcast_dirty.swap(false, Ordering::AcqRel)
    }

    /// Atomically clear the flush-dirty bit. Returns the previous value.
    pub fn take_flush_dirty(&self) -> bool {
        self.flush_dirty.swap(false, Ordering::AcqRel)
    }
}

/// Phase 2.5: parsed `usage` block extracted from a stream-json line.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ParsedUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_input_tokens: u64,
    pub cache_creation_input_tokens: u64,
}

/// Parse a single Claude stream-json output line and extract `usage` if the
/// line is an `assistant` or `result` event with a `usage` object. Tolerant
/// of partial/missing fields. Returns `None` if the line is not JSON, not an
/// expected event, or has no usage block.
///
/// Looks at both `message.usage` (assistant events) and top-level `usage`
/// (result events).
pub fn parse_usage_from_line(line: &str) -> Option<ParsedUsage> {
    let v: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
    let kind = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
    if kind != "assistant" && kind != "result" {
        return None;
    }
    let usage = v
        .get("message")
        .and_then(|m| m.get("usage"))
        .or_else(|| v.get("usage"))?;
    let take = |k: &str| usage.get(k).and_then(|n| n.as_u64()).unwrap_or(0);
    let parsed = ParsedUsage {
        input_tokens: take("input_tokens"),
        output_tokens: take("output_tokens"),
        cache_read_input_tokens: take("cache_read_input_tokens"),
        cache_creation_input_tokens: take("cache_creation_input_tokens"),
    };
    if parsed == ParsedUsage::default() {
        return None;
    }
    Some(parsed)
}

/// Phase 2.5: per-team broadcast payload. Built by `collect_usage_tick`.
#[derive(Debug, Clone, serde::Serialize)]
pub struct UsageTickAgent {
    pub name: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_input_tokens: u64,
    pub cache_creation_input_tokens: u64,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct UsageTickTeam {
    pub team_uuid: String,
    pub team_name: String,
    pub agents: Vec<UsageTickAgent>,
}

/// Serializable agent info (for RPC responses — excludes process handles).
#[derive(Debug, Clone, serde::Serialize)]
pub struct AgentInfo {
    pub id: String,
    pub name: String,
    pub cli: String,
    pub model: String,
    pub team_name: String,
    pub working_directory: String,
    pub status: AgentStatus,
    pub pid: u32,
    pub created_at: u64,
    pub output_lines: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default)]
    pub parked: bool,
}

/// Team metadata for headless teams (live, in-memory).
#[derive(Debug, Clone, serde::Serialize)]
pub struct HeadlessTeam {
    pub name: String,
    /// Phase 2: stable identity used for `--session-id` of the leader and for
    /// the on-disk metadata directory.
    pub team_uuid: String,
    pub agents: Vec<String>,
    pub working_directory: String,
    pub leader_session_id: String,
    pub created_at: u64,
}

/// Parameters for spawning a headless agent.
#[derive(Debug, serde::Deserialize)]
pub struct SpawnParams {
    pub name: String,
    pub team_name: String,
    #[serde(default = "default_cli")]
    pub cli: String,
    #[serde(default = "default_model")]
    pub model: String,
    pub working_directory: String,
    /// Resolved absolute path to the CLI binary (from Swift's agentBinaryPath).
    pub cli_path: Option<String>,
    /// Swift app socket path — agents use this as TERMMESH_SOCKET for team.* commands.
    #[serde(default)]
    pub app_socket_path: Option<String>,
    /// Agent-specific instructions (preset system prompt). Optional.
    /// Phase 2: stored verbatim as raw bytes — String here for JSON convenience,
    /// but the value is passed straight through to the CLI without escaping.
    #[serde(default)]
    pub instructions: Option<String>,
    /// Override TERMMESH_AGENT_NAME env var (for autonomous tasks that report as a different agent).
    #[serde(default)]
    pub agent_name_override: Option<String>,
}

fn default_cli() -> String {
    "claude".into()
}
fn default_model() -> String {
    "sonnet".into()
}

/// Parameters for creating a headless team.
#[derive(Debug, serde::Deserialize)]
pub struct TeamCreateParams {
    pub team_name: String,
    pub working_directory: String,
    #[serde(default)]
    pub leader_session_id: String,
    pub agents: Vec<AgentSpec>,
    /// Swift app socket path — passed through to each spawned agent as TERMMESH_SOCKET.
    #[serde(default)]
    pub app_socket_path: Option<String>,

    // ── Phase 2 additions (all optional for back-compat) ─────────────────
    /// Caller-supplied team UUID. Daemon generates a fresh UUIDv4 if absent.
    #[serde(default)]
    pub team_uuid: Option<String>,
    /// Per-agent session UUIDs (resume path only). Map of agent_name -> uuid.
    /// Non-claude agents ignore this map.
    #[serde(default)]
    pub session_ids: Option<HashMap<String, String>>,
    /// Worktree metadata (record-only — does not affect spawn).
    #[serde(default)]
    pub worktree: Option<WorktreeParam>,
    /// Realpath of the git root containing `working_directory` (Swift-supplied).
    #[serde(default)]
    pub git_root: Option<String>,
    /// Branch resolved at create time.
    #[serde(default)]
    pub git_branch_at_create: Option<String>,
    /// `claude --version` captured by Swift at create time.
    #[serde(default)]
    pub claude_cli_version: Option<String>,
    /// term-mesh app version (Swift `Bundle.main.shortVersionString`).
    #[serde(default)]
    pub termmesh_app_version: Option<String>,
    /// SHA-256 (or any opaque digest hash) of the AgentRunbookService output
    /// used at create time.
    #[serde(default)]
    pub runbook_digest_hash: Option<String>,
    /// Leader CLI mode for metadata (e.g. "claude", "adopted"). Defaults to
    /// "headless" execution mode regardless.
    #[serde(default)]
    pub leader_mode: Option<String>,
    /// Leader model for metadata.
    #[serde(default)]
    pub leader_model: Option<String>,
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct WorktreeParam {
    pub mode: String,
    pub path: String,
    pub branch: String,
}

/// Specification for an individual agent within a team create request.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct AgentSpec {
    pub name: String,
    #[serde(default = "default_cli")]
    pub cli: String,
    #[serde(default = "default_model")]
    pub model: String,
    /// Resolved absolute path to the CLI binary (from Swift's agentBinaryPath).
    pub cli_path: Option<String>,
    /// Agent-specific instructions (preset system prompt).
    #[serde(default)]
    pub instructions: Option<String>,
    /// Optional custom instructions (e.g. a watcher `--spec`). Folded into the
    /// effective instructions at create time so they persist and reach the CLI
    /// as `--append-system-prompt`. R7 (watcher-only) is enforced by the client,
    /// which only attaches this to the watcher agent.
    #[serde(default)]
    pub custom_instructions: Option<String>,
    /// Phase 2: optional explicit agent_type (defaults to `name` for back-compat).
    #[serde(default)]
    pub agent_type: Option<String>,
    /// Phase 2: optional UI color hint persisted in metadata.
    #[serde(default)]
    pub color: Option<String>,
    /// Extra CLI arguments appended after the standard args (no shell escaping needed).
    #[serde(default)]
    pub extra_args: Vec<String>,
    /// Extra environment variables merged into the subprocess env (base env takes precedence).
    #[serde(default)]
    pub extra_env: std::collections::HashMap<String, String>,
    /// Auto-recycle: recycle this agent every N completed tasks (None = off).
    #[serde(default)]
    pub auto_recycle_every: Option<u32>,
}

/// Merge a base preset instruction with an optional custom-instruction block.
/// Returns the combined instruction text, or `None` when both are empty.
/// Content is preserved verbatim (only emptiness is whitespace-trimmed) so a
/// watcher `--spec` sentinel survives unchanged.
fn merge_instructions(base: Option<&str>, custom: Option<&str>) -> Option<String> {
    let base = base.filter(|s| !s.trim().is_empty());
    let custom = custom.filter(|s| !s.trim().is_empty());
    match (base, custom) {
        (Some(b), Some(c)) => Some(format!("{b}\n\n## Custom Instructions\n\n{c}")),
        (Some(b), None) => Some(b.to_string()),
        (None, Some(c)) => Some(c.to_string()),
        (None, None) => None,
    }
}

/// Manages all headless agent subprocesses and teams.
pub struct HeadlessManager {
    agents: HashMap<String, HeadlessAgent>,
    teams: HashMap<String, HeadlessTeam>,
    /// Phase 2: in-memory cache of the global idle-park minutes (0 = disabled).
    idle_park_minutes: u32,
    /// Phase 2: snapshot of host-side runbook digest hash, used by
    /// `list_resumable` for the `runbook_matches` flag. Daemon doesn't compute
    /// this itself — Swift sets it via `headless.update_validity_snapshot`
    /// (future) or it's left None.
    pub current_runbook_digest_hash: Option<String>,
    /// Same as above for `claude --version`.
    pub current_claude_cli_version: Option<String>,
    /// D2 in-flight guard: team_uuids whose `archive_pane_team` is currently
    /// executing. Prevents concurrent archive of the same team racing on the
    /// rename step. Outer `tokio::Mutex` on `HeadlessManager` already serializes
    /// RPC handlers, but this guard documents intent and remains correct if the
    /// archive path becomes finer-grained in the future.
    ///
    /// Held behind `Arc` so an `InFlightGuard` (RAII Drop) can outlive the
    /// `&mut self` borrow on `archive_pane_team` and release the slot under
    /// every exit path — `?` early-return, normal return, AND panic unwind.
    archive_in_flight: Arc<std::sync::Mutex<HashSet<String>>>,
}

/// RAII release of an `archive_in_flight` slot. Removed under Drop so any
/// exit path — including panic unwinds inside `archive_pane_team` — frees the
/// uuid for the next caller. Lock poisoning is swallowed silently: a poisoned
/// mutex already implies a previous panic, and there is no useful recovery
/// path from inside `Drop`.
struct InFlightGuard {
    set: Arc<std::sync::Mutex<HashSet<String>>>,
    key: String,
}

impl Drop for InFlightGuard {
    fn drop(&mut self) {
        if let Ok(mut s) = self.set.lock() {
            s.remove(&self.key);
        }
    }
}

/// Internal spawn parameters that carry Phase 2 metadata (session id + raw
/// instructions bytes) — used by both the live spawn path and the resume path.
struct InternalSpawnArgs {
    name: String,
    team_name: String,
    team_uuid: String,
    cli: String,
    model: String,
    working_directory: String,
    cli_path: Option<String>,
    app_socket_path: Option<String>,
    /// Raw instruction bytes (None ⇒ no `--append-system-prompt`).
    instructions: Option<Vec<u8>>,
    agent_name_override: Option<String>,
    /// Required when `cli == "claude"` — the daemon-generated UUID.
    claude_session_id: Option<String>,
    /// Whether this is a resume of an existing claude session.
    resume_claude: bool,
    /// Phase 2.5: existing cumulative usage to seed counters with (resume /
    /// unpark path). None ⇒ fresh zero counters.
    preloaded_usage: Option<meta::UsageTotals>,
    /// Extra CLI arguments appended after the standard args.
    extra_args: Vec<String>,
    /// Extra environment variables merged into the subprocess env.
    extra_env: std::collections::HashMap<String, String>,
    /// Auto-recycle threshold from AgentSpec (None = off).
    auto_recycle_every: Option<u32>,
    /// Pre-loaded completed_task_count for resume/unpark paths.
    preloaded_completed_task_count: u32,
}

impl HeadlessManager {
    pub fn new() -> Self {
        let cfg = meta::load_config();
        Self {
            agents: HashMap::new(),
            teams: HashMap::new(),
            idle_park_minutes: cfg.idle_park_minutes,
            current_runbook_digest_hash: None,
            current_claude_cli_version: None,
            archive_in_flight: Arc::new(std::sync::Mutex::new(HashSet::new())),
        }
    }

    #[allow(dead_code)] // exposed for diagnostics + future RPC
    pub fn idle_park_minutes(&self) -> u32 {
        self.idle_park_minutes
    }

    pub fn set_idle_park_minutes(&mut self, minutes: u32) -> Result<(), String> {
        if minutes > 1440 {
            return Err("minutes must be 0..=1440".into());
        }
        self.idle_park_minutes = minutes;
        meta::save_config(&meta::DaemonConfig {
            schema: meta::SCHEMA_VERSION,
            idle_park_minutes: minutes,
        })
    }

    /// Public RPC entry for `headless.spawn` (legacy single-agent spawn).
    pub async fn spawn_agent(&mut self, params: SpawnParams) -> Result<AgentInfo, String> {
        // Legacy callers may not have an associated on-disk team — spawn the
        // agent without writing metadata so the v0 behavior is preserved.
        // (Phase 2 metadata lives in create_team / resume_team paths.)
        let id = format!("{}@{}", params.name, params.team_name);
        if self.agents.contains_key(&id) {
            return Err(format!("agent already exists: {id}"));
        }

        // Resolve team_uuid if a live Phase 2 team exists, else use empty
        // string sentinel (legacy path; no disk writes).
        let team_uuid = self
            .teams
            .get(&params.team_name)
            .map(|t| t.team_uuid.clone())
            .unwrap_or_default();

        let session_id = if params.cli == "claude" {
            Some(meta::new_uuid())
        } else {
            None
        };

        let instructions_bytes = params.instructions.as_ref().map(|s| s.as_bytes().to_vec());

        let internal = InternalSpawnArgs {
            name: params.name.clone(),
            team_name: params.team_name.clone(),
            team_uuid,
            cli: params.cli.clone(),
            model: params.model.clone(),
            working_directory: params.working_directory.clone(),
            cli_path: params.cli_path.clone(),
            app_socket_path: params.app_socket_path.clone(),
            instructions: instructions_bytes,
            agent_name_override: params.agent_name_override.clone(),
            claude_session_id: session_id.clone(),
            resume_claude: false,
            preloaded_usage: None,
            extra_args: Vec::new(),
            extra_env: std::collections::HashMap::new(),
            auto_recycle_every: None,
            preloaded_completed_task_count: 0,
        };

        self.spawn_internal(internal).await
    }

    /// Core spawn — used by both `spawn_agent` and `create_team`.
    async fn spawn_internal(&mut self, args: InternalSpawnArgs) -> Result<AgentInfo, String> {
        let id = format!("{}@{}", args.name, args.team_name);
        if self.agents.contains_key(&id) {
            return Err(format!("agent already exists: {id}"));
        }

        let daemon_socket = cli_builder::daemon_socket_path()
            .to_string_lossy()
            .to_string();

        let cmd = match args.cli.as_str() {
            "kiro" => cli_builder::build_kiro_command(
                &args.name,
                &args.team_name,
                &args.model,
                &daemon_socket,
                args.cli_path.as_deref(),
                args.app_socket_path.as_deref(),
                &args.extra_args,
                &args.extra_env,
            ),
            "codex" => cli_builder::build_codex_command(
                &args.name,
                &args.team_name,
                &args.model,
                &daemon_socket,
                args.cli_path.as_deref(),
                args.app_socket_path.as_deref(),
                &args.extra_args,
                &args.extra_env,
            ),
            "gemini" => cli_builder::build_gemini_command(
                &args.name,
                &args.team_name,
                &args.model,
                &daemon_socket,
                args.cli_path.as_deref(),
                args.app_socket_path.as_deref(),
                &args.extra_args,
                &args.extra_env,
            ),
            _ => {
                let session_id = args
                    .claude_session_id
                    .clone()
                    .ok_or_else(|| "internal: claude spawn missing session_id".to_string())?;
                let mode = if args.resume_claude {
                    cli_builder::ClaudeSpawnMode::Resume { session_id }
                } else {
                    cli_builder::ClaudeSpawnMode::Fresh { session_id }
                };
                cli_builder::build_claude_command(
                    &args.name,
                    &args.team_name,
                    &args.model,
                    &args.working_directory,
                    &daemon_socket,
                    args.cli_path.as_deref(),
                    args.app_socket_path.as_deref(),
                    args.instructions.as_deref(),
                    mode,
                    &args.extra_args,
                    &args.extra_env,
                )
            }
        };

        tracing::info!(
            "spawning headless agent: {} (cli={}, model={}, dir={}, resume={})",
            id,
            args.cli,
            args.model,
            args.working_directory,
            args.resume_claude
        );

        let mut command = Command::new(&cmd.program);
        command
            .args(&cmd.args)
            .envs(cmd.env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .current_dir(&args.working_directory)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        // Each CLI agent gets its own process group (pid == pgid) so that
        // killpg can reap grandchildren (MCP servers, sub-shells, etc.).
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }

        if let Some(ref name_override) = args.agent_name_override {
            command.env("TERMMESH_AGENT_NAME", name_override);
            command.env(
                "TERMMESH_AGENT_ID",
                format!("{name_override}@{}", args.team_name),
            );
        }

        for key in &cmd.env_remove {
            command.env_remove(key);
        }

        let mut child = command
            .spawn()
            .map_err(|e| format!("failed to spawn '{}': {e}", cmd.program))?;

        let pid = child.id().ok_or("failed to get child PID")?;
        let stdin = child.stdin.take().ok_or("failed to capture stdin")?;
        let stdout = child.stdout.take().ok_or("failed to capture stdout")?;
        let stderr = child.stderr.take().ok_or("failed to capture stderr")?;

        let stdout_buffer = Arc::new(Mutex::new(OutputBuffer::new(10_000)));
        let last_activity_ms = Arc::new(std::sync::atomic::AtomicU64::new(now_ms()));

        // Phase 2.5: per-agent usage counters. Seed from any preloaded
        // snapshot (resume / unpark).
        let usage_counters: Arc<UsageCounters> = match args.preloaded_usage.as_ref() {
            Some(t) => UsageCounters::from_persisted(t),
            None => Arc::new(UsageCounters::default()),
        };

        // Phase 2.5: parse usage from stdout only for claude (stream-json).
        let parse_usage_for_this_cli = args.cli == "claude";
        let buf_clone = stdout_buffer.clone();
        let id_clone = id.clone();
        let activity_clone = last_activity_ms.clone();
        let usage_clone = usage_counters.clone();
        // Phase B2: auto-reply detector wire-up. TUI agents (Claude/Codex) often
        // print the STATUS/FILES/VERIFY/NEXT/FULL_REPORT header in their response
        // but skip invoking `tm-agent reply`, leaving tasks stuck. The detector
        // observes their stdout and synthesises the reply when the agent forgets.
        // Disable via TERMMESH_AUTO_REPLY=off.
        let auto_reply_enabled = std::env::var("TERMMESH_AUTO_REPLY")
            .map(|v| !matches!(v.trim().to_lowercase().as_str(), "off" | "0" | "false" | "no"))
            .unwrap_or(true);
        let ar_team = args.team_name.clone();
        let ar_agent = args.name.clone();
        let ar_socket = args.app_socket_path.clone();
        let ar_last_hash = Arc::new(std::sync::Mutex::new(None::<u64>));
        tokio::spawn(async move {
            use crate::auto_reply::AutoReplyDetector;
            let mut reader = BufReader::new(stdout).lines();
            let mut detector = AutoReplyDetector::new();
            let mut tick_timer = tokio::time::interval(std::time::Duration::from_millis(200));
            // Skip the first immediate tick — it would fire before any input arrives.
            tick_timer.tick().await;

            loop {
                tokio::select! {
                    line_result = reader.next_line() => {
                        match line_result {
                            Ok(Some(line)) => {
                                activity_clone.store(now_ms(), std::sync::atomic::Ordering::Relaxed);
                                if parse_usage_for_this_cli {
                                    if let Some(u) = parse_usage_from_line(&line) {
                                        usage_clone.observe(&u, now_ms());
                                    }
                                }
                                buf_clone.lock().await.push(line.clone());

                                if auto_reply_enabled {
                                    let now = std::time::Instant::now();
                                    // Detector is line-based and adds its own newline
                                    // handling internally; push line + "\n" to match.
                                    let mut payload = line.into_bytes();
                                    payload.push(b'\n');
                                    if let Some(ev) = detector.push_bytes(&payload, now) {
                                        try_emit_auto_reply(
                                            &ar_team,
                                            &ar_agent,
                                            ar_socket.as_deref(),
                                            &ar_last_hash,
                                            ev,
                                        ).await;
                                    }
                                }
                            }
                            Ok(None) | Err(_) => break,
                        }
                    }
                    _ = tick_timer.tick(), if auto_reply_enabled => {
                        if let Some(ev) = detector.tick(std::time::Instant::now()) {
                            try_emit_auto_reply(
                                &ar_team,
                                &ar_agent,
                                ar_socket.as_deref(),
                                &ar_last_hash,
                                ev,
                            ).await;
                        }
                    }
                }
            }
            // On reader exit, flush any pending body capture (best effort).
            if auto_reply_enabled {
                if let Some(ev) = detector.flush() {
                    try_emit_auto_reply(
                        &ar_team,
                        &ar_agent,
                        ar_socket.as_deref(),
                        &ar_last_hash,
                        ev,
                    ).await;
                }
            }
            tracing::debug!("stdout reader exited for {id_clone}");
        });

        let buf_clone2 = stdout_buffer.clone();
        let id_clone2 = id.clone();
        tokio::spawn(async move {
            let mut reader = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                buf_clone2.lock().await.push(format!("[stderr] {line}"));
            }
            tracing::debug!("stderr reader exited for {id_clone2}");
        });

        let proto = protocol::protocol_for(&args.cli);

        let now = meta::now_unix();

        let info = AgentInfo {
            id: id.clone(),
            name: args.name.clone(),
            cli: args.cli.clone(),
            model: args.model.clone(),
            team_name: args.team_name.clone(),
            working_directory: args.working_directory.clone(),
            status: AgentStatus::Running,
            pid,
            created_at: now,
            output_lines: 0,
            session_id: args.claude_session_id.clone(),
            parked: false,
        };

        self.agents.insert(
            id.clone(),
            HeadlessAgent {
                id,
                name: args.name,
                cli: args.cli,
                model: args.model,
                team_name: args.team_name,
                team_uuid: args.team_uuid,
                working_directory: args.working_directory,
                child: Some(child),
                stdin: Some(stdin),
                stdout_buffer,
                protocol: proto,
                status: AgentStatus::Running,
                pid,
                created_at: now,
                session_id: args.claude_session_id,
                last_activity_ms,
                parked: false,
                usage: usage_counters,
                auto_recycle_every: args.auto_recycle_every,
                completed_task_count: args.preloaded_completed_task_count,
            },
        );

        Ok(info)
    }

    /// Reap naturally-exited children using non-blocking try_wait.
    /// Call at the entry of RPC handlers so stale Running entries are cleared
    /// before any logic that depends on agent.status or agent.stdin.
    fn reap_exited_agents(&mut self) {
        for a in self.agents.values_mut() {
            if a.status == AgentStatus::Running {
                if let Some(child) = a.child.as_mut() {
                    if matches!(child.try_wait(), Ok(Some(_))) {
                        a.status = AgentStatus::Terminated;
                        a.stdin = None; // closes parent write-end fd
                        a.child = None; // drops reaped child handle
                    }
                }
            }
        }
    }

    /// Send a message to a headless agent's stdin via its protocol adapter.
    pub async fn send_message(&mut self, agent_id: &str, text: &str) -> Result<(), String> {
        self.reap_exited_agents();
        let agent = self
            .agents
            .get_mut(agent_id)
            .ok_or_else(|| format!("agent not found: {agent_id}"))?;

        if agent.status == AgentStatus::Terminated || agent.status == AgentStatus::Parked {
            return Err(format!("agent is {:?}: {agent_id}", agent.status));
        }

        let bytes = agent.protocol.encode_message(text);
        let close_stdin = agent.protocol.closes_stdin_after_message();
        let stdin = agent
            .stdin
            .as_mut()
            .ok_or_else(|| format!("agent has no stdin: {agent_id}"))?;
        stdin
            .write_all(&bytes)
            .await
            .map_err(|e| format!("write to stdin failed: {e}"))?;
        stdin
            .flush()
            .await
            .map_err(|e| format!("flush stdin failed: {e}"))?;

        // codex exec - reads the whole prompt then blocks on stdin EOF before it
        // starts; drop stdin so the child sees end-of-input. claude keeps stdin
        // open for multi-turn stream-json, so close_stdin is false there.
        if close_stdin {
            agent.stdin = None;
        }

        // Reset idle tracker on outbound activity (§5.2).
        agent
            .last_activity_ms
            .store(now_ms(), std::sync::atomic::Ordering::Relaxed);

        tracing::debug!("sent {} bytes to {agent_id}", bytes.len());
        Ok(())
    }

    /// Whether `team_name` is a daemon-managed headless team. False means the
    /// team's panes live in the Swift app (a GUI team) — §4's watch routing uses
    /// this to pick the pane-recycle path over a headless one-shot spawn.
    pub fn has_team(&self, team_name: &str) -> bool {
        self.teams.contains_key(team_name)
    }

    pub async fn read_output(&mut self, agent_id: &str, lines: usize) -> Result<Vec<String>, String> {
        self.reap_exited_agents();
        let agent = self
            .agents
            .get(agent_id)
            .ok_or_else(|| format!("agent not found: {agent_id}"))?;

        let buf = agent.stdout_buffer.lock().await;
        Ok(buf.tail(lines).iter().map(|s| s.to_string()).collect())
    }

    /// Terminate a headless agent subprocess and remove it from the manager.
    pub async fn terminate(&mut self, agent_id: &str) -> Result<(), String> {
        let pid = {
            let agent = self
                .agents
                .get(agent_id)
                .ok_or_else(|| format!("agent not found: {agent_id}"))?;
            if agent.status == AgentStatus::Terminated || agent.status == AgentStatus::Parked {
                self.agents.remove(agent_id);
                return Ok(());
            }
            agent.pid
        };

        tracing::info!("terminating headless agent: {agent_id} (pid={pid})");

        // Kill the entire process group (pid == pgid after setsid in pre_exec),
        // so grandchildren (MCP servers, sub-shells) are reaped too.
        signal_agent_process_group(pid, libc::SIGTERM)?;

        if let Some(agent) = self.agents.get_mut(agent_id) {
            if let Some(child) = agent.child.as_mut() {
                let wait_result =
                    tokio::time::timeout(std::time::Duration::from_secs(5), child.wait()).await;
                match wait_result {
                    Ok(Ok(_)) => {
                        tracing::debug!("agent {agent_id} exited gracefully");
                    }
                    _ => {
                        tracing::warn!("agent {agent_id} did not exit within 5s, sending SIGKILL");
                        signal_agent_process_group(pid, libc::SIGKILL)?;
                        let _ = child.wait().await;
                    }
                }
            }
        }

        self.agents.remove(agent_id);
        Ok(())
    }

    pub async fn status(&mut self, agent_id: &str) -> Result<AgentInfo, String> {
        self.reap_exited_agents();
        let agent = self
            .agents
            .get(agent_id)
            .ok_or_else(|| format!("agent not found: {agent_id}"))?;

        let output_lines = agent.stdout_buffer.lock().await.len();

        Ok(AgentInfo {
            id: agent.id.clone(),
            name: agent.name.clone(),
            cli: agent.cli.clone(),
            model: agent.model.clone(),
            team_name: agent.team_name.clone(),
            working_directory: agent.working_directory.clone(),
            status: agent.status,
            pid: agent.pid,
            created_at: agent.created_at,
            output_lines,
            session_id: agent.session_id.clone(),
            parked: agent.parked,
        })
    }

    pub async fn list(&mut self, team_name: Option<&str>) -> Vec<AgentInfo> {
        self.reap_exited_agents();
        let mut result = Vec::new();
        for agent in self.agents.values() {
            if let Some(tn) = team_name {
                if agent.team_name != tn {
                    continue;
                }
            }
            let output_lines = agent.stdout_buffer.lock().await.len();
            result.push(AgentInfo {
                id: agent.id.clone(),
                name: agent.name.clone(),
                cli: agent.cli.clone(),
                model: agent.model.clone(),
                team_name: agent.team_name.clone(),
                working_directory: agent.working_directory.clone(),
                status: agent.status,
                pid: agent.pid,
                created_at: agent.created_at,
                output_lines,
                session_id: agent.session_id.clone(),
                parked: agent.parked,
            });
        }
        result
    }

    /// Create a headless team: register team metadata and spawn all agents.
    pub async fn create_team(&mut self, params: TeamCreateParams) -> Result<HeadlessTeam, String> {
        if self.teams.contains_key(&params.team_name) {
            return Err(format!("team_name_in_use: {}", params.team_name));
        }

        // Validate / generate team_uuid.
        let team_uuid = match params.team_uuid.as_deref() {
            Some(s) => meta::parse_uuid(s)?,
            None => meta::new_uuid(),
        };

        // Reject if a live team with the same uuid already exists.
        if self.teams.values().any(|t| t.team_uuid == team_uuid) {
            return Err(format!("team_already_live: {team_uuid}"));
        }

        // Validate agent names early — BEFORE any subprocess spawn or disk write.
        for spec in &params.agents {
            meta::validate_agent_name(&spec.name)?;
        }

        let now = meta::now_unix();
        let mut agent_ids: Vec<String> = Vec::new();
        let mut written_paths: Vec<std::path::PathBuf> = Vec::new();

        // Determine leader_mode/model for metadata.
        let leader_mode = params
            .leader_mode
            .clone()
            .unwrap_or_else(|| "claude".into());
        let leader_model = params
            .leader_model
            .clone()
            .unwrap_or_else(|| "sonnet".into());

        // Pre-create the team dir + agents + instructions subdirs so partial
        // failures are easier to clean up.
        let _ = meta::create_dir_secure(&meta::team_dir(&team_uuid));
        let _ = meta::create_dir_secure(&meta::agents_subdir(&team_uuid));
        let _ = meta::create_dir_secure(&meta::instructions_subdir(&team_uuid));

        // Build provisional agent metadata first (so we can write it).
        let mut agent_metas: Vec<meta::AgentMeta> = Vec::new();

        for spec in &params.agents {
            let provided_session = params
                .session_ids
                .as_ref()
                .and_then(|m| m.get(&spec.name))
                .cloned();
            // Validate provided session UUID if present.
            let session_id = if spec.cli == "claude" {
                if let Some(s) = provided_session {
                    Some(meta::parse_uuid(&s)?)
                } else {
                    Some(meta::new_uuid())
                }
            } else {
                None
            };

            // Fold any custom_instructions (e.g. watcher --spec) into the
            // effective instructions so they persist (sha256 + instructions/<name>.txt)
            // and reach the CLI as --append-system-prompt. R7 (watcher-only) is
            // enforced by the client, which only attaches custom_instructions to
            // the watcher agent.
            let instr_bytes = merge_instructions(
                spec.instructions.as_deref(),
                spec.custom_instructions.as_deref(),
            )
            .map(String::into_bytes)
            .filter(|b| !b.is_empty());
            let instr_hash = instr_bytes.as_ref().map(|b| meta::sha256_hex(b));

            let agent_meta = meta::AgentMeta {
                schema: meta::SCHEMA_VERSION,
                team_uuid: team_uuid.clone(),
                name: spec.name.clone(),
                agent_type: spec.agent_type.clone().unwrap_or_else(|| spec.name.clone()),
                cli: spec.cli.clone(),
                model: spec.model.clone(),
                session_id: session_id.clone(),
                color: spec.color.clone(),
                created_at: now,
                instructions_sha256: instr_hash,
                cli_path_at_create: spec.cli_path.clone(),
                parked: false,
                usage_total: None,
                extra_args: spec.extra_args.clone(),
                extra_env: spec.extra_env.clone(),
                auto_recycle_every: spec.auto_recycle_every,
                completed_task_count: 0,
            };

            // Persist instructions (raw bytes) + agent.json before spawn so a
            // crash mid-create leaves recoverable metadata.
            if let Some(ref bytes) = instr_bytes {
                if let Err(e) = meta::write_instructions(&team_uuid, &spec.name, bytes) {
                    return Err(format!("metadata write failed: {e}"));
                }
                written_paths.push(meta::instructions_path(&team_uuid, &spec.name));
            }
            if let Err(e) = meta::write_agent_meta(&agent_meta) {
                return Err(format!("metadata write failed: {e}"));
            }
            written_paths.push(meta::agent_json_path(&team_uuid, &spec.name));

            agent_metas.push(agent_meta);
        }

        // Write team.json (no destroyed_at).
        let leader_session_id = if params.leader_session_id.is_empty() {
            None
        } else {
            Some(params.leader_session_id.clone())
        };
        let team_meta = meta::TeamMeta {
            schema: meta::SCHEMA_VERSION,
            team_uuid: team_uuid.clone(),
            team_name: params.team_name.clone(),
            created_at: now,
            destroyed_at: None,
            working_directory: params.working_directory.clone(),
            git_root: params.git_root.clone(),
            git_branch_at_create: params.git_branch_at_create.clone(),
            leader: meta::LeaderMeta {
                mode: leader_mode,
                model: leader_model,
                session_id: leader_session_id,
            },
            agents: params.agents.iter().map(|s| s.name.clone()).collect(),
            worktree: params.worktree.as_ref().map(|w| meta::WorktreeMeta {
                mode: w.mode.clone(),
                path: w.path.clone(),
                branch: w.branch.clone(),
            }),
            execution_mode: "headless".into(),
            claude_cli_version: params.claude_cli_version.clone(),
            termmesh_app_version: params
                .termmesh_app_version
                .clone()
                .unwrap_or_else(|| env!("CARGO_PKG_VERSION").into()),
            app_socket_path_at_create: params.app_socket_path.clone(),
            runbook_digest_hash: params.runbook_digest_hash.clone(),
        };
        if let Err(e) = meta::write_team_meta(&team_meta) {
            // Cleanup written metadata.
            let _ = std::fs::remove_dir_all(meta::team_dir(&team_uuid));
            return Err(format!("metadata write failed: {e}"));
        }

        // Now spawn all agents. On failure, terminate already-spawned, then
        // also remove disk metadata (the team never went live).
        let resume_claude = params.session_ids.is_some();
        for (spec, agent_meta) in params.agents.iter().zip(agent_metas.iter()) {
            // Use the SAME merged instructions as the persisted metadata above so
            // the live process's --append-system-prompt matches instructions/<name>.txt
            // (and the resume-time sha256 check). Folds in watcher --spec.
            let instr_bytes = merge_instructions(
                spec.instructions.as_deref(),
                spec.custom_instructions.as_deref(),
            )
            .map(String::into_bytes)
            .filter(|b| !b.is_empty());

            let internal = InternalSpawnArgs {
                name: spec.name.clone(),
                team_name: params.team_name.clone(),
                team_uuid: team_uuid.clone(),
                cli: spec.cli.clone(),
                model: spec.model.clone(),
                working_directory: params.working_directory.clone(),
                cli_path: spec.cli_path.clone(),
                app_socket_path: params.app_socket_path.clone(),
                instructions: instr_bytes,
                agent_name_override: None,
                claude_session_id: agent_meta.session_id.clone(),
                resume_claude,
                // create_team always starts fresh counters; resume_team has
                // its own path that seeds preloaded_usage from disk.
                preloaded_usage: None,
                extra_args: spec.extra_args.clone(),
                extra_env: spec.extra_env.clone(),
                auto_recycle_every: spec.auto_recycle_every,
                preloaded_completed_task_count: 0,
            };

            match self.spawn_internal(internal).await {
                Ok(info) => agent_ids.push(info.id),
                Err(e) => {
                    tracing::error!(
                        "create_team: spawn failed for '{}': {e}, rolling back",
                        spec.name
                    );
                    for id in &agent_ids {
                        let _ = self.terminate(id).await;
                    }
                    let _ = std::fs::remove_dir_all(meta::team_dir(&team_uuid));
                    return Err(format!("cli_spawn_failed: {}: {e}", spec.name));
                }
            }
        }

        let team = HeadlessTeam {
            name: params.team_name.clone(),
            team_uuid,
            agents: agent_ids,
            working_directory: params.working_directory,
            leader_session_id: params.leader_session_id,
            created_at: now,
        };
        self.teams.insert(params.team_name, team.clone());
        Ok(team)
    }

    /// Destroy a headless team. On disk: rewrite team.json with destroyed_at,
    /// then rename `<uuid>/` -> `<uuid>.archived.<ts>/`.
    pub async fn destroy_team(&mut self, team_name: &str) -> Result<DestroyResult, String> {
        // Phase 2.5: flush any pending usage counters for this team before
        // the agent records are removed.
        let flushed = self.flush_dirty_usage_for_team(team_name);
        if flushed > 0 {
            tracing::debug!("destroy_team({team_name}): flushed {flushed} usage record(s)");
        }

        let team = self
            .teams
            .remove(team_name)
            .ok_or_else(|| format!("team_not_found: {team_name}"))?;

        for agent_id in &team.agents {
            if let Err(e) = self.terminate(agent_id).await {
                tracing::warn!("failed to terminate agent {agent_id}: {e}");
            }
        }
        for agent_id in &team.agents {
            self.agents.remove(agent_id);
        }

        // Update on-disk metadata (best-effort — disk divergence is preferable
        // to a stuck in-memory team; see contract §3.2).
        let destroyed_at = meta::now_unix();
        let mut archived_path: Option<String> = None;
        let team_dir = meta::team_dir(&team.team_uuid);
        if team_dir.exists() {
            match meta::read_team_meta(&team_dir) {
                Ok(mut meta_struct) => {
                    meta_struct.destroyed_at = Some(destroyed_at);
                    if let Err(e) = meta::write_team_meta(&meta_struct) {
                        tracing::warn!("destroy: failed to rewrite team.json: {e}");
                    }
                }
                Err(e) => {
                    tracing::warn!("destroy: failed to read team.json for {team_name}: {e}");
                    // Migration stub for pre-Phase-2 teams (§8).
                    let stub = make_pre_phase2_stub(&team, destroyed_at);
                    let _ = meta::create_dir_secure(&meta::team_dir(&team.team_uuid));
                    let _ = meta::write_team_meta(&stub);
                }
            }
            match meta::rename_to_archived(&team.team_uuid, destroyed_at) {
                Ok(p) => archived_path = Some(p.to_string_lossy().into_owned()),
                Err(e) => tracing::warn!("destroy: rename failed for {team_name}: {e}"),
            }
        } else {
            // Pre-Phase-2 team — emit a migration stub (§8).
            let stub = make_pre_phase2_stub(&team, destroyed_at);
            let _ = meta::create_dir_secure(&meta::team_dir(&team.team_uuid));
            if meta::write_team_meta(&stub).is_ok() {
                if let Ok(p) = meta::rename_to_archived(&team.team_uuid, destroyed_at) {
                    archived_path = Some(p.to_string_lossy().into_owned());
                }
            }
        }

        tracing::info!("destroyed headless team: {team_name}");
        Ok(DestroyResult {
            team_uuid: team.team_uuid,
            archived_path,
        })
    }

    // ────────────────────────────────────────────────────────────────────────
    // Pane-mode archive / resume
    //
    // pane-mode teams live entirely in the Swift app (the daemon has no live
    // record of them). On destroy, the app calls `team.archive_pane` with a
    // payload assembled from its in-memory `Team` struct; the daemon writes
    // the same `team.json` / `agents/*.json` layout headless uses and renames
    // the dir to `.archived.<ts>` so `list_resumable` picks it up. The
    // `execution_mode` field on `TeamMeta` distinguishes the two modes so
    // resume routing can branch.
    // ────────────────────────────────────────────────────────────────────────

    pub fn archive_pane_team(
        &mut self,
        params: ArchivePaneParams,
    ) -> Result<ArchivePaneResult, String> {
        // D1: team_uuid grace mode. Swift already holds Team.teamUuid; future
        // versions will hard-reject missing/empty uuids with `invalid_params`.
        let team_uuid = match params.team_uuid.as_deref() {
            Some(s) if !s.is_empty() => meta::parse_uuid(s)?,
            _ => {
                let fallback = meta::new_uuid();
                tracing::warn!(
                    "archive_pane: missing team_uuid for team_name={} — falling back to {} (grace mode; future versions will reject)",
                    params.team_name,
                    fallback
                );
                fallback
            }
        };

        // D2: in-flight guard. Reject concurrent archive of the same uuid so
        // two racing callers can't trample each other's rename step. The
        // returned `InFlightGuard` releases the slot on Drop — covers `?`
        // early-return, normal return, AND panic unwind.
        let _in_flight = {
            let mut guard = self
                .archive_in_flight
                .lock()
                .map_err(|e| format!("archive_in_flight lock poisoned: {e}"))?;
            if !guard.insert(team_uuid.clone()) {
                return Err(format!(
                    "in_flight: archive already running for team_uuid={team_uuid}"
                ));
            }
            drop(guard);
            InFlightGuard {
                set: Arc::clone(&self.archive_in_flight),
                key: team_uuid.clone(),
            }
        };

        let now = meta::now_unix();

        // D2: replace-in-place. Drop any prior archived dirs for this uuid
        // plus any orphan live dir from a crashed/aborted previous run.
        let mut replaced = false;
        match meta::list_archived_teams() {
            Ok(entries) => {
                for e in entries.into_iter().filter(|e| e.team_uuid == team_uuid) {
                    match std::fs::remove_dir_all(&e.archived_dir) {
                        Ok(_) => {
                            replaced = true;
                            tracing::info!(
                                "archive_pane: replaced stale archive {} (uuid={})",
                                e.archived_dir.display(),
                                team_uuid
                            );
                        }
                        Err(err) => {
                            tracing::warn!(
                                "archive_pane: failed to remove stale archive {}: {err}",
                                e.archived_dir.display()
                            );
                        }
                    }
                }
            }
            Err(err) => {
                tracing::warn!("archive_pane: scan archived dirs failed: {err}");
            }
        }
        let live_dir = meta::team_dir(&team_uuid);
        if live_dir.exists() {
            std::fs::remove_dir_all(&live_dir)
                .map_err(|err| format!("clear orphan live dir {}: {err}", live_dir.display()))?;
            replaced = true;
            tracing::info!(
                "archive_pane: cleared orphan live dir {} (uuid={})",
                live_dir.display(),
                team_uuid
            );
        }

        // Build TeamMeta — mirrors headless format with execution_mode = "pane".
        let team_meta = meta::TeamMeta {
            schema: meta::SCHEMA_VERSION,
            team_uuid: team_uuid.clone(),
            team_name: params.team_name.clone(),
            created_at: now,
            destroyed_at: Some(now),
            working_directory: params.working_directory.clone(),
            git_root: params.git_root.clone(),
            git_branch_at_create: params.git_branch_at_create.clone(),
            leader: meta::LeaderMeta {
                mode: params.leader_mode.clone(),
                model: params.leader_model.clone(),
                session_id: Some(params.leader_session_id.clone())
                    .filter(|s| !s.is_empty()),
            },
            agents: params.agents.iter().map(|a| a.name.clone()).collect(),
            worktree: match (
                params.worktree_mode.as_deref(),
                params.worktree_path.as_deref(),
                params.worktree_branch.as_deref(),
            ) {
                (Some(m), Some(p), Some(b)) if !m.is_empty() && !p.is_empty() => {
                    Some(meta::WorktreeMeta {
                        mode: m.to_string(),
                        path: p.to_string(),
                        branch: b.to_string(),
                    })
                }
                _ => None,
            },
            execution_mode: "pane".to_string(),
            claude_cli_version: None,
            termmesh_app_version: params
                .termmesh_app_version
                .clone()
                .unwrap_or_else(|| "unknown".to_string()),
            app_socket_path_at_create: None,
            runbook_digest_hash: None,
        };

        meta::create_dir_secure(&meta::team_dir(&team_uuid))
            .map_err(|e| format!("create team dir: {e}"))?;
        meta::create_dir_secure(&meta::agents_subdir(&team_uuid))
            .map_err(|e| format!("create agents subdir: {e}"))?;
        meta::create_dir_secure(&meta::instructions_subdir(&team_uuid))
            .map_err(|e| format!("create instructions subdir: {e}"))?;

        meta::write_team_meta(&team_meta)?;

        for a in &params.agents {
            let instr_bytes = a.instructions.as_deref().unwrap_or("").as_bytes();
            let instr_sha = if instr_bytes.is_empty() {
                None
            } else {
                Some(meta::sha256_hex(instr_bytes))
            };
            if !instr_bytes.is_empty() {
                meta::write_instructions(&team_uuid, &a.name, instr_bytes)?;
            }
            let agent_meta = meta::AgentMeta {
                schema: meta::SCHEMA_VERSION,
                team_uuid: team_uuid.clone(),
                name: a.name.clone(),
                agent_type: a.agent_type.clone(),
                cli: a.cli.clone(),
                model: a.model.clone(),
                session_id: a.session_id.clone().filter(|s| !s.is_empty()),
                color: a.color.clone(),
                created_at: now,
                instructions_sha256: instr_sha,
                cli_path_at_create: None,
                parked: false,
                usage_total: None,
                extra_args: Vec::new(),
                extra_env: std::collections::HashMap::new(),
                auto_recycle_every: None,
                completed_task_count: 0,
            };
            meta::write_agent_meta(&agent_meta)?;
        }

        let archived = meta::rename_to_archived(&team_uuid, now)?;
        tracing::info!(
            "archived pane-mode team {} ({}) → {} (replaced={replaced})",
            params.team_name,
            team_uuid,
            archived.display()
        );
        Ok(ArchivePaneResult {
            team_uuid: team_uuid.clone(),
            archived_path: archived.to_string_lossy().into_owned(),
            replaced,
        })
        // `_in_flight` drops here, removing the slot.
    }

    /// Resume metadata for a pane-mode archive. Returns the team meta + per-agent
    /// session IDs / instructions so the Swift app can recreate the workspace
    /// and spawn each CLI with `--resume <sid>`. Renames `.archived.<ts>` back
    /// to live so the dir won't be GC'd while the resume flow runs (the app
    /// owns the in-memory lifecycle once it has the metadata).
    pub fn resume_pane(&self, params: ResumePaneParams) -> Result<ResumePaneResult, String> {
        let team_uuid = meta::parse_uuid(&params.team_uuid)?;
        // Find the archived dir for this UUID.
        let archived_entries = meta::list_archived_teams()
            .map_err(|e| format!("scan archived: {e}"))?;
        let entry = archived_entries
            .into_iter()
            .find(|e| e.team_uuid == team_uuid)
            .ok_or_else(|| format!("no archive for team_uuid={team_uuid}"))?;

        // Promote archived → live so future operations can find it under team_dir().
        let live_dir = meta::rename_to_live(&entry.archived_dir, &team_uuid)?;
        let team_meta = meta::read_team_meta(&live_dir)?;
        if team_meta.team_uuid != team_uuid {
            return Err(format!(
                "uuid mismatch in archive: dir={team_uuid} file={}",
                team_meta.team_uuid
            ));
        }

        let mut agents = Vec::with_capacity(team_meta.agents.len());
        for agent_name in &team_meta.agents {
            let am = meta::read_agent_meta(&team_uuid, agent_name)?;
            let instr = match meta::read_instructions(&team_uuid, agent_name) {
                Ok(bytes) => String::from_utf8(bytes).ok(),
                Err(_) => None,
            };
            agents.push(ResumePaneAgent {
                name: am.name,
                agent_type: am.agent_type,
                cli: am.cli,
                model: am.model,
                color: am.color,
                session_id: am.session_id,
                instructions: instr,
            });
        }

        Ok(ResumePaneResult {
            team_uuid: team_meta.team_uuid,
            team_name: team_meta.team_name,
            created_at: team_meta.created_at,
            destroyed_at: team_meta.destroyed_at,
            working_directory: team_meta.working_directory,
            git_root: team_meta.git_root,
            leader: team_meta.leader,
            agents,
            worktree: team_meta.worktree,
        })
    }

    /// Delete a single archived team on demand. Mirrors what `gc_sweep` does
    /// after `ARCHIVE_RETENTION_SECS`, but available immediately from the
    /// resume picker so users can drop archives they no longer need. Returns
    /// `deleted: false` (without error) when the uuid has no archive — keeps
    /// the UI idempotent (clicking delete after another machine already swept
    /// shouldn't surface as an error).
    pub fn delete_archive(&self, params: DeleteArchiveParams) -> Result<DeleteArchiveResult, String> {
        let team_uuid = meta::parse_uuid(&params.team_uuid)?;
        let entries = meta::list_archived_teams()
            .map_err(|e| format!("scan archived: {e}"))?;
        let entry = match entries.into_iter().find(|e| e.team_uuid == team_uuid) {
            Some(e) => e,
            None => {
                return Ok(DeleteArchiveResult {
                    team_uuid,
                    deleted: false,
                });
            }
        };
        std::fs::remove_dir_all(&entry.archived_dir)
            .map_err(|e| format!("remove {}: {e}", entry.archived_dir.display()))?;
        tracing::info!(
            "manually deleted archived team {} ({})",
            entry.archived_dir.display(),
            team_uuid
        );
        Ok(DeleteArchiveResult {
            team_uuid,
            deleted: true,
        })
    }

    pub fn list_teams(&self) -> Vec<&HeadlessTeam> {
        self.teams.values().collect()
    }

    #[allow(dead_code)]
    pub fn get_team(&self, team_name: &str) -> Option<&HeadlessTeam> {
        self.teams.get(team_name)
    }

    pub async fn terminate_all(&mut self) {
        let team_names: Vec<String> = self.teams.keys().cloned().collect();
        for name in team_names {
            let _ = self.destroy_team(&name).await;
        }
        let agent_ids: Vec<String> = self.agents.keys().cloned().collect();
        for id in agent_ids {
            let _ = self.terminate(&id).await;
        }
        self.agents.clear();
    }

    /// Recycle the agent identified by the fully-qualified `name@team_name` key.
    /// Loads persisted AgentMeta + instructions so the fresh subprocess retains
    /// its role instructions, CLI profile (extra_args/extra_env), and cli_path.
    /// Returns Err if AgentMeta cannot be read (abort — silent context drop is
    /// worse than a refused recycle).
    ///
    /// Requires both `agent_name` and `team_name` to form an unambiguous key.
    /// Callers that only have the agent name must supply the team name from
    /// their own context (e.g. the task.update request's `team_name` param).
    pub async fn recycle_by_name(&mut self, agent_name: &str, team_name: &str) {
        if let Err(e) = self.recycle_by_name_inner(agent_name, team_name).await {
            tracing::warn!("auto-recycle: aborted for {agent_name}@{team_name}: {e}");
        }
    }

    async fn recycle_by_name_inner(
        &mut self,
        agent_name: &str,
        team_name: &str,
    ) -> Result<(), String> {
        let id = format!("{agent_name}@{team_name}");

        // Snapshot team_uuid and working_directory from live agent state.
        let (team_uuid, working_directory) = {
            let agent = self
                .agents
                .get(&id)
                .ok_or_else(|| format!("agent not found for key '{id}'"))?;
            (agent.team_uuid.clone(), agent.working_directory.clone())
        };

        // Load persisted team metadata to recover app_socket_path_at_create.
        let app_socket_path = meta::read_team_meta(&meta::team_dir(&team_uuid))
            .ok()
            .and_then(|tm| tm.app_socket_path_at_create);

        // Load persisted metadata — abort if corrupt (same policy as unpark).
        let agent_meta = meta::read_agent_meta(&team_uuid, agent_name)
            .map_err(|e| format!("corrupt_metadata: {e}"))?;

        // Load persisted instructions bytes (verify hash if present).
        let instructions_bytes = match agent_meta.instructions_sha256.as_deref() {
            Some(expected) => {
                let bytes = meta::read_instructions(&team_uuid, agent_name)
                    .map_err(|_| "corrupt_metadata: instructions missing".to_string())?;
                let actual = meta::sha256_hex(&bytes);
                if actual != expected {
                    return Err("corrupt_metadata: instructions hash mismatch".into());
                }
                Some(bytes)
            }
            None => None,
        };

        let args = InternalSpawnArgs {
            name: agent_name.to_string(),
            team_name: team_name.to_string(),
            team_uuid: team_uuid.clone(),
            cli: agent_meta.cli.clone(),
            model: agent_meta.model.clone(),
            working_directory,
            cli_path: agent_meta.cli_path_at_create.clone(),
            app_socket_path,
            instructions: instructions_bytes,
            agent_name_override: None,
            // Fresh session — Claude transcript is intentionally discarded on recycle.
            claude_session_id: Some(uuid::Uuid::new_v4().to_string()),
            resume_claude: false,
            preloaded_usage: None,
            // Carry CLI profile forward (extra_args, extra_env).
            extra_args: agent_meta.extra_args.clone(),
            extra_env: agent_meta.extra_env.clone(),
            // Carry recycle threshold; reset completed count to 0.
            auto_recycle_every: agent_meta.auto_recycle_every,
            preloaded_completed_task_count: 0,
        };

        tracing::info!("auto-recycle: terminating agent {id}");
        let _ = self.terminate(&id).await;

        tracing::info!("auto-recycle: respawning agent {}@{}", args.name, args.team_name);
        self.spawn_internal(args)
            .await
            .map(|info| {
                tracing::info!("auto-recycle: respawned agent {} (pid={})", info.id, info.pid);
            })
            .map_err(|e| format!("cli_spawn_failed: {e}"))
    }

    /// Called when a task assigned to `agent_name` in `team_name` transitions to
    /// Completed. Increments the agent's completed_task_count and triggers
    /// recycle_by_name when the effective threshold is hit.
    pub async fn handle_auto_recycle_completion_by_name(
        &mut self,
        agent_name: &str,
        team_name: &str,
    ) {
        let id = format!("{agent_name}@{team_name}");
        let agent = match self.agents.get_mut(&id) {
            Some(a) => a,
            None => return,
        };
        let threshold = match agent.auto_recycle_every {
            Some(n) if n > 0 => n,
            _ => return,
        };
        agent.completed_task_count += 1;
        // Mark dirty so the 30s flush persists the new count.
        agent.usage.flush_dirty.store(true, std::sync::atomic::Ordering::Release);
        let count = agent.completed_task_count;
        if count % threshold == 0 {
            tracing::info!(
                "auto-recycle: headless agent {id} hit threshold ({count}/{threshold}), recycling"
            );
            self.recycle_by_name(agent_name, team_name).await;
        }
    }

    pub async fn add_agent(
        &mut self,
        team_name: &str,
        spec: AgentSpec,
        app_socket_path: Option<&str>,
    ) -> Result<AgentInfo, String> {
        meta::validate_agent_name(&spec.name)?;

        let (team_uuid, working_directory) = {
            let team = self
                .teams
                .get(team_name)
                .ok_or_else(|| format!("team_not_found: {team_name}"))?;
            (team.team_uuid.clone(), team.working_directory.clone())
        };

        let agent_id = format!("{}@{}", spec.name, team_name);
        if self.agents.contains_key(&agent_id) {
            return Err(format!(
                "agent '{}' already exists in team '{}'",
                spec.name, team_name
            ));
        }

        // Generate session_id for claude.
        let session_id = if spec.cli == "claude" {
            Some(meta::new_uuid())
        } else {
            None
        };

        let instr_bytes = spec
            .instructions
            .as_ref()
            .map(|s| s.as_bytes().to_vec())
            .filter(|b| !b.is_empty());
        let instr_hash = instr_bytes.as_ref().map(|b| meta::sha256_hex(b));

        // Persist metadata if the team has a metadata dir.
        let team_dir_exists = meta::team_dir(&team_uuid).exists();
        if team_dir_exists {
            let agent_meta = meta::AgentMeta {
                schema: meta::SCHEMA_VERSION,
                team_uuid: team_uuid.clone(),
                name: spec.name.clone(),
                agent_type: spec.agent_type.clone().unwrap_or_else(|| spec.name.clone()),
                cli: spec.cli.clone(),
                model: spec.model.clone(),
                session_id: session_id.clone(),
                color: spec.color.clone(),
                created_at: meta::now_unix(),
                instructions_sha256: instr_hash,
                cli_path_at_create: spec.cli_path.clone(),
                parked: false,
                usage_total: None,
                extra_args: spec.extra_args.clone(),
                extra_env: spec.extra_env.clone(),
                auto_recycle_every: spec.auto_recycle_every,
                completed_task_count: 0,
            };
            if let Some(ref bytes) = instr_bytes {
                let _ = meta::write_instructions(&team_uuid, &spec.name, bytes);
            }
            let _ = meta::write_agent_meta(&agent_meta);
            // Append to team.json:agents[] (best-effort).
            if let Ok(mut tm) = meta::read_team_meta(&meta::team_dir(&team_uuid)) {
                if !tm.agents.contains(&spec.name) {
                    tm.agents.push(spec.name.clone());
                    let _ = meta::write_team_meta(&tm);
                }
            }
        }

        let internal = InternalSpawnArgs {
            name: spec.name.clone(),
            team_name: team_name.to_string(),
            team_uuid,
            cli: spec.cli,
            model: spec.model,
            working_directory,
            cli_path: spec.cli_path,
            app_socket_path: app_socket_path.map(String::from),
            instructions: instr_bytes,
            agent_name_override: None,
            claude_session_id: session_id,
            resume_claude: false,
            preloaded_usage: None,
            extra_args: spec.extra_args,
            extra_env: spec.extra_env,
            auto_recycle_every: spec.auto_recycle_every,
            preloaded_completed_task_count: 0,
        };

        let info = self.spawn_internal(internal).await?;

        match self.teams.get_mut(team_name) {
            Some(team) => {
                team.agents.push(info.id.clone());
            }
            None => {
                tracing::error!(
                    "team '{}' disappeared after spawn, rolling back agent '{}'",
                    team_name,
                    info.id
                );
                let _ = self.terminate(&info.id).await;
                self.agents.remove(&info.id);
                return Err(format!(
                    "team '{}' was removed during agent spawn",
                    team_name
                ));
            }
        }

        Ok(info)
    }

    #[allow(dead_code)]
    pub fn is_headless(&self, agent_id: &str) -> bool {
        self.agents.contains_key(agent_id)
    }

    pub fn resolve_agent_id(&self, team_name: &str, agent_name: &str) -> Option<String> {
        let id = format!("{agent_name}@{team_name}");
        if self.agents.contains_key(&id) {
            Some(id)
        } else {
            None
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // Phase 2: park / unpark
    // ────────────────────────────────────────────────────────────────────

    /// Park an agent: terminate the subprocess, preserve metadata on disk.
    pub async fn park_agent(
        &mut self,
        team_name: &str,
        agent_name: &str,
    ) -> Result<ParkResult, String> {
        let team_uuid = self
            .teams
            .get(team_name)
            .ok_or_else(|| format!("team_not_found: {team_name}"))?
            .team_uuid
            .clone();

        let agent_id = format!("{agent_name}@{team_name}");
        let agent = self
            .agents
            .get_mut(&agent_id)
            .ok_or_else(|| format!("agent_not_found: {agent_id}"))?;

        if agent.parked || agent.status == AgentStatus::Parked {
            return Err(format!("agent_already_parked: {agent_name}"));
        }
        if agent.status == AgentStatus::Terminated {
            return Err(format!("agent_terminated: {agent_name}"));
        }

        let pid = agent.pid;
        let session_id = agent.session_id.clone();

        // SIGTERM then wait.
        signal_agent_process_group(pid, libc::SIGTERM)?;
        if let Some(child) = agent.child.as_mut() {
            let _ = tokio::time::timeout(std::time::Duration::from_secs(5), child.wait()).await;
        }
        signal_agent_process_group(pid, libc::SIGKILL)?;
        if let Some(child) = agent.child.as_mut() {
            let _ = child.wait().await;
        }

        agent.parked = true;
        agent.status = AgentStatus::Parked;
        agent.child = None;
        agent.stdin = None;

        // Phase 2.5: snapshot current usage so the same rewrite of agent.json
        // can carry it. Consumes the flush-dirty bit (don't double-flush).
        let usage_snapshot = if agent.usage.take_flush_dirty() {
            Some(agent.usage.snapshot())
        } else {
            None
        };

        // Update agent.json:parked = true (and usage_total if dirty).
        if let Ok(mut meta_struct) = meta::read_agent_meta(&team_uuid, agent_name) {
            meta_struct.parked = true;
            if let Some(snap) = usage_snapshot {
                meta_struct.usage_total = Some(snap);
            }
            let _ = meta::write_agent_meta(&meta_struct);
        }

        Ok(ParkResult {
            parked: true,
            agent_name: agent_name.to_string(),
            session_id,
        })
    }

    /// Unpark a parked agent: re-spawn with stored session_id and instructions.
    pub async fn unpark_agent(
        &mut self,
        team_name: &str,
        agent_name: &str,
        app_socket_path: Option<&str>,
    ) -> Result<AgentInfo, String> {
        let (team_uuid, working_directory) = {
            let team = self
                .teams
                .get(team_name)
                .ok_or_else(|| format!("team_not_found: {team_name}"))?;
            (team.team_uuid.clone(), team.working_directory.clone())
        };

        let agent_id = format!("{agent_name}@{team_name}");
        let agent = self
            .agents
            .get(&agent_id)
            .ok_or_else(|| format!("agent_not_found: {agent_id}"))?;
        if !agent.parked && agent.status != AgentStatus::Parked {
            return Err(format!("agent_not_parked: {agent_name}"));
        }

        let agent_meta = meta::read_agent_meta(&team_uuid, agent_name)
            .map_err(|e| format!("corrupt_metadata: {e}"))?;

        // Claude: session_id required.
        if agent_meta.cli == "claude" && agent_meta.session_id.is_none() {
            return Err("no_session".into());
        }

        // Verify instructions hash if present.
        let instructions_bytes = match agent_meta.instructions_sha256.as_deref() {
            Some(expected) => {
                let bytes = meta::read_instructions(&team_uuid, agent_name)
                    .map_err(|_| "corrupt_metadata: instructions_hash".to_string())?;
                let actual = meta::sha256_hex(&bytes);
                if actual != expected {
                    return Err("corrupt_metadata: instructions_hash".into());
                }
                Some(bytes)
            }
            None => None,
        };

        // Remove the parked stub entry so spawn_internal can re-insert.
        self.agents.remove(&agent_id);

        let internal = InternalSpawnArgs {
            name: agent_name.to_string(),
            team_name: team_name.to_string(),
            team_uuid: team_uuid.clone(),
            cli: agent_meta.cli.clone(),
            model: agent_meta.model.clone(),
            working_directory,
            cli_path: agent_meta.cli_path_at_create.clone(),
            app_socket_path: app_socket_path.map(String::from),
            instructions: instructions_bytes,
            agent_name_override: None,
            claude_session_id: agent_meta.session_id.clone(),
            resume_claude: agent_meta.cli == "claude",
            // Phase 2.5: carry usage forward through park→unpark.
            preloaded_usage: agent_meta.usage_total.clone(),
            // Carry CLI profile forward through park→unpark.
            extra_args: agent_meta.extra_args.clone(),
            extra_env: agent_meta.extra_env.clone(),
            // Carry recycle config + count forward through park→unpark.
            auto_recycle_every: agent_meta.auto_recycle_every,
            preloaded_completed_task_count: agent_meta.completed_task_count,
        };

        let info = self
            .spawn_internal(internal)
            .await
            .map_err(|e| format!("cli_spawn_failed: {e}"))?;

        // Update on-disk parked flag.
        if let Ok(mut m) = meta::read_agent_meta(&team_uuid, agent_name) {
            m.parked = false;
            let _ = meta::write_agent_meta(&m);
        }

        Ok(info)
    }

    /// Walk all agents and SIGTERM any claude agent whose idle window exceeds
    /// the configured threshold. Returns `(team_name, agent_name)` of parked
    /// agents (caller logs / emits events).
    pub async fn idle_park_sweep(&mut self) -> Vec<(String, String)> {
        if self.idle_park_minutes == 0 {
            return Vec::new();
        }
        let threshold_ms = (self.idle_park_minutes as u64) * 60 * 1000;
        let now = now_ms();

        // Collect candidates first to avoid borrow issues.
        let candidates: Vec<(String, String)> = self
            .agents
            .values()
            .filter(|a| {
                if a.parked || a.status != AgentStatus::Running || a.cli != "claude" {
                    return false;
                }
                let last = a
                    .last_activity_ms
                    .load(std::sync::atomic::Ordering::Relaxed);
                now.saturating_sub(last) >= threshold_ms
            })
            .map(|a| (a.team_name.clone(), a.name.clone()))
            .collect();

        let mut parked = Vec::new();
        for (team, agent) in candidates {
            match self.park_agent(&team, &agent).await {
                Ok(_) => {
                    tracing::info!("idle auto-park: {agent}@{team}");
                    parked.push((team, agent));
                }
                Err(e) => {
                    tracing::warn!("idle auto-park failed for {agent}@{team}: {e}");
                }
            }
        }
        parked
    }

    // ────────────────────────────────────────────────────────────────────
    // Phase 2.5: token usage broadcast + disk flush
    // ────────────────────────────────────────────────────────────────────

    /// Collect a usage-tick snapshot for every team that has at least one
    /// agent with `broadcast_dirty == true`. Clears the broadcast-dirty bit
    /// for each emitted agent. Returns an empty vec if no team is dirty.
    ///
    /// Cheap and lock-free apart from grabbing the `&self` borrow — does no
    /// disk I/O.
    pub fn collect_usage_tick(&self) -> Vec<UsageTickTeam> {
        // Group dirty agents by team_uuid.
        let mut by_team: HashMap<String, (String, Vec<UsageTickAgent>)> = HashMap::new();
        for agent in self.agents.values() {
            if !agent.usage.take_broadcast_dirty() {
                continue;
            }
            let snap = agent.usage.snapshot();
            let entry = by_team
                .entry(agent.team_uuid.clone())
                .or_insert_with(|| (agent.team_name.clone(), Vec::new()));
            entry.1.push(UsageTickAgent {
                name: agent.name.clone(),
                input_tokens: snap.input_tokens,
                output_tokens: snap.output_tokens,
                cache_read_input_tokens: snap.cache_read_input_tokens,
                cache_creation_input_tokens: snap.cache_creation_input_tokens,
            });
        }

        by_team
            .into_iter()
            .filter(|(_, (_, agents))| !agents.is_empty())
            .map(|(team_uuid, (team_name, agents))| UsageTickTeam {
                team_uuid,
                team_name,
                agents,
            })
            .collect()
    }

    /// Flush every agent whose `flush_dirty` bit is set to disk by rewriting
    /// its `agent.json` with the current `usage_total` snapshot. Clears the
    /// flush-dirty bit on success. Disk I/O happens on the current task —
    /// callers should invoke via `tokio::task::spawn_blocking` from hot paths.
    ///
    /// Best-effort: failures are logged but do not propagate. Returns the
    /// number of agents successfully flushed.
    pub fn flush_dirty_usage(&self) -> usize {
        let mut flushed = 0usize;
        // Snapshot candidates first to bound the lock window per agent.
        let candidates: Vec<(String, String, meta::UsageTotals, u32, Option<u32>)> = self
            .agents
            .values()
            .filter_map(|a| {
                if !a.usage.take_flush_dirty() {
                    return None;
                }
                if a.team_uuid.is_empty() {
                    // Legacy spawn path without on-disk metadata — nothing to
                    // flush. The dirty bit is consumed (no point retrying).
                    return None;
                }
                Some((a.team_uuid.clone(), a.name.clone(), a.usage.snapshot(), a.completed_task_count, a.auto_recycle_every))
            })
            .collect();

        for (team_uuid, name, snap, completed, recycle_every) in candidates {
            match meta::read_agent_meta(&team_uuid, &name) {
                Ok(mut m) => {
                    m.usage_total = Some(snap);
                    m.completed_task_count = completed;
                    m.auto_recycle_every = recycle_every;
                    if let Err(e) = meta::write_agent_meta(&m) {
                        tracing::warn!(
                            "usage flush: write agent.json failed for {name}@{team_uuid}: {e}"
                        );
                    } else {
                        flushed += 1;
                    }
                }
                Err(e) => {
                    tracing::warn!(
                        "usage flush: read agent.json failed for {name}@{team_uuid}: {e}"
                    );
                }
            }
        }
        flushed
    }

    /// Force-flush dirty usage for every agent belonging to `team_name`.
    /// Intended for `destroy_team` / `park` paths where we want disk to
    /// reflect the final state before the agent record may be removed.
    pub fn flush_dirty_usage_for_team(&self, team_name: &str) -> usize {
        let mut flushed = 0usize;
        let candidates: Vec<(String, String, meta::UsageTotals, u32, Option<u32>)> = self
            .agents
            .values()
            .filter_map(|a| {
                if a.team_name != team_name {
                    return None;
                }
                if !a.usage.take_flush_dirty() {
                    return None;
                }
                if a.team_uuid.is_empty() {
                    return None;
                }
                Some((a.team_uuid.clone(), a.name.clone(), a.usage.snapshot(), a.completed_task_count, a.auto_recycle_every))
            })
            .collect();
        for (team_uuid, name, snap, completed, recycle_every) in candidates {
            if let Ok(mut m) = meta::read_agent_meta(&team_uuid, &name) {
                m.usage_total = Some(snap);
                m.completed_task_count = completed;
                m.auto_recycle_every = recycle_every;
                if meta::write_agent_meta(&m).is_ok() {
                    flushed += 1;
                }
            }
        }
        flushed
    }

    // ────────────────────────────────────────────────────────────────────
    // Phase 2: list_resumable / resume_team
    // ────────────────────────────────────────────────────────────────────

    /// Pure-data version of `list_resumable` — does no validity probing.
    /// Validity probing (worktree exists, branch_now, etc.) is layered on top
    /// by the RPC handler in `list_resumable_with_validity`.
    pub fn list_resumable(
        &self,
        git_root_filter: Option<&str>,
        limit: usize,
    ) -> ListResumableResult {
        // D4: lazy zombie sweep — drop pane archives that can never be resumed
        // (leader + all agents lack session_id) so the picker never shows them.
        // Cheap relative to the scan that follows; cleans up immediately after
        // a buggy/aborted archive instead of waiting for the periodic timer.
        let zombies = meta::sweep_zombie_pane_archives();
        if zombies > 0 {
            tracing::info!(
                "headless gc: removed {zombies} zombie pane archive(s) during list_resumable"
            );
        }

        let archived = match meta::list_archived_teams() {
            Ok(v) => v,
            Err(e) => {
                return ListResumableResult {
                    teams: Vec::new(),
                    scanned: 0,
                    skipped: 0,
                    fatal_error: Some(format!("cannot read headless dir: {e}")),
                }
            }
        };

        let mut scanned = 0usize;
        let mut skipped = 0usize;
        let mut rows: Vec<ResumableTeam> = Vec::new();

        for entry in archived {
            scanned += 1;
            let team_meta = match meta::read_team_meta(&entry.archived_dir) {
                Ok(m) => m,
                Err(e) => {
                    skipped += 1;
                    tracing::warn!("list_resumable: skip {}: {e}", entry.archived_dir.display());
                    continue;
                }
            };
            if team_meta.team_uuid != entry.team_uuid {
                skipped += 1;
                tracing::warn!(
                    "list_resumable: uuid mismatch in {} (dir={}, file={})",
                    entry.archived_dir.display(),
                    entry.team_uuid,
                    team_meta.team_uuid
                );
                continue;
            }

            // Filter by git_root if requested.
            if let Some(filter) = git_root_filter {
                let canonical_filter = std::fs::canonicalize(filter)
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_else(|_| filter.to_string());
                match team_meta.git_root.as_deref() {
                    Some(r) if r == filter => {}
                    Some(r) if r == canonical_filter => {}
                    _ => continue,
                }
            }

            let agent_metas = meta::read_all_agent_metas(&entry.archived_dir, &entry.team_uuid);
            let mut agent_rows = Vec::new();
            let mut all_present = true;
            let mut corrupt = false;
            for name in &team_meta.agents {
                match agent_metas.get(name) {
                    Some(m) => {
                        let has_session = m.session_id.is_some();
                        let has_instr = m.instructions_sha256.is_some();
                        if m.cli == "claude" && !has_session {
                            all_present = false;
                        }
                        agent_rows.push(ResumableAgent {
                            name: m.name.clone(),
                            agent_type: m.agent_type.clone(),
                            cli: m.cli.clone(),
                            model: m.model.clone(),
                            color: m.color.clone(),
                            has_session,
                            has_instructions: has_instr,
                        });
                    }
                    None => {
                        corrupt = true;
                        all_present = false;
                    }
                }
            }
            if corrupt {
                skipped += 1;
                tracing::warn!(
                    "list_resumable: corrupt agents in {}",
                    entry.archived_dir.display()
                );
                continue;
            }

            // Validity probing.
            let working_directory = team_meta.working_directory.clone();
            let git_branch_now = current_branch_at(&working_directory);
            let worktree_status = team_meta.worktree.as_ref().map(|w| {
                let canonical_recorded =
                    std::fs::canonicalize(&w.path).map(|p| p.to_string_lossy().into_owned());
                let exists = match &canonical_recorded {
                    Ok(actual) => actual == &w.path,
                    Err(_) => false,
                };
                let branch_now = if exists {
                    current_branch_at(&w.path)
                } else {
                    None
                };
                WorktreeStatus {
                    mode: w.mode.clone(),
                    path: w.path.clone(),
                    branch: w.branch.clone(),
                    exists,
                    branch_now,
                }
            });

            let worktree_exists = worktree_status.as_ref().map(|w| w.exists).unwrap_or(true); // no worktree ⇒ vacuously OK
            let branch_matches = match (
                team_meta.git_branch_at_create.as_deref(),
                worktree_status
                    .as_ref()
                    .and_then(|w| w.branch_now.as_deref())
                    .or(git_branch_now.as_deref()),
            ) {
                (Some(a), Some(b)) => a == b,
                (None, None) => true,
                _ => false,
            };
            let runbook_matches = match (
                team_meta.runbook_digest_hash.as_deref(),
                self.current_runbook_digest_hash.as_deref(),
            ) {
                (Some(a), Some(b)) => a == b,
                (None, _) => true, // no recorded hash ⇒ skip the check
                _ => true,
            };
            let cli_version_matches = match (
                team_meta.claude_cli_version.as_deref(),
                self.current_claude_cli_version.as_deref(),
            ) {
                (Some(a), Some(b)) => a == b,
                (None, _) => true,
                _ => true,
            };
            let has_any_session = team_meta
                .leader
                .session_id
                .as_deref()
                .map(|s| !s.is_empty())
                .unwrap_or(false)
                || agent_rows.iter().any(|a| a.has_session);
            let sessions_resumable = if team_meta.execution_mode == "pane" {
                has_any_session
            } else {
                all_present
            };
            let resumable = worktree_exists && sessions_resumable;
            let blocking_reason = if !worktree_exists {
                Some("worktree_gone".to_string())
            } else if !sessions_resumable {
                Some("no_sessions".to_string())
            } else {
                None
            };

            rows.push(ResumableTeam {
                team_uuid: team_meta.team_uuid.clone(),
                team_name: team_meta.team_name.clone(),
                created_at: team_meta.created_at,
                destroyed_at: team_meta
                    .destroyed_at
                    .unwrap_or(entry.destroyed_at_from_suffix),
                working_directory,
                git_root: team_meta.git_root.clone(),
                git_branch_at_create: team_meta.git_branch_at_create.clone(),
                git_branch_now,
                worktree: worktree_status,
                agents: agent_rows,
                validity: ResumableValidity {
                    worktree_exists,
                    branch_matches,
                    runbook_matches,
                    cli_version_matches,
                    all_sessions_present: all_present,
                },
                resumable,
                blocking_reason,
                mode: team_meta.execution_mode.clone(),
                leader_session_id: team_meta.leader.session_id.clone(),
            });

            if rows.len() >= limit {
                break;
            }
        }

        // Sort destroyed_at desc, then team_name asc.
        rows.sort_by(|a, b| {
            b.destroyed_at
                .cmp(&a.destroyed_at)
                .then(a.team_name.cmp(&b.team_name))
        });

        ListResumableResult {
            teams: rows,
            scanned,
            skipped,
            fatal_error: None,
        }
    }

    /// Resume a team. Thin wrapper that reads metadata then calls `create_team`
    /// with session_ids/team_uuid populated.
    pub async fn resume_team(
        &mut self,
        params: ResumeTeamParams,
    ) -> Result<ResumeTeamResult, String> {
        let team_uuid = meta::parse_uuid(&params.team_uuid)?;

        // Live counterpart?
        if self.teams.values().any(|t| t.team_uuid == team_uuid) {
            return Err(format!("team_already_live: {team_uuid}"));
        }

        // Locate archived dir.
        let archived =
            meta::list_archived_teams().map_err(|e| format!("cannot read headless dir: {e}"))?;
        let archived_entry = archived
            .into_iter()
            .find(|e| e.team_uuid == team_uuid)
            .ok_or_else(|| format!("team_not_found: {team_uuid}"))?;

        let team_meta = meta::read_team_meta(&archived_entry.archived_dir)
            .map_err(|e| format!("corrupt_metadata: team.json: {e}"))?;

        let team_name = params
            .team_name_override
            .clone()
            .unwrap_or_else(|| team_meta.team_name.clone());

        if self.teams.contains_key(&team_name) {
            return Err(format!("team_name_in_use: {team_name}"));
        }

        // Load all agent metas.
        let agent_metas = meta::read_all_agent_metas(&archived_entry.archived_dir, &team_uuid);
        for name in &team_meta.agents {
            if !agent_metas.contains_key(name) {
                return Err(format!("corrupt_metadata: agents/{name}.json"));
            }
        }

        // Worktree existence check.
        if let Some(w) = team_meta.worktree.as_ref() {
            let canonical =
                std::fs::canonicalize(&w.path).map(|p| p.to_string_lossy().into_owned());
            match canonical {
                Ok(actual) if actual == w.path => {}
                _ => return Err("worktree_gone".into()),
            }
        }

        // Branch drift check.
        if !params.accept_branch_drift {
            let now_branch = team_meta
                .worktree
                .as_ref()
                .and_then(|w| current_branch_at(&w.path))
                .or_else(|| current_branch_at(&team_meta.working_directory));
            if let (Some(was), Some(now)) = (
                team_meta.git_branch_at_create.as_deref(),
                now_branch.as_deref(),
            ) {
                if was != now {
                    return Err("branch_drift_rejected".into());
                }
            }
        }

        // Sessions present?
        let mut session_ids = HashMap::new();
        for (name, m) in &agent_metas {
            if m.cli != "claude" {
                continue;
            }
            match m.session_id.as_ref() {
                Some(id) => {
                    session_ids.insert(name.clone(), id.clone());
                }
                None => return Err("no_sessions".into()),
            }
        }
        if session_ids.is_empty() {
            return Err("no_sessions".into());
        }

        // Verify instructions integrity.
        for (name, m) in &agent_metas {
            if let Some(expected) = m.instructions_sha256.as_deref() {
                let bytes = meta::read_instructions(&team_uuid, name).or_else(|_| {
                    // The archived dir was just located but is not yet renamed
                    // to live — read from the archived path directly.
                    std::fs::read(
                        archived_entry
                            .archived_dir
                            .join("instructions")
                            .join(format!("{name}.txt")),
                    )
                });
                let bytes = bytes.map_err(|_| "corrupt_metadata: instructions_hash".to_string())?;
                if meta::sha256_hex(&bytes) != expected {
                    return Err("corrupt_metadata: instructions_hash".into());
                }
            }
        }

        // Rename to live BEFORE spawning (so spawn_internal reads instructions
        // from the live dir, and so a parallel resume gets team_already_live).
        let _live_dir = meta::rename_to_live(&archived_entry.archived_dir, &team_uuid)?;
        let now = meta::now_unix();

        // Spawn each agent directly with raw bytes read from disk. This
        // bypasses the AgentSpec.instructions String round-trip so non-UTF-8
        // instructions (rare but contractually mandated) survive verbatim.
        let mut spawned_ids: Vec<String> = Vec::new();
        let agent_names = team_meta.agents.clone();
        for name in &agent_names {
            let m = agent_metas.get(name).unwrap().clone();
            let instr_bytes = if m.instructions_sha256.is_some() {
                Some(
                    std::fs::read(meta::instructions_path(&team_uuid, name))
                        .map_err(|e| format!("corrupt_metadata: instructions read failed: {e}"))?,
                )
            } else {
                None
            };

            let internal = InternalSpawnArgs {
                name: name.clone(),
                team_name: team_name.clone(),
                team_uuid: team_uuid.clone(),
                cli: m.cli.clone(),
                model: m.model.clone(),
                working_directory: team_meta.working_directory.clone(),
                cli_path: m.cli_path_at_create.clone(),
                app_socket_path: params.app_socket_path.clone(),
                instructions: instr_bytes,
                agent_name_override: None,
                claude_session_id: m.session_id.clone(),
                resume_claude: m.cli == "claude",
                // Phase 2.5: carry usage forward through destroy→resume.
                preloaded_usage: m.usage_total.clone(),
                // Carry CLI profile forward through destroy→resume.
                extra_args: m.extra_args.clone(),
                extra_env: m.extra_env.clone(),
                // Carry recycle config + count forward through destroy→resume.
                auto_recycle_every: m.auto_recycle_every,
                preloaded_completed_task_count: m.completed_task_count,
            };

            match self.spawn_internal(internal).await {
                Ok(info) => spawned_ids.push(info.id),
                Err(e) => {
                    // Full rollback: terminate already-spawned, rename back to
                    // archived.
                    for id in &spawned_ids {
                        let _ = self.terminate(id).await;
                    }
                    let suffix = archived_entry.destroyed_at_from_suffix;
                    let _ = std::fs::rename(
                        meta::team_dir(&team_uuid),
                        meta::headless_root().join(format!("{team_uuid}.archived.{suffix}")),
                    );
                    return Err(format!("cli_spawn_failed: {name}: {e}"));
                }
            }

            // Mark agent unparked on disk (resume always unparks).
            if m.parked {
                let mut m2 = m.clone();
                m2.parked = false;
                let _ = meta::write_agent_meta(&m2);
            }
        }

        // Rewrite team.json with destroyed_at = null.
        let mut live_meta = team_meta.clone();
        live_meta.destroyed_at = None;
        live_meta.team_name = team_name.clone();
        let _ = meta::write_team_meta(&live_meta);

        let leader_sid = if params.leader_session_id.is_empty() {
            String::new()
        } else {
            params.leader_session_id.clone()
        };
        let team = HeadlessTeam {
            name: team_name.clone(),
            team_uuid: team_uuid.clone(),
            agents: spawned_ids,
            working_directory: team_meta.working_directory.clone(),
            leader_session_id: leader_sid,
            created_at: now,
        };
        self.teams.insert(team_name.clone(), team.clone());

        // Silence unused warning re: session_ids — it was used for validation
        // above (existence of claude session_ids).
        let _ = session_ids;

        Ok(ResumeTeamResult {
            team,
            resumed: true,
        })
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct DestroyResult {
    pub team_uuid: String,
    pub archived_path: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ParkResult {
    pub parked: bool,
    pub agent_name: String,
    pub session_id: Option<String>,
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct ResumeTeamParams {
    pub team_uuid: String,
    #[serde(default)]
    pub team_name_override: Option<String>,
    pub leader_session_id: String,
    #[serde(default)]
    pub app_socket_path: Option<String>,
    #[serde(default)]
    pub accept_branch_drift: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ResumeTeamResult {
    #[serde(flatten)]
    pub team: HeadlessTeam,
    pub resumed: bool,
}

// ────────────────────────────────────────────────────────────────────────────
// Pane-mode archive params/result
// ────────────────────────────────────────────────────────────────────────────

/// Params for `team.archive_pane` — the Swift app calls this from
/// `TeamOrchestrator.destroyTeam` to persist a pane-mode team archive so it
/// shows up in `headless.list_resumable` (with `mode: "pane"`).
#[derive(Debug, Clone, serde::Deserialize)]
pub struct ArchivePaneParams {
    #[serde(default)]
    pub team_uuid: Option<String>,
    pub team_name: String,
    pub leader_session_id: String,
    pub leader_mode: String,
    pub leader_model: String,
    pub working_directory: String,
    #[serde(default)]
    pub git_root: Option<String>,
    #[serde(default)]
    pub git_branch_at_create: Option<String>,
    #[serde(default)]
    pub worktree_mode: Option<String>,
    #[serde(default)]
    pub worktree_path: Option<String>,
    #[serde(default)]
    pub worktree_branch: Option<String>,
    pub agents: Vec<ArchivePaneAgent>,
    #[serde(default)]
    pub termmesh_app_version: Option<String>,
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct ArchivePaneAgent {
    pub name: String,
    pub cli: String,
    pub model: String,
    pub agent_type: String,
    #[serde(default)]
    pub color: Option<String>,
    /// claude/codex session id captured by the sidebar token-tracking
    /// infrastructure. None when the agent never opened a session.
    #[serde(default)]
    pub session_id: Option<String>,
    /// Raw instructions bytes (utf-8); written into the archive so resume can
    /// rebuild the agent's role description. May be empty.
    #[serde(default)]
    pub instructions: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ArchivePaneResult {
    pub team_uuid: String,
    pub archived_path: String,
    /// D2: `true` when this call removed at least one prior archive or orphan
    /// live dir for the same `team_uuid` before writing the new archive.
    /// Backward-compatible — older Swift clients ignore unknown fields.
    pub replaced: bool,
}

/// Params for `team.resume_pane` — pure metadata read. Unlike
/// `headless.resume_team` this does NOT spawn subprocesses; the Swift app is
/// responsible for creating the workspace and panes, and consumes the agent
/// `session_id`s here to pass `--resume <sid>` to each CLI.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct ResumePaneParams {
    pub team_uuid: String,
}

/// Params for `team.delete_archive` — remove a single archived team. Mirrors
/// what `gc_sweep` would do after the retention window, but on-demand from the
/// resume picker so users can drop an archive they no longer need.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct DeleteArchiveParams {
    pub team_uuid: String,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct DeleteArchiveResult {
    pub team_uuid: String,
    pub deleted: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ResumePaneResult {
    pub team_uuid: String,
    pub team_name: String,
    pub created_at: u64,
    pub destroyed_at: Option<u64>,
    pub working_directory: String,
    pub git_root: Option<String>,
    pub leader: meta::LeaderMeta,
    pub agents: Vec<ResumePaneAgent>,
    pub worktree: Option<meta::WorktreeMeta>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ResumePaneAgent {
    pub name: String,
    pub agent_type: String,
    pub cli: String,
    pub model: String,
    pub color: Option<String>,
    pub session_id: Option<String>,
    pub instructions: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ResumableAgent {
    pub name: String,
    pub agent_type: String,
    pub cli: String,
    pub model: String,
    pub color: Option<String>,
    pub has_session: bool,
    pub has_instructions: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct WorktreeStatus {
    pub mode: String,
    pub path: String,
    pub branch: String,
    pub exists: bool,
    pub branch_now: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ResumableValidity {
    pub worktree_exists: bool,
    pub branch_matches: bool,
    pub runbook_matches: bool,
    pub cli_version_matches: bool,
    pub all_sessions_present: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ResumableTeam {
    pub team_uuid: String,
    pub team_name: String,
    pub created_at: u64,
    pub destroyed_at: u64,
    pub working_directory: String,
    pub git_root: Option<String>,
    pub git_branch_at_create: Option<String>,
    pub git_branch_now: Option<String>,
    pub worktree: Option<WorktreeStatus>,
    pub agents: Vec<ResumableAgent>,
    pub validity: ResumableValidity,
    pub resumable: bool,
    pub blocking_reason: Option<String>,
    /// "headless" (daemon-managed subprocesses) or "pane" (GUI panes).
    /// Drives resume routing on the client (pane archives use `team.resume_pane`
    /// instead of `headless.resume_team`).
    pub mode: String,
    /// Leader's session id from the archived `team.json`. For pane-mode this
    /// is the actual claude session id (used to look up the leader's last
    /// transcript message for the picker preview); for headless this is the
    /// daemon-spawned leader's session id. May be None when the leader never
    /// produced a session.
    pub leader_session_id: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ListResumableResult {
    pub teams: Vec<ResumableTeam>,
    pub scanned: usize,
    pub skipped: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fatal_error: Option<String>,
}

/// Migration stub for pre-Phase-2 teams (§8).
fn make_pre_phase2_stub(team: &HeadlessTeam, destroyed_at: u64) -> meta::TeamMeta {
    meta::TeamMeta {
        schema: meta::SCHEMA_VERSION,
        team_uuid: team.team_uuid.clone(),
        team_name: team.name.clone(),
        created_at: team.created_at,
        destroyed_at: Some(destroyed_at),
        working_directory: team.working_directory.clone(),
        git_root: None,
        git_branch_at_create: None,
        leader: meta::LeaderMeta {
            mode: "headless".into(),
            model: "sonnet".into(),
            session_id: None,
        },
        agents: team
            .agents
            .iter()
            .filter_map(|id| id.split('@').next().map(String::from))
            .collect(),
        worktree: None,
        execution_mode: "headless".into(),
        claude_cli_version: None,
        termmesh_app_version: env!("CARGO_PKG_VERSION").into(),
        app_socket_path_at_create: None,
        runbook_digest_hash: None,
    }
}

/// Return the current branch at `path` (None if not a repo or detached).
fn current_branch_at(path: &str) -> Option<String> {
    let repo = git2::Repository::discover(path).ok()?;
    let head = repo.head().ok()?;
    head.shorthand().map(|s| s.to_string())
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Best-effort auto-reply emission. Skips when:
/// - no app socket is configured (no GUI side to call back to)
/// - the same event content was just fired (idempotency via content_hash)
///
/// All failures log + drop. Never returns an error — auto-reply must not
/// disrupt the PTY reader loop. Caller is the headless stdout reader task.
async fn try_emit_auto_reply(
    team_name: &str,
    agent_name: &str,
    socket_path: Option<&str>,
    last_hash: &Arc<std::sync::Mutex<Option<u64>>>,
    event: crate::auto_reply::AutoReplyEvent,
) {
    let Some(sock) = socket_path else {
        tracing::debug!(
            "auto-reply skipped: no app socket configured (agent={agent_name})"
        );
        return;
    };
    let hash = event.content_hash();
    {
        let mut guard = last_hash.lock().expect("auto-reply hash lock poisoned");
        if *guard == Some(hash) {
            tracing::debug!(
                "auto-reply skipped: duplicate content hash (agent={agent_name})"
            );
            return;
        }
        *guard = Some(hash);
    }
    match crate::auto_reply_emit::emit(sock, team_name, agent_name, &event).await {
        Ok(true) => tracing::info!(
            "auto-reply emitted: agent={agent_name} status={} task_updated=true",
            event.status
        ),
        Ok(false) => tracing::info!(
            "auto-reply emitted: agent={agent_name} status={} task_updated=false (no matching task)",
            event.status
        ),
        Err(e) => tracing::warn!(
            "auto-reply emit failed: agent={agent_name} status={} err={e}",
            event.status
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::cell::RefCell;

    /// Test-only mutex protecting TERMMESH_HEADLESS_ROOT env var access.
    /// When tests set the env var, they must hold this lock to prevent
    /// parallel tests from overwriting each other's paths.
    static ENV_VAR_LOCK: Mutex<()> = Mutex::new(());

    /// Thread-local cache of the test root path.  Prevents race conditions
    /// where async tasks read stale env vars after another test changes it.
    thread_local! {
        static TEST_HEADLESS_ROOT: RefCell<Option<std::path::PathBuf>> = RefCell::new(None);
    }

    /// RAII guard that holds the env var lock for test duration.
    /// The guard keeps the TempDir alive and holds the mutex until dropped.
    struct ScopedRoot {
        _dir: tempfile::TempDir,
        _lock: std::sync::MutexGuard<'static, ()>,
    }

    impl ScopedRoot {
        /// Get the path to the scoped temp directory.
        fn path(&self) -> &std::path::Path {
            self._dir.path()
        }
    }

    impl Drop for ScopedRoot {
        fn drop(&mut self) {
            // Clear thread-local cache when test ends
            TEST_HEADLESS_ROOT.with(|root| {
                *root.borrow_mut() = None;
            });
        }
    }


    /// Get headless root path from thread-local cache, or fallback to env var.
    fn test_headless_root() -> std::path::PathBuf {
        TEST_HEADLESS_ROOT.with(|root| {
            root.borrow().clone().unwrap_or_else(|| {
                // Fallback: re-read env var. In tests with scoped_root(), this should be
                // the same value cached above (due to env var set by scoped_root).
                // This fallback handles edge cases where cache might not be set.
                meta::headless_root()
            })
        })
    }

    /// Set the thread-local cache of headless root path.
    fn set_test_headless_root(path: std::path::PathBuf) {
        TEST_HEADLESS_ROOT.with(|root| {
            *root.borrow_mut() = Some(path);
        });
    }

    /// Read instructions using cached headless root to avoid race conditions.
    fn test_read_instructions(team_uuid: &str, agent_name: &str) -> std::io::Result<Vec<u8>> {
        let root = test_headless_root();
        let path = root
            .join(team_uuid)
            .join("instructions")
            .join(format!("{agent_name}.txt"));
        std::fs::read(path)
    }

    /// Read agent meta using cached headless root to avoid race conditions.
    fn test_read_agent_meta(team_uuid: &str, name: &str) -> Result<meta::AgentMeta, String> {
        let root = test_headless_root();
        let path = root.join(team_uuid).join("agents").join(format!("{name}.json"));
        std::fs::read(&path)
            .map_err(|e| format!("read {}: {}", path.display(), e))
            .and_then(|bytes| {
                serde_json::from_slice::<meta::AgentMeta>(&bytes)
                    .map_err(|e| format!("parse {}: {}", path.display(), e))
            })
    }

    /// Helper: scope `TERMMESH_HEADLESS_ROOT` to a fresh tmp dir for the test.
    /// The returned guard must be held for the entire test duration to prevent
    /// parallel tests from overwriting each other's paths.
    /// Note: If a previous test panicked while holding the lock, the mutex may
    /// be poisoned. We recover from poisoning with into_inner().
    fn scoped_root() -> ScopedRoot {
        let lock = ENV_VAR_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("TERMMESH_HEADLESS_ROOT", dir.path());
        // Cache path in thread-local to prevent async tasks from reading stale env var.
        let path = dir.path().to_path_buf();
        set_test_headless_root(path);
        ScopedRoot {
            _dir: dir,
            _lock: lock,
        }
    }

    #[test]
    fn merge_instructions_custom_only_passes_through_verbatim() {
        // Headless watcher --spec case: no base preset, only the spec.
        let out = merge_instructions(None, Some("SPEC-SENTINEL-42")).unwrap();
        assert_eq!(out, "SPEC-SENTINEL-42");
    }

    #[test]
    fn merge_instructions_base_only_unchanged() {
        let out = merge_instructions(Some("base prompt"), None).unwrap();
        assert_eq!(out, "base prompt");
    }

    #[test]
    fn merge_instructions_both_appends_custom_block() {
        let out = merge_instructions(Some("base prompt"), Some("SPEC-SENTINEL-42")).unwrap();
        assert_eq!(
            out,
            "base prompt\n\n## Custom Instructions\n\nSPEC-SENTINEL-42"
        );
    }

    #[test]
    fn merge_instructions_empty_inputs_return_none() {
        assert_eq!(merge_instructions(None, None), None);
        assert_eq!(merge_instructions(Some("   "), Some("\n")), None);
    }

    /// End-to-end runtime-artifact proof for the watcher `--spec` fold (F1):
    /// a real `create_team` writes the merged spec to the watcher's persisted
    /// instructions, while a sibling executor (no custom_instructions) gets none.
    /// Uses a fake CLI that just blocks on stdin so spawn succeeds without a real
    /// agent process. Runs against an isolated TERMMESH_HEADLESS_ROOT — never the
    /// live team store.
    /// NOTE: Uses serial_test to prevent parallel test interference via env vars.
    #[tokio::test]
    async fn create_team_folds_watcher_spec_into_persisted_instructions() {
        let root = scoped_root();  // Acquire lock for duration of test
        let root_path = root.path().to_path_buf();
        const SENTINEL: &str = "SPEC-SENTINEL-F1-7f3a";

        // Fake CLI: stays alive reading stdin so spawn_internal succeeds.
        let fake_cli = root_path.join("fake-cli.sh");
        std::fs::write(&fake_cli, "#!/bin/sh\nexec cat >/dev/null 2>&1\n").unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&fake_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let fake_cli = fake_cli.to_string_lossy().to_string();
        let workdir = root_path.to_string_lossy().to_string();

        let params: TeamCreateParams = serde_json::from_value(serde_json::json!({
            "team_name": "f1-verify",
            "working_directory": workdir,
            "agents": [
                {
                    "name": "watcher",
                    "agent_type": "watcher",
                    "cli": "claude",
                    "model": "sonnet",
                    "cli_path": fake_cli,
                    "custom_instructions": SENTINEL,
                },
                {
                    "name": "executor",
                    "agent_type": "executor",
                    "cli": "claude",
                    "model": "sonnet",
                    "cli_path": fake_cli,
                },
            ],
        }))
        .unwrap();

        let mut mgr = HeadlessManager::new();
        let team = mgr.create_team(params).await.expect("create_team");
        let uuid = team.team_uuid.clone();

        // Watcher: spec persisted verbatim + sha256 recorded.
        let watcher_instr = test_read_instructions(&uuid, "watcher")
            .expect("watcher instructions file should exist");
        let watcher_instr = String::from_utf8(watcher_instr).unwrap();
        assert!(
            watcher_instr.contains(SENTINEL),
            "watcher instructions must contain the spec sentinel verbatim, got: {watcher_instr:?}"
        );
        let watcher_meta = test_read_agent_meta(&uuid, "watcher").unwrap();
        assert!(
            watcher_meta.instructions_sha256.is_some(),
            "watcher instructions_sha256 must be set"
        );

        // Executor (R7): no instructions file, no sha256.
        assert!(
            test_read_instructions(&uuid, "executor").is_err(),
            "executor must NOT have an instructions file (R7 watcher-only)"
        );
        let executor_meta = test_read_agent_meta(&uuid, "executor").unwrap();
        assert!(
            executor_meta.instructions_sha256.is_none(),
            "executor instructions_sha256 must be null (R7 watcher-only)"
        );

        let _ = mgr.destroy_team("f1-verify").await;
    }

    #[test]
    fn set_idle_park_minutes_bounds() {
        let _scope = scoped_root();
        let mut mgr = HeadlessManager::new();
        assert!(mgr.set_idle_park_minutes(0).is_ok());
        assert!(mgr.set_idle_park_minutes(30).is_ok());
        assert!(mgr.set_idle_park_minutes(1440).is_ok());
        assert!(mgr.set_idle_park_minutes(1441).is_err());
        assert_eq!(mgr.idle_park_minutes(), 1440);
    }

    #[test]
    fn idle_park_minutes_persisted_across_managers() {
        let _scope = scoped_root();
        {
            let mut mgr = HeadlessManager::new();
            mgr.set_idle_park_minutes(45).unwrap();
        }
        let mgr2 = HeadlessManager::new();
        assert_eq!(mgr2.idle_park_minutes(), 45);
    }

    #[test]
    fn list_resumable_empty_when_no_dirs() {
        let _scope = scoped_root();
        let mgr = HeadlessManager::new();
        let result = mgr.list_resumable(None, 50);
        assert!(result.teams.is_empty());
        assert_eq!(result.scanned, 0);
        assert_eq!(result.skipped, 0);
        assert!(result.fatal_error.is_none());
    }

    #[test]
    fn list_resumable_reads_archived_team() {
        let _scope = scoped_root();
        let team_uuid = "8f3d1a2b-4c5e-4f6a-9b8c-0d1e2f3a4b5c".to_string();
        let destroyed_at = 1715600000u64;

        // Build the archived directory manually.
        let archived_dir =
            meta::headless_root().join(format!("{team_uuid}.archived.{destroyed_at}"));
        let agents_dir = archived_dir.join("agents");
        std::fs::create_dir_all(&agents_dir).unwrap();
        let instr_dir = archived_dir.join("instructions");
        std::fs::create_dir_all(&instr_dir).unwrap();

        let inst_bytes = b"You are explorer. It's a test.";
        std::fs::write(instr_dir.join("explorer.txt"), inst_bytes).unwrap();

        let agent_meta = meta::AgentMeta {
            schema: meta::SCHEMA_VERSION,
            team_uuid: team_uuid.clone(),
            name: "explorer".into(),
            agent_type: "explorer".into(),
            cli: "claude".into(),
            model: "sonnet".into(),
            session_id: Some("1a2b3c4d-1111-2222-3333-444455556666".into()),
            color: Some("green".into()),
            created_at: 1715500000,
            instructions_sha256: Some(meta::sha256_hex(inst_bytes)),
            cli_path_at_create: Some("/opt/homebrew/bin/claude".into()),
            parked: false,
            usage_total: None,
            extra_args: Vec::new(),
            extra_env: std::collections::HashMap::new(),
            auto_recycle_every: None,
            completed_task_count: 0,
        };
        std::fs::write(
            agents_dir.join("explorer.json"),
            serde_json::to_vec_pretty(&agent_meta).unwrap(),
        )
        .unwrap();

        let team_meta = meta::TeamMeta {
            schema: meta::SCHEMA_VERSION,
            team_uuid: team_uuid.clone(),
            team_name: "my-team".into(),
            created_at: 1715500000,
            destroyed_at: Some(destroyed_at),
            working_directory: "/tmp/proj".into(),
            git_root: None,
            git_branch_at_create: None,
            leader: meta::LeaderMeta {
                mode: "claude".into(),
                model: "sonnet".into(),
                session_id: None,
            },
            agents: vec!["explorer".into()],
            worktree: None,
            execution_mode: "headless".into(),
            claude_cli_version: Some("1.2.3".into()),
            termmesh_app_version: "0.72.0".into(),
            app_socket_path_at_create: None,
            runbook_digest_hash: None,
        };
        std::fs::write(
            archived_dir.join("team.json"),
            serde_json::to_vec_pretty(&team_meta).unwrap(),
        )
        .unwrap();

        let mgr = HeadlessManager::new();
        let result = mgr.list_resumable(None, 50);
        assert_eq!(result.scanned, 1);
        assert_eq!(result.skipped, 0);
        assert_eq!(result.teams.len(), 1);
        let row = &result.teams[0];
        assert_eq!(row.team_uuid, team_uuid);
        assert_eq!(row.team_name, "my-team");
        assert_eq!(row.destroyed_at, destroyed_at);
        assert_eq!(row.agents.len(), 1);
        assert_eq!(row.agents[0].name, "explorer");
        assert!(row.agents[0].has_session);
        assert!(row.agents[0].has_instructions);
        assert!(row.validity.all_sessions_present);
        assert!(row.validity.worktree_exists); // no worktree ⇒ vacuously true
        assert!(row.resumable);
    }

    #[test]
    fn list_resumable_allows_pane_archive_with_leader_session_only() {
        let _scope = scoped_root();
        let team_uuid = "22222222-3333-4444-5555-666666666666".to_string();
        let destroyed_at = 1715600100u64;

        let archived_dir =
            meta::headless_root().join(format!("{team_uuid}.archived.{destroyed_at}"));
        std::fs::create_dir_all(archived_dir.join("agents")).unwrap();
        std::fs::create_dir_all(archived_dir.join("instructions")).unwrap();

        let inst_bytes = b"You are explorer.";
        std::fs::write(archived_dir.join("instructions/explorer.txt"), inst_bytes).unwrap();
        let agent_meta = meta::AgentMeta {
            schema: meta::SCHEMA_VERSION,
            team_uuid: team_uuid.clone(),
            name: "explorer".into(),
            agent_type: "explorer".into(),
            cli: "claude".into(),
            model: "sonnet".into(),
            session_id: None,
            color: Some("green".into()),
            created_at: destroyed_at - 100,
            instructions_sha256: Some(meta::sha256_hex(inst_bytes)),
            cli_path_at_create: None,
            parked: false,
            usage_total: None,
            extra_args: Vec::new(),
            extra_env: std::collections::HashMap::new(),
            auto_recycle_every: None,
            completed_task_count: 0,
        };
        std::fs::write(
            archived_dir.join("agents/explorer.json"),
            serde_json::to_vec_pretty(&agent_meta).unwrap(),
        )
        .unwrap();

        let team_meta = meta::TeamMeta {
            schema: meta::SCHEMA_VERSION,
            team_uuid: team_uuid.clone(),
            team_name: "pane-team".into(),
            created_at: destroyed_at - 100,
            destroyed_at: Some(destroyed_at),
            working_directory: "/tmp/proj".into(),
            git_root: None,
            git_branch_at_create: None,
            leader: meta::LeaderMeta {
                mode: "claude".into(),
                model: "sonnet".into(),
                session_id: Some("leader-sid".into()),
            },
            agents: vec!["explorer".into()],
            worktree: None,
            execution_mode: "pane".into(),
            claude_cli_version: None,
            termmesh_app_version: "test".into(),
            app_socket_path_at_create: None,
            runbook_digest_hash: None,
        };
        std::fs::write(
            archived_dir.join("team.json"),
            serde_json::to_vec_pretty(&team_meta).unwrap(),
        )
        .unwrap();

        let mgr = HeadlessManager::new();
        let result = mgr.list_resumable(None, 50);
        assert_eq!(result.teams.len(), 1);
        let row = &result.teams[0];
        assert_eq!(row.mode, "pane");
        assert!(!row.validity.all_sessions_present);
        assert!(row.resumable);
        assert!(row.blocking_reason.is_none());
    }

    #[test]
    fn list_resumable_skips_corrupt() {
        let _scope = scoped_root();
        // Create an "archived" dir with malformed team.json.
        let team_uuid = "11111111-2222-3333-4444-555555555555";
        let archived_dir = meta::headless_root().join(format!("{team_uuid}.archived.1000"));
        std::fs::create_dir_all(&archived_dir).unwrap();
        std::fs::write(archived_dir.join("team.json"), b"not valid json").unwrap();

        let mgr = HeadlessManager::new();
        let result = mgr.list_resumable(None, 50);
        assert_eq!(result.scanned, 1);
        assert_eq!(result.skipped, 1);
        assert!(result.teams.is_empty());
    }

    // ────────────────────────────────────────────────────────────────────
    // Phase 2.5: usage parsing + agent.json round-trip
    // ────────────────────────────────────────────────────────────────────

    #[test]
    fn parse_usage_from_assistant_event() {
        // Sample shape captured from `claude --output-format stream-json`.
        let line = r#"{"type":"assistant","message":{"id":"msg_x","role":"assistant","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":6,"cache_creation_input_tokens":35599,"cache_read_input_tokens":0,"output_tokens":12}}}"#;
        let parsed = parse_usage_from_line(line).expect("usage block present");
        assert_eq!(parsed.input_tokens, 6);
        assert_eq!(parsed.output_tokens, 12);
        assert_eq!(parsed.cache_creation_input_tokens, 35599);
        assert_eq!(parsed.cache_read_input_tokens, 0);
    }

    #[test]
    fn parse_usage_from_result_event_top_level() {
        // Claude `result` events sometimes carry `usage` at the top level.
        let line = r#"{"type":"result","subtype":"success","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":100,"cache_creation_input_tokens":0},"total_cost_usd":0.001}"#;
        let parsed = parse_usage_from_line(line).expect("usage block present");
        assert_eq!(parsed.input_tokens, 1);
        assert_eq!(parsed.output_tokens, 2);
        assert_eq!(parsed.cache_read_input_tokens, 100);
        assert_eq!(parsed.cache_creation_input_tokens, 0);
    }

    #[test]
    fn parse_usage_returns_none_for_unrelated_lines() {
        // Wrong type.
        assert!(parse_usage_from_line(r#"{"type":"system","subtype":"init"}"#).is_none());
        // No usage block.
        assert!(
            parse_usage_from_line(r#"{"type":"assistant","message":{"role":"assistant"}}"#)
                .is_none()
        );
        // Not JSON.
        assert!(parse_usage_from_line("hello world").is_none());
        // Zero usage block.
        assert!(parse_usage_from_line(
            r#"{"type":"result","usage":{"input_tokens":0,"output_tokens":0}}"#
        )
        .is_none());
    }

    #[test]
    fn usage_counters_accumulate_and_dirty_bits_clear() {
        let counters = UsageCounters::default();
        assert!(!counters.take_broadcast_dirty());
        assert!(!counters.take_flush_dirty());

        counters.observe(
            &ParsedUsage {
                input_tokens: 10,
                output_tokens: 5,
                cache_read_input_tokens: 1000,
                cache_creation_input_tokens: 2000,
            },
            12345,
        );
        // Second observation accumulates.
        counters.observe(
            &ParsedUsage {
                input_tokens: 3,
                output_tokens: 7,
                cache_read_input_tokens: 0,
                cache_creation_input_tokens: 500,
            },
            12346,
        );

        let snap = counters.snapshot();
        assert_eq!(snap.input_tokens, 13);
        assert_eq!(snap.output_tokens, 12);
        assert_eq!(snap.cache_read_input_tokens, 1000);
        assert_eq!(snap.cache_creation_input_tokens, 2500);
        assert_eq!(snap.last_updated_ms, 12346);

        // Both dirty bits are set and clear independently.
        assert!(counters.take_broadcast_dirty());
        assert!(!counters.take_broadcast_dirty());
        assert!(counters.take_flush_dirty());
        assert!(!counters.take_flush_dirty());
    }

    #[test]
    fn agent_meta_round_trip_with_usage_total() {
        let team_uuid = "deadbeef-1111-2222-3333-444455556666";
        let meta_in = meta::AgentMeta {
            schema: meta::SCHEMA_VERSION,
            team_uuid: team_uuid.into(),
            name: "executor".into(),
            agent_type: "executor".into(),
            cli: "claude".into(),
            model: "sonnet".into(),
            session_id: Some("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".into()),
            color: None,
            created_at: 1715600000,
            instructions_sha256: None,
            cli_path_at_create: None,
            parked: false,
            usage_total: Some(meta::UsageTotals {
                input_tokens: 12345,
                output_tokens: 678,
                cache_read_input_tokens: 22000,
                cache_creation_input_tokens: 13000,
                last_updated_ms: 1715600000_000,
            }),
            extra_args: Vec::new(),
            extra_env: std::collections::HashMap::new(),
            auto_recycle_every: Some(3),
            completed_task_count: 2,
        };
        let bytes = serde_json::to_vec_pretty(&meta_in).unwrap();
        let meta_out: meta::AgentMeta = serde_json::from_slice(&bytes).unwrap();
        let u = meta_out.usage_total.expect("usage_total preserved");
        assert_eq!(u.input_tokens, 12345);
        assert_eq!(u.output_tokens, 678);
        assert_eq!(u.cache_read_input_tokens, 22000);
        assert_eq!(u.cache_creation_input_tokens, 13000);
        assert_eq!(u.last_updated_ms, 1715600000_000);
    }

    #[test]
    fn agent_meta_back_compat_when_usage_total_absent() {
        // JSON without `usage_total` (legacy schema=1) parses with None.
        let json = r#"{
            "schema": 1,
            "team_uuid": "deadbeef-1111-2222-3333-444455556666",
            "name": "explorer",
            "agent_type": "explorer",
            "cli": "claude",
            "model": "sonnet",
            "session_id": null,
            "color": null,
            "created_at": 1715600000,
            "instructions_sha256": null,
            "cli_path_at_create": null,
            "parked": false
        }"#;
        let parsed: meta::AgentMeta = serde_json::from_str(json).unwrap();
        assert!(parsed.usage_total.is_none());
    }

    // ────────────────────────────────────────────────────────────────────
    // D1 + D2 + D4: pane-mode archive_pane / zombie sweep
    // ────────────────────────────────────────────────────────────────────

    fn sample_archive_params(team_uuid: Option<String>) -> ArchivePaneParams {
        ArchivePaneParams {
            team_uuid,
            team_name: "iso".into(),
            leader_session_id: "lead-sid".into(),
            leader_mode: "claude".into(),
            leader_model: "sonnet".into(),
            working_directory: "/tmp/iso".into(),
            git_root: None,
            git_branch_at_create: None,
            worktree_mode: None,
            worktree_path: None,
            worktree_branch: None,
            agents: vec![ArchivePaneAgent {
                name: "explorer".into(),
                cli: "claude".into(),
                model: "sonnet".into(),
                agent_type: "explorer".into(),
                color: None,
                session_id: Some("agent-sid".into()),
                instructions: Some("test".into()),
            }],
            termmesh_app_version: Some("0.0.0-test".into()),
        }
    }

    #[test]
    fn archive_pane_replaces_in_place_for_same_uuid() {
        let _scope = scoped_root();
        let mut mgr = HeadlessManager::new();
        let team_uuid = "22222222-3333-4444-5555-666666666666".to_string();

        let r1 = mgr
            .archive_pane_team(sample_archive_params(Some(team_uuid.clone())))
            .expect("first archive");
        assert!(!r1.replaced, "first archive should not replace");
        assert_eq!(r1.team_uuid, team_uuid);

        let r2 = mgr
            .archive_pane_team(sample_archive_params(Some(team_uuid.clone())))
            .expect("second archive");
        assert!(r2.replaced, "second archive must replace the first");
        assert_eq!(r2.team_uuid, team_uuid);

        let archived = meta::list_archived_teams().unwrap();
        let matching: Vec<_> = archived
            .iter()
            .filter(|e| e.team_uuid == team_uuid)
            .collect();
        assert_eq!(
            matching.len(),
            1,
            "exactly one archived dir per uuid after replace"
        );
    }

    #[test]
    fn archive_pane_grace_mode_assigns_uuid_when_missing() {
        let _scope = scoped_root();
        let mut mgr = HeadlessManager::new();

        let r = mgr
            .archive_pane_team(sample_archive_params(None))
            .expect("grace-mode archive");
        assert!(!r.team_uuid.is_empty(), "fallback uuid was assigned");
        assert!(!r.replaced);
    }

    #[test]
    fn sweep_zombie_pane_archives_removes_all_session_none() {
        let _scope = scoped_root();
        let team_uuid = "33333333-4444-5555-6666-777777777777".to_string();
        let destroyed_at = 1_000_000u64;
        let archived = meta::headless_root()
            .join(format!("{team_uuid}.archived.{destroyed_at}"));
        std::fs::create_dir_all(archived.join("agents")).unwrap();

        let team_meta = meta::TeamMeta {
            schema: meta::SCHEMA_VERSION,
            team_uuid: team_uuid.clone(),
            team_name: "zombie".into(),
            created_at: destroyed_at - 100,
            destroyed_at: Some(destroyed_at),
            working_directory: "/tmp".into(),
            git_root: None,
            git_branch_at_create: None,
            leader: meta::LeaderMeta {
                mode: "claude".into(),
                model: "sonnet".into(),
                session_id: None,
            },
            agents: vec!["a".into()],
            worktree: None,
            execution_mode: "pane".into(),
            claude_cli_version: None,
            termmesh_app_version: "test".into(),
            app_socket_path_at_create: None,
            runbook_digest_hash: None,
        };
        std::fs::write(
            archived.join("team.json"),
            serde_json::to_vec_pretty(&team_meta).unwrap(),
        )
        .unwrap();
        let agent_meta = meta::AgentMeta {
            schema: meta::SCHEMA_VERSION,
            team_uuid: team_uuid.clone(),
            name: "a".into(),
            agent_type: "explorer".into(),
            cli: "claude".into(),
            model: "sonnet".into(),
            session_id: None,
            color: None,
            created_at: destroyed_at - 100,
            instructions_sha256: None,
            cli_path_at_create: None,
            parked: false,
            usage_total: None,
            extra_args: Vec::new(),
            extra_env: std::collections::HashMap::new(),
            auto_recycle_every: None,
            completed_task_count: 0,
        };
        std::fs::write(
            archived.join("agents/a.json"),
            serde_json::to_vec_pretty(&agent_meta).unwrap(),
        )
        .unwrap();

        let removed = meta::sweep_zombie_pane_archives();
        assert_eq!(removed, 1);
        assert!(!archived.exists(), "zombie archive must be removed");
    }

    #[test]
    fn in_flight_guard_releases_on_panic() {
        use std::panic::{catch_unwind, AssertUnwindSafe};
        let set: Arc<std::sync::Mutex<HashSet<String>>> =
            Arc::new(std::sync::Mutex::new(HashSet::new()));
        set.lock().unwrap().insert("k".to_string());
        let captured = Arc::clone(&set);
        let res = catch_unwind(AssertUnwindSafe(|| {
            let _g = InFlightGuard {
                set: Arc::clone(&captured),
                key: "k".to_string(),
            };
            panic!("boom");
        }));
        assert!(res.is_err(), "panic must propagate from catch_unwind");
        assert!(
            set.lock().unwrap().is_empty(),
            "InFlightGuard must release the slot during panic unwind"
        );
    }

    #[test]
    fn sweep_zombie_pane_archives_keeps_headless_mode_and_with_session() {
        let _scope = scoped_root();
        // pane-mode but with leader session_id → must NOT be removed.
        let team_uuid = "44444444-5555-6666-7777-888888888888".to_string();
        let destroyed_at = 1_000_001u64;
        let archived = meta::headless_root()
            .join(format!("{team_uuid}.archived.{destroyed_at}"));
        std::fs::create_dir_all(archived.join("agents")).unwrap();
        let team_meta = meta::TeamMeta {
            schema: meta::SCHEMA_VERSION,
            team_uuid: team_uuid.clone(),
            team_name: "alive".into(),
            created_at: destroyed_at - 100,
            destroyed_at: Some(destroyed_at),
            working_directory: "/tmp".into(),
            git_root: None,
            git_branch_at_create: None,
            leader: meta::LeaderMeta {
                mode: "claude".into(),
                model: "sonnet".into(),
                session_id: Some("lead-sid".into()),
            },
            agents: vec![],
            worktree: None,
            execution_mode: "pane".into(),
            claude_cli_version: None,
            termmesh_app_version: "test".into(),
            app_socket_path_at_create: None,
            runbook_digest_hash: None,
        };
        std::fs::write(
            archived.join("team.json"),
            serde_json::to_vec_pretty(&team_meta).unwrap(),
        )
        .unwrap();

        let removed = meta::sweep_zombie_pane_archives();
        assert_eq!(removed, 0);
        assert!(archived.exists(), "archive with leader session must remain");
    }

    #[tokio::test]
    async fn reap_exited_agents_clears_handles() {
        let _scope = scoped_root();
        // Spawn a real process that exits immediately.
        let mut child = tokio::process::Command::new("true")
            .stdin(std::process::Stdio::piped())
            .spawn()
            .expect("spawn `true`");
        // Wait for it so try_wait() will definitely see an exit status.
        child.wait().await.expect("wait");

        let agent_id = "test-reap-agent".to_string();
        let agent = HeadlessAgent {
            id: agent_id.clone(),
            name: agent_id.clone(),
            cli: "claude".into(),
            model: "sonnet".into(),
            team_name: "test-team".into(),
            team_uuid: "00000000-0000-0000-0000-000000000000".into(),
            working_directory: "/tmp".into(),
            child: Some(child),
            stdin: None,
            stdout_buffer: Arc::new(tokio::sync::Mutex::new(OutputBuffer::new(100))),
            protocol: Box::new(protocol::ClaudeStreamJson),
            status: AgentStatus::Running,
            pid: 0,
            created_at: 0,
            session_id: None,
            last_activity_ms: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            parked: false,
            usage: Arc::new(UsageCounters::default()),
            auto_recycle_every: None,
            completed_task_count: 0,
        };

        let mut mgr = HeadlessManager::new();
        mgr.agents.insert(agent_id.clone(), agent);

        mgr.reap_exited_agents();

        let a = mgr.agents.get(&agent_id).expect("agent still present");
        assert_eq!(a.status, AgentStatus::Terminated, "status should be Terminated after reap");
        assert!(a.child.is_none(), "child handle should be cleared");
        assert!(a.stdin.is_none(), "stdin handle should be cleared");
    }
}
