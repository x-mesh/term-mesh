use std::path::PathBuf;

/// Configuration for spawning a headless agent subprocess.
pub struct CliCommand {
    pub program: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

/// Build the CLI command for a Claude Code agent in stream-json mode.
pub fn build_claude_command(
    name: &str,
    team_name: &str,
    model: &str,
    _working_directory: &str,
    daemon_socket: &str,
) -> CliCommand {
    let claude_path = std::env::var("CLAUDE_PATH")
        .unwrap_or_else(|_| "claude".to_string());

    let agent_id = format!("{name}@{team_name}");

    let args = vec![
        "--input-format".into(), "stream-json".into(),
        "--output-format".into(), "stream-json".into(),
        "--verbose".into(),
        "--dangerously-skip-permissions".into(),
        "--model".into(), model.to_string(),
    ];

    let env = vec![
        ("TERMMESH_SOCKET".into(), daemon_socket.to_string()),
        ("TERMMESH_TEAM".into(), team_name.to_string()),
        ("TERMMESH_AGENT_NAME".into(), name.to_string()),
        ("TERMMESH_AGENT_ID".into(), agent_id),
        ("TERMMESH_HEADLESS".into(), "1".to_string()),
    ];

    CliCommand {
        program: claude_path,
        args,
        env,
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
