pub mod buffer;
pub mod cli_builder;
pub mod meta;
pub mod protocol;

use std::collections::HashMap;
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
        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                activity_clone.store(now_ms(), std::sync::atomic::Ordering::Relaxed);
                if parse_usage_for_this_cli {
                    if let Some(u) = parse_usage_from_line(&line) {
                        usage_clone.observe(&u, now_ms());
                    }
                }
                buf_clone.lock().await.push(line);
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
            },
        );

        Ok(info)
    }

    /// Send a message to a headless agent's stdin via its protocol adapter.
    pub async fn send_message(&mut self, agent_id: &str, text: &str) -> Result<(), String> {
        let agent = self
            .agents
            .get_mut(agent_id)
            .ok_or_else(|| format!("agent not found: {agent_id}"))?;

        if agent.status == AgentStatus::Terminated || agent.status == AgentStatus::Parked {
            return Err(format!("agent is {:?}: {agent_id}", agent.status));
        }

        let bytes = agent.protocol.encode_message(text);
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

        // Reset idle tracker on outbound activity (§5.2).
        agent
            .last_activity_ms
            .store(now_ms(), std::sync::atomic::Ordering::Relaxed);

        tracing::debug!("sent {} bytes to {agent_id}", bytes.len());
        Ok(())
    }

    pub async fn read_output(&self, agent_id: &str, lines: usize) -> Result<Vec<String>, String> {
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

    pub async fn status(&self, agent_id: &str) -> Result<AgentInfo, String> {
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

    pub async fn list(&self, team_name: Option<&str>) -> Vec<AgentInfo> {
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

            let instr_bytes = spec
                .instructions
                .as_ref()
                .map(|s| s.as_bytes().to_vec())
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
            let instr_bytes = spec
                .instructions
                .as_ref()
                .map(|s| s.as_bytes().to_vec())
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
        let team_uuid = match params.team_uuid {
            Some(s) if !s.is_empty() => meta::parse_uuid(&s)?,
            _ => meta::new_uuid(),
        };
        let now = meta::now_unix();

        // Build TeamMeta — mirrors headless format with execution_mode = "pane".
        let team_meta = meta::TeamMeta {
            schema: meta::SCHEMA_VERSION,
            team_uuid: team_uuid.clone(),
            team_name: params.team_name.clone(),
            created_at: now, // best effort — Swift doesn't always know exact creation epoch
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
            worktree: match (params.worktree_mode.as_deref(), params.worktree_path.as_deref(), params.worktree_branch.as_deref()) {
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

        // Create dirs.
        meta::create_dir_secure(&meta::team_dir(&team_uuid))
            .map_err(|e| format!("create team dir: {e}"))?;
        meta::create_dir_secure(&meta::agents_subdir(&team_uuid))
            .map_err(|e| format!("create agents subdir: {e}"))?;
        meta::create_dir_secure(&meta::instructions_subdir(&team_uuid))
            .map_err(|e| format!("create instructions subdir: {e}"))?;

        // Write team.json.
        meta::write_team_meta(&team_meta)?;

        // Write per-agent meta + instructions.
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
            };
            meta::write_agent_meta(&agent_meta)?;
        }

        // Rename live → archived.<ts>.
        let archived = meta::rename_to_archived(&team_uuid, now)?;
        tracing::info!(
            "archived pane-mode team {} ({}) → {}",
            params.team_name,
            team_uuid,
            archived.display()
        );
        Ok(ArchivePaneResult {
            team_uuid,
            archived_path: archived.to_string_lossy().into_owned(),
        })
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
            extra_args: Vec::new(),
            extra_env: std::collections::HashMap::new(),
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
        let candidates: Vec<(String, String, meta::UsageTotals)> = self
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
                Some((a.team_uuid.clone(), a.name.clone(), a.usage.snapshot()))
            })
            .collect();

        for (team_uuid, name, snap) in candidates {
            match meta::read_agent_meta(&team_uuid, &name) {
                Ok(mut m) => {
                    m.usage_total = Some(snap);
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
        let candidates: Vec<(String, String, meta::UsageTotals)> = self
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
                Some((a.team_uuid.clone(), a.name.clone(), a.usage.snapshot()))
            })
            .collect();
        for (team_uuid, name, snap) in candidates {
            if let Ok(mut m) = meta::read_agent_meta(&team_uuid, &name) {
                m.usage_total = Some(snap);
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
            let resumable = worktree_exists && all_present;
            let blocking_reason = if !worktree_exists {
                Some("worktree_gone".to_string())
            } else if !all_present {
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
                extra_args: Vec::new(),
                extra_env: std::collections::HashMap::new(),
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: scope `TERMMESH_HEADLESS_ROOT` to a fresh tmp dir for the test.
    fn scoped_root() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("TERMMESH_HEADLESS_ROOT", dir.path());
        dir
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
}
