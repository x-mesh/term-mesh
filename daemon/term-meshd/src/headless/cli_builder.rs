use std::path::PathBuf;

/// Configuration for spawning a headless agent subprocess.
pub struct CliCommand {
    pub program: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    /// Environment variables to remove from the child process.
    pub env_remove: Vec<String>,
}

/// Common term-mesh environment variables for all agent CLIs.
fn base_env(
    name: &str,
    team_name: &str,
    daemon_socket: &str,
    app_socket_path: Option<&str>,
) -> Vec<(String, String)> {
    let agent_id = format!("{name}@{team_name}");
    // TERMMESH_SOCKET → Swift app socket (for team.* commands via tm-agent).
    // Falls back to daemon socket when no app socket is provided (CLI-only mode).
    let primary_socket = app_socket_path.unwrap_or(daemon_socket);

    // Ensure the daemon's own binary directory (Resources/bin) is in PATH.
    // When the app is launched from Finder/Spotlight, macOS provides a minimal PATH
    // that doesn't include Resources/bin. Pane mode handles this in TeamOrchestrator.swift,
    // but headless mode inherits the daemon's PATH which may be missing it.
    let daemon_bin_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_string_lossy().to_string()))
        .unwrap_or_default();
    let current_path = std::env::var("PATH").unwrap_or_default();
    let path = if !daemon_bin_dir.is_empty() && !current_path.contains(&daemon_bin_dir) {
        format!("{daemon_bin_dir}:{current_path}")
    } else {
        current_path
    };

    vec![
        ("TERMMESH_SOCKET".into(), primary_socket.to_string()),
        ("TERMMESH_DAEMON_SOCKET".into(), daemon_socket.to_string()),
        ("TERMMESH_TEAM".into(), team_name.to_string()),
        ("TERMMESH_AGENT_NAME".into(), name.to_string()),
        ("TERMMESH_AGENT_ID".into(), agent_id),
        ("TERMMESH_HEADLESS".into(), "1".to_string()),
        ("PATH".into(), path),
    ]
}

/// Resolve a CLI binary path: explicit path > env var > bare name fallback.
fn resolve_cli_path(cli_path: Option<&str>, env_key: &str, fallback: &str) -> String {
    cli_path
        .map(String::from)
        .or_else(|| std::env::var(env_key).ok())
        .unwrap_or_else(|| fallback.to_string())
}

/// Build the CLI command for a Claude Code agent in stream-json mode.
pub fn build_claude_command(
    name: &str,
    team_name: &str,
    model: &str,
    _working_directory: &str,
    daemon_socket: &str,
    cli_path: Option<&str>,
    app_socket_path: Option<&str>,
) -> CliCommand {
    let program = resolve_cli_path(cli_path, "CLAUDE_PATH", "claude");

    let args = vec![
        "--input-format".into(), "stream-json".into(),
        "--output-format".into(), "stream-json".into(),
        "--verbose".into(),
        "--dangerously-skip-permissions".into(),
        "--model".into(), model.to_string(),
    ];

    let env = base_env(name, team_name, daemon_socket, app_socket_path);

    // Remove env vars that cause nested-session detection in Claude Code
    let env_remove = vec![
        "CLAUDECODE".into(),
        "CLAUDE_CODE_ENTRYPOINT".into(),
    ];

    CliCommand { program, args, env, env_remove }
}

/// Map short model names to Kiro CLI model identifiers.
fn kiro_model_name(short: &str) -> &str {
    match short.to_lowercase().as_str() {
        "opus" => "claude-opus-4-6-20250618",
        "sonnet" => "claude-sonnet-4-6-20250514",
        "haiku" => "claude-haiku-4-5-20251001",
        _ => short,
    }
}

/// Build the CLI command for a Kiro agent.
pub fn build_kiro_command(
    name: &str,
    team_name: &str,
    model: &str,
    daemon_socket: &str,
    cli_path: Option<&str>,
    app_socket_path: Option<&str>,
) -> CliCommand {
    let program = resolve_cli_path(cli_path, "KIRO_PATH", "kiro-cli");

    let profile_name = format!("team-{team_name}-{name}");

    // Write the Kiro agent profile so --agent can reference it
    write_kiro_profile(
        &profile_name,
        &format!("Worker agent {name} in team {team_name}"),
        &format!(
            "You are a focused worker agent named '{}' in team '{}'. \
             Rules: 1) Be EXTREMELY concise — no preamble, no summaries unless asked. \
             2) Output only code, commands, or direct answers. \
             3) When done, state the result in 1-2 lines max. 4) Never repeat the task back.",
            name, team_name
        ),
    );

    let kiro_model = kiro_model_name(model);
    let args = vec![
        "chat".into(),
        "--trust-all-tools".into(),
        "--wrap".into(), "never".into(),
        "--agent".into(), profile_name,
        "--model".into(), kiro_model.to_string(),
    ];

    let env = base_env(name, team_name, daemon_socket, app_socket_path);
    CliCommand { program, args, env, env_remove: vec![] }
}

/// Write a Kiro agent profile TOML to ~/.kiro/agents/<name>.toml
fn write_kiro_profile(profile_name: &str, description: &str, prompt: &str) {
    let home = match dirs::home_dir() {
        Some(h) => h,
        None => return,
    };
    let agents_dir = home.join(".kiro").join("agents");
    if std::fs::create_dir_all(&agents_dir).is_err() {
        tracing::warn!("failed to create kiro agents dir: {}", agents_dir.display());
        return;
    }
    let path = agents_dir.join(format!("{profile_name}.toml"));
    let content = format!(
        "[agent]\nname = \"{profile_name}\"\ndescription = \"{description}\"\n\n[agent.prompt]\nsystem = \"\"\"{prompt}\"\"\"\n"
    );
    if let Err(e) = std::fs::write(&path, &content) {
        tracing::warn!("failed to write kiro profile {}: {e}", path.display());
    }
}

/// Map short model names to Codex CLI model identifiers.
fn codex_model_name(short: &str) -> &str {
    match short.to_lowercase().as_str() {
        "opus" => "gpt-5.4",
        "sonnet" => "gpt-5.4",
        "haiku" => "gpt-5.1-codex-mini",
        _ => short,
    }
}

/// Build the CLI command for a Codex agent.
/// Uses `codex exec` (non-interactive) with `--json` for JSONL output and stdin prompt.
pub fn build_codex_command(
    name: &str,
    team_name: &str,
    model: &str,
    daemon_socket: &str,
    cli_path: Option<&str>,
    app_socket_path: Option<&str>,
) -> CliCommand {
    let program = resolve_cli_path(cli_path, "CODEX_PATH", "codex");

    let codex_model = codex_model_name(model);
    let args = vec![
        "exec".into(),
        "--sandbox".into(), "danger-full-access".into(),
        "--model".into(), codex_model.to_string(),
        "--json".into(),
        "-".into(),  // read prompt from stdin
    ];

    let env = base_env(name, team_name, daemon_socket, app_socket_path);
    CliCommand { program, args, env, env_remove: vec![] }
}

/// Map short model names to Gemini CLI model identifiers.
fn gemini_model_name(short: &str) -> &str {
    match short.to_lowercase().as_str() {
        "opus" => "gemini-3-pro",
        "sonnet" => "gemini-3-flash",
        "haiku" => "gemini-3-flash",
        _ => short,
    }
}

/// Build the CLI command for a Gemini agent.
pub fn build_gemini_command(
    name: &str,
    team_name: &str,
    model: &str,
    daemon_socket: &str,
    cli_path: Option<&str>,
    app_socket_path: Option<&str>,
) -> CliCommand {
    let program = resolve_cli_path(cli_path, "GEMINI_PATH", "gemini");

    let gemini_model = gemini_model_name(model);
    let args = vec![
        "--yolo".into(),
        "--model".into(), gemini_model.to_string(),
    ];

    let env = base_env(name, team_name, daemon_socket, app_socket_path);
    CliCommand { program, args, env, env_remove: vec![] }
}

/// Resolve the daemon socket path (same logic as socket::default_socket_path).
pub fn daemon_socket_path() -> PathBuf {
    if let Ok(p) = std::env::var("TERMMESH_DAEMON_UNIX_PATH") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    let dir = dirs::runtime_dir()
        .or_else(|| std::env::var("TMPDIR").ok().map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    dir.join("term-meshd.sock")
}
