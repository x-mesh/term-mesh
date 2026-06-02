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

/// Standard user-level bin directories where agent CLIs (codex, gemini, kiro,
/// claude) are commonly installed. Only directories that actually exist are
/// returned, so the composed PATH stays clean.
///
/// Covers: pipx/uv/manual (`~/.local/bin`, where `codex` lands), rust
/// (`~/.cargo/bin`), bun (`~/.bun/bin`), go (`~/go/bin`), npm global prefixes,
/// `~/bin`, and Homebrew (`/opt/homebrew/{bin,sbin}` Apple Silicon,
/// `/usr/local/{bin,sbin}` Intel).
fn user_bin_dirs() -> Vec<String> {
    let mut out: Vec<PathBuf> = Vec::new();
    if let Some(home) = dirs::home_dir() {
        for rel in [
            ".local/bin",
            ".cargo/bin",
            "bin",
            "go/bin",
            ".bun/bin",
            ".npm-global/bin",
            ".npm-packages/bin",
        ] {
            out.push(home.join(rel));
        }
    }
    for abs in [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
    ] {
        out.push(PathBuf::from(abs));
    }
    out.into_iter()
        .filter(|p| p.is_dir())
        .map(|p| p.to_string_lossy().into_owned())
        .collect()
}

/// Compose the PATH for a headless agent subprocess.
///
/// A GUI-launched daemon (Finder/Spotlight/launchd) inherits a minimal PATH that
/// omits user-level bin dirs, so spawning a CLI installed in e.g. `~/.local/bin`
/// (codex) fails with "No such file or directory" — even though it is installed.
/// This prepends the daemon's own `Resources/bin` and the standard user bin dirs
/// ahead of the inherited PATH, deduplicating while preserving order
/// (daemon bin → user bins → inherited PATH).
fn compose_agent_path(daemon_bin_dir: &str, current_path: &str) -> String {
    let mut seen = std::collections::HashSet::new();
    let mut parts: Vec<String> = Vec::new();
    let candidates = std::iter::once(daemon_bin_dir.to_string())
        .chain(user_bin_dirs())
        .chain(current_path.split(':').map(str::to_string));
    for p in candidates {
        if p.is_empty() {
            continue;
        }
        if seen.insert(p.clone()) {
            parts.push(p);
        }
    }
    parts.join(":")
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

    // Compose a PATH that includes the daemon's own binary directory (Resources/bin)
    // AND standard user-level bin dirs. When the app is launched from
    // Finder/Spotlight/launchd, macOS provides a minimal PATH that omits both
    // Resources/bin and user dirs like ~/.local/bin, so a headless spawn of e.g.
    // `codex` fails with "No such file or directory". Pane mode handles this in
    // TeamOrchestrator.swift; headless mode inherits the daemon's PATH and must
    // recover the missing entries here.
    let daemon_bin_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_string_lossy().to_string()))
        .unwrap_or_default();
    let current_path = std::env::var("PATH").unwrap_or_default();
    let path = compose_agent_path(&daemon_bin_dir, &current_path);

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
    extra_args: &[String],
    extra_env: &std::collections::HashMap<String, String>,
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
    // "opus" and legacy "opus-1m" both resolve to claude-opus-4-8[1m].
    let resolved_model = match model {
        "opus" | "opus-1m" => "claude-opus-4-8[1m]",
        other => other,
    };
    args.push(OsString::from(resolved_model));

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

    for arg in extra_args {
        args.push(OsString::from(arg));
    }

    // extra_env first so base_env values take precedence on key collision.
    let mut env: Vec<(String, String)> = extra_env
        .iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    env.extend(base_env(name, team_name, daemon_socket, app_socket_path));

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
        "opus" => "claude-opus-4.8",
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
    extra_args: &[String],
    extra_env: &std::collections::HashMap<String, String>,
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
    let mut args: Vec<OsString> = vec![
        "chat".into(),
        "--trust-all-tools".into(),
        "--wrap".into(),
        "never".into(),
        "--agent".into(),
        OsString::from(&profile_name),
        "--model".into(),
        OsString::from(kiro_model),
    ];

    for arg in extra_args {
        args.push(OsString::from(arg));
    }

    let mut env: Vec<(String, String)> = extra_env
        .iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    env.extend(base_env(name, team_name, daemon_socket, app_socket_path));

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
    extra_args: &[String],
    extra_env: &std::collections::HashMap<String, String>,
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

    for arg in extra_args {
        args.push(OsString::from(arg));
    }

    let mut env: Vec<(String, String)> = extra_env
        .iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    env.extend(base_env(name, team_name, daemon_socket, app_socket_path));

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
    extra_args: &[String],
    extra_env: &std::collections::HashMap<String, String>,
) -> CliCommand {
    let program = resolve_cli_path(cli_path, "GEMINI_PATH", "gemini");

    let gemini_model = gemini_model_name(model);
    let mut args: Vec<OsString> = vec![
        "--yolo".into(),
        "--model".into(),
        OsString::from(gemini_model),
    ];

    for arg in extra_args {
        args.push(OsString::from(arg));
    }

    let mut env: Vec<(String, String)> = extra_env
        .iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    env.extend(base_env(name, team_name, daemon_socket, app_socket_path));

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
    fn compose_agent_path_prepends_daemon_bin_and_dedupes() {
        // daemon bin already present in inherited PATH must not duplicate, and
        // must sit first. Inherited entries are preserved after user bins.
        let out = compose_agent_path("/app/Resources/bin", "/app/Resources/bin:/usr/bin:/bin");
        let parts: Vec<&str> = out.split(':').collect();
        assert_eq!(parts[0], "/app/Resources/bin", "daemon bin must be first");
        assert_eq!(
            parts.iter().filter(|p| **p == "/app/Resources/bin").count(),
            1,
            "no duplicate daemon bin"
        );
        assert!(parts.contains(&"/usr/bin"));
        assert!(parts.contains(&"/bin"));
    }

    #[test]
    fn compose_agent_path_skips_empty_segments() {
        let out = compose_agent_path("", "::/usr/bin:");
        let parts: Vec<&str> = out.split(':').collect();
        assert!(!parts.iter().any(|p| p.is_empty()), "no empty PATH segments");
        assert!(parts.contains(&"/usr/bin"));
    }

    #[test]
    fn base_env_path_includes_inherited_entries() {
        // Regardless of which user bin dirs exist on the test host, the inherited
        // PATH entries must survive into the agent env (the codex-spawn fix only
        // *prepends*; it never drops the daemon's existing PATH).
        let env = base_env("watcher", "t1", "/tmp/d.sock", None);
        let path = env
            .iter()
            .find(|(k, _)| k == "PATH")
            .map(|(_, v)| v.clone())
            .unwrap_or_default();
        let inherited = std::env::var("PATH").unwrap_or_default();
        for entry in inherited.split(':').filter(|s| !s.is_empty()) {
            assert!(
                path.split(':').any(|p| p == entry),
                "inherited PATH entry {entry} dropped from agent PATH"
            );
        }
    }

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
            &[],
            &std::collections::HashMap::new(),
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
            &[],
            &std::collections::HashMap::new(),
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
            &[],
            &std::collections::HashMap::new(),
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
            &[],
            &std::collections::HashMap::new(),
        );
        assert!(!cmd
            .args
            .iter()
            .any(|a| a == &OsString::from("--append-system-prompt")));
    }
}
