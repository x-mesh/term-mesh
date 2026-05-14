use std::ffi::OsString;
use std::path::PathBuf;

/// Configuration for spawning a headless agent subprocess.
///
/// `args` is `Vec<OsString>` so the `--append-system-prompt` value can carry
/// raw bytes verbatim on Unix (via `OsStrExt::from_bytes`). Phase 2 contract §4
/// mandates no encoding conversion / quote escaping on instructions.
pub struct CliCommand {
    pub program: String,
    pub args: Vec<OsString>,
    pub env: Vec<(String, String)>,
    /// Environment variables to remove from the child process.
    pub env_remove: Vec<String>,
}

/// Phase 2: spawn mode for the claude CLI.
#[derive(Debug, Clone)]
pub enum ClaudeSpawnMode {
    /// New session — `--session-id <uuid>`.
    Fresh { session_id: String },
    /// Resuming an existing session — `--resume <uuid>`.
    Resume { session_id: String },
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
///
/// Phase 2 contract §4:
/// - `--session-id <uuid>` (fresh) or `--resume <uuid>` (resume), supplied by
///   the daemon (never CLI-derived).
/// - `--print` is added unconditionally so behavior is independent of the CLI's
///   TTY autodetection.
/// - `--append-system-prompt` carries the **raw bytes** of instructions —
///   no quote escaping, no UTF-8 round trip. Empty / `None` ⇒ flag omitted
///   entirely (NEVER pass an empty value).
pub fn build_claude_command(
    name: &str,
    team_name: &str,
    model: &str,
    _working_directory: &str,
    daemon_socket: &str,
    cli_path: Option<&str>,
    app_socket_path: Option<&str>,
    instructions: Option<&[u8]>,
    mode: ClaudeSpawnMode,
) -> CliCommand {
    let program = resolve_cli_path(cli_path, "CLAUDE_PATH", "claude");

    let mut args: Vec<OsString> = Vec::new();

    // Session flag must come first for diff/audit stability (§4.3).
    match &mode {
        ClaudeSpawnMode::Fresh { session_id } => {
            args.push(OsString::from("--session-id"));
            args.push(OsString::from(session_id));
        }
        ClaudeSpawnMode::Resume { session_id } => {
            args.push(OsString::from("--resume"));
            args.push(OsString::from(session_id));
        }
    }

    for s in [
        "--print",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--dangerously-skip-permissions",
        "--model",
    ] {
        args.push(OsString::from(s));
    }
    args.push(OsString::from(model));

    // Pass agent-specific instructions as --append-system-prompt.
    // Raw bytes — no escaping. `Command::arg` does NOT pass through a shell,
    // so the previous `replace('\'', "'\\''")` was a bug (silent bytewise drift
    // on instructions containing single quotes). See contract §4.3.
    if let Some(inst) = instructions {
        if !inst.is_empty() {
            args.push(OsString::from("--append-system-prompt"));
            args.push(os_string_from_bytes(inst));
        }
    }

    let env = base_env(name, team_name, daemon_socket, app_socket_path);

    // Remove env vars that cause nested-session detection in Claude Code
    let env_remove = vec!["CLAUDECODE".into(), "CLAUDE_CODE_ENTRYPOINT".into()];

    CliCommand {
        program,
        args,
        env,
        env_remove,
    }
}

/// Construct an `OsString` from raw bytes verbatim on Unix; lossy UTF-8 fallback
/// elsewhere (term-meshd is Unix-only in practice).
#[cfg(unix)]
fn os_string_from_bytes(b: &[u8]) -> OsString {
    use std::os::unix::ffi::OsStringExt;
    OsString::from_vec(b.to_vec())
}

#[cfg(not(unix))]
fn os_string_from_bytes(b: &[u8]) -> OsString {
    OsString::from(String::from_utf8_lossy(b).into_owned())
}

/// Map short model names to Kiro CLI model identifiers.
fn kiro_model_name(short: &str) -> &str {
    match short.to_lowercase().as_str() {
        "opus" => "claude-opus-4.7",
        "sonnet" => "claude-sonnet-4.6",
        "haiku" => "claude-haiku-4.5",
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
    let args: Vec<OsString> = vec![
        "chat".into(),
        "--trust-all-tools".into(),
        "--wrap".into(),
        "never".into(),
        "--agent".into(),
        OsString::from(&profile_name),
        "--model".into(),
        OsString::from(kiro_model),
    ];

    let env = base_env(name, team_name, daemon_socket, app_socket_path);
    CliCommand {
        program,
        args,
        env,
        env_remove: vec![],
    }
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
/// All tiers use gpt-5.5; differentiation happens via reasoning effort
/// (see codex_reasoning_effort).
fn codex_model_name(short: &str) -> &str {
    match short.to_lowercase().as_str() {
        "opus" | "sonnet" | "haiku" => "gpt-5.5",
        _ => short,
    }
}

/// Map short model tier to Codex reasoning effort.
/// Returns None for non-tier names so unknown/passthrough models don't get the flag injected.
fn codex_reasoning_effort(short: &str) -> Option<&str> {
    match short.to_lowercase().as_str() {
        "opus" => Some("high"),
        "sonnet" => Some("medium"),
        "haiku" => Some("low"),
        _ => None,
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
    let mut args: Vec<OsString> = vec![
        "exec".into(),
        "--sandbox".into(),
        "danger-full-access".into(),
        "--model".into(),
        OsString::from(codex_model),
    ];
    if let Some(effort) = codex_reasoning_effort(model) {
        args.push("-c".into());
        args.push(OsString::from(format!("model_reasoning_effort={effort}")));
    }
    args.push("--json".into());
    args.push("-".into()); // read prompt from stdin

    let env = base_env(name, team_name, daemon_socket, app_socket_path);
    CliCommand {
        program,
        args,
        env,
        env_remove: vec![],
    }
}

/// Map short model names to Gemini CLI model identifiers.
fn gemini_model_name(short: &str) -> &str {
    match short.to_lowercase().as_str() {
        "opus" => "gemini-3.1-pro-preview",
        "sonnet" => "gemini-3-flash-preview",
        "haiku" => "gemini-3.1-flash-lite-preview",
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
    let args: Vec<OsString> = vec![
        "--yolo".into(),
        "--model".into(),
        OsString::from(gemini_model),
    ];

    let env = base_env(name, team_name, daemon_socket, app_socket_path);
    CliCommand {
        program,
        args,
        env,
        env_remove: vec![],
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_fresh_argv_order() {
        let cmd = build_claude_command(
            "explorer",
            "my-team",
            "sonnet",
            "/proj",
            "/tmp/term-meshd.sock",
            None,
            None,
            None,
            ClaudeSpawnMode::Fresh {
                session_id: "1a2b3c4d-1111-2222-3333-444455556666".into(),
            },
        );
        let argv: Vec<&str> = cmd.args.iter().map(|s| s.to_str().unwrap()).collect();
        assert_eq!(
            argv,
            vec![
                "--session-id",
                "1a2b3c4d-1111-2222-3333-444455556666",
                "--print",
                "--input-format",
                "stream-json",
                "--output-format",
                "stream-json",
                "--verbose",
                "--dangerously-skip-permissions",
                "--model",
                "sonnet",
            ]
        );
    }

    #[test]
    fn claude_resume_argv_uses_resume_flag() {
        let cmd = build_claude_command(
            "explorer",
            "my-team",
            "sonnet",
            "/proj",
            "/tmp/term-meshd.sock",
            None,
            None,
            None,
            ClaudeSpawnMode::Resume {
                session_id: "abc-resume".into(),
            },
        );
        assert_eq!(cmd.args[0], OsString::from("--resume"));
        assert_eq!(cmd.args[1], OsString::from("abc-resume"));
    }

    #[test]
    fn claude_append_system_prompt_passes_raw_bytes() {
        // Contains single quote — used to be corrupted by `replace('\'', "'\\''")`.
        let inst = b"You're an explorer. Say 'hello'.";
        let cmd = build_claude_command(
            "explorer",
            "my-team",
            "sonnet",
            "/proj",
            "/tmp/term-meshd.sock",
            None,
            None,
            Some(inst),
            ClaudeSpawnMode::Fresh {
                session_id: "uuid".into(),
            },
        );
        let last = cmd.args.last().unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::ffi::OsStrExt;
            assert_eq!(last.as_bytes(), inst);
        }
        // The --append-system-prompt flag is the penultimate arg.
        assert_eq!(
            cmd.args[cmd.args.len() - 2],
            OsString::from("--append-system-prompt")
        );
    }

    #[test]
    fn claude_empty_instructions_omits_flag() {
        let cmd = build_claude_command(
            "x",
            "t",
            "sonnet",
            "/p",
            "/tmp/s",
            None,
            None,
            Some(b""),
            ClaudeSpawnMode::Fresh {
                session_id: "u".into(),
            },
        );
        assert!(!cmd
            .args
            .iter()
            .any(|a| a == &OsString::from("--append-system-prompt")));
    }
}
