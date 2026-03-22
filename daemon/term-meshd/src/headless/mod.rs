pub mod buffer;
pub mod cli_builder;
pub mod protocol;

use std::collections::HashMap;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::Mutex;

use buffer::OutputBuffer;
use protocol::AgentProtocol;

/// Status of a headless agent subprocess.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentStatus {
    Spawning,
    Running,
    Terminated,
}

/// A headless agent: a subprocess managed by the daemon with stdin/stdout pipes.
pub struct HeadlessAgent {
    pub id: String,
    pub name: String,
    pub cli: String,
    pub model: String,
    pub team_name: String,
    pub working_directory: String,
    pub child: Child,
    pub stdin: ChildStdin,
    pub stdout_buffer: Arc<Mutex<OutputBuffer>>,
    pub protocol: Box<dyn AgentProtocol>,
    pub status: AgentStatus,
    pub pid: u32,
    pub created_at: u64,
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
}

/// Team metadata for headless teams.
#[derive(Debug, Clone, serde::Serialize)]
pub struct HeadlessTeam {
    pub name: String,
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
    /// Agent-specific instructions (preset system prompt).
    #[serde(default)]
    pub instructions: Option<String>,
}

fn default_cli() -> String { "claude".into() }
fn default_model() -> String { "sonnet".into() }

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
}

/// Manages all headless agent subprocesses and teams.
pub struct HeadlessManager {
    agents: HashMap<String, HeadlessAgent>,
    teams: HashMap<String, HeadlessTeam>,
}

impl HeadlessManager {
    pub fn new() -> Self {
        Self {
            agents: HashMap::new(),
            teams: HashMap::new(),
        }
    }

    /// Spawn a single headless agent subprocess.
    pub async fn spawn_agent(&mut self, params: SpawnParams) -> Result<AgentInfo, String> {
        let id = format!("{}@{}", params.name, params.team_name);

        if self.agents.contains_key(&id) {
            return Err(format!("agent already exists: {id}"));
        }

        let daemon_socket = cli_builder::daemon_socket_path()
            .to_string_lossy()
            .to_string();

        let cmd = match params.cli.as_str() {
            "kiro" => cli_builder::build_kiro_command(
                &params.name,
                &params.team_name,
                &params.model,
                &daemon_socket,
                params.cli_path.as_deref(),
                params.app_socket_path.as_deref(),
            ),
            "codex" => cli_builder::build_codex_command(
                &params.name,
                &params.team_name,
                &params.model,
                &daemon_socket,
                params.cli_path.as_deref(),
                params.app_socket_path.as_deref(),
            ),
            "gemini" => cli_builder::build_gemini_command(
                &params.name,
                &params.team_name,
                &params.model,
                &daemon_socket,
                params.cli_path.as_deref(),
                params.app_socket_path.as_deref(),
            ),
            _ => cli_builder::build_claude_command(
                &params.name,
                &params.team_name,
                &params.model,
                &params.working_directory,
                &daemon_socket,
                params.cli_path.as_deref(),
                params.app_socket_path.as_deref(),
                params.instructions.as_deref(),
            ),
        };

        tracing::info!(
            "spawning headless agent: {} (cli={}, model={}, dir={})",
            id, params.cli, params.model, params.working_directory
        );

        let mut command = Command::new(&cmd.program);
        command
            .args(&cmd.args)
            .envs(cmd.env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .current_dir(&params.working_directory)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);

        // Remove env vars that would interfere with the subprocess
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

        // Spawn stdout reader task
        let buf_clone = stdout_buffer.clone();
        let id_clone = id.clone();
        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                buf_clone.lock().await.push(line);
            }
            tracing::debug!("stdout reader exited for {id_clone}");
        });

        // Spawn stderr reader task (merge into same buffer with [stderr] prefix)
        let buf_clone2 = stdout_buffer.clone();
        let id_clone2 = id.clone();
        tokio::spawn(async move {
            let mut reader = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                buf_clone2.lock().await.push(format!("[stderr] {line}"));
            }
            tracing::debug!("stderr reader exited for {id_clone2}");
        });

        let proto = protocol::protocol_for(&params.cli);

        // Send handshake if the protocol requires one
        // (Claude stream-json doesn't need one, but future protocols may)

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let info = AgentInfo {
            id: id.clone(),
            name: params.name.clone(),
            cli: params.cli.clone(),
            model: params.model.clone(),
            team_name: params.team_name.clone(),
            working_directory: params.working_directory.clone(),
            status: AgentStatus::Running,
            pid,
            created_at: now,
            output_lines: 0,
        };

        self.agents.insert(id.clone(), HeadlessAgent {
            id,
            name: params.name,
            cli: params.cli,
            model: params.model,
            team_name: params.team_name,
            working_directory: params.working_directory,
            child,
            stdin,
            stdout_buffer,
            protocol: proto,
            status: AgentStatus::Running,
            pid,
            created_at: now,
        });

        Ok(info)
    }

    /// Send a message to a headless agent's stdin via its protocol adapter.
    pub async fn send_message(&mut self, agent_id: &str, text: &str) -> Result<(), String> {
        let agent = self.agents.get_mut(agent_id)
            .ok_or_else(|| format!("agent not found: {agent_id}"))?;

        if agent.status == AgentStatus::Terminated {
            return Err(format!("agent is terminated: {agent_id}"));
        }

        let bytes = agent.protocol.encode_message(text);
        agent.stdin.write_all(&bytes).await
            .map_err(|e| format!("write to stdin failed: {e}"))?;
        agent.stdin.flush().await
            .map_err(|e| format!("flush stdin failed: {e}"))?;

        tracing::debug!("sent {} bytes to {agent_id}", bytes.len());
        Ok(())
    }

    /// Read the last N lines from an agent's output buffer.
    pub async fn read_output(&self, agent_id: &str, lines: usize) -> Result<Vec<String>, String> {
        let agent = self.agents.get(agent_id)
            .ok_or_else(|| format!("agent not found: {agent_id}"))?;

        let buf = agent.stdout_buffer.lock().await;
        Ok(buf.tail(lines).iter().map(|s| s.to_string()).collect())
    }

    /// Terminate a headless agent subprocess.
    pub async fn terminate(&mut self, agent_id: &str) -> Result<(), String> {
        let agent = self.agents.get_mut(agent_id)
            .ok_or_else(|| format!("agent not found: {agent_id}"))?;

        if agent.status == AgentStatus::Terminated {
            return Ok(());
        }

        tracing::info!("terminating headless agent: {agent_id} (pid={})", agent.pid);

        // Try graceful SIGTERM first
        let pid = agent.pid;
        unsafe {
            libc::kill(pid as i32, libc::SIGTERM);
        }

        // Wait up to 5 seconds for the process to exit
        let wait_result = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            agent.child.wait(),
        ).await;

        match wait_result {
            Ok(Ok(_)) => {
                tracing::debug!("agent {agent_id} exited gracefully");
            }
            _ => {
                // Force kill
                tracing::warn!("agent {agent_id} did not exit within 5s, sending SIGKILL");
                unsafe {
                    libc::kill(pid as i32, libc::SIGKILL);
                }
                let _ = agent.child.wait().await;
            }
        }

        agent.status = AgentStatus::Terminated;
        Ok(())
    }

    /// Get info for a single agent.
    pub async fn status(&self, agent_id: &str) -> Result<AgentInfo, String> {
        let agent = self.agents.get(agent_id)
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
        })
    }

    /// List all headless agents (optionally filtered by team).
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
            });
        }
        result
    }

    /// Create a headless team: register team metadata and spawn all agents.
    pub async fn create_team(&mut self, params: TeamCreateParams) -> Result<HeadlessTeam, String> {
        if self.teams.contains_key(&params.team_name) {
            return Err(format!("team already exists: {}", params.team_name));
        }

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let mut agent_ids = Vec::new();

        for spec in &params.agents {
            let spawn_params = SpawnParams {
                name: spec.name.clone(),
                team_name: params.team_name.clone(),
                cli: spec.cli.clone(),
                model: spec.model.clone(),
                working_directory: params.working_directory.clone(),
                cli_path: spec.cli_path.clone(),
                app_socket_path: params.app_socket_path.clone(),
                instructions: spec.instructions.clone(),
            };

            match self.spawn_agent(spawn_params).await {
                Ok(info) => {
                    agent_ids.push(info.id);
                }
                Err(e) => {
                    // Cleanup already-spawned agents on failure
                    tracing::error!("failed to spawn agent '{}': {e}, cleaning up", spec.name);
                    for id in &agent_ids {
                        let _ = self.terminate(id).await;
                    }
                    return Err(format!("failed to spawn agent '{}': {e}", spec.name));
                }
            }
        }

        let team = HeadlessTeam {
            name: params.team_name.clone(),
            agents: agent_ids,
            working_directory: params.working_directory,
            leader_session_id: params.leader_session_id,
            created_at: now,
        };

        self.teams.insert(params.team_name, team.clone());
        Ok(team)
    }

    /// Destroy a headless team: terminate all agents and remove team metadata.
    pub async fn destroy_team(&mut self, team_name: &str) -> Result<(), String> {
        let team = self.teams.remove(team_name)
            .ok_or_else(|| format!("team not found: {team_name}"))?;

        for agent_id in &team.agents {
            if let Err(e) = self.terminate(agent_id).await {
                tracing::warn!("failed to terminate agent {agent_id}: {e}");
            }
        }

        // Remove agent entries
        for agent_id in &team.agents {
            self.agents.remove(agent_id);
        }

        tracing::info!("destroyed headless team: {team_name}");
        Ok(())
    }

    /// List all headless teams.
    pub fn list_teams(&self) -> Vec<&HeadlessTeam> {
        self.teams.values().collect()
    }

    /// Get a specific team.
    pub fn get_team(&self, team_name: &str) -> Option<&HeadlessTeam> {
        self.teams.get(team_name)
    }

    /// Terminate all agents and teams (called on daemon shutdown).
    pub async fn terminate_all(&mut self) {
        let team_names: Vec<String> = self.teams.keys().cloned().collect();
        for name in team_names {
            let _ = self.destroy_team(&name).await;
        }

        // Also terminate any orphaned agents not in a team
        let agent_ids: Vec<String> = self.agents.keys().cloned().collect();
        for id in agent_ids {
            let _ = self.terminate(&id).await;
        }
        self.agents.clear();
    }

    /// Add a single agent to an existing headless team.
    pub async fn add_agent(&mut self, team_name: &str, spec: AgentSpec, app_socket_path: Option<&str>) -> Result<AgentInfo, String> {
        let team = self.teams.get(team_name)
            .ok_or_else(|| format!("team not found: {team_name}"))?;

        let agent_id = format!("{}@{}", spec.name, team_name);
        if self.agents.contains_key(&agent_id) {
            return Err(format!("agent '{}' already exists in team '{}'", spec.name, team_name));
        }

        let working_directory = team.working_directory.clone();

        let spawn_params = SpawnParams {
            name: spec.name.clone(),
            team_name: team_name.to_string(),
            cli: spec.cli,
            model: spec.model,
            working_directory,
            cli_path: spec.cli_path,
            app_socket_path: app_socket_path.map(String::from),
            instructions: spec.instructions,
        };

        let info = self.spawn_agent(spawn_params).await?;

        // Update team's agent list (team must still exist since we hold &mut self)
        match self.teams.get_mut(team_name) {
            Some(team) => {
                team.agents.push(info.id.clone());
            }
            None => {
                // Rollback: terminate the orphaned agent
                tracing::error!("team '{}' disappeared after spawn, rolling back agent '{}'", team_name, info.id);
                let _ = self.terminate(&info.id).await;
                self.agents.remove(&info.id);
                return Err(format!("team '{}' was removed during agent spawn", team_name));
            }
        }

        Ok(info)
    }

    /// Check if an agent exists and is headless.
    pub fn is_headless(&self, agent_id: &str) -> bool {
        self.agents.contains_key(agent_id)
    }

    /// Look up an agent by name within a team.
    pub fn resolve_agent_id(&self, team_name: &str, agent_name: &str) -> Option<String> {
        let id = format!("{agent_name}@{team_name}");
        if self.agents.contains_key(&id) {
            Some(id)
        } else {
            None
        }
    }
}
