//! Peer-federation client for tm-agent.
//!
//! Phase 2.2b shipped a line-buffered PoC. Phase 2.3B-b.2 adds:
//!   - termios raw mode so each keystroke reaches the remote immediately
//!     (vim, less, etc. behave correctly)
//!   - SIGWINCH → Resize frame so the remote PTY reflows on window resize
//!   - Ctrl-] detach key (line-based Ctrl-D EOF no longer reaches us under
//!     raw mode)
//!   - All outgoing frames serialized through a single writer thread so
//!     SIGWINCH, stdin, and handshake-follow-up writes don't race.

use std::io::{self, Read, Write};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::fs::FileTypeExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicI32, AtomicU64, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant};

use peer_proto::v1::envelope::Payload;
use peer_proto::v1::workspace_layout::Node as LayoutNode;
use peer_proto::v1::{
    AttachMode, AttachSurface, Auth, EnsureSurfaceRequest, EnsureSurfaceResponse,
    EnsureSurfaceRestartPolicy, EnsureSurfaceResult, Envelope, Goodbye, Hello, Input, ListSurfaces,
    ListWorkspaces, Resize, TerminateSurfaceRequest, TerminateSurfaceResponse,
    TerminateSurfaceResult, Workspace, WorkspaceLayout,
};
use peer_proto::{capability, PeerCapabilities, MAX_FRAME_BYTES};
use prost::Message;
use serde_json::{json, Value};

const PROTOCOL_VERSION: &str = "1.0.0";
const DEFAULT_COLS: u32 = 80;
const DEFAULT_ROWS: u32 = 24;
/// Ctrl-] — same convention as telnet. One keystroke, no two-step escape.
const DETACH_KEY: u8 = 0x1d;
const REMOTE_SOCKET_PROBE: &str = r#"sh -c 'p=$(sed -n "s/^TERMMESH_PEER_SOCKET=//p" "$HOME/.config/term-mesh/peer.env" 2>/dev/null | tail -n 1 | sed "s/^[[:space:]]*//;s/[[:space:]]*$//;s/^\"//;s/\"$//"); for c in "$p" "${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/tm-peer.sock}" "/run/user/$(id -u)/tm-peer.sock" "/tmp/term-mesh-peer-$(id -u)/peer.sock"; do [ -n "$c" ] && [ -S "$c" ] && { printf "%s" "$c"; exit 0; }; done; if (command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet term-meshd) || pgrep -u "$(id -u)" -x term-meshd >/dev/null 2>&1; then exit 44; fi; exit 43'"#;

#[derive(Clone, Copy)]
pub enum RestartPolicy {
    Never,
    OnDaemonRestart,
}

#[derive(Debug)]
struct PeerCliError {
    code: &'static str,
    stage: &'static str,
}

impl PeerCliError {
    fn new(code: &'static str, stage: &'static str, _detail: impl Into<String>) -> Self {
        Self { code, stage }
    }

    fn json(&self, host: &str) -> Value {
        json!({
            "error": {
                "code": self.code,
                "detail": public_error_context(self.code),
                "stage": self.stage,
            },
            "host": host,
            "ok": false,
        })
    }
}

struct RemotePeer {
    child: Child,
    local_socket: PathBuf,
    private_dir: PathBuf,
    remote_socket: String,
}

#[derive(Debug, PartialEq, Eq)]
struct ResolvedSshConfig {
    hostname: String,
    user: String,
    port: u16,
    identity_files: Vec<String>,
    certificate_files: Vec<String>,
    identities_only: bool,
    identity_agent: Option<String>,
    host_key_alias: Option<String>,
    user_known_hosts_file: Option<String>,
    global_known_hosts_file: Option<String>,
    strict_host_key_checking: String,
    check_host_ip: bool,
    hash_known_hosts: bool,
    verify_host_key_dns: String,
    update_host_keys: String,
    revoked_host_keys: Option<String>,
}

fn public_error_context(code: &str) -> &'static str {
    match code {
        "SSH_AUTH_FAILED" | "PEER_AUTH_FAILED" => "authentication failed",
        "DAEMON_UNAVAILABLE" => "remote daemon is unavailable",
        "SOCKET_UNAVAILABLE" | "SOCKET_CONNECT_FAILED" | "SOCKET_FORWARD_TIMEOUT" => {
            "peer socket is unavailable"
        }
        "INVALID_HOST"
        | "INVALID_SOCKET_PATH"
        | "INVALID_SURFACE_ID"
        | "INVALID_CWD"
        | "INVALID_EXECUTABLE" => "request validation failed",
        _ => "peer operation failed",
    }
}

impl Drop for RemotePeer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.private_dir);
    }
}

impl RemotePeer {
    fn open(host: &str, remote_socket: Option<&str>) -> Result<Self, PeerCliError> {
        validate_ssh_target(host)?;
        let ssh_config = resolve_ssh_config(host)?;
        let remote_socket = match remote_socket {
            Some(path) => path.to_string(),
            None => probe_remote_socket(host)?,
        };
        validate_remote_socket(&remote_socket)?;
        let private_dir = create_private_tunnel_dir()?;
        let local_socket = private_dir.join("peer.sock");
        let control_socket = private_dir.join("control.sock");
        let forward = format!("{}:{}", local_socket.display(), remote_socket);
        let mut child = Command::new("/usr/bin/ssh")
            .args(ssh_master_args(host, &control_socket))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| {
                let _ = std::fs::remove_dir_all(&private_dir);
                PeerCliError::new("SSH_SPAWN_FAILED", "ssh", e.to_string())
            })?;

        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            match tunnel_is_ready(&mut child, &control_socket) {
                Ok(true) => break,
                Ok(false) => {}
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    let _ = std::fs::remove_dir_all(&private_dir);
                    return Err(error);
                }
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                let _ = std::fs::remove_dir_all(&private_dir);
                return Err(PeerCliError::new(
                    "SSH_TUNNEL_FAILED",
                    "ssh",
                    "SSH control socket did not appear",
                ));
            }
            thread::sleep(Duration::from_millis(25));
        }
        let mut forward_child = match Command::new("/usr/bin/ssh")
            .args(ssh_forward_args(&ssh_config, &control_socket, &forward))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(child) => child,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = std::fs::remove_dir_all(&private_dir);
                return Err(PeerCliError::new(
                    "SSH_TUNNEL_FAILED",
                    "ssh",
                    error.to_string(),
                ));
            }
        };
        if let Err(error) = wait_for_forward_command(&mut child, &mut forward_child, deadline) {
            let _ = std::fs::remove_dir_all(&private_dir);
            return Err(error);
        }
        loop {
            let ready = match tunnel_is_ready(&mut child, &local_socket) {
                Ok(ready) => ready,
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    let _ = std::fs::remove_dir_all(&private_dir);
                    return Err(error);
                }
            };
            if ready {
                return Ok(Self {
                    child,
                    local_socket,
                    private_dir,
                    remote_socket,
                });
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                let _ = std::fs::remove_dir_all(&private_dir);
                return Err(PeerCliError::new(
                    "SOCKET_FORWARD_TIMEOUT",
                    "socket",
                    "forwarded socket did not appear",
                ));
            }
            thread::sleep(Duration::from_millis(25));
        }
    }
}

fn tunnel_is_ready(child: &mut Child, local_socket: &Path) -> Result<bool, PeerCliError> {
    if let Some(status) = child
        .try_wait()
        .map_err(|error| PeerCliError::new("SSH_TUNNEL_FAILED", "ssh", error.to_string()))?
    {
        return Err(PeerCliError::new(
            "SSH_TUNNEL_FAILED",
            "ssh",
            format!("ssh exited with status {}", status.code().unwrap_or(-1)),
        ));
    }
    Ok(is_unix_socket(local_socket))
}

fn wait_for_forward_command(
    master: &mut Child,
    control: &mut Child,
    deadline: Instant,
) -> Result<(), PeerCliError> {
    loop {
        match master.try_wait() {
            Ok(Some(status)) => {
                terminate_ssh_children(master, control);
                return Err(PeerCliError::new(
                    "SSH_TUNNEL_FAILED",
                    "ssh",
                    format!("ssh exited with status {}", status.code().unwrap_or(-1)),
                ));
            }
            Ok(None) => {}
            Err(_) => {
                terminate_ssh_children(master, control);
                return Err(PeerCliError::new(
                    "SSH_TUNNEL_FAILED",
                    "ssh",
                    "failed to poll SSH master",
                ));
            }
        }
        match control.try_wait() {
            Ok(Some(status)) if status.success() => {
                // Close the small race between the master poll above and a
                // successful control exit. The socket loop checks it again.
                match master.try_wait() {
                    Ok(None) => return Ok(()),
                    Ok(Some(status)) => {
                        terminate_ssh_children(master, control);
                        return Err(PeerCliError::new(
                            "SSH_TUNNEL_FAILED",
                            "ssh",
                            format!("ssh exited with status {}", status.code().unwrap_or(-1)),
                        ));
                    }
                    Err(_) => {
                        terminate_ssh_children(master, control);
                        return Err(PeerCliError::new(
                            "SSH_TUNNEL_FAILED",
                            "ssh",
                            "failed to poll SSH master",
                        ));
                    }
                }
            }
            Ok(Some(_)) => {
                terminate_ssh_children(master, control);
                return Err(PeerCliError::new(
                    "SSH_TUNNEL_FAILED",
                    "ssh",
                    "SSH control forward failed",
                ));
            }
            Ok(None) => {}
            Err(_) => {
                terminate_ssh_children(master, control);
                return Err(PeerCliError::new(
                    "SSH_TUNNEL_FAILED",
                    "ssh",
                    "failed to poll SSH control command",
                ));
            }
        }
        if Instant::now() >= deadline {
            terminate_ssh_children(master, control);
            return Err(PeerCliError::new(
                "SSH_TUNNEL_FAILED",
                "ssh",
                "SSH control forward timed out",
            ));
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn terminate_ssh_children(master: &mut Child, control: &mut Child) {
    let _ = control.kill();
    let _ = master.kill();
    let _ = control.wait();
    let _ = master.wait();
}

fn create_private_tunnel_dir() -> Result<PathBuf, PeerCliError> {
    for _ in 0..16 {
        let name = format!("tm-agent-peer-{}", hex_full(&random_16_bytes()));
        // Keep the full Unix-socket pathname under macOS's short SUN_LEN.
        let path = Path::new("/tmp").join(name);
        match std::fs::DirBuilder::new().mode(0o700).create(&path) {
            Ok(()) => return Ok(path),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(PeerCliError::new(
                    "PRIVATE_DIR_FAILED",
                    "socket",
                    error.to_string(),
                ))
            }
        }
    }
    Err(PeerCliError::new(
        "PRIVATE_DIR_FAILED",
        "socket",
        "could not allocate private tunnel directory",
    ))
}

#[derive(Clone, Copy)]
enum TrustPathMode {
    #[cfg(test)]
    FailClosed,
    OriginalConfigMaster,
}

fn config_line_parts(line: &str) -> Option<(&str, &str)> {
    let delimiter = line.find(|character| character == ' ' || character == '\t')?;
    Some((&line[..delimiter], &line[delimiter + 1..]))
}

#[cfg(test)]
fn parse_ssh_config(output: &str) -> Result<ResolvedSshConfig, PeerCliError> {
    parse_ssh_config_with_mode(output, TrustPathMode::FailClosed)
}

fn parse_ssh_config_with_mode(
    output: &str,
    trust_path_mode: TrustPathMode,
) -> Result<ResolvedSshConfig, PeerCliError> {
    let mut hostname = None;
    let mut user = None;
    let mut port = None;
    let mut identity_files = Vec::new();
    let mut certificate_files = Vec::new();
    let mut identities_only = false;
    let mut identity_agent = None;
    let mut proxy_jump = None;
    let mut proxy_command = None;
    let mut known_hosts_command = None;
    let mut host_key_alias = None;
    #[cfg(test)]
    let mut user_known_hosts_file = None;
    #[cfg(test)]
    let mut global_known_hosts_file = None;
    let mut strict_host_key_checking = "ask".to_string();
    let mut check_host_ip = false;
    let mut hash_known_hosts = false;
    let mut verify_host_key_dns = "no".to_string();
    let mut update_host_keys = "no".to_string();
    let mut revoked_host_keys = None;
    for line in output.lines() {
        let Some((key, value)) = config_line_parts(line) else {
            continue;
        };
        match key {
            "hostname" => hostname = Some(value.to_string()),
            "user" => user = Some(value.to_string()),
            "port" => port = value.parse::<u16>().ok(),
            "identityfile" => identity_files.push(value.to_string()),
            "certificatefile" if value != "none" => certificate_files.push(value.to_string()),
            "identitiesonly" => identities_only = value == "yes",
            "identityagent" => identity_agent = Some(value.to_string()),
            "proxyjump" if value != "none" => proxy_jump = Some(value.to_string()),
            "proxycommand" => proxy_command = Some(value.to_string()),
            "knownhostscommand" => known_hosts_command = Some(value.to_string()),
            "hostkeyalias" if value != "none" => host_key_alias = Some(value.to_string()),
            #[cfg(test)]
            "userknownhostsfile" => user_known_hosts_file = Some(value.to_string()),
            #[cfg(test)]
            "globalknownhostsfile" => global_known_hosts_file = Some(value.to_string()),
            "stricthostkeychecking" => strict_host_key_checking = value.to_string(),
            "checkhostip" => check_host_ip = value == "yes",
            "hashknownhosts" => hash_known_hosts = value == "yes",
            "verifyhostkeydns" => verify_host_key_dns = value.to_string(),
            "updatehostkeys" => update_host_keys = value.to_string(),
            "revokedhostkeys" if value != "none" => revoked_host_keys = Some(value.to_string()),
            _ => {}
        }
    }
    let (user_known_hosts_file, global_known_hosts_file) = match trust_path_mode {
        #[cfg(test)]
        TrustPathMode::FailClosed => (
            reconcile_known_hosts_value(user_known_hosts_file)?,
            reconcile_known_hosts_value(global_known_hosts_file)?,
        ),
        // The original config is consumed only by the no-forward master, so
        // trust path values are neither reconstructed nor re-emitted.
        TrustPathMode::OriginalConfigMaster => (None, None),
    };
    let config = ResolvedSshConfig {
        hostname: hostname.ok_or_else(|| {
            PeerCliError::new("SSH_CONFIG_FAILED", "ssh", "ssh -G omitted hostname")
        })?,
        user: user
            .ok_or_else(|| PeerCliError::new("SSH_CONFIG_FAILED", "ssh", "ssh -G omitted user"))?,
        port: port.ok_or_else(|| {
            PeerCliError::new("SSH_CONFIG_FAILED", "ssh", "ssh -G omitted valid port")
        })?,
        identity_files,
        certificate_files,
        identities_only,
        identity_agent,
        host_key_alias,
        user_known_hosts_file,
        global_known_hosts_file,
        strict_host_key_checking,
        check_host_ip,
        hash_known_hosts,
        verify_host_key_dns,
        update_host_keys,
        revoked_host_keys,
    };
    if proxy_jump.is_some() {
        return Err(PeerCliError::new(
            "UNSUPPORTED_SSH_CONFIG",
            "ssh",
            "ProxyJump is not supported by the sanitized SSH transport",
        ));
    }
    if proxy_command
        .as_deref()
        .is_some_and(|value| value != "none")
    {
        return Err(PeerCliError::new(
            "UNSUPPORTED_PROXY_COMMAND",
            "ssh",
            "ProxyCommand is not supported by the sanitized SSH transport",
        ));
    }
    if known_hosts_command
        .as_deref()
        .is_some_and(|value| value != "none")
    {
        return Err(PeerCliError::new(
            "UNSUPPORTED_SSH_CONFIG",
            "ssh",
            "KnownHostsCommand is not supported by the sanitized SSH transport",
        ));
    }
    validate_ssh_target(&config.hostname)?;
    validate_ssh_target(&config.user)?;
    for value in config
        .identity_files
        .iter()
        .chain(config.certificate_files.iter())
        .chain(config.identity_agent.iter())
        .chain(config.host_key_alias.iter())
        .chain(config.user_known_hosts_file.iter())
        .chain(config.global_known_hosts_file.iter())
        .chain(std::iter::once(&config.strict_host_key_checking))
        .chain(std::iter::once(&config.verify_host_key_dns))
        .chain(std::iter::once(&config.update_host_keys))
        .chain(config.revoked_host_keys.iter())
    {
        validate_resolved_ssh_value(value)?;
    }
    Ok(config)
}

#[cfg(test)]
fn reconcile_known_hosts_value(value: Option<String>) -> Result<Option<String>, PeerCliError> {
    let Some(value) = value else { return Ok(None) };
    if value.bytes().any(|byte| byte.is_ascii_whitespace()) {
        return Err(PeerCliError::new(
            "UNSUPPORTED_SSH_CONFIG",
            "ssh",
            "known-hosts path boundaries are ambiguous in ssh -G output",
        ));
    }
    Ok(Some(value))
}

fn validate_resolved_ssh_value(value: &str) -> Result<(), PeerCliError> {
    if value.is_empty()
        || value.starts_with('-')
        || value.bytes().any(|byte| byte.is_ascii_control())
    {
        return Err(PeerCliError::new(
            "SSH_CONFIG_FAILED",
            "ssh",
            "ssh -G returned an unsafe option value",
        ));
    }
    Ok(())
}

fn ssh_master_args(host: &str, control_socket: &Path) -> Vec<String> {
    vec![
        "-M".into(),
        "-S".into(),
        control_socket.display().to_string(),
        "-N".into(),
        "-T".into(),
        "-x".into(),
        "-o".into(),
        "ControlMaster=yes".into(),
        "-o".into(),
        "ControlPersist=no".into(),
        "-o".into(),
        "ForkAfterAuthentication=no".into(),
        "-o".into(),
        "ClearAllForwardings=yes".into(),
        "-o".into(),
        "PermitLocalCommand=no".into(),
        "-o".into(),
        "LogLevel=ERROR".into(),
        "-o".into(),
        "ConnectTimeout=10".into(),
        "-o".into(),
        "BatchMode=yes".into(),
        "--".into(),
        host.into(),
    ]
}

fn ssh_forward_args(
    config: &ResolvedSshConfig,
    control_socket: &Path,
    forward: &str,
) -> Vec<String> {
    vec![
        "-F".into(),
        "/dev/null".into(),
        "-S".into(),
        control_socket.display().to_string(),
        "-O".into(),
        "forward".into(),
        "-L".into(),
        forward.into(),
        "-l".into(),
        config.user.clone(),
        "-p".into(),
        config.port.to_string(),
        "--".into(),
        config.hostname.clone(),
    ]
}

fn resolve_ssh_config(host: &str) -> Result<ResolvedSshConfig, PeerCliError> {
    let output = Command::new("/usr/bin/ssh")
        .args(["-G", "--", host])
        .stdin(Stdio::null())
        .output()
        .map_err(|e| PeerCliError::new("SSH_CONFIG_FAILED", "ssh", e.to_string()))?;
    if !output.status.success() {
        return Err(PeerCliError::new(
            "SSH_CONFIG_FAILED",
            "ssh",
            "ssh -G failed",
        ));
    }
    let output = decode_ssh_g_stdout(output.stdout)?;
    parse_ssh_config_with_mode(&output, TrustPathMode::OriginalConfigMaster)
}

fn decode_ssh_g_stdout(output: Vec<u8>) -> Result<String, PeerCliError> {
    String::from_utf8(output).map_err(|_| {
        PeerCliError::new(
            "SSH_CONFIG_FAILED",
            "ssh",
            "ssh -G output is not valid UTF-8",
        )
    })
}

fn ssh_probe_args(host: &str) -> Vec<String> {
    vec![
        "-T".into(),
        "-x".into(),
        "-S".into(),
        "none".into(),
        "-o".into(),
        "ClearAllForwardings=yes".into(),
        "-o".into(),
        "PermitLocalCommand=no".into(),
        "-o".into(),
        "LogLevel=ERROR".into(),
        "-o".into(),
        "ConnectTimeout=10".into(),
        "-o".into(),
        "BatchMode=yes".into(),
        "--".into(),
        host.into(),
        REMOTE_SOCKET_PROBE.into(),
    ]
}

fn validate_ssh_target(host: &str) -> Result<(), PeerCliError> {
    if host.is_empty()
        || host.starts_with('-')
        || host
            .bytes()
            .any(|b| b.is_ascii_whitespace() || b.is_ascii_control())
    {
        return Err(PeerCliError::new(
            "INVALID_HOST",
            "validate",
            "host must be one non-option SSH target",
        ));
    }
    Ok(())
}

fn validate_remote_socket(path: &str) -> Result<(), PeerCliError> {
    if !path.starts_with('/') || path.contains(':') || path.bytes().any(|b| b.is_ascii_control()) {
        return Err(PeerCliError::new(
            "INVALID_SOCKET_PATH",
            "socket",
            "remote socket path is not a safe absolute Unix path",
        ));
    }
    Ok(())
}

fn is_unix_socket(path: &Path) -> bool {
    std::fs::metadata(path)
        .map(|m| m.file_type().is_socket())
        .unwrap_or(false)
}

fn probe_remote_socket(host: &str) -> Result<String, PeerCliError> {
    let mut child = Command::new("/usr/bin/ssh")
        .args(ssh_probe_args(host))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| PeerCliError::new("SSH_SPAWN_FAILED", "ssh", e.to_string()))?;
    let deadline = Instant::now() + Duration::from_secs(15);
    while child
        .try_wait()
        .map_err(|e| PeerCliError::new("SSH_PROBE_FAILED", "ssh", e.to_string()))?
        .is_none()
    {
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(PeerCliError::new(
                "SSH_PROBE_TIMEOUT",
                "ssh",
                "remote socket probe timed out",
            ));
        }
        thread::sleep(Duration::from_millis(25));
    }
    let output = child
        .wait_with_output()
        .map_err(|e| PeerCliError::new("SSH_PROBE_FAILED", "ssh", e.to_string()))?;
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    match output.status.code().unwrap_or(-1) {
        0 => {
            let path = String::from_utf8(output.stdout).map_err(|_| {
                PeerCliError::new("INVALID_SOCKET_PATH", "socket", "probe output is not UTF-8")
            })?;
            let path = path.trim().to_string();
            validate_remote_socket(&path)?;
            Ok(path)
        }
        43 => Err(PeerCliError::new(
            "DAEMON_UNAVAILABLE",
            "daemon",
            "term-meshd is not running",
        )),
        44 => Err(PeerCliError::new(
            "SOCKET_UNAVAILABLE",
            "socket",
            "term-meshd is running but no peer socket was found",
        )),
        255 if stderr.to_ascii_lowercase().contains("permission denied") => Err(PeerCliError::new(
            "SSH_AUTH_FAILED",
            "auth",
            "SSH authentication failed",
        )),
        code => Err(PeerCliError::new(
            "SSH_PROBE_FAILED",
            "ssh",
            if stderr.is_empty() {
                format!("ssh exited with status {code}")
            } else {
                stderr
            },
        )),
    }
}

/// Establish a connection, run the Hello/Auth handshake, and return the
/// stream halves + the running seq counter. Used by both `list_cmd` and
/// `attach_cmd` so their handshake stays in sync.
fn connect_and_authenticate(
    socket_path: &Path,
    emit_banners: bool,
) -> anyhow::Result<(UnixStream, UnixStream, Arc<AtomicU64>, PeerCapabilities)> {
    let stream = UnixStream::connect(socket_path)
        .map_err(|e| anyhow::anyhow!("connect {}: {e}", socket_path.display()))?;
    let read_stream = stream.try_clone()?;
    let mut write_stream = stream;
    let mut read_ref = write_stream.try_clone()?;

    let seq = Arc::new(AtomicU64::new(0));
    let peer_id = random_16_bytes();
    write_envelope(
        &mut write_stream,
        &Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::Hello(Hello {
                protocol_version: PROTOCOL_VERSION.into(),
                peer_id,
                display_name: std::env::var("TERMMESH_PEER_CLIENT_NAME")
                    .unwrap_or_else(|_| "tm-agent-peer".into()),
                capabilities: capability::supported_vec(),
                app_version: env!("CARGO_PKG_VERSION").into(),
            })),
        },
    )?;

    let host_hello = read_envelope(&mut read_ref)?;
    let Some(Payload::Hello(h)) = host_hello.payload else {
        anyhow::bail!("host did not send Hello first");
    };
    if emit_banners {
        eprintln!(
            "[peer] connected to {} ({}), protocol {}",
            h.display_name, h.app_version, h.protocol_version
        );
        if !h.capabilities.is_empty() {
            eprintln!("[peer] host capabilities: {}", h.capabilities.join(", "));
        }
    }
    // Parsed once here and handed to the caller — plumbing only for now
    // (see P3, docs/peer-perf-proposal.md): neither list_cmd nor
    // attach_cmd branches on it yet, but future wire changes (P8 and
    // later) need somewhere to ask "does the host support X" before
    // using it.
    let host_capabilities = PeerCapabilities::from_hello(h.capabilities);

    let challenge = read_envelope(&mut read_ref)?;
    match challenge.payload {
        Some(Payload::AuthChallenge(_)) => {}
        other => anyhow::bail!("expected AuthChallenge, got {other:?}"),
    }

    write_envelope(
        &mut write_stream,
        &Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::Auth(Auth {
                method: "ssh-passthrough".into(),
                token_id: vec![],
                signature: vec![],
            })),
        },
    )?;

    let auth_result = read_envelope(&mut read_ref)?;
    match auth_result.payload {
        Some(Payload::AuthResult(r)) if r.accepted => {
            if emit_banners {
                eprintln!("[peer] authenticated");
            }
        }
        Some(Payload::AuthResult(r)) => anyhow::bail!("auth rejected: {}", r.reason),
        other => anyhow::bail!("expected AuthResult, got {other:?}"),
    }

    // Both read halves on the same underlying socket; return one pair to the caller.
    drop(read_ref);
    Ok((read_stream, write_stream, seq, host_capabilities))
}

fn list_surfaces(
    read_stream: &mut UnixStream,
    write_stream: &mut UnixStream,
    seq: &AtomicU64,
) -> anyhow::Result<Vec<peer_proto::v1::SurfaceInfo>> {
    write_envelope(
        write_stream,
        &Envelope {
            seq: next_seq(seq),
            correlation_id: 0,
            payload: Some(Payload::ListSurfaces(ListSurfaces {})),
        },
    )?;
    let list_reply = read_reply_envelope(read_stream)?;
    match list_reply.payload {
        Some(Payload::SurfaceList(sl)) => Ok(sl.surfaces),
        other => anyhow::bail!("expected SurfaceList, got {other:?}"),
    }
}

fn handshake_error(error: anyhow::Error) -> PeerCliError {
    let detail = format!("{error:#}");
    if detail.contains("auth rejected") || detail.contains("expected AuthResult") {
        PeerCliError::new("PEER_AUTH_FAILED", "auth", detail)
    } else if detail.starts_with("connect ") {
        PeerCliError::new("SOCKET_CONNECT_FAILED", "socket", detail)
    } else {
        PeerCliError::new("PEER_HANDSHAKE_FAILED", "handshake", detail)
    }
}

fn print_json(value: &Value) {
    println!(
        "{}",
        serde_json::to_string(value).expect("JSON value serializes")
    );
}

pub fn status_cmd(host: &str, remote_socket: Option<&str>) -> i32 {
    let result = (|| -> Result<Value, PeerCliError> {
        let tunnel = RemotePeer::open(host, remote_socket)?;
        let (_, _, _, capabilities) =
            connect_and_authenticate(&tunnel.local_socket, false).map_err(handshake_error)?;
        Ok(json!({
            "authenticated": true,
            "host": host,
            "ok": true,
            "peer_socket": tunnel.remote_socket,
            "status": "ready",
            "surface_ensure": capabilities.has(capability::SURFACE_ENSURE_V1),
        }))
    })();
    match result {
        Ok(value) => {
            print_json(&value);
            0
        }
        Err(error) => {
            print_json(&error.json(host));
            1
        }
    }
}

pub fn ensure_cmd(
    host: &str,
    remote_socket: Option<&str>,
    key: &str,
    cwd: &Path,
    executable: &Path,
    args: &[String],
    policy: RestartPolicy,
) -> i32 {
    let result = ensure_remote(host, remote_socket, key, cwd, executable, args, policy);
    match result {
        Ok(value) => {
            print_json(&value);
            if value["ok"].as_bool() == Some(true) {
                0
            } else {
                2
            }
        }
        Err(error) => {
            print_json(&error.json(host));
            1
        }
    }
}

fn ensure_remote(
    host: &str,
    remote_socket: Option<&str>,
    key: &str,
    cwd: &Path,
    executable: &Path,
    args: &[String],
    policy: RestartPolicy,
) -> Result<Value, PeerCliError> {
    let cwd = cwd
        .to_str()
        .ok_or_else(|| PeerCliError::new("INVALID_CWD", "validate", "cwd must be valid UTF-8"))?;
    let executable = executable.to_str().ok_or_else(|| {
        PeerCliError::new(
            "INVALID_EXECUTABLE",
            "validate",
            "executable must be valid UTF-8",
        )
    })?;
    if !Path::new(cwd).is_absolute() {
        return Err(PeerCliError::new(
            "INVALID_CWD",
            "validate",
            "cwd must be an absolute remote path",
        ));
    }
    if !Path::new(executable).is_absolute() {
        return Err(PeerCliError::new(
            "INVALID_EXECUTABLE",
            "validate",
            "executable must be an absolute remote path",
        ));
    }
    let tunnel = RemotePeer::open(host, remote_socket)?;
    let (mut read_stream, mut write_stream, seq, capabilities) =
        connect_and_authenticate(&tunnel.local_socket, false).map_err(handshake_error)?;
    if !capabilities.has(capability::SURFACE_ENSURE_V1) {
        return Err(PeerCliError::new(
            "CAPABILITY_UNAVAILABLE",
            "handshake",
            "host does not advertise surface.ensure.v1",
        ));
    }
    read_stream
        .set_read_timeout(Some(Duration::from_secs(15)))
        .map_err(|e| PeerCliError::new("SOCKET_CONFIG_FAILED", "socket", e.to_string()))?;
    let request_id = random_16_bytes();
    let request_seq = next_seq(&seq);
    write_envelope(
        &mut write_stream,
        &Envelope {
            seq: request_seq,
            correlation_id: 0,
            payload: Some(Payload::EnsureSurfaceRequest(EnsureSurfaceRequest {
                request_id: request_id.clone(),
                key: key.to_string(),
                cwd: cwd.to_string(),
                executable: executable.to_string(),
                args: args.to_vec(),
                restart_policy: match policy {
                    RestartPolicy::Never => EnsureSurfaceRestartPolicy::Never,
                    RestartPolicy::OnDaemonRestart => EnsureSurfaceRestartPolicy::OnDaemonRestart,
                } as i32,
            })),
        },
    )
    .map_err(|e| PeerCliError::new("ENSURE_SEND_FAILED", "ensure", e.to_string()))?;

    loop {
        let envelope = read_envelope(&mut read_stream)
            .map_err(|e| PeerCliError::new("ENSURE_RESPONSE_FAILED", "ensure", e.to_string()))?;
        let Some(Payload::EnsureSurfaceResponse(response)) = envelope.payload else {
            continue;
        };
        if envelope.correlation_id != request_seq || response.request_id != request_id {
            continue;
        }
        return Ok(ensure_response_json(host, response));
    }
}

fn ensure_response_json(host: &str, response: EnsureSurfaceResponse) -> Value {
    let result =
        EnsureSurfaceResult::try_from(response.result).unwrap_or(EnsureSurfaceResult::Unspecified);
    let result_name = match result {
        EnsureSurfaceResult::Created => "CREATED",
        EnsureSurfaceResult::Reused => "REUSED",
        EnsureSurfaceResult::Recreated => "RECREATED",
        EnsureSurfaceResult::SpecConflict => "SPEC_CONFLICT",
        EnsureSurfaceResult::Failed => "FAILED",
        EnsureSurfaceResult::Unspecified => "UNSPECIFIED",
    };
    let mut value = json!({
        "disposition": result_name,
        "generation": response.generation,
        "host": host,
        "instance_id": hex_full(&response.instance_id),
        "ok": matches!(result, EnsureSurfaceResult::Created | EnsureSurfaceResult::Reused | EnsureSurfaceResult::Recreated),
        "pid": response.pid,
        "request_id": hex_full(&response.request_id),
        "result": result_name,
        "spec_hash": hex_full(&response.spec_hash),
        "surface_id": hex_full(&response.surface_id),
    });
    if let Some(error) = response.error {
        value["error"] = json!({
            "code": peer_proto::v1::EnsureSurfaceErrorCode::try_from(error.code)
                .map(|code| code.as_str_name())
                .unwrap_or("ENSURE_SURFACE_ERROR_CODE_UNSPECIFIED"),
            "exit_code": error.exit_code,
            "os_error": error.os_error,
            "signal": error.signal,
            "stage": public_peer_stage(&error.stage),
        });
    }
    value
}

pub fn terminate_cmd(host: &str, remote_socket: Option<&str>, surface_id: &str) -> i32 {
    let result = terminate_remote(host, remote_socket, surface_id);
    match result {
        Ok(value) => {
            print_json(&value);
            if value["ok"].as_bool() == Some(true) {
                0
            } else {
                2
            }
        }
        Err(error) => {
            print_json(&error.json(host));
            1
        }
    }
}

fn parse_surface_id(value: &str) -> Result<Vec<u8>, PeerCliError> {
    if value.len() != 32 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(PeerCliError::new(
            "INVALID_SURFACE_ID",
            "validate",
            "surface_id must be exactly 32 hexadecimal characters",
        ));
    }
    (0..32)
        .step_by(2)
        .map(|offset| {
            u8::from_str_radix(&value[offset..offset + 2], 16).map_err(|_| {
                PeerCliError::new("INVALID_SURFACE_ID", "validate", "surface_id is invalid")
            })
        })
        .collect()
}

fn terminate_remote(
    host: &str,
    remote_socket: Option<&str>,
    surface_id: &str,
) -> Result<Value, PeerCliError> {
    let surface_id = parse_surface_id(surface_id)?;
    let tunnel = RemotePeer::open(host, remote_socket)?;
    let (mut read_stream, mut write_stream, seq, capabilities) =
        connect_and_authenticate(&tunnel.local_socket, false).map_err(handshake_error)?;
    if !capabilities.has(capability::SURFACE_TERMINATE_V1) {
        return Err(PeerCliError::new(
            "CAPABILITY_UNAVAILABLE",
            "handshake",
            "host does not advertise surface.terminate.v1",
        ));
    }
    read_stream
        .set_read_timeout(Some(Duration::from_secs(15)))
        .map_err(|error| PeerCliError::new("SOCKET_CONFIG_FAILED", "socket", error.to_string()))?;
    let request_id = random_16_bytes();
    let request_seq = next_seq(&seq);
    write_envelope(
        &mut write_stream,
        &Envelope {
            seq: request_seq,
            correlation_id: 0,
            payload: Some(Payload::TerminateSurfaceRequest(TerminateSurfaceRequest {
                request_id: request_id.clone(),
                surface_id: surface_id.clone(),
            })),
        },
    )
    .map_err(|error| PeerCliError::new("TERMINATE_SEND_FAILED", "terminate", error.to_string()))?;
    loop {
        let envelope = read_envelope(&mut read_stream).map_err(|error| {
            PeerCliError::new("TERMINATE_RESPONSE_FAILED", "terminate", error.to_string())
        })?;
        let Some(Payload::TerminateSurfaceResponse(response)) = envelope.payload else {
            continue;
        };
        if envelope.correlation_id != request_seq || response.request_id != request_id {
            continue;
        }
        validate_terminate_surface_id(&surface_id, &response)?;
        return Ok(terminate_response_json(host, response));
    }
}

fn validate_terminate_surface_id(
    requested_surface_id: &[u8],
    response: &TerminateSurfaceResponse,
) -> Result<(), PeerCliError> {
    if response.surface_id != requested_surface_id {
        return Err(PeerCliError::new(
            "TERMINATE_PROTOCOL_ERROR",
            "terminate",
            "response surface_id did not match request",
        ));
    }
    Ok(())
}

fn terminate_response_json(host: &str, response: TerminateSurfaceResponse) -> Value {
    let result = TerminateSurfaceResult::try_from(response.result)
        .unwrap_or(TerminateSurfaceResult::Unspecified);
    let result_name = match result {
        TerminateSurfaceResult::Terminated => "TERMINATED",
        TerminateSurfaceResult::NotFound => "NOT_FOUND",
        TerminateSurfaceResult::Failed => "FAILED",
        TerminateSurfaceResult::Unspecified => "UNSPECIFIED",
    };
    let mut value = json!({
        "host": host,
        "ok": matches!(result, TerminateSurfaceResult::Terminated | TerminateSurfaceResult::NotFound),
        "request_id": hex_full(&response.request_id),
        "result": result_name,
        "surface_id": hex_full(&response.surface_id),
    });
    if let Some(error) = response.error {
        value["error"] = json!({
            "code": peer_proto::v1::TerminateSurfaceErrorCode::try_from(error.code)
                .map(|code| code.as_str_name())
                .unwrap_or("TERMINATE_SURFACE_ERROR_CODE_UNSPECIFIED"),
            "stage": public_peer_stage(&error.stage),
        });
    }
    value
}

fn public_peer_stage(stage: &str) -> &'static str {
    match stage {
        "validate" => "validate",
        "chdir" => "chdir",
        "exec" => "exec",
        "exec_handshake" => "exec_handshake",
        "startup" => "startup",
        "reconcile" => "reconcile",
        "persist" => "persist",
        "spawn" => "spawn",
        "terminate" => "terminate",
        "internal" => "internal",
        _ => "peer",
    }
}

pub fn list_host_cmd(host: &str) -> anyhow::Result<()> {
    let tunnel = RemotePeer::open(host, None).map_err(|error| {
        anyhow::anyhow!(
            "{} at {}: {}",
            error.code,
            error.stage,
            public_error_context(error.code)
        )
    })?;
    list_cmd(&tunnel.local_socket)
}

pub fn list_cmd(socket_path: &Path) -> anyhow::Result<()> {
    let (mut read_stream, mut write_stream, seq, _host_capabilities) =
        connect_and_authenticate(socket_path, /* emit_banners */ false)?;
    let surfaces = list_surfaces(&mut read_stream, &mut write_stream, &seq)?;
    if surfaces.is_empty() {
        println!("(no surfaces)");
        return Ok(());
    }
    for s in surfaces {
        let status = if s.attachable { "live" } else { "dead" };
        let branch = if s.branch.is_empty() {
            "-".into()
        } else {
            format!("@{}", s.branch)
        };
        println!(
            "{title:<20} {cols:>3}x{rows:<3}  {status:<4}  {branch:<16}  {cwd}  [{id}]",
            title = s.title,
            cols = s.cols,
            rows = s.rows,
            branch = branch,
            cwd = if s.cwd.is_empty() {
                "-"
            } else {
                s.cwd.as_str()
            },
            id = hex_short(&s.surface_id),
        );
    }
    Ok(())
}

/// Candidate paths for THIS host's own peer socket, in priority order —
/// the local counterpart to `REMOTE_SOCKET_PROBE` (which runs over ssh).
fn probe_local_peer_socket() -> anyhow::Result<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(p) = std::env::var("TERMMESH_PEER_SOCKET") {
        if !p.is_empty() {
            candidates.push(PathBuf::from(p));
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        let env_file = PathBuf::from(&home).join(".config/term-mesh/peer.env");
        if let Ok(contents) = std::fs::read_to_string(&env_file) {
            // Last assignment wins, matching the remote probe's `tail -n 1`.
            if let Some(v) = contents
                .lines()
                .filter_map(|l| l.strip_prefix("TERMMESH_PEER_SOCKET="))
                .last()
            {
                let v = v.trim().trim_matches('"');
                if !v.is_empty() {
                    candidates.push(PathBuf::from(v));
                }
            }
        }
    }
    if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        if !xdg.is_empty() {
            candidates.push(PathBuf::from(xdg).join("tm-peer.sock"));
        }
    }
    let uid = unsafe { libc::getuid() };
    candidates.push(PathBuf::from(format!("/run/user/{uid}/tm-peer.sock")));
    candidates.push(PathBuf::from(format!("/tmp/term-mesh-peer-{uid}/peer.sock")));

    for c in &candidates {
        if std::fs::metadata(c)
            .map(|m| m.file_type().is_socket())
            .unwrap_or(false)
        {
            return Ok(c.clone());
        }
    }
    anyhow::bail!(
        "no term-mesh peer socket found (looked at TERMMESH_PEER_SOCKET, \
         ~/.config/term-mesh/peer.env, $XDG_RUNTIME_DIR/tm-peer.sock, \
         /run/user/{uid}/tm-peer.sock, /tmp/term-mesh-peer-{uid}/peer.sock) — \
         is term-meshd running with peer federation enabled?"
    )
}

/// Roster query: ListWorkspaces -> WorkspaceList, skipping any layout
/// push the host may interleave before the reply lands.
fn list_workspaces(
    read_stream: &mut UnixStream,
    write_stream: &mut UnixStream,
    seq: &AtomicU64,
) -> anyhow::Result<Vec<Workspace>> {
    write_envelope(
        write_stream,
        &Envelope {
            seq: next_seq(seq),
            correlation_id: 0,
            payload: Some(Payload::ListWorkspaces(ListWorkspaces {})),
        },
    )?;
    loop {
        let reply = read_envelope(read_stream)?;
        match reply.payload {
            Some(Payload::WorkspaceList(wl)) => return Ok(wl.workspaces),
            // A fresh connection can see a proactive WorkspaceLayoutChanged
            // push before our reply; skip anything that is not the answer.
            Some(_) => continue,
            None => anyhow::bail!("empty envelope while awaiting WorkspaceList"),
        }
    }
}

#[derive(Default, Clone, Copy)]
struct WsCounts {
    panes: u32,
    surfaces: u32,
    busy: u32,
}

/// Fold a workspace's split tree into (panes, surfaces, busy panes).
fn count_layout(layout: &Option<WorkspaceLayout>) -> WsCounts {
    fn walk(node: &WorkspaceLayout, c: &mut WsCounts) {
        match &node.node {
            Some(LayoutNode::Pane(p)) => {
                c.panes += 1;
                // tabs always includes the active surface, so its length is
                // the surface count for this pane; guard the empty case.
                c.surfaces += (p.tabs.len().max(1)) as u32;
                if p.busy {
                    c.busy += 1;
                }
            }
            Some(LayoutNode::Split(s)) => {
                if let Some(f) = s.first.as_deref() {
                    walk(f, c);
                }
                if let Some(sec) = s.second.as_deref() {
                    walk(sec, c);
                }
            }
            None => {}
        }
    }
    let mut c = WsCounts::default();
    if let Some(l) = layout {
        walk(l, &mut c);
    }
    c
}

fn print_layout_tree(layout: &Option<WorkspaceLayout>, indent: usize) {
    fn walk(node: &WorkspaceLayout, indent: usize) {
        let pad = "  ".repeat(indent);
        match &node.node {
            Some(LayoutNode::Pane(p)) => {
                let busy = if p.busy { "● busy" } else { "○ idle" };
                let title = if p.title.is_empty() {
                    "-"
                } else {
                    p.title.as_str()
                };
                let cwd = if p.cwd.is_empty() {
                    String::new()
                } else {
                    format!("  {}", p.cwd)
                };
                let tabs = p.tabs.len().max(1);
                println!(
                    "{pad}{busy}  {title}  ({tabs} tab{s}){cwd}  [{id}]",
                    s = if tabs == 1 { "" } else { "s" },
                    id = hex_short(&p.surface_id),
                );
            }
            Some(LayoutNode::Split(s)) => {
                println!("{pad}⊟ split ({})", s.orientation);
                if let Some(f) = s.first.as_deref() {
                    walk(f, indent + 1);
                }
                if let Some(sec) = s.second.as_deref() {
                    walk(sec, indent + 1);
                }
            }
            None => {}
        }
    }
    match layout {
        Some(l) => walk(l, indent),
        None => println!("{}(empty)", "  ".repeat(indent)),
    }
}

fn truncate_str(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
        out.push('…');
        out
    }
}

/// `tm-agent ls` — inventory of THIS host's daemon: every workspace and,
/// per workspace, its pane / surface / busy counts. One-shot local peer
/// query against the daemon's own peer socket (no ssh, no daemon change).
pub fn ls_cmd(socket_path: &Path, json_out: bool, tree: bool) -> anyhow::Result<()> {
    let (mut read_stream, mut write_stream, seq, _caps) =
        connect_and_authenticate(socket_path, /* emit_banners */ false)?;
    let workspaces = list_workspaces(&mut read_stream, &mut write_stream, &seq)?;

    let mut total = WsCounts::default();
    let rows: Vec<(&Workspace, WsCounts)> = workspaces
        .iter()
        .map(|w| {
            let c = count_layout(&w.layout);
            total.panes += c.panes;
            total.surfaces += c.surfaces;
            total.busy += c.busy;
            (w, c)
        })
        .collect();

    if json_out {
        let items: Vec<Value> = rows
            .iter()
            .map(|(w, c)| {
                json!({
                    "id": hex_short(&w.workspace_id),
                    "title": w.title,
                    "panes": c.panes,
                    "surfaces": c.surfaces,
                    "busy": c.busy,
                    "default": w.is_default,
                })
            })
            .collect();
        let out = json!({
            "workspaces": workspaces.len(),
            "panes": total.panes,
            "surfaces": total.surfaces,
            "busy": total.busy,
            "items": items,
        });
        println!("{}", serde_json::to_string_pretty(&out)?);
        return Ok(());
    }

    println!(
        "term-meshd — {} workspace{} · {} panes · {} surfaces · {} busy",
        workspaces.len(),
        if workspaces.len() == 1 { "" } else { "s" },
        total.panes,
        total.surfaces,
        total.busy,
    );
    if workspaces.is_empty() {
        return Ok(());
    }
    println!(
        "{:<24} {:>5} {:>8} {:>4}  {}",
        "WORKSPACE", "PANES", "SURFACES", "BUSY", "DEFAULT"
    );
    for (w, c) in &rows {
        let title = if w.title.is_empty() {
            "<untitled>"
        } else {
            w.title.as_str()
        };
        println!(
            "{title:<24} {panes:>5} {surf:>8} {busy:>4}  {def}",
            title = truncate_str(title, 24),
            panes = c.panes,
            surf = c.surfaces,
            busy = c.busy,
            def = if w.is_default { "*" } else { "" },
        );
    }
    if tree {
        for (w, _) in &rows {
            let title = if w.title.is_empty() {
                "<untitled>"
            } else {
                w.title.as_str()
            };
            println!("\n{title} [{}]", hex_short(&w.workspace_id));
            print_layout_tree(&w.layout, 1);
        }
    }
    Ok(())
}

/// `tm-agent ls` entry point: probe the local daemon's peer socket, then
/// print its inventory. Returns a process exit code.
pub fn ls_local_cmd(json_out: bool, tree: bool) -> i32 {
    let socket = match probe_local_peer_socket() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("tm-agent ls: {e:#}");
            return 1;
        }
    };
    match ls_cmd(&socket, json_out, tree) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("tm-agent ls: {e:#}");
            1
        }
    }
}

pub fn attach_host_cmd(
    host: &str,
    name: Option<&str>,
    surface_id: Option<&str>,
    plain: bool,
) -> anyhow::Result<()> {
    let tunnel = RemotePeer::open(host, None).map_err(|error| {
        anyhow::anyhow!(
            "{} at {}: {}",
            error.code,
            error.stage,
            public_error_context(error.code)
        )
    })?;
    attach_cmd(&tunnel.local_socket, name, surface_id, plain)
}

/// Pick a surface by full 32-hex ID, by exact title or short-ID prefix, or
/// fall back to the first attachable surface. Shared by attach and send-key.
fn select_surface(
    surfaces: &[peer_proto::v1::SurfaceInfo],
    name: Option<&str>,
    surface_id: Option<&str>,
) -> anyhow::Result<peer_proto::v1::SurfaceInfo> {
    match surface_id {
        Some(id) => {
            let normalized = id.to_ascii_lowercase();
            if normalized.len() != 32 || !normalized.bytes().all(|b| b.is_ascii_hexdigit()) {
                anyhow::bail!("surface ID must be exactly 32 hexadecimal characters");
            }
            surfaces
                .iter()
                .find(|surface| hex_full(&surface.surface_id) == normalized)
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("surface ID {id:?} not found on host"))
        }
        None => match name {
            Some(n) => {
                // Match by exact title OR by ID hex-prefix (e.g. "33e5ce65").
                let n_lower = n.to_ascii_lowercase();
                surfaces
                    .iter()
                    .find(|s| s.title == n || hex_short(&s.surface_id).starts_with(&n_lower))
                    .cloned()
                    .ok_or_else(|| {
                        let available: Vec<String> = surfaces
                            .iter()
                            .map(|s| format!("{} [{}]", s.title, hex_short(&s.surface_id)))
                            .collect();
                        anyhow::anyhow!(
                            "surface \"{n}\" not found on host; available: {}",
                            available.join(", ")
                        )
                    })
            }
            None => surfaces
                .first()
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("host reports no attachable surfaces")),
        },
    }
}

pub fn attach_cmd(
    socket_path: &Path,
    name: Option<&str>,
    surface_id: Option<&str>,
    plain: bool,
) -> anyhow::Result<()> {
    let (mut read_stream_init, mut write_stream, seq, _host_capabilities) =
        connect_and_authenticate(socket_path, /* emit_banners */ true)?;

    let surfaces = list_surfaces(&mut read_stream_init, &mut write_stream, &seq)?;

    let chosen = select_surface(&surfaces, name, surface_id)?;

    eprintln!(
        "[peer] attaching surface \"{}\" ({}) {}x{}",
        hex_short(&chosen.surface_id),
        chosen.title,
        chosen.cols,
        chosen.rows
    );

    let mut read_stream = read_stream_init;
    let surface_id = chosen.surface_id.clone();

    // ---- attach ----
    let (cols, rows) = term_size().unwrap_or((DEFAULT_COLS, DEFAULT_ROWS));
    write_envelope(
        &mut write_stream,
        &Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::AttachSurface(AttachSurface {
                surface_id: surface_id.clone(),
                mode: AttachMode::CoWrite as i32,
                client_cols: cols,
                client_rows: rows,
                resume_from_seq: 0,
            })),
        },
    )?;
    let attach_reply = read_reply_envelope(&mut read_stream)?;
    match attach_reply.payload {
        Some(Payload::AttachResult(r)) if r.accepted => {
            eprintln!("[peer] attached; streaming. Ctrl-] to detach.");
        }
        Some(Payload::AttachResult(r)) => anyhow::bail!("attach rejected: {}", r.reason),
        other => anyhow::bail!("expected AttachResult, got {other:?}"),
    }

    // ---- transition to interactive mode ----

    // Raw mode on stdin (no-op if stdin isn't a TTY, e.g. in tests).
    let _raw_guard = RawModeGuard::enable();

    // Single writer thread so stdin / SIGWINCH / cleanup can all emit frames
    // without locking the stream.
    let (out_tx, out_rx) = mpsc::channel::<Envelope>();
    let writer_handle = std::thread::spawn(move || -> io::Result<()> {
        while let Ok(env) = out_rx.recv() {
            if write_envelope(&mut write_stream, &env).is_err() {
                break;
            }
        }
        let _ = write_stream.shutdown(std::net::Shutdown::Write);
        Ok(())
    });

    // Socket → stdout reader thread.
    let reader_handle = std::thread::spawn(move || -> io::Result<()> {
        let stdout = io::stdout();
        let mut stripper = AnsiStripper::new();
        let mut stripped: Vec<u8> = Vec::new();
        loop {
            let env = match read_envelope(&mut read_stream) {
                Ok(e) => e,
                Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
                Err(e) => return Err(e),
            };
            match env.payload {
                Some(Payload::PtyData(p)) => {
                    let mut out = stdout.lock();
                    if plain {
                        stripped.clear();
                        stripper.feed(&p.payload, &mut stripped);
                        out.write_all(&stripped)?;
                    } else {
                        out.write_all(&p.payload)?;
                    }
                    out.flush()?;
                }
                Some(Payload::WorkspaceUpdate(wu)) => {
                    if let Some(peer_proto::v1::workspace_update::Kind::Meta(m)) = wu.kind {
                        let branch = if m.branch.is_empty() {
                            String::new()
                        } else {
                            format!(" @{}", m.branch)
                        };
                        let cwd = if m.cwd.is_empty() {
                            "-"
                        } else {
                            m.cwd.as_str()
                        };
                        eprintln!("\r\n[peer] workspace: cwd={cwd}{branch}");
                    }
                }
                Some(Payload::Error(e)) => {
                    eprintln!("\r\n[peer error {}] {}", e.code, e.message);
                    if e.code >= 500 {
                        return Ok(());
                    }
                }
                Some(Payload::Goodbye(g)) => {
                    eprintln!("\r\n[peer] host goodbye: {}", g.reason);
                    return Ok(());
                }
                _ => {}
            }
        }
    });

    // SIGWINCH pipe + processor thread.
    let sigwinch_read_fd = install_sigwinch_pipe()
        .map_err(|e| {
            eprintln!("[peer] SIGWINCH setup failed: {e} — resize events won't propagate");
            e
        })
        .ok();

    let sigwinch_handle = sigwinch_read_fd.map(|fd| {
        let tx = out_tx.clone();
        let id = surface_id.clone();
        let seq = seq.clone();
        std::thread::spawn(move || {
            let mut scratch = [0u8; 16];
            loop {
                // Drain the pipe (one byte per SIGWINCH; merge bursts).
                let n = unsafe { libc::read(fd, scratch.as_mut_ptr() as *mut _, scratch.len()) };
                if n <= 0 {
                    break;
                }
                if let Some((cols, rows)) = term_size() {
                    let env = Envelope {
                        seq: next_seq(&seq),
                        correlation_id: 0,
                        payload: Some(Payload::Resize(Resize {
                            surface_id: id.clone(),
                            cols,
                            rows,
                            pixel_width: 0,
                            pixel_height: 0,
                        })),
                    };
                    if tx.send(env).is_err() {
                        break;
                    }
                }
            }
        })
    });

    // ---- stdin relay + detach watch ----
    let stdin = io::stdin();
    let mut buf = [0u8; 1024];
    let mut detached = false;
    loop {
        let n = match stdin.lock().read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        if buf[..n].contains(&DETACH_KEY) {
            detached = true;
            break;
        }
        let env = Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::Input(Input {
                surface_id: surface_id.clone(),
                kind: Some(peer_proto::v1::input::Kind::Keys(buf[..n].to_vec())),
            })),
        };
        if out_tx.send(env).is_err() {
            break;
        }
    }

    // ---- graceful goodbye ----
    let reason = if detached {
        "client detach (Ctrl-])"
    } else {
        "client stdin EOF"
    };
    let _ = out_tx.send(Envelope {
        seq: next_seq(&seq),
        correlation_id: 0,
        payload: Some(Payload::Goodbye(Goodbye {
            reason: reason.into(),
        })),
    });

    // Close the SIGWINCH pipe's write end BEFORE dropping out_tx so the
    // sigwinch thread (which holds an out_tx clone and is blocked in
    // libc::read on the pipe's read end) wakes up, drops its clone, and
    // lets the writer thread observe "no more senders".
    let prev_fd = SIGWINCH_PIPE_WRITE.swap(-1, Ordering::Relaxed);
    if prev_fd >= 0 {
        unsafe {
            libc::close(prev_fd);
        }
    }

    drop(out_tx);
    let _ = writer_handle.join();
    let _ = reader_handle.join();
    if let Some(h) = sigwinch_handle {
        let _ = h.join();
    }

    if detached {
        eprintln!("[peer] detached.");
    }
    Ok(())
}

/// Streaming ANSI/OSC stripper. Removes CSI (`\e[…`), OSC (`\e]…`, including
/// the shell-integration `]133;…` prompt markers), single-char escapes, NUL,
/// and other non-printable control bytes, keeping printable text plus
/// `\n`/`\r`/`\t`. Stateful, so escape sequences split across `PtyData` chunks
/// are still handled.
#[derive(Default)]
struct AnsiStripper {
    state: StripState,
}

#[derive(Default, Clone, Copy)]
enum StripState {
    #[default]
    Normal,
    Esc,
    /// ESC + charset-designator intermediate: consume exactly one more byte.
    EscInter,
    Csi,
    Osc,
    /// ESC seen inside an OSC string; a following `\` is ST (terminator).
    OscEsc,
}

impl AnsiStripper {
    fn new() -> Self {
        Self::default()
    }

    fn feed(&mut self, input: &[u8], out: &mut Vec<u8>) {
        for &b in input {
            self.state = match self.state {
                StripState::Normal => {
                    if b == 0x1b {
                        StripState::Esc
                    } else {
                        // Printable ASCII, the three whitespace controls, and
                        // every byte >= 0x80. The last part matters: in a UTF-8
                        // stream those are lead/continuation bytes, so dropping
                        // them erases Korean, emoji, and box-drawing glyphs
                        // rather than the escape sequences we mean to strip.
                        let keep = b == b'\n'
                            || b == b'\r'
                            || b == b'\t'
                            || (0x20..0x7f).contains(&b)
                            || b >= 0x80;
                        if keep {
                            out.push(b);
                        }
                        StripState::Normal
                    }
                }
                StripState::Esc => match b {
                    b'[' => StripState::Csi,
                    b']' => StripState::Osc,
                    b'(' | b')' | b'*' | b'+' => StripState::EscInter,
                    // ESC + a single final byte (ESC =, ESC >, ESC M, …): done.
                    _ => StripState::Normal,
                },
                StripState::EscInter => StripState::Normal,
                StripState::Csi => {
                    // Final byte 0x40–0x7e ends the CSI; params/intermediates continue.
                    if (0x40..=0x7e).contains(&b) {
                        StripState::Normal
                    } else {
                        StripState::Csi
                    }
                }
                StripState::Osc => {
                    if b == 0x07 {
                        StripState::Normal // BEL terminates OSC
                    } else if b == 0x1b {
                        StripState::OscEsc
                    } else {
                        StripState::Osc
                    }
                }
                StripState::OscEsc => {
                    if b == b'\\' {
                        StripState::Normal // ESC \ (ST) terminates OSC
                    } else {
                        StripState::Osc
                    }
                }
            };
        }
    }
}

/// Translate a key name into the terminal byte sequence to send.
///
/// Recognized names: `Enter`/`Return`, `Tab`, `Esc`, `Space`, `Backspace`,
/// `Up`/`Down`/`Left`/`Right`, `Home`/`End`, `PageUp`/`PageDown`, `Delete`,
/// and control keys as `C-x` / `Ctrl-x` / `^x`. Anything else is sent as its
/// literal UTF-8 bytes, so `2`, `y`, or `q` type through unchanged. Names are
/// case-insensitive.
fn key_bytes(name: &str) -> anyhow::Result<Vec<u8>> {
    let lower = name.to_ascii_lowercase();
    let bytes = match lower.as_str() {
        "enter" | "return" | "cr" => vec![b'\r'],
        "tab" => vec![b'\t'],
        "esc" | "escape" => vec![0x1b],
        "space" => vec![b' '],
        "backspace" | "bs" => vec![0x7f],
        "up" => vec![0x1b, b'[', b'A'],
        "down" => vec![0x1b, b'[', b'B'],
        "right" => vec![0x1b, b'[', b'C'],
        "left" => vec![0x1b, b'[', b'D'],
        "home" => vec![0x1b, b'[', b'H'],
        "end" => vec![0x1b, b'[', b'F'],
        "pageup" | "pgup" => vec![0x1b, b'[', b'5', b'~'],
        "pagedown" | "pgdn" => vec![0x1b, b'[', b'6', b'~'],
        "delete" | "del" => vec![0x1b, b'[', b'3', b'~'],
        s if s.starts_with("ctrl-") || s.starts_with("c-") || s.starts_with('^') => {
            let letter = s
                .trim_start_matches("ctrl-")
                .trim_start_matches("c-")
                .trim_start_matches('^');
            let mut chars = letter.chars();
            match (chars.next(), chars.next()) {
                // Ctrl-A = 0x01 … Ctrl-Z = 0x1a (letter & 0x1f).
                (Some(c), None) if c.is_ascii_alphabetic() => {
                    vec![(c.to_ascii_uppercase() as u8) - b'@']
                }
                _ => anyhow::bail!("unknown control key: {name:?}"),
            }
        }
        _ => name.as_bytes().to_vec(),
    };
    Ok(bytes)
}

pub fn send_key_host_cmd(
    host: &str,
    name: Option<&str>,
    surface_id: Option<&str>,
    keys: &[String],
) -> anyhow::Result<()> {
    let tunnel = RemotePeer::open(host, None).map_err(|error| {
        anyhow::anyhow!(
            "{} at {}: {}",
            error.code,
            error.stage,
            public_error_context(error.code)
        )
    })?;
    send_key_cmd(&tunnel.local_socket, name, surface_id, keys)
}

/// Attach to a surface, send one or more keys as `Input` frames, then detach.
///
/// Non-interactive: no raw mode, no stdin relay, no stdout streaming — it
/// resolves the keys, attaches co-write, fires the input, and leaves. Menu
/// navigation is deterministic: `send-key --name shell Down Down Enter`.
pub fn send_key_cmd(
    socket_path: &Path,
    name: Option<&str>,
    surface_id: Option<&str>,
    keys: &[String],
) -> anyhow::Result<()> {
    if keys.is_empty() {
        anyhow::bail!("no keys given (e.g. `peer send-key --name shell Enter`)");
    }
    // Resolve every key up front so a bad name fails before we touch the host.
    let payloads: Vec<Vec<u8>> = keys
        .iter()
        .map(|k| key_bytes(k))
        .collect::<anyhow::Result<_>>()?;

    let (read_stream, mut write_stream, seq, _host_capabilities) =
        connect_and_authenticate(socket_path, /* emit_banners */ false)?;
    let mut read_stream = read_stream;
    let surfaces = list_surfaces(&mut read_stream, &mut write_stream, &seq)?;
    let chosen = select_surface(&surfaces, name, surface_id)?;
    let surface_id = chosen.surface_id.clone();

    // Attach co-write so the host accepts our Input frames.
    let (cols, rows) = term_size().unwrap_or((DEFAULT_COLS, DEFAULT_ROWS));
    write_envelope(
        &mut write_stream,
        &Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::AttachSurface(AttachSurface {
                surface_id: surface_id.clone(),
                mode: AttachMode::CoWrite as i32,
                client_cols: cols,
                client_rows: rows,
                resume_from_seq: 0,
            })),
        },
    )?;
    match read_envelope(&mut read_stream)?.payload {
        Some(Payload::AttachResult(r)) if r.accepted => {}
        Some(Payload::AttachResult(r)) => anyhow::bail!("attach rejected: {}", r.reason),
        other => anyhow::bail!("expected AttachResult, got {other:?}"),
    }

    // Drain (discard) the host's replay/PtyData so its socket writes never
    // block and stall its read of our Input frames. Bounded so join() can't
    // hang if the host never closes.
    let mut drain_stream = read_stream;
    let _ = drain_stream.set_read_timeout(Some(Duration::from_secs(3)));
    let drain = thread::spawn(move || while read_envelope(&mut drain_stream).is_ok() {});

    for bytes in payloads {
        write_envelope(
            &mut write_stream,
            &Envelope {
                seq: next_seq(&seq),
                correlation_id: 0,
                payload: Some(Payload::Input(Input {
                    surface_id: surface_id.clone(),
                    kind: Some(peer_proto::v1::input::Kind::Keys(bytes)),
                })),
            },
        )?;
    }

    // Goodbye + half-close: the host applies our ordered Input before it reads
    // the Goodbye and closes, which ends the drain thread on EOF.
    let _ = write_envelope(
        &mut write_stream,
        &Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::Goodbye(Goodbye {
                reason: "send-key done".into(),
            })),
        },
    );
    let _ = write_stream.flush();
    let _ = write_stream.shutdown(std::net::Shutdown::Write);
    let _ = drain.join();
    Ok(())
}

pub fn snapshot_host_cmd(
    host: &str,
    name: Option<&str>,
    surface_id: Option<&str>,
) -> anyhow::Result<()> {
    let tunnel = RemotePeer::open(host, None).map_err(|error| {
        anyhow::anyhow!(
            "{} at {}: {}",
            error.code,
            error.stage,
            public_error_context(error.code)
        )
    })?;
    snapshot_cmd(&tunnel.local_socket, name, surface_id)
}

/// Attach read-only, collect the surface's current screen until the stream
/// goes quiet (repaint delivered) or a hard cap elapses, strip escapes, print
/// the plain text once, and detach. Never sends input, so it can't disturb the
/// surface the operator is using.
pub fn snapshot_cmd(
    socket_path: &Path,
    name: Option<&str>,
    surface_id: Option<&str>,
) -> anyhow::Result<()> {
    let (read_stream, mut write_stream, seq, _host_capabilities) =
        connect_and_authenticate(socket_path, /* emit_banners */ false)?;
    let mut read_stream = read_stream;
    let surfaces = list_surfaces(&mut read_stream, &mut write_stream, &seq)?;
    let chosen = select_surface(&surfaces, name, surface_id)?;
    let surface_id = chosen.surface_id.clone();

    // Use the surface's own dimensions so the emulated grid matches what other
    // viewers see and attaching does not resize/reflow the shared PTY.
    let cols = if chosen.cols == 0 { DEFAULT_COLS } else { chosen.cols };
    let rows = if chosen.rows == 0 { DEFAULT_ROWS } else { chosen.rows };
    write_envelope(
        &mut write_stream,
        &Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::AttachSurface(AttachSurface {
                surface_id: surface_id.clone(),
                mode: AttachMode::ReadOnly as i32,
                client_cols: cols,
                client_rows: rows,
                resume_from_seq: 0,
            })),
        },
    )?;
    match read_envelope(&mut read_stream)?.payload {
        Some(Payload::AttachResult(r)) if r.accepted => {}
        Some(Payload::AttachResult(r)) => anyhow::bail!("attach rejected: {}", r.reason),
        other => anyhow::bail!("expected AttachResult, got {other:?}"),
    }

    // Collect PtyData until the stream is quiet for one read-timeout window
    // (repaint delivered) or a hard cap elapses.
    let _ = read_stream.set_read_timeout(Some(Duration::from_millis(200)));
    // Feed the replay through a real VT emulator and render the resulting grid,
    // so the output is the ONE current screen — not the raw output history
    // (which duplicates every redraw and concatenates cursor-positioned text).
    let mut parser = vt100::Parser::new(rows as u16, cols as u16, 0);
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if Instant::now() >= deadline {
            break;
        }
        match read_envelope(&mut read_stream) {
            Ok(env) => match env.payload {
                Some(Payload::PtyData(p)) => parser.process(&p.payload),
                Some(Payload::Goodbye(_)) => break,
                _ => {}
            },
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock
                    || e.kind() == io::ErrorKind::TimedOut =>
            {
                break; // quiescent — repaint finished
            }
            Err(_) => break,
        }
    }

    let _ = write_envelope(
        &mut write_stream,
        &Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::Goodbye(Goodbye {
                reason: "snapshot done".into(),
            })),
        },
    );
    let _ = write_stream.shutdown(std::net::Shutdown::Write);

    // Render the current screen grid (trailing blank rows trimmed).
    println!("{}", parser.screen().contents().trim_end());
    Ok(())
}

// ── benchmark (P8 measurement harness) ────────────────────────────
//
// Measures peer-relay latency/throughput so the P8 transport question
// (is the SSH tunnel a meaningful cost on LAN?) can be decided from
// numbers instead of estimates. See docs/peer-p8-measurement.md.
//
// This is NOT an interactive client: no raw mode, no SIGWINCH. It drives
// the remote surface programmatically and prints metrics as JSON (--json)
// or a human table. The SSH-vs-direct comparison is done by pointing it at
// different sockets (a forwarded `ssh -L` socket vs the host's real one),
// so this code contains no transport logic of its own.

/// Which measurements to run.
#[derive(Clone, Copy)]
enum BenchMode {
    /// Input→echo round-trip through the remote PTY (felt typing latency).
    Rtt,
    /// Ping/Pong round-trip (pure wire+framing, no PTY echo).
    Wire,
    /// Large host→client burst, measured as bytes/sec.
    Throughput,
    /// All of the above.
    All,
}

impl BenchMode {
    fn parse(s: &str) -> anyhow::Result<Self> {
        match s {
            "rtt" => Ok(BenchMode::Rtt),
            "wire" => Ok(BenchMode::Wire),
            "throughput" | "tput" => Ok(BenchMode::Throughput),
            "all" => Ok(BenchMode::All),
            other => anyhow::bail!("unknown bench mode {other:?} (rtt|wire|throughput|all)"),
        }
    }
    fn wants_wire(self) -> bool {
        matches!(self, BenchMode::Wire | BenchMode::All)
    }
    fn wants_rtt(self) -> bool {
        matches!(self, BenchMode::Rtt | BenchMode::All)
    }
    fn wants_throughput(self) -> bool {
        matches!(self, BenchMode::Throughput | BenchMode::All)
    }
}

#[derive(Default)]
struct BenchResults {
    wire_ms: Option<Vec<f64>>,
    rtt_ms: Option<Vec<f64>>,
    /// (bytes, seconds)
    throughput: Option<(u64, f64)>,
}

/// (min, p50, p95, p99, max, n) over a non-empty sample set.
fn stats(samples: &[f64]) -> Option<(f64, f64, f64, f64, f64, usize)> {
    if samples.is_empty() {
        return None;
    }
    let mut v = samples.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = v.len();
    let pick = |q: f64| v[(((n - 1) as f64) * q).round() as usize];
    Some((v[0], pick(0.50), pick(0.95), pick(0.99), v[n - 1], n))
}

impl BenchResults {
    fn print(&self, socket_path: &Path, json: bool) {
        if json {
            let mut parts: Vec<String> = Vec::new();
            parts.push(format!(
                "\"socket\":{:?}",
                socket_path.display().to_string()
            ));
            let stat_json = |label: &str, s: &Option<Vec<f64>>| -> Option<String> {
                let (min, p50, p95, p99, max, n) = stats(s.as_deref()?)?;
                Some(format!(
                    "\"{label}\":{{\"min_ms\":{min:.3},\"p50_ms\":{p50:.3},\"p95_ms\":{p95:.3},\"p99_ms\":{p99:.3},\"max_ms\":{max:.3},\"n\":{n}}}"
                ))
            };
            if let Some(j) = stat_json("wire_ms", &self.wire_ms) {
                parts.push(j);
            }
            if let Some(j) = stat_json("rtt_ms", &self.rtt_ms) {
                parts.push(j);
            }
            if let Some((bytes, secs)) = self.throughput {
                let mbps = if secs > 0.0 {
                    (bytes as f64) / secs / 1_000_000.0
                } else {
                    0.0
                };
                parts.push(format!(
                    "\"throughput\":{{\"bytes\":{bytes},\"secs\":{secs:.4},\"mb_per_s\":{mbps:.3}}}"
                ));
            }
            println!("{{{}}}", parts.join(","));
            return;
        }

        println!("peer bench — {}", socket_path.display());
        let print_stat = |label: &str, s: &Option<Vec<f64>>| {
            if let Some((min, p50, p95, p99, max, n)) = s.as_deref().and_then(stats) {
                println!(
                    "  {label:<10} n={n:<4} min={min:6.2}  p50={p50:6.2}  p95={p95:6.2}  p99={p99:6.2}  max={max:7.2}   (ms)"
                );
            }
        };
        print_stat("wire", &self.wire_ms);
        print_stat("rtt", &self.rtt_ms);
        if let Some((bytes, secs)) = self.throughput {
            let mbps = if secs > 0.0 {
                (bytes as f64) / secs / 1_000_000.0
            } else {
                0.0
            };
            println!("  throughput  {bytes} bytes in {secs:.3}s = {mbps:.2} MB/s");
        }
    }
}

pub fn bench_cmd(
    socket_path: &Path,
    mode: &str,
    iterations: usize,
    name: Option<&str>,
    json: bool,
) -> anyhow::Result<()> {
    let mode = BenchMode::parse(mode)?;
    let mut results = BenchResults::default();

    // Wire RTT needs only the handshake — no attach.
    if mode.wants_wire() {
        let (mut read_stream, mut write_stream, seq, _caps) =
            connect_and_authenticate(socket_path, /* emit_banners */ false)?;
        read_stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .ok();
        results.wire_ms = Some(bench_wire(
            &mut read_stream,
            &mut write_stream,
            &seq,
            iterations,
        )?);
        let _ = write_envelope(&mut write_stream, &goodbye_env(&seq, "bench wire done"));
    }

    // RTT + throughput need an attached surface.
    if mode.wants_rtt() || mode.wants_throughput() {
        let (mut read_stream, mut write_stream, seq, _caps) =
            connect_and_authenticate(socket_path, /* emit_banners */ false)?;
        let surface_id = perform_attach(&mut read_stream, &mut write_stream, &seq, name)?;

        // Reader thread forwards raw PtyData payload bytes; timing is stamped
        // on the main thread when a marker is observed (same-process channel
        // transfer is negligible relative to the network round-trips measured).
        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        let reader_handle = std::thread::spawn(move || loop {
            match read_envelope(&mut read_stream) {
                Ok(env) => match env.payload {
                    Some(Payload::PtyData(p)) => {
                        if tx.send(p.payload).is_err() {
                            break;
                        }
                    }
                    Some(Payload::Goodbye(_)) | Some(Payload::Error(_)) => break,
                    _ => {}
                },
                Err(_) => break,
            }
        });

        if mode.wants_rtt() {
            results.rtt_ms = Some(bench_rtt(
                &mut write_stream,
                &seq,
                &surface_id,
                &rx,
                iterations,
            )?);
        }
        if mode.wants_throughput() {
            results.throughput = Some(bench_throughput(&mut write_stream, &seq, &surface_id, &rx)?);
        }

        let _ = write_envelope(&mut write_stream, &goodbye_env(&seq, "bench done"));
        drop(write_stream);
        let _ = reader_handle.join();
    }

    results.print(socket_path, json);
    Ok(())
}

fn perform_attach(
    read_stream: &mut UnixStream,
    write_stream: &mut UnixStream,
    seq: &AtomicU64,
    name: Option<&str>,
) -> anyhow::Result<Vec<u8>> {
    let surfaces = list_surfaces(read_stream, write_stream, seq)?;
    let chosen = match name {
        Some(n) => {
            let n_lower = n.to_ascii_lowercase();
            surfaces
                .iter()
                .find(|s| s.title == n || hex_short(&s.surface_id).starts_with(&n_lower))
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("surface \"{n}\" not found on host"))?
        }
        None => surfaces
            .first()
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("host reports no attachable surfaces"))?,
    };
    let (cols, rows) = term_size().unwrap_or((DEFAULT_COLS, DEFAULT_ROWS));
    write_envelope(
        write_stream,
        &Envelope {
            seq: next_seq(seq),
            correlation_id: 0,
            payload: Some(Payload::AttachSurface(AttachSurface {
                surface_id: chosen.surface_id.clone(),
                mode: AttachMode::CoWrite as i32,
                client_cols: cols,
                client_rows: rows,
                resume_from_seq: 0,
            })),
        },
    )?;
    match read_reply_envelope(read_stream)?.payload {
        Some(Payload::AttachResult(r)) if r.accepted => Ok(chosen.surface_id),
        Some(Payload::AttachResult(r)) => anyhow::bail!("attach rejected: {}", r.reason),
        other => anyhow::bail!("expected AttachResult, got {other:?}"),
    }
}

fn bench_wire(
    read_stream: &mut UnixStream,
    write_stream: &mut UnixStream,
    seq: &AtomicU64,
    iterations: usize,
) -> anyhow::Result<Vec<f64>> {
    const WARMUP: usize = 3;
    let mut samples = Vec::with_capacity(iterations);
    for i in 0..(iterations + WARMUP) {
        let nonce = next_seq(seq);
        let t0 = Instant::now();
        write_envelope(
            write_stream,
            &Envelope {
                seq: next_seq(seq),
                correlation_id: 0,
                payload: Some(Payload::Ping(peer_proto::v1::Ping { nonce })),
            },
        )?;
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if Instant::now() > deadline {
                anyhow::bail!("wire ping {nonce} timed out");
            }
            match read_envelope(read_stream)?.payload {
                Some(Payload::Pong(p)) if p.nonce == nonce => {
                    if i >= WARMUP {
                        samples.push(t0.elapsed().as_secs_f64() * 1000.0);
                    }
                    break;
                }
                _ => continue,
            }
        }
    }
    Ok(samples)
}

fn bench_rtt(
    write_stream: &mut UnixStream,
    seq: &AtomicU64,
    surface_id: &[u8],
    rx: &mpsc::Receiver<Vec<u8>>,
    iterations: usize,
) -> anyhow::Result<Vec<f64>> {
    const WARMUP: usize = 3;
    // Let the attach viewport snapshot drain before the first sample.
    drain(rx);
    std::thread::sleep(Duration::from_millis(200));
    drain(rx);

    let mut samples = Vec::with_capacity(iterations);
    for i in 0..(iterations + WARMUP) {
        // Unique, alphanumeric-only token so ANSI/interleaved echo (e.g. zsh
        // syntax highlighting) can be tolerated via alphanumeric filtering.
        let token = format!("TMBR{}Q{}", i, next_seq(seq));
        let needle = token.as_bytes().to_vec();
        drain(rx);
        let t0 = Instant::now();
        send_keys(write_stream, seq, surface_id, token.as_bytes())?;

        let mut acc: Vec<u8> = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut found = false;
        while Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(bytes) => {
                    acc.extend(bytes.iter().filter(|b| b.is_ascii_alphanumeric()));
                    if contains(&acc, &needle) {
                        if i >= WARMUP {
                            samples.push(t0.elapsed().as_secs_f64() * 1000.0);
                        }
                        found = true;
                        break;
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    anyhow::bail!("host disconnected during rtt bench")
                }
            }
        }
        if !found && i >= WARMUP {
            eprintln!("[bench] rtt sample {i} timed out (no echo observed)");
        }
        // Clear the remote input line so it doesn't accumulate between samples.
        send_keys(write_stream, seq, surface_id, b"\x15")?;
        std::thread::sleep(Duration::from_millis(30));
    }
    if samples.is_empty() {
        anyhow::bail!(
            "no rtt samples — echo never observed. Is the surface a shell with terminal echo on?"
        );
    }
    Ok(samples)
}

fn bench_throughput(
    write_stream: &mut UnixStream,
    seq: &AtomicU64,
    surface_id: &[u8],
    rx: &mpsc::Receiver<Vec<u8>>,
) -> anyhow::Result<(u64, f64)> {
    drain(rx);
    // ~589 KB of host→client output. Marker-free: we time from the first
    // output byte to the last, detecting burst end by a 400ms idle gap. Both
    // A/B conditions measure identically so the comparison stays fair.
    send_keys(write_stream, seq, surface_id, b"seq 1 100000\r")?;

    let first = match rx.recv_timeout(Duration::from_secs(10)) {
        Ok(b) => b,
        Err(_) => anyhow::bail!("throughput: no output within 10s"),
    };
    let t0 = Instant::now();
    let mut total = first.len() as u64;
    let mut last = Instant::now();
    loop {
        match rx.recv_timeout(Duration::from_millis(400)) {
            Ok(b) => {
                total += b.len() as u64;
                last = Instant::now();
            }
            Err(_) => break, // idle gap ⇒ burst finished (or disconnect)
        }
    }
    let secs = last.saturating_duration_since(t0).as_secs_f64();
    Ok((total, secs))
}

fn send_keys(
    write_stream: &mut UnixStream,
    seq: &AtomicU64,
    surface_id: &[u8],
    bytes: &[u8],
) -> io::Result<()> {
    write_envelope(
        write_stream,
        &Envelope {
            seq: next_seq(seq),
            correlation_id: 0,
            payload: Some(Payload::Input(Input {
                surface_id: surface_id.to_vec(),
                kind: Some(peer_proto::v1::input::Kind::Keys(bytes.to_vec())),
            })),
        },
    )
}

fn goodbye_env(seq: &AtomicU64, reason: &str) -> Envelope {
    Envelope {
        seq: next_seq(seq),
        correlation_id: 0,
        payload: Some(Payload::Goodbye(Goodbye {
            reason: reason.into(),
        })),
    }
}

/// Discard any already-buffered PtyData without blocking.
fn drain(rx: &mpsc::Receiver<Vec<u8>>) {
    while rx.try_recv().is_ok() {}
}

/// Contiguous-subslice search.
fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || haystack.len() < needle.len() {
        return false;
    }
    haystack.windows(needle.len()).any(|w| w == needle)
}

// ── framing (sync) ────────────────────────────────────────────────

fn read_envelope<R: Read>(reader: &mut R) -> io::Result<Envelope> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_le_bytes(len_buf);
    if len > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame length {len} exceeds {MAX_FRAME_BYTES}"),
        ));
    }
    let mut buf = vec![0u8; len as usize];
    reader.read_exact(&mut buf)?;
    Envelope::decode(buf.as_slice())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("decode: {e}")))
}

fn write_envelope<W: Write>(writer: &mut W, envelope: &Envelope) -> io::Result<()> {
    let bytes = envelope.encode_to_vec();
    let len = bytes.len();
    if len > MAX_FRAME_BYTES as usize {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame length {len} exceeds {MAX_FRAME_BYTES}"),
        ));
    }
    writer.write_all(&(len as u32).to_le_bytes())?;
    writer.write_all(&bytes)?;
    writer.flush()?;
    Ok(())
}

// ── termios raw-mode guard ────────────────────────────────────────

struct RawModeGuard {
    original: libc::termios,
    applied: bool,
}

impl RawModeGuard {
    fn enable() -> Self {
        let mut original: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::isatty(libc::STDIN_FILENO) } != 1 {
            return RawModeGuard {
                original,
                applied: false,
            };
        }
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } != 0 {
            return RawModeGuard {
                original,
                applied: false,
            };
        }
        let mut raw = original;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) } == 0 {
            RawModeGuard {
                original,
                applied: true,
            }
        } else {
            RawModeGuard {
                original,
                applied: false,
            }
        }
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        if self.applied {
            unsafe {
                libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &self.original);
            }
        }
    }
}

// ── SIGWINCH self-pipe ────────────────────────────────────────────

/// Write end of the SIGWINCH pipe. Read by the signal handler with atomic
/// load; any value >= 0 is a live fd. AtomicI32 loads are async-signal-safe.
static SIGWINCH_PIPE_WRITE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn sigwinch_handler(_sig: libc::c_int) {
    let fd = SIGWINCH_PIPE_WRITE.load(Ordering::Relaxed);
    if fd < 0 {
        return;
    }
    let buf = [1u8];
    // write(2) is async-signal-safe; ignore errors — the processor thread
    // will just miss one wakeup.
    unsafe {
        libc::write(fd, buf.as_ptr() as *const _, 1);
    }
}

fn install_sigwinch_pipe() -> io::Result<libc::c_int> {
    let mut fds = [0i32; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    for &fd in &fds {
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD, 0) };
        if flags >= 0 {
            unsafe {
                libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
            }
        }
    }
    let read_fd = fds[0];
    let write_fd = fds[1];
    SIGWINCH_PIPE_WRITE.store(write_fd, Ordering::Relaxed);

    let mut sa: libc::sigaction = unsafe { std::mem::zeroed() };
    sa.sa_sigaction = sigwinch_handler as *const () as libc::sighandler_t;
    unsafe {
        libc::sigemptyset(&mut sa.sa_mask);
    }
    sa.sa_flags = libc::SA_RESTART;

    let rc = unsafe { libc::sigaction(libc::SIGWINCH, &sa, std::ptr::null_mut()) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(read_fd)
}

// ── helpers ───────────────────────────────────────────────────────

/// The next envelope, skipping host-initiated pushes no request asked for.
///
/// The host emits `HostStats` on its own schedule (see
/// `spawn_host_stats_push`), so any reply-shaped read can be handed one
/// instead of its answer. `list_workspaces` already loops past stray pushes;
/// the surface listing and the attach replies did not, which made
/// `peer list` and `peer bench --mode rtt` fail outright against any host
/// that reports stats — the reply was there, one frame later.
///
/// Only stats are skipped, matching the Swift client: an `Error` frame still
/// reaches the caller.
fn read_reply_envelope(read_stream: &mut impl std::io::Read) -> anyhow::Result<Envelope> {
    loop {
        let env = read_envelope(read_stream)?;
        if matches!(env.payload, Some(Payload::HostStats(_))) {
            continue;
        }
        return Ok(env);
    }
}

fn next_seq(seq: &AtomicU64) -> u64 {
    seq.fetch_add(1, Ordering::Relaxed) + 1
}

fn random_16_bytes() -> Vec<u8> {
    let mut out = [0u8; 16];
    if std::fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut out))
        .is_ok()
    {
        return out.to_vec();
    }
    let pid = std::process::id() as u128;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mix = (pid << 64) | (now & 0xFFFF_FFFF_FFFF_FFFF);
    out.copy_from_slice(&mix.to_le_bytes());
    out.to_vec()
}

fn hex_short(bytes: &[u8]) -> String {
    let n = bytes.len().min(4);
    bytes[..n].iter().map(|b| format!("{b:02x}")).collect()
}

fn hex_full(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(unix)]
fn term_size() -> Option<(u32, u32)> {
    use std::mem::MaybeUninit;
    let mut ws: MaybeUninit<libc::winsize> = MaybeUninit::uninit();
    let rc = unsafe { libc::ioctl(libc::STDIN_FILENO, libc::TIOCGWINSZ, ws.as_mut_ptr()) };
    if rc == 0 {
        let ws = unsafe { ws.assume_init() };
        if ws.ws_col > 0 && ws.ws_row > 0 {
            return Some((ws.ws_col as u32, ws.ws_row as u32));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use peer_proto::v1::{
        EnsureSurfaceError, EnsureSurfaceErrorCode, Pong, TerminateSurfaceError,
        TerminateSurfaceErrorCode,
    };
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn framing_roundtrip_via_pipe() {
        use std::io::Cursor;
        let env = Envelope {
            seq: 7,
            correlation_id: 0,
            payload: Some(Payload::Pong(Pong { nonce: 123 })),
        };
        let mut buf = Vec::new();
        write_envelope(&mut buf, &env).unwrap();
        let mut cur = Cursor::new(buf);
        let back = read_envelope(&mut cur).unwrap();
        assert_eq!(back.seq, 7);
        match back.payload.unwrap() {
            Payload::Pong(p) => assert_eq!(p.nonce, 123),
            _ => panic!(),
        }
    }

    #[test]
    fn oversized_frame_is_rejected() {
        use std::io::Cursor;
        let mut buf = Vec::new();
        buf.extend_from_slice(&(MAX_FRAME_BYTES + 1).to_le_bytes());
        let mut cur = Cursor::new(buf);
        let err = read_envelope(&mut cur).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn key_bytes_maps_terminal_names_controls_and_literals() {
        assert_eq!(key_bytes("Enter").unwrap(), b"\r");
        assert_eq!(key_bytes("PgDn").unwrap(), b"\x1b[6~");
        assert_eq!(key_bytes("C-c").unwrap(), b"\x03");
        assert_eq!(key_bytes("한글").unwrap(), "한글".as_bytes());
        assert!(key_bytes("Ctrl-ab").is_err());
    }

    #[test]
    fn ansi_stripper_preserves_text_across_split_csi_and_osc_sequences() {
        let mut stripper = AnsiStripper::new();
        let mut out = Vec::new();

        stripper.feed(b"hello \x1b[3", &mut out);
        stripper.feed(b"1mred\x1b[0m\x1b]133;A", &mut out);
        stripper.feed(b"\x07 world\n", &mut out);

        assert_eq!(out, b"hello red world\n");
    }

    #[test]
    fn ansi_stripper_keeps_utf8_text_while_dropping_escapes() {
        let mut stripper = AnsiStripper::new();
        let mut out = Vec::new();

        // Korean, emoji, and box-drawing all live above 0x7f; only the SGR
        // sequences around them should disappear.
        stripper.feed("┌ \x1b[1m한글\x1b[0m 🎉 ┐\n".as_bytes(), &mut out);

        assert_eq!(String::from_utf8(out).unwrap(), "┌ 한글 🎉 ┐\n");
    }

    #[test]
    fn ansi_stripper_keeps_utf8_split_across_feeds() {
        let mut stripper = AnsiStripper::new();
        let mut out = Vec::new();

        // A multi-byte character straddling two reads must survive intact.
        let text = "한".as_bytes();
        stripper.feed(&text[..1], &mut out);
        stripper.feed(&text[1..], &mut out);

        assert_eq!(String::from_utf8(out).unwrap(), "한");
    }

    fn surface_info(id: u8, title: &str) -> peer_proto::v1::SurfaceInfo {
        peer_proto::v1::SurfaceInfo {
            surface_id: vec![id; 16],
            workspace_name: "workspace".into(),
            title: title.into(),
            cols: 120,
            rows: 40,
            surface_type: "terminal".into(),
            attachable: true,
            cwd: "/tmp".into(),
            branch: "develop".into(),
        }
    }

    #[test]
    fn select_surface_resolves_exact_id_title_and_default_without_ambiguity() {
        let alpha = surface_info(0x11, "alpha");
        let beta = surface_info(0x22, "beta");
        let surfaces = vec![alpha.clone(), beta.clone()];

        assert_eq!(select_surface(&surfaces, None, None).unwrap().surface_id, alpha.surface_id);
        assert_eq!(
            select_surface(&surfaces, Some("beta"), None)
                .unwrap()
                .surface_id,
            beta.surface_id
        );
        assert_eq!(
            select_surface(&surfaces, None, Some(&hex_full(&beta.surface_id)))
                .unwrap()
                .title,
            "beta"
        );
        assert!(select_surface(&surfaces, None, Some("deadbeef")).is_err());
        assert!(select_surface(&surfaces, Some("missing"), None).is_err());
    }

    #[test]
    fn raw_mode_guard_noop_when_stdin_not_tty() {
        // In cargo test, stdin is a pipe, not a TTY. Enable must be a no-op
        // and Drop must not panic.
        let guard = RawModeGuard::enable();
        assert!(!guard.applied);
        drop(guard);
    }

    #[test]
    fn host_and_remote_socket_validation_blocks_option_injection() {
        assert_eq!(
            validate_ssh_target("-oProxyCommand=bad").unwrap_err().code,
            "INVALID_HOST"
        );
        assert!(validate_ssh_target("root@jw-server").is_ok());
        assert_eq!(
            validate_remote_socket("relative.sock").unwrap_err().code,
            "INVALID_SOCKET_PATH"
        );
        assert_eq!(
            validate_remote_socket("/tmp/a:b.sock").unwrap_err().code,
            "INVALID_SOCKET_PATH"
        );
        assert!(validate_remote_socket("/run/user/0/tm-peer.sock").is_ok());
    }

    #[test]
    fn ssh_config_preserves_none_sentinels_and_host_trust() {
        let config = parse_ssh_config(
            "hostname host.example\nuser runner\nport 2222\nidentityfile none\nidentityagent none\nidentitiesonly yes\nproxyjump none\nproxycommand none\nknownhostscommand none\nhostkeyalias stable-host\nuserknownhostsfile /tmp/user-known\nglobalknownhostsfile /tmp/global-known\nstricthostkeychecking yes\ncheckhostip yes\nhashknownhosts yes\nverifyhostkeydns yes\nupdatehostkeys ask\nrevokedhostkeys /tmp/revoked\n",
        )
        .unwrap();
        assert_eq!(config.identity_files, ["none"]);
        assert_eq!(config.identity_agent.as_deref(), Some("none"));
        assert_eq!(config.host_key_alias.as_deref(), Some("stable-host"));
        assert_eq!(
            config.user_known_hosts_file.as_deref(),
            Some("/tmp/user-known")
        );
        assert_eq!(config.revoked_host_keys.as_deref(), Some("/tmp/revoked"));
    }

    #[test]
    fn ssh_config_rejects_proxy_command_and_unsafe_values() {
        let base = "hostname host.example\nuser runner\nport 22\n";
        let error =
            parse_ssh_config(&format!("{base}proxycommand echo SECRET_TOKEN\n")).unwrap_err();
        assert_eq!(error.code, "UNSUPPORTED_PROXY_COMMAND");
        assert!(!error.json("host").to_string().contains("SECRET_TOKEN"));
        assert!(
            parse_ssh_config(&format!("{base}proxycommand none\nhostkeyalias -oBad\n")).is_err()
        );
        for config in [
            format!("{base}proxycommand none\nproxyjump bastion.example\n"),
            format!("{base}proxycommand none\nknownhostscommand echo SECRET_TOKEN\n"),
        ] {
            let error = parse_ssh_config(&config).unwrap_err();
            assert_eq!(error.code, "UNSUPPORTED_SSH_CONFIG");
            assert!(!error.json("host").to_string().contains("SECRET_TOKEN"));
        }
    }

    #[test]
    fn ssh_g_invalid_utf8_is_rejected_without_lossy_conversion() {
        let error = decode_ssh_g_stdout(vec![0xff, b'\n']).unwrap_err();
        assert_eq!(error.code, "SSH_CONFIG_FAILED");
        assert!(!error.json("host").to_string().contains('\u{fffd}'));
    }

    #[test]
    fn ssh_g_known_hosts_collision_is_never_reconstructed() {
        let output = "hostname host.example\nuser runner\nport 22\nproxycommand none\nuserknownhostsfile /tmp/a b\nglobalknownhostsfile /etc/a /etc/b\n";
        let error = parse_ssh_config(output).unwrap_err();
        assert_eq!(error.code, "UNSUPPORTED_SSH_CONFIG");

        // The original-config master consumes these values itself. The control
        // command never receives an inferred tokenization, even if a quoted
        // single path collides with a built-in multi-path rendering.
        let config =
            parse_ssh_config_with_mode(output, TrustPathMode::OriginalConfigMaster).unwrap();
        assert_eq!(config.user_known_hosts_file, None);
        assert_eq!(config.global_known_hosts_file, None);
        let args = ssh_forward_args(&config, Path::new("/tmp/control"), "a:b");
        assert!(!args.iter().any(|arg| arg.contains("knownhosts")));
        assert!(!args.iter().any(|arg| arg.contains("/tmp/a b")));
    }

    #[test]
    fn ssh_g_scalar_keeps_leading_and_trailing_spaces() {
        let config = parse_ssh_config(
            "hostname host.example\nuser runner\nport 22\nproxycommand none\nidentityagent  /tmp/agent.sock \n",
        )
        .unwrap();
        assert_eq!(config.identity_agent.as_deref(), Some(" /tmp/agent.sock "));
    }

    #[test]
    fn tunnel_directory_is_private_unique_and_child_death_wins() {
        let first = create_private_tunnel_dir().unwrap();
        let second = create_private_tunnel_dir().unwrap();
        assert_ne!(first, second);
        assert_eq!(
            std::fs::metadata(&first).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let socket = first.join("peer.sock");
        let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let mut child = Command::new("/bin/sh")
            .args(["-c", "exit 0"])
            .spawn()
            .unwrap();
        let _ = child.wait();
        let error = tunnel_is_ready(&mut child, &socket).unwrap_err();
        assert_eq!(error.code, "SSH_TUNNEL_FAILED");
        let _ = std::fs::remove_dir_all(first);
        let _ = std::fs::remove_dir_all(second);
    }

    #[test]
    fn ssh_tunnel_arguments_keep_the_requested_local_forward() {
        let forward = "/tmp/local.sock:/run/user/0/tm-peer.sock";
        let config = ResolvedSshConfig {
            hostname: "jw-server".into(),
            user: "root".into(),
            port: 22,
            identity_files: vec!["~/.ssh/id_ed25519".into()],
            certificate_files: vec![],
            identities_only: true,
            identity_agent: None,
            host_key_alias: None,
            user_known_hosts_file: Some("~/.ssh/known_hosts".into()),
            global_known_hosts_file: Some("/etc/ssh/ssh_known_hosts".into()),
            strict_host_key_checking: "yes".into(),
            check_host_ip: true,
            hash_known_hosts: true,
            verify_host_key_dns: "no".into(),
            update_host_keys: "no".into(),
            revoked_host_keys: None,
        };
        let args = ssh_forward_args(&config, Path::new("/tmp/control.sock"), forward);
        let forward_index = args.iter().position(|arg| arg == "-L").expect("-L");
        assert_eq!(
            args.get(forward_index + 1).map(String::as_str),
            Some(forward)
        );
        assert_eq!(args[args.len() - 2..], ["--", "jw-server"]);
        assert!(args.windows(2).any(|pair| pair == ["-F", "/dev/null"]));
        assert!(!args
            .iter()
            .any(|argument| argument.contains("IdentityFile")));
    }

    #[test]
    fn original_master_clears_config_forwards_and_local_command() {
        let config = ResolvedSshConfig {
            hostname: "example.invalid".into(),
            user: "tester".into(),
            port: 22,
            identity_files: vec![],
            certificate_files: vec![],
            identities_only: false,
            identity_agent: None,
            host_key_alias: None,
            user_known_hosts_file: Some("~/.ssh/known_hosts".into()),
            global_known_hosts_file: Some("/etc/ssh/ssh_known_hosts".into()),
            strict_host_key_checking: "ask".into(),
            check_host_ip: false,
            hash_known_hosts: false,
            verify_host_key_dns: "no".into(),
            update_host_keys: "no".into(),
            revoked_host_keys: None,
        };
        let master = ssh_master_args("alias", Path::new("/tmp/control.sock"));
        assert!(master.iter().any(|arg| arg == "ClearAllForwardings=yes"));
        assert!(master.iter().any(|arg| arg == "PermitLocalCommand=no"));
        assert!(master.iter().any(|arg| arg == "ForkAfterAuthentication=no"));
        let forward = ssh_forward_args(&config, Path::new("/tmp/control.sock"), "owned:remote");
        assert!(forward.windows(2).any(|pair| pair == ["-F", "/dev/null"]));
        assert!(forward
            .windows(2)
            .any(|pair| pair == ["-L", "owned:remote"]));
    }

    fn test_child(script: &str) -> Child {
        Command::new("/bin/sh")
            .args(["-c", script])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap()
    }

    #[test]
    fn forward_master_exit_reaps_the_control_child() {
        let mut master = test_child("exit 9");
        let mut control = test_child("exec sleep 5");
        let error = wait_for_forward_command(
            &mut master,
            &mut control,
            Instant::now() + Duration::from_secs(1),
        )
        .unwrap_err();
        assert_eq!(error.code, "SSH_TUNNEL_FAILED");
        assert!(master.try_wait().unwrap().is_some());
        assert!(control.try_wait().unwrap().is_some());
    }

    #[test]
    fn forward_control_failure_reaps_the_master_child() {
        let mut master = test_child("exec sleep 5");
        let mut control = test_child("exit 7");
        let error = wait_for_forward_command(
            &mut master,
            &mut control,
            Instant::now() + Duration::from_secs(1),
        )
        .unwrap_err();
        assert_eq!(error.code, "SSH_TUNNEL_FAILED");
        assert!(master.try_wait().unwrap().is_some());
        assert!(control.try_wait().unwrap().is_some());
    }

    #[test]
    fn forward_timeout_reaps_both_children() {
        let mut master = test_child("exec sleep 5");
        let mut control = test_child("exec sleep 5");
        let error = wait_for_forward_command(
            &mut master,
            &mut control,
            Instant::now() + Duration::from_millis(40),
        )
        .unwrap_err();
        assert_eq!(error.code, "SSH_TUNNEL_FAILED");
        assert!(master.try_wait().unwrap().is_some());
        assert!(control.try_wait().unwrap().is_some());
    }

    #[test]
    fn ensure_success_json_has_stable_day_zero_fields() {
        let value = ensure_response_json(
            "root@jw-server",
            EnsureSurfaceResponse {
                request_id: vec![1; 16],
                result: EnsureSurfaceResult::Reused as i32,
                surface_id: vec![2; 16],
                instance_id: vec![3; 16],
                generation: 7,
                pid: 42,
                spec_hash: vec![4; 32],
                error: None,
            },
        );
        assert_eq!(value["ok"], true);
        assert_eq!(value["result"], "REUSED");
        assert_eq!(value["disposition"], "REUSED");
        assert_eq!(value["surface_id"].as_str().unwrap().len(), 32);
        assert_eq!(value["instance_id"].as_str().unwrap().len(), 32);
        assert_eq!(value["spec_hash"].as_str().unwrap().len(), 64);
        assert_eq!(value["request_id"], "01010101010101010101010101010101");
        assert_eq!(value["request_id"].as_str().unwrap().len(), 32);
        assert_eq!(value["generation"], 7);
        assert_eq!(value["pid"], 42);
    }

    #[test]
    fn ensure_failure_json_preserves_structured_process_details() {
        let value = ensure_response_json(
            "root@jw-server",
            EnsureSurfaceResponse {
                request_id: vec![1; 16],
                result: EnsureSurfaceResult::Failed as i32,
                error: Some(EnsureSurfaceError {
                    code: EnsureSurfaceErrorCode::CommandSignaled as i32,
                    stage: "startup".into(),
                    safe_context: "command terminated during startup".into(),
                    exit_code: 0,
                    signal: 9,
                    os_error: 0,
                }),
                ..Default::default()
            },
        );
        assert_eq!(value["ok"], false);
        assert_eq!(value["result"], "FAILED");
        assert_eq!(
            value["error"]["code"],
            "ENSURE_SURFACE_ERROR_CODE_COMMAND_SIGNALED"
        );
        assert_eq!(value["error"]["signal"], 9);
        assert_eq!(value["error"]["exit_code"], 0);
        assert_eq!(value["error"]["os_error"], 0);
        assert_eq!(value["request_id"], "01010101010101010101010101010101");
        assert_eq!(value["request_id"].as_str().unwrap().len(), 32);
    }

    #[test]
    fn ensure_spec_conflict_json_echoes_request_id() {
        let value = ensure_response_json(
            "root@jw-server",
            EnsureSurfaceResponse {
                request_id: vec![0xab; 16],
                result: EnsureSurfaceResult::SpecConflict as i32,
                error: Some(EnsureSurfaceError {
                    code: EnsureSurfaceErrorCode::SpecConflict as i32,
                    stage: "reconcile".into(),
                    safe_context: "existing surface uses a different specification".into(),
                    ..Default::default()
                }),
                ..Default::default()
            },
        );
        assert_eq!(value["ok"], false);
        assert_eq!(value["result"], "SPEC_CONFLICT");
        assert_eq!(value["request_id"], "abababababababababababababababab");
        assert_eq!(value["request_id"].as_str().unwrap().len(), 32);
    }

    #[test]
    fn terminate_surface_id_validation_is_exact() {
        assert_eq!(
            parse_surface_id("00").unwrap_err().code,
            "INVALID_SURFACE_ID"
        );
        assert_eq!(
            parse_surface_id("gggggggggggggggggggggggggggggggg")
                .unwrap_err()
                .code,
            "INVALID_SURFACE_ID"
        );
        assert_eq!(
            parse_surface_id("00112233445566778899aabbccddeeff")
                .unwrap()
                .len(),
            16
        );
    }

    #[test]
    fn terminate_json_covers_success_not_found_and_failure() {
        for (result, name, ok) in [
            (TerminateSurfaceResult::Terminated, "TERMINATED", true),
            (TerminateSurfaceResult::NotFound, "NOT_FOUND", true),
            (TerminateSurfaceResult::Failed, "FAILED", false),
        ] {
            let value = terminate_response_json(
                "root@jw-server",
                TerminateSurfaceResponse {
                    request_id: vec![0x12; 16],
                    result: result as i32,
                    surface_id: vec![0xab; 16],
                    error: (result == TerminateSurfaceResult::Failed).then(|| {
                        TerminateSurfaceError {
                            code: TerminateSurfaceErrorCode::Internal as i32,
                            stage: "terminate".into(),
                            safe_context: "surface termination failed".into(),
                        }
                    }),
                },
            );
            assert_eq!(value["result"], name);
            assert_eq!(value["ok"], ok);
            assert_eq!(value["request_id"], "12121212121212121212121212121212");
            assert_eq!(value["surface_id"], "abababababababababababababababab");
        }
    }

    #[test]
    fn terminate_rejects_mismatched_response_surface_and_redacts_context() {
        let response = TerminateSurfaceResponse {
            request_id: vec![1; 16],
            result: TerminateSurfaceResult::Failed as i32,
            surface_id: vec![2; 16],
            error: Some(TerminateSurfaceError {
                code: TerminateSurfaceErrorCode::Internal as i32,
                stage: "SECRET_STAGE".into(),
                safe_context: "SECRET_TOKEN".into(),
            }),
        };
        assert_eq!(
            validate_terminate_surface_id(&vec![3; 16], &response)
                .unwrap_err()
                .code,
            "TERMINATE_PROTOCOL_ERROR"
        );
        let json = terminate_response_json("host", response);
        assert_eq!(json["error"]["stage"], "peer");
        let encoded = json.to_string();
        assert!(!encoded.contains("SECRET_TOKEN"));
        assert!(!encoded.contains("SECRET_STAGE"));
    }
}
