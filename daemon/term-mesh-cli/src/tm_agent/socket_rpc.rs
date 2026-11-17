use super::*;

// ── Socket / RPC infrastructure ──────────────────────────────────────

pub(crate) fn detect_socket() -> Option<PathBuf> {
    // Priority 1: Explicit environment variable (always wins)
    if let Ok(sock) = env::var("TERMMESH_SOCKET") {
        let p = PathBuf::from(&sock);
        if is_socket_alive(&p) {
            return Some(p);
        }
    }

    // Priority 1.5: The app control socket of the pane THIS process runs in.
    // Every term-mesh pane gets `TERMMESH_SOCKET_PATH` injected by the app
    // (GhosttyTerminalView -> SocketControlSettings.socketPath()); agent panes
    // additionally get `TERMMESH_SOCKET` (handled above). When multiple
    // term-mesh instances run side by side (e.g. production + a `--tag`/STAGING
    // build, each with its own daemon socket), the global last-socket-path file
    // and the `/tmp/*.sock` glob below can resolve to a SIBLING instance's
    // daemon — whose surface registry does not contain this pane's surface_id,
    // so team.attach / read / collect fail with `not_in_workspace`. The
    // pane-injected path is the authoritative socket for the caller, so it must
    // win over the global fallbacks.
    if let Ok(sock) = env::var("TERMMESH_SOCKET_PATH") {
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
pub(crate) fn is_socket_alive(path: &PathBuf) -> bool {
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

pub(crate) fn uid_is_trusted(peer_uid: u32, expected_uid: u32) -> bool {
    peer_uid == expected_uid || peer_uid == 0
}

pub(crate) fn doctor_expected_uid_from(uid: u32, sudo_uid: Option<u32>) -> u32 {
    if uid == 0 {
        sudo_uid.unwrap_or(0)
    } else {
        uid
    }
}

pub(crate) fn doctor_expected_uid() -> u32 {
    let uid = unsafe { libc::getuid() };
    let sudo_uid = env::var("SUDO_UID")
        .ok()
        .and_then(|value| value.parse().ok());
    doctor_expected_uid_from(uid, sudo_uid)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct DoctorPeerIdentity {
    pub(crate) uid: u32,
    pub(crate) pid: u32,
}

#[cfg(target_os = "linux")]
pub(crate) fn doctor_peer_identity(stream: &UnixStream) -> Option<DoctorPeerIdentity> {
    use std::os::fd::AsRawFd;
    let mut credential = std::mem::MaybeUninit::<libc::ucred>::zeroed();
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            credential.as_mut_ptr().cast(),
            &mut length,
        )
    };
    if result != 0 || (length as usize) < std::mem::size_of::<libc::ucred>() {
        return None;
    }
    let credential = unsafe { credential.assume_init() };
    Some(DoctorPeerIdentity {
        uid: credential.uid,
        pid: u32::try_from(credential.pid).ok()?,
    })
}

#[cfg(target_os = "macos")]
pub(crate) fn doctor_peer_identity(stream: &UnixStream) -> Option<DoctorPeerIdentity> {
    use std::os::fd::AsRawFd;
    const LOCAL_PEERPID: libc::c_int = 0x002;
    const SOL_LOCAL: libc::c_int = 0;

    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0 {
        return None;
    }
    let mut pid: libc::pid_t = 0;
    let mut length = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
    if unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            SOL_LOCAL,
            LOCAL_PEERPID,
            (&mut pid as *mut libc::pid_t).cast(),
            &mut length,
        )
    } != 0
        || (length as usize) < std::mem::size_of::<libc::pid_t>()
    {
        return None;
    }
    Some(DoctorPeerIdentity {
        uid,
        pid: u32::try_from(pid).ok()?,
    })
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub(crate) fn doctor_peer_identity(_stream: &UnixStream) -> Option<DoctorPeerIdentity> {
    None
}

pub(crate) fn rpc_call(sock: &PathBuf, method: &str, params: Value) -> Result<Value, String> {
    let timeout = env::var("TERMMESH_RPC_TIMEOUT")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(6);
    rpc_call_timeout(sock, method, params, timeout)
}

/// The durable request body crosses a file/RPC boundary before it reaches the
/// leader. Refuse to expose it to the model unless both integrity fields match
/// the bytes actually returned by the owning app.
/// Leader-side commands an adopted leader runs early and often: its inbox is
/// registered from them because term-mesh did not launch that session and so
/// could not give it a SessionStart hook.
pub(crate) fn reports_claude_inbox(command: &Commands) -> bool {
    matches!(
        command,
        Commands::Create { adopt: true, .. }
            | Commands::Wait { .. }
            | Commands::Leader(LeaderCommands::Request(LeaderRequestCommands::Take { .. }))
    )
}

pub(crate) fn claude_config_dir() -> Option<PathBuf> {
    match env::var("CLAUDE_CONFIG_DIR") {
        Ok(dir) if !dir.is_empty() => Some(PathBuf::from(dir)),
        _ => env::var("HOME")
            .ok()
            .map(|home| PathBuf::from(home).join(".claude")),
    }
}

/// A Claude background session (`/bg`) runs in the claude daemon's own pty,
/// not in a pane, and inherits the `TERMMESH_SURFACE_ID` of the pane that
/// started the daemon. `CLAUDE_CODE_SESSION_KIND=bg` is set on the session
/// process but not passed to its Bash children, so `CLAUDE_JOB_DIR`, which
/// only background sessions give their tools, is what a tool sees.
pub(crate) fn is_claude_background_session(env_var: &dyn Fn(&str) -> Option<String>) -> bool {
    env_var("CLAUDE_CODE_SESSION_KIND").is_some_and(|kind| kind.trim() == "bg")
        || env_var("CLAUDE_JOB_DIR").is_some_and(|dir| !dir.trim().is_empty())
}

/// What `claude.inbox.register` needs, from the environment Claude Code gives
/// its Bash children. `None` outside an interactive Claude session in a
/// term-mesh pane. The transcript and pid are looked up by session id: the
/// app confirms delivery from the transcript and detects `/clear` from the pid.
pub(crate) fn claude_inbox_params(
    env_var: &dyn Fn(&str) -> Option<String>,
    config_dir: &Path,
) -> Option<Value> {
    // The inherited surface is another session's pane; registering there
    // would take that pane's leader inbox.
    if is_claude_background_session(env_var) {
        return None;
    }
    let get = |name: &str| env_var(name).filter(|value| !value.is_empty());
    let surface = get("TERMMESH_SURFACE_ID")?;
    let socket = get("CLAUDE_CODE_MESSAGING_SOCKET")?;
    let token = get("CLAUDE_CODE_MESSAGING_TOKEN")?;
    let session = get("CLAUDE_CODE_SESSION_ID")?;
    let mut params = json!({
        "surface_id": surface,
        "socket_path": socket,
        "token": token,
        "session_id": session,
        "entrypoint": get("CLAUDE_CODE_ENTRYPOINT").unwrap_or_default(),
    });
    let transcript_name = format!("{session}.jsonl");
    if let Ok(projects) = fs::read_dir(config_dir.join("projects")) {
        if let Some(path) = projects
            .flatten()
            .map(|project| project.path().join(&transcript_name))
            .find(|path| path.is_file())
        {
            params["transcript_path"] = json!(path.to_string_lossy());
        }
    }
    if let Ok(sessions) = fs::read_dir(config_dir.join("sessions")) {
        for entry in sessions.flatten() {
            let path = entry.path();
            let Some(pid) = path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .map(str::to_owned)
            else {
                continue;
            };
            let Ok(text) = fs::read_to_string(&path) else {
                continue;
            };
            let Ok(record) = serde_json::from_str::<Value>(&text) else {
                continue;
            };
            if record.get("sessionId").and_then(Value::as_str) == Some(session.as_str()) {
                params["claude_pid"] = json!(pid);
                break;
            }
        }
    }
    Some(params)
}

/// Best effort and silent: the token is sent only to an app that says the
/// leader inbox is on, and is never printed.
pub(crate) fn report_claude_inbox(sock: &PathBuf) {
    let Some(config_dir) = claude_config_dir() else {
        return;
    };
    let Some(params) = claude_inbox_params(&|name| env::var(name).ok(), &config_dir) else {
        return;
    };
    let enabled = rpc_call_timeout(sock, "claude.inbox.status", json!({}), 2)
        .ok()
        .and_then(|response| response["result"]["leader_enabled"].as_bool())
        .unwrap_or(false);
    if enabled {
        let _ = rpc_call_timeout(sock, "claude.inbox.register", params, 2);
    }
}

#[cfg(test)]
mod claude_inbox_report_tests {
    use super::*;
    use std::collections::HashMap;

    const SESSION: &str = "14adb8a2-baf0-4435-9eaa-2a95cbc4490c";

    fn claude_env() -> HashMap<&'static str, String> {
        HashMap::from([
            (
                "TERMMESH_SURFACE_ID",
                "6216B81F-D848-4AB9-9222-0939A37E6753".to_string(),
            ),
            (
                "CLAUDE_CODE_MESSAGING_SOCKET",
                "/tmp/cc-socks/4242.sock".to_string(),
            ),
            ("CLAUDE_CODE_MESSAGING_TOKEN", "t".repeat(64)),
            ("CLAUDE_CODE_SESSION_ID", SESSION.to_string()),
            ("CLAUDE_CODE_ENTRYPOINT", "cli".to_string()),
        ])
    }

    fn params(env: &HashMap<&'static str, String>, dir: &Path) -> Option<Value> {
        claude_inbox_params(&|name| env.get(name).cloned(), dir)
    }

    #[test]
    fn an_interactive_session_reports_its_inbox_transcript_and_pid() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join("projects/-Users-me-work");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join(format!("{SESSION}.jsonl")), "{}\n").unwrap();
        fs::create_dir_all(dir.path().join("sessions")).unwrap();
        fs::write(
            dir.path().join("sessions/111.json"),
            r#"{"sessionId":"another"}"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("sessions/4242.json"),
            format!(r#"{{"sessionId":"{SESSION}"}}"#),
        )
        .unwrap();

        let params = params(&claude_env(), dir.path()).unwrap();
        assert_eq!(params["socket_path"], "/tmp/cc-socks/4242.sock");
        assert_eq!(params["session_id"], SESSION);
        assert_eq!(params["entrypoint"], "cli");
        assert_eq!(params["claude_pid"], "4242");
        assert_eq!(
            params["transcript_path"],
            project
                .join(format!("{SESSION}.jsonl"))
                .to_string_lossy()
                .as_ref()
        );
    }

    #[test]
    fn a_session_without_its_transcript_or_registry_entry_still_reports_the_inbox() {
        let dir = tempfile::tempdir().unwrap();
        let params = params(&claude_env(), dir.path()).unwrap();
        assert!(params.get("transcript_path").is_none());
        assert!(params.get("claude_pid").is_none());
    }

    #[test]
    fn nothing_is_reported_outside_a_claude_session_in_a_term_mesh_pane() {
        let dir = tempfile::tempdir().unwrap();
        for missing in [
            "TERMMESH_SURFACE_ID",
            "CLAUDE_CODE_MESSAGING_SOCKET",
            "CLAUDE_CODE_MESSAGING_TOKEN",
            "CLAUDE_CODE_SESSION_ID",
        ] {
            let mut env = claude_env();
            env.insert(missing, String::new());
            assert!(params(&env, dir.path()).is_none(), "{missing} empty");
            env.remove(missing);
            assert!(params(&env, dir.path()).is_none(), "{missing} unset");
        }
    }

    #[test]
    fn a_background_session_does_not_take_the_launching_panes_inbox() {
        let dir = tempfile::tempdir().unwrap();
        let mut env = claude_env();
        env.insert(
            "CLAUDE_JOB_DIR",
            "/Users/me/.claude/jobs/99e1e8fa".to_string(),
        );
        assert!(params(&env, dir.path()).is_none());
    }

    #[test]
    fn only_leader_side_commands_report() {
        let parse = |args: &[&str]| Cli::try_parse_from(args).unwrap().command;
        assert!(reports_claude_inbox(&parse(&["tm-agent", "wait"])));
        assert!(reports_claude_inbox(&parse(&[
            "tm-agent", "create", "0", "--adopt"
        ])));
        assert!(reports_claude_inbox(&parse(&[
            "tm-agent", "leader", "request", "take", "lr-1"
        ])));
        assert!(!reports_claude_inbox(&parse(&["tm-agent", "create", "2"])));
        assert!(!reports_claude_inbox(&parse(&["tm-agent", "status"])));
    }
}

pub(crate) fn verify_leader_request_response(response: Value) -> Result<Value, String> {
    // Integrity fields exist only on a successful claim. Preserve an RPC
    // failure envelope verbatim so the caller sees `invalid_state`,
    // `unauthorized`, etc. instead of replacing it with a misleading missing
    // result/content protocol error.
    if rpc_response_failed(&response) {
        return Ok(response);
    }
    let result = response
        .get("result")
        .ok_or_else(|| "PROTOCOL_ERROR: leader request response has no result".to_string())?;
    let content = result["content"]
        .as_str()
        .ok_or_else(|| "PROTOCOL_ERROR: leader request response has no content".to_string())?;
    let expected_bytes = result["content_bytes"].as_u64().ok_or_else(|| {
        "PROTOCOL_ERROR: leader request response has no content_bytes".to_string()
    })?;
    let expected_sha = result["content_sha256"].as_str().ok_or_else(|| {
        "PROTOCOL_ERROR: leader request response has no content_sha256".to_string()
    })?;
    let actual_bytes = content.len() as u64;
    let actual_sha = format!("{:x}", Sha256::digest(content.as_bytes()));
    if actual_bytes != expected_bytes || actual_sha != expected_sha {
        return Err(format!(
            "INTEGRITY_ERROR: durable leader request mismatch \
             (bytes expected={expected_bytes} actual={actual_bytes}, \
             sha256 expected={expected_sha} actual={actual_sha})"
        ));
    }
    Ok(response)
}

#[cfg(test)]
mod durable_leader_request_tests {
    use super::*;

    #[test]
    fn verifies_long_unicode_content() {
        let content = "한글🙂 quoted payload".repeat(80);
        let response = json!({
            "ok": true,
            "result": {
                "content": content,
                "content_bytes": content.len(),
                "content_sha256": format!("{:x}", Sha256::digest(content.as_bytes())),
            }
        });
        assert!(verify_leader_request_response(response).is_ok());
    }

    #[test]
    fn rejects_truncated_content() {
        let full = "한글🙂 payload".repeat(80);
        let boundary = full.char_indices().nth(40).unwrap().0;
        let truncated = &full[..boundary];
        let response = json!({
            "ok": true,
            "result": {
                "content": truncated,
                "content_bytes": full.len(),
                "content_sha256": format!("{:x}", Sha256::digest(full.as_bytes())),
            }
        });
        let error = verify_leader_request_response(response).unwrap_err();
        assert!(error.contains("INTEGRITY_ERROR"));
    }

    #[test]
    fn preserves_rpc_failure_before_integrity_validation() {
        let response = json!({
            "ok": false,
            "error": {"code": "invalid_state", "message": "already claimed"}
        });
        assert_eq!(
            verify_leader_request_response(response.clone()).unwrap(),
            response
        );
    }
}

pub(crate) fn local_rpc_call_timeout_duration(
    sock: &PathBuf,
    method: &str,
    params: Value,
    timeout: Duration,
) -> Result<Value, String> {
    let deadline = Instant::now() + timeout;
    let stream = UnixStream::connect(sock).map_err(|e| format!("connect: {e}"))?;
    stream.set_write_timeout(Some(timeout)).ok();

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

    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err("RPC deadline expired before response read".to_string());
    }
    stream.set_read_timeout(Some(remaining)).ok();

    let mut reader = BufReader::new(&stream);
    let mut response = String::new();
    reader
        .read_line(&mut response)
        .map_err(|e| format!("read: {e}"))?;

    if response.trim().is_empty() {
        return Err(json!({
            "code": "no_app",
            "message": "no active term-mesh app — launch the app or run /team-up to bootstrap a team"
        })
        .to_string());
    }
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
pub(crate) fn rpc_call_with_reader(
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

    if response.trim().is_empty() {
        return Err(json!({
            "code": "no_app",
            "message": "no active term-mesh app — launch the app or run /team-up to bootstrap a team"
        })
        .to_string());
    }
    serde_json::from_str(&response).map_err(|e| format!("parse: {e}"))
}

/// Send multiple JSON-RPC calls over a single connection.
pub(crate) fn rpc_batch(sock: &PathBuf, payloads: &[String]) -> Result<Vec<Value>, String> {
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

/// Batch counterpart for a remote leader: one policy-routed call per payload,
/// in order. A failed call becomes an `{"error": ...}` entry, as in
/// `rpc_batch`, so the output keeps one entry per payload.
pub(crate) fn rpc_batch_per_call(
    payloads: &[String],
    mut call: impl FnMut(&str, Value) -> Result<Value, String>,
) -> Result<Vec<Value>, String> {
    let mut requests = Vec::with_capacity(payloads.len());
    for (i, payload) in payloads.iter().enumerate() {
        let request: Value = serde_json::from_str(payload)
            .map_err(|e| format!("invalid JSON in payload {i}: {e}"))?;
        let method = request["method"]
            .as_str()
            .ok_or_else(|| format!("payload {i} has no method"))?
            .to_string();
        let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
        requests.push((method, params));
    }
    Ok(requests
        .into_iter()
        .map(|(method, params)| call(&method, params).unwrap_or_else(|e| json!({ "error": e })))
        .collect())
}

pub(crate) fn run_raw_routed(sock: &PathBuf, payload: &str) -> Result<Value, String> {
    rpc_batch_per_call(&[payload.to_string()], |method, params| {
        rpc_call(sock, method, params)
    })
    .and_then(|mut results| results.pop().ok_or_else(|| "no response".to_string()))
}

/// Parse human-readable semicolon-separated commands into JSON-RPC payload strings
/// for use with `rpc_batch`. Supported verbs: status, task list, send, broadcast.
pub(crate) fn parse_batch_commands(commands: &str, team: &str) -> Result<Vec<String>, String> {
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
                        "text": format!("{text}\n"),
                        "send_sequence_aware": true
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
