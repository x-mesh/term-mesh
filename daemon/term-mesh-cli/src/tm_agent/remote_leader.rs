use super::*;

pub(crate) fn rpc_call_timeout(
    sock: &PathBuf,
    method: &str,
    params: Value,
    timeout_secs: u64,
) -> Result<Value, String> {
    match remote_leader_rpc_policy(remote_leader_route().is_some(), method) {
        RemoteLeaderRpcPolicy::Proxy => remote_leader_rpc_call(
            sock,
            method,
            params,
            remote_leader_timeout(method, Duration::from_secs(timeout_secs)).as_secs(),
        ),
        // A remote leader's TERMMESH_SOCKET points at the peer host's local
        // app. Falling through for a disallowed team method therefore acts on
        // that app, not on the GUI team that owns the leader. In particular,
        // `tm-agent create` used to create a second same-name team after a
        // window restore. Team methods must fail closed; non-team utilities
        // may still use the local socket deliberately.
        RemoteLeaderRpcPolicy::RejectTeam => Err(remote_leader_team_rejection(method)),
        RemoteLeaderRpcPolicy::Local => {
            local_rpc_call_timeout_duration(sock, method, params, Duration::from_secs(timeout_secs))
        }
    }
}

pub(crate) fn rpc_call_timeout_duration(
    sock: &PathBuf,
    method: &str,
    params: Value,
    timeout: Duration,
) -> Result<Value, String> {
    match remote_leader_rpc_policy(remote_leader_route().is_some(), method) {
        RemoteLeaderRpcPolicy::Proxy => {
            remote_leader_rpc_call_duration(sock, method, params, timeout)
        }
        RemoteLeaderRpcPolicy::RejectTeam => Err(remote_leader_team_rejection(method)),
        RemoteLeaderRpcPolicy::Local => {
            local_rpc_call_timeout_duration(sock, method, params, timeout)
        }
    }
}

pub(crate) fn remote_leader_lifecycle_rejection(
    has_route: bool,
    command: &Commands,
) -> Option<String> {
    if !has_route {
        return None;
    }
    match command {
        Commands::Create { .. } => Some(remote_leader_team_rejection("team.create")),
        Commands::Destroy => Some(remote_leader_team_rejection("team.destroy")),
        _ => None,
    }
}

pub(crate) fn remote_leader_team_rejection(method: &str) -> String {
    format!(
        "{method} is not allowed from a scoped remote leader; \
         use the owning project window to change team lifecycle"
    )
}

pub(crate) const REMOTE_LEADER_TIMEOUT_MARGIN: Duration = Duration::from_secs(1);
pub(crate) const REMOTE_LEADER_DELEGATE_RECOVERY_TIMEOUT: Duration = Duration::from_secs(30 * 60);

pub(crate) fn remote_leader_timeout(method: &str, requested: Duration) -> Duration {
    let transport_window =
        // One window lets the old audience report that its viewer never
        // returned. A Project adoption can replace the route file during that
        // wait, so reserve a second complete window for the refreshed route.
        Duration::from_secs(peer_proto::team_leader::COMMAND_PENDING_TIMEOUT_SECS * 2)
            + REMOTE_LEADER_TIMEOUT_MARGIN;
    if method == "team.delegate" {
        requested.max(REMOTE_LEADER_DELEGATE_RECOVERY_TIMEOUT)
    } else {
        requested.max(transport_window)
    }
}

#[cfg(test)]
mod remote_leader_timeout_tests {
    use super::*;

    #[test]
    fn remote_leader_timeout_outlives_daemon_pending_window() {
        assert_eq!(
            remote_leader_timeout("team.status", Duration::from_secs(6)),
            Duration::from_secs(31)
        );
        assert_eq!(
            remote_leader_timeout("team.status", Duration::from_secs(30)),
            Duration::from_secs(31)
        );
        assert_eq!(
            remote_leader_timeout("team.status", Duration::from_secs(60)),
            Duration::from_secs(60)
        );
        assert_eq!(
            remote_leader_timeout("team.delegate", Duration::from_secs(6)),
            REMOTE_LEADER_DELEGATE_RECOVERY_TIMEOUT
        );
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum RemoteLeaderRpcPolicy {
    Proxy,
    RejectTeam,
    Local,
}

pub(crate) fn remote_leader_rpc_policy(has_route: bool, method: &str) -> RemoteLeaderRpcPolicy {
    if !has_route {
        return RemoteLeaderRpcPolicy::Local;
    }
    if remote_leader_method_allowed(method) {
        return RemoteLeaderRpcPolicy::Proxy;
    }
    if method.starts_with("team.") {
        return RemoteLeaderRpcPolicy::RejectTeam;
    }
    RemoteLeaderRpcPolicy::Local
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RemoteLeaderRoute {
    pub(crate) grant_id_hex: String,
    pub(crate) project_id: String,
    pub(crate) team_uuid: String,
    pub(crate) expires_at_unix_secs: u64,
    pub(crate) target_peer_id_hex: String,
}

/// Serializes every test that mutates process-global environment, or reads a
/// variable another test mutates (`HOME` above all). Separate per-test locks
/// did not exclude one another: a test resolved `~/.term-mesh/logs` under a
/// temporary `HOME` that a concurrent test had already removed.
#[cfg(test)]
pub(crate) static REMOTE_LEADER_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
thread_local! {
    pub(crate) static REMOTE_LEADER_ENV_LOCK_HELD: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Holds `REMOTE_LEADER_ENV_LOCK` for a test body and marks it held, so code
/// under test that calls `remote_leader_route()` does not deadlock on the
/// non-reentrant mutex.
#[cfg(test)]
pub(crate) struct ProcessEnvGuard {
    _lock: std::sync::MutexGuard<'static, ()>,
}

#[cfg(test)]
impl ProcessEnvGuard {
    pub(crate) fn acquire() -> Self {
        REMOTE_LEADER_ENV_LOCK_HELD.with(|held| {
            assert!(!held.get(), "ProcessEnvGuard cannot be nested");
        });
        let lock = REMOTE_LEADER_ENV_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        REMOTE_LEADER_ENV_LOCK_HELD.with(|held| held.set(true));
        Self { _lock: lock }
    }
}

#[cfg(test)]
impl Drop for ProcessEnvGuard {
    fn drop(&mut self) {
        REMOTE_LEADER_ENV_LOCK_HELD.with(|held| held.set(false));
    }
}

#[cfg(test)]
pub(crate) struct RouteDerivationEnv {
    saved: Vec<(&'static str, Option<OsString>)>,
}

#[cfg(test)]
impl RouteDerivationEnv {
    pub(crate) fn isolated() -> Self {
        let keys = [
            "TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE",
            "TERMMESH_SOCKET",
            "TERMMESH_SOCKET_PATH",
        ];
        let saved = keys
            .into_iter()
            .map(|key| {
                let value = env::var_os(key);
                env::remove_var(key);
                (key, value)
            })
            .collect();
        Self { saved }
    }
}

#[cfg(test)]
impl Drop for RouteDerivationEnv {
    fn drop(&mut self) {
        for (key, value) in self.saved.drain(..) {
            match value {
                Some(value) => env::set_var(key, value),
                None => env::remove_var(key),
            }
        }
    }
}

/// Names the file holding this process's scoped route. The value is a path,
/// never a bearer, so it is safe in a process environment that outlives the
/// app that wrote it.
pub(crate) const REMOTE_LEADER_ROUTE_FILE_ENV: &str = "TERMMESH_LEADER_ROUTE_FILE";

/// The route a long-lived remote worker actually follows.
///
/// A worker's environment is fixed at spawn. The grant inside it is not: it
/// belongs to the app that minted it, and dies when that viewer exits. A
/// second client adopting the same durable project therefore inherited
/// workers whose `tm-agent send`/`inbox`/`reply` addressed a revoked bearer,
/// with no way to correct it short of restarting every process and losing its
/// context.
///
/// So the environment names a *file* instead, and this is read on every
/// invocation. The adopting app replaces that file's contents atomically and
/// the very next `tm-agent` call follows the new grant. The five plain
/// variables remain the fallback, which is what keeps workers spawned by an
/// older app — and any host where staging a file was not possible — working
/// exactly as before.
pub(crate) fn remote_leader_route() -> Option<RemoteLeaderRoute> {
    // Tests that temporarily isolate the process-global leader route hold this
    // lock for their duration. Other test threads must not observe the cleared
    // environment; the owning thread is allowed to call this function while
    // retaining the guard.
    #[cfg(test)]
    let _env_lock = REMOTE_LEADER_ENV_LOCK_HELD.with(|held| {
        (!held.get()).then(|| {
            REMOTE_LEADER_ENV_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
        })
    });
    if let Some(path) = env::var(REMOTE_LEADER_ROUTE_FILE_ENV)
        .ok()
        .filter(|value| !value.trim().is_empty())
    {
        if let Some(route) = remote_leader_route_from_file(Path::new(path.trim())) {
            return Some(route);
        }
    }
    // Leaders launched before the route-file contract cannot gain a new
    // environment variable after another viewer adopts their Project. The
    // adopted viewer still stages the deterministic leader file, so discover
    // that path from the frozen team UUID before falling back to the frozen
    // bearer. This upgrades the next tm-agent invocation without restarting
    // the long-lived leader process.
    if let (Some(home), Some(team_uuid)) = (
        env::var("HOME").ok().filter(|value| !value.is_empty()),
        env::var("TERMMESH_LEADER_TEAM_UUID")
            .ok()
            .filter(|value| !value.is_empty()),
    ) {
        let path = default_remote_leader_route_file(Path::new(&home), &team_uuid);
        if let Some(route) = remote_leader_route_from_file(&path) {
            return Some(route);
        }
    }
    remote_leader_route_from_env()
}

pub(crate) fn default_remote_leader_route_file(home: &Path, team_uuid: &str) -> PathBuf {
    let identity = format!("leader-{team_uuid}");
    let safe: String = identity
        .to_ascii_lowercase()
        .chars()
        .filter(|value| value.is_ascii_alphanumeric() || *value == '-')
        .take(48)
        .collect();
    home.join(".term-mesh")
        .join("agent-routes")
        .join(format!("{safe}.json"))
}

pub(crate) fn remote_leader_route_from_env() -> Option<RemoteLeaderRoute> {
    validated_remote_leader_route(RemoteLeaderRoute {
        grant_id_hex: env::var("TERMMESH_LEADER_GRANT_ID").ok()?,
        project_id: env::var("TERMMESH_LEADER_PROJECT_ID").ok()?,
        team_uuid: env::var("TERMMESH_LEADER_TEAM_UUID").ok()?,
        expires_at_unix_secs: env::var("TERMMESH_LEADER_EXPIRES_AT").ok()?.parse().ok()?,
        target_peer_id_hex: env::var("TERMMESH_LEADER_PEER_ID").ok()?,
    })
}

/// Read a staged route, refusing anything another account could have written.
///
/// The file carries a bearer, so a mode that grants group or other any bit —
/// or an owner that is not this user — is treated as absent rather than
/// trusted. Falling back to the environment is the safe answer: it is the
/// route this process was born with.
pub(crate) fn remote_leader_route_from_file(path: &Path) -> Option<RemoteLeaderRoute> {
    use std::os::unix::fs::MetadataExt;
    use std::os::unix::fs::PermissionsExt;

    // No `follow` question to answer: the metadata is read from the same
    // handle the bytes come from, so a symlink swapped in between the two
    // cannot move the check off the file that is actually parsed.
    let mut file = fs::File::open(path).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() {
        return None;
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        return None;
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        return None;
    }
    // A staged route is a few hundred bytes. Reading a bounded prefix keeps a
    // wrong or hostile path from turning one `tm-agent` call into a full read
    // of an arbitrary file.
    const MAX_ROUTE_FILE_BYTES: u64 = 64 * 1024;
    let mut text = String::new();
    Read::take(&mut file, MAX_ROUTE_FILE_BYTES)
        .read_to_string(&mut text)
        .ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    let string_field =
        |key: &str| -> Option<String> { value.get(key)?.as_str().map(|text| text.to_string()) };
    validated_remote_leader_route(RemoteLeaderRoute {
        grant_id_hex: string_field("grant_id_hex")?,
        project_id: string_field("project_id")?,
        team_uuid: string_field("team_uuid")?,
        expires_at_unix_secs: value.get("expires_at_unix_secs")?.as_u64()?,
        target_peer_id_hex: string_field("target_peer_id_hex")?,
    })
}

pub(crate) fn validated_remote_leader_route(route: RemoteLeaderRoute) -> Option<RemoteLeaderRoute> {
    if route.grant_id_hex.len() != 64
        || route.target_peer_id_hex.len() != 32
        || route.project_id.is_empty()
        || route.team_uuid.is_empty()
    {
        return None;
    }
    Some(route)
}

#[cfg(test)]
mod remote_leader_route_file_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::{Arc, Mutex};

    const ROUTE_ENV: [&str; 6] = [
        "HOME",
        "TERMMESH_LEADER_GRANT_ID",
        "TERMMESH_LEADER_PROJECT_ID",
        "TERMMESH_LEADER_TEAM_UUID",
        "TERMMESH_LEADER_EXPIRES_AT",
        "TERMMESH_LEADER_PEER_ID",
    ];

    /// Same contract as `xk_bridge_tests::LocalRpcEnv`: hold the process-global
    /// route lock, mark it held so `remote_leader_route()` does not deadlock on
    /// the non-reentrant mutex, and put every original value back on drop.
    struct RouteEnv {
        saved: Vec<(&'static str, Option<std::ffi::OsString>)>,
        _lock: std::sync::MutexGuard<'static, ()>,
    }

    impl RouteEnv {
        fn new() -> Self {
            let lock = REMOTE_LEADER_ENV_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            REMOTE_LEADER_ENV_LOCK_HELD.with(|held| held.set(true));
            let mut saved: Vec<(&'static str, Option<std::ffi::OsString>)> = ROUTE_ENV
                .iter()
                .map(|key| (*key, env::var_os(key)))
                .collect();
            saved.push((
                REMOTE_LEADER_ROUTE_FILE_ENV,
                env::var_os(REMOTE_LEADER_ROUTE_FILE_ENV),
            ));
            for (key, _) in &saved {
                env::remove_var(key);
            }
            Self { saved, _lock: lock }
        }

        fn set_env_route(&self, grant: &str) {
            env::set_var("TERMMESH_LEADER_GRANT_ID", grant);
            env::set_var("TERMMESH_LEADER_PROJECT_ID", "name:env-project");
            env::set_var("TERMMESH_LEADER_TEAM_UUID", "env-team");
            env::set_var("TERMMESH_LEADER_EXPIRES_AT", "42");
            env::set_var("TERMMESH_LEADER_PEER_ID", "ef".repeat(16));
        }
    }

    impl Drop for RouteEnv {
        fn drop(&mut self) {
            for (key, value) in self.saved.drain(..) {
                match value {
                    Some(original) => env::set_var(key, original),
                    None => env::remove_var(key),
                }
            }
            REMOTE_LEADER_ENV_LOCK_HELD.with(|held| held.set(false));
        }
    }

    fn route_json(grant: &str) -> String {
        json!({
            "version": 1,
            "grant_id_hex": grant,
            "project_id": "name:file-project",
            "team_uuid": "file-team",
            "expires_at_unix_secs": 4_102_444_800u64,
            "target_peer_id_hex": "ab".repeat(16),
        })
        .to_string()
    }

    fn stage(dir: &tempfile::TempDir, name: &str, body: &str, mode: u32) -> PathBuf {
        let path = dir.path().join(name);
        fs::write(&path, body).expect("write staged route");
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).expect("chmod staged route");
        path
    }

    #[test]
    fn owner_only_route_file_parses_every_scoped_field() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = stage(&dir, "route.json", &route_json(&"cd".repeat(32)), 0o600);

        let route = remote_leader_route_from_file(&path).expect("staged route");

        assert_eq!(route.grant_id_hex, "cd".repeat(32));
        assert_eq!(route.project_id, "name:file-project");
        assert_eq!(route.team_uuid, "file-team");
        assert_eq!(route.expires_at_unix_secs, 4_102_444_800);
        assert_eq!(route.target_peer_id_hex, "ab".repeat(16));
    }

    #[test]
    fn group_or_world_readable_route_file_is_refused() {
        let dir = tempfile::tempdir().expect("tempdir");
        for mode in [0o640, 0o604, 0o666, 0o660] {
            let path = stage(&dir, "route.json", &route_json(&"cd".repeat(32)), mode);
            assert!(
                remote_leader_route_from_file(&path).is_none(),
                "mode {mode:o} must not be trusted with a bearer"
            );
        }
    }

    #[test]
    fn malformed_or_short_route_fields_are_refused() {
        let dir = tempfile::tempdir().expect("tempdir");
        let cases = [
            ("not json at all".to_string(), "garbage"),
            (route_json("cd"), "short grant"),
            (
                json!({
                    "grant_id_hex": "cd".repeat(32),
                    "project_id": "",
                    "team_uuid": "file-team",
                    "expires_at_unix_secs": 1u64,
                    "target_peer_id_hex": "ab".repeat(16),
                })
                .to_string(),
                "empty project",
            ),
            (
                json!({
                    "grant_id_hex": "cd".repeat(32),
                    "project_id": "name:file-project",
                    "team_uuid": "file-team",
                    "expires_at_unix_secs": "42",
                    "target_peer_id_hex": "ab".repeat(16),
                })
                .to_string(),
                "string expiry",
            ),
        ];
        for (body, label) in cases {
            let path = stage(&dir, "route.json", &body, 0o600);
            assert!(
                remote_leader_route_from_file(&path).is_none(),
                "{label} must not resolve to a route"
            );
        }
        assert!(
            remote_leader_route_from_file(&dir.path().join("absent.json")).is_none(),
            "a missing route file is not an error, only an absence"
        );
        assert!(
            remote_leader_route_from_file(dir.path()).is_none(),
            "a directory is not a route file"
        );
    }

    fn answer_one_local_rpc(listener: &std::os::unix::net::UnixListener) -> String {
        let (stream, _) = listener.accept().expect("accept local rpc");
        let mut line = String::new();
        BufReader::new(&stream)
            .read_line(&mut line)
            .expect("read local rpc");
        let method = serde_json::from_str::<Value>(&line).expect("request json")["method"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        let result = if method == "peer.leader.call" {
            json!({"ok": true, "result": {}, "cached": false})
        } else {
            json!({})
        };
        (&stream)
            .write_all(format!("{}\n", json!({"id": 1, "result": result})).as_bytes())
            .expect("write local rpc response");
        method
    }

    #[test]
    fn remote_leader_timeout_helpers_route_every_call_through_the_policy() {
        let dir = tempfile::tempdir().expect("tempdir");
        let sock = dir.path().join("app.sock");
        let listener = std::os::unix::net::UnixListener::bind(&sock).expect("bind");
        listener.set_nonblocking(true).expect("nonblocking");
        let guard = RouteEnv::new();
        guard.set_env_route(&"11".repeat(32));

        for result in [
            rpc_call_timeout(&sock, "team.create", json!({}), 2),
            rpc_call_timeout_duration(&sock, "team.destroy", json!({}), Duration::from_secs(2)),
        ] {
            let error = result.expect_err("team lifecycle must be rejected");
            assert!(
                error.contains("is not allowed from a scoped remote leader"),
                "{error}"
            );
        }
        assert_eq!(
            listener.accept().map_err(|error| error.kind()).err(),
            Some(std::io::ErrorKind::WouldBlock),
            "a rejected team method must not reach the peer host's local app"
        );

        listener.set_nonblocking(false).expect("blocking");
        let server = std::thread::spawn(move || {
            [
                answer_one_local_rpc(&listener),
                answer_one_local_rpc(&listener),
            ]
        });
        let local = rpc_call_timeout(&sock, "headless.list", json!({}), 2).expect("local call");
        assert_eq!(local["result"], json!({}));
        let proxied = rpc_call_timeout(&sock, "team.inbox", json!({}), 2).expect("proxied call");
        assert_eq!(proxied["remote_leader_proxy"], json!(true));
        assert_eq!(
            server.join().expect("server thread"),
            ["headless.list", "peer.leader.call"]
        );
    }

    #[test]
    fn remote_leader_never_resolves_team_members_on_the_local_daemon() {
        let local = || Some(PathBuf::from("/tmp/local-daemon.sock"));
        assert_eq!(
            headless_daemon_socket_for_route(false, local),
            Some(PathBuf::from("/tmp/local-daemon.sock"))
        );
        assert_eq!(
            headless_daemon_socket_for_route(true, || panic!("must not probe the local daemon")),
            None
        );

        let guard = RouteEnv::new();
        guard.set_env_route(&"11".repeat(32));
        assert_eq!(team_headless_daemon_socket(), None);
    }

    /// `RouteEnv` does not save these keys, and `SocketDiscoveryEnv` takes a
    /// lock `RouteEnv` already holds, so a test sets them through this guard
    /// while the route lock is held.
    struct ExtraEnv(Vec<(&'static str, Option<std::ffi::OsString>)>);

    impl ExtraEnv {
        fn set(values: &[(&'static str, Option<&std::ffi::OsStr>)]) -> Self {
            let saved = values
                .iter()
                .map(|(key, value)| {
                    let original = env::var_os(key);
                    match value {
                        Some(value) => env::set_var(key, value),
                        None => env::remove_var(key),
                    }
                    (*key, original)
                })
                .collect();
            Self(saved)
        }
    }

    impl Drop for ExtraEnv {
        fn drop(&mut self) {
            for (key, value) in self.0.drain(..) {
                match value {
                    Some(original) => env::set_var(key, original),
                    None => env::remove_var(key),
                }
            }
        }
    }

    fn assert_listener_untouched(listener: &std::os::unix::net::UnixListener, why: &str) {
        assert_eq!(
            listener.accept().map_err(|error| error.kind()).err(),
            Some(std::io::ErrorKind::WouldBlock),
            "{why}"
        );
    }

    #[test]
    fn remote_leader_team_headless_daemon_socket_is_wired_to_the_route() {
        let dir = tempfile::tempdir().expect("tempdir");
        let daemon = dir.path().join("daemon.sock");
        let _listener = std::os::unix::net::UnixListener::bind(&daemon).expect("bind");
        let guard = RouteEnv::new();
        let _daemon_env = ExtraEnv::set(&[("TERMMESH_DAEMON_SOCKET", Some(daemon.as_os_str()))]);

        assert_eq!(team_headless_daemon_socket(), Some(daemon.clone()));
        guard.set_env_route(&"11".repeat(32));
        assert_eq!(
            team_headless_daemon_socket(),
            None,
            "a live local daemon must not be resolved for a remote leader's team"
        );
    }

    #[test]
    fn remote_leader_skips_auto_watch_without_asking_for_team_status() {
        let dir = tempfile::tempdir().expect("tempdir");
        let sock = dir.path().join("app.sock");
        let listener = std::os::unix::net::UnixListener::bind(&sock).expect("bind");
        listener.set_nonblocking(true).expect("nonblocking");
        let guard = RouteEnv::new();
        let _auto_watch_env = ExtraEnv::set(&[("TERMMESH_AUTO_WATCH", None)]);
        guard.set_env_route(&"11".repeat(32));

        maybe_auto_watch_after_team_change(&sock, "remote-team", false, dir.path());

        assert_listener_untouched(
            &listener,
            "the owning host manages the watcher; no team.status may be proxied",
        );
    }

    #[test]
    fn remote_leader_raw_payload_goes_through_the_policy() {
        let dir = tempfile::tempdir().expect("tempdir");
        let sock = dir.path().join("app.sock");
        let listener = std::os::unix::net::UnixListener::bind(&sock).expect("bind");
        listener.set_nonblocking(true).expect("nonblocking");
        let guard = RouteEnv::new();
        guard.set_env_route(&"11".repeat(32));

        let rejected = run_raw_routed(&sock, r#"{"method":"team.create","params":{}}"#)
            .expect("a per-call failure is reported as an error entry");
        let error = rejected["error"].as_str().unwrap_or_default();
        assert!(
            error.contains("is not allowed from a scoped remote leader"),
            "{rejected}"
        );
        assert!(rpc_response_failed(&rejected));
        assert_listener_untouched(
            &listener,
            "a rejected raw team method must not reach the peer host's local app",
        );

        listener.set_nonblocking(false).expect("blocking");
        let server = std::thread::spawn(move || answer_one_local_rpc(&listener));
        let proxied =
            run_raw_routed(&sock, r#"{"method":"team.inbox","params":{}}"#).expect("proxied");
        assert_eq!(proxied["remote_leader_proxy"], json!(true));
        assert_eq!(server.join().expect("server thread"), "peer.leader.call");
    }

    #[test]
    fn remote_leader_lifecycle_commands_are_rejected_only_under_a_route() {
        let parse = |args: &[&str]| Cli::try_parse_from(args).unwrap().command;
        for args in [
            &["tm-agent", "create", "2"][..],
            &["tm-agent", "create", "2", "--headless"],
            &["tm-agent", "create", "0", "--adopt"],
            &["tm-agent", "destroy"],
        ] {
            let command = parse(args);
            let rejection = remote_leader_lifecycle_rejection(true, &command)
                .unwrap_or_else(|| panic!("{args:?} must be rejected under a route"));
            assert!(
                rejection.contains("is not allowed from a scoped remote leader"),
                "{rejection}"
            );
            assert_eq!(remote_leader_lifecycle_rejection(false, &command), None);
        }
        for args in [&["tm-agent", "status"][..], &["tm-agent", "wait"]] {
            assert_eq!(remote_leader_lifecycle_rejection(true, &parse(args)), None);
        }
    }

    #[test]
    fn staged_route_wins_over_the_spawn_time_environment() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = stage(&dir, "route.json", &route_json(&"cd".repeat(32)), 0o600);
        let guard = RouteEnv::new();
        guard.set_env_route(&"11".repeat(32));
        env::set_var(REMOTE_LEADER_ROUTE_FILE_ENV, &path);

        let route = remote_leader_route().expect("route");
        assert_eq!(
            route.grant_id_hex,
            "cd".repeat(32),
            "an adopting app replaces the file, never the frozen environment"
        );
        assert_eq!(route.team_uuid, "file-team");
    }

    #[test]
    fn leader_without_route_env_discovers_the_adopted_viewers_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        let guard = RouteEnv::new();
        guard.set_env_route(&"11".repeat(32));
        env::set_var("TERMMESH_LEADER_TEAM_UUID", "05AC84AA-A_B");
        env::set_var("HOME", dir.path());
        let path = default_remote_leader_route_file(dir.path(), "05AC84AA-A_B");
        fs::create_dir_all(path.parent().expect("route parent")).expect("mkdir route parent");
        fs::write(&path, route_json(&"99".repeat(32))).expect("write adopted route");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("chmod route");

        let route = remote_leader_route().expect("adopted route");
        assert_eq!(route.grant_id_hex, "99".repeat(32));
        assert_eq!(
            path.file_name().and_then(|value| value.to_str()),
            Some("leader-05ac84aa-ab.json")
        );
    }

    #[test]
    fn replacing_the_file_moves_a_live_worker_to_the_new_grant() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = stage(&dir, "route.json", &route_json(&"cd".repeat(32)), 0o600);
        let guard = RouteEnv::new();
        guard.set_env_route(&"11".repeat(32));
        env::set_var(REMOTE_LEADER_ROUTE_FILE_ENV, &path);
        assert_eq!(
            remote_leader_route().expect("first route").grant_id_hex,
            "cd".repeat(32)
        );

        // Exactly what adoption does on the far side: write a sibling, then
        // rename over the live path.
        let staged = dir.path().join("route.json.tmp");
        fs::write(&staged, route_json(&"99".repeat(32))).expect("stage replacement");
        fs::set_permissions(&staged, fs::Permissions::from_mode(0o600)).expect("chmod replacement");
        fs::rename(&staged, &path).expect("atomic replace");

        assert_eq!(
            remote_leader_route().expect("second route").grant_id_hex,
            "99".repeat(32),
            "the next invocation must follow the adopting app's grant"
        );
    }

    #[test]
    fn viewer_error_retries_the_same_request_through_the_replaced_route_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = stage(&dir, "route.json", &route_json(&"cd".repeat(32)), 0o600);
        let socket_path = dir.path().join("daemon.sock");
        let listener = std::os::unix::net::UnixListener::bind(&socket_path).expect("bind");
        let seen = Arc::new(Mutex::new(Vec::<Value>::new()));
        let seen_server = Arc::clone(&seen);
        let replacement_path = path.clone();
        let server = std::thread::spawn(move || {
            for attempt in 0..2 {
                let (stream, _) = listener.accept().expect("accept");
                let mut line = String::new();
                BufReader::new(stream.try_clone().expect("clone"))
                    .read_line(&mut line)
                    .expect("read request");
                let request: Value = serde_json::from_str(&line).expect("request json");
                seen_server.lock().unwrap().push(request);
                let response = if attempt == 0 {
                    let replacement = json!({
                        "version": 1,
                        "grant_id_hex": "99".repeat(32),
                        "project_id": "name:file-project",
                        "team_uuid": "file-team",
                        "expires_at_unix_secs": 4_102_444_800u64,
                        "target_peer_id_hex": "ef".repeat(16),
                    });
                    let staged = replacement_path.with_extension("tmp");
                    fs::write(&staged, replacement.to_string()).expect("write replacement");
                    fs::set_permissions(&staged, fs::Permissions::from_mode(0o600))
                        .expect("chmod replacement");
                    fs::rename(&staged, &replacement_path).expect("replace route");
                    json!({
                        "jsonrpc": "2.0", "id": 1,
                        "error": {
                            "code": -32601,
                            "message": "authorized peer viewer is unavailable"
                        }
                    })
                } else {
                    json!({
                        "jsonrpc": "2.0", "id": 1,
                        "result": {
                            "ok": true, "cached": false,
                            "result": {"task": {"id": "task-1"}}
                        }
                    })
                };
                let mut writer = stream;
                writeln!(writer, "{response}").expect("write response");
            }
        });

        let guard = RouteEnv::new();
        guard.set_env_route(&"11".repeat(32));
        env::set_var(REMOTE_LEADER_ROUTE_FILE_ENV, &path);
        let result = remote_leader_rpc_call(
            &socket_path,
            "team.delegate",
            json!({"agent_name": "reviewer"}),
            2,
        )
        .expect("retried delegation");
        server.join().expect("server");

        assert_eq!(result["result"]["task"]["id"], "task-1");
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert_eq!(
            seen[0]["params"]["request_id_hex"], seen[1]["params"]["request_id_hex"],
            "route replacement must not mint a second delegation identity"
        );
        assert_eq!(seen[0]["params"]["target_peer_id_hex"], "ab".repeat(16));
        assert_eq!(seen[1]["params"]["target_peer_id_hex"], "ef".repeat(16));
        assert_eq!(seen[1]["params"]["grant_id_hex"], "99".repeat(32));
    }

    #[test]
    fn an_unusable_route_file_falls_back_to_the_spawn_time_environment() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = stage(&dir, "route.json", "{ truncated", 0o600);
        let guard = RouteEnv::new();
        guard.set_env_route(&"11".repeat(32));
        env::set_var(REMOTE_LEADER_ROUTE_FILE_ENV, &path);

        let route = remote_leader_route().expect("environment fallback");
        assert_eq!(route.grant_id_hex, "11".repeat(32));
        assert_eq!(route.team_uuid, "env-team");

        env::set_var(REMOTE_LEADER_ROUTE_FILE_ENV, dir.path().join("absent.json"));
        assert_eq!(
            remote_leader_route()
                .expect("environment fallback")
                .team_uuid,
            "env-team",
            "a worker spawned before route files existed keeps its own route"
        );
    }

    #[test]
    fn no_route_file_and_no_environment_means_no_route() {
        let _guard = RouteEnv::new();
        assert!(remote_leader_route().is_none());
    }
}

/// What a remote leader may proxy to the project's owner.
///
/// The generic half is spelled out; the grant-scoped half is not, because
/// `peer_proto::team_leader::SCOPED_METHODS` is the one definition both
/// acceptors use. Mirroring it here is what let this list drift ahead of them
/// — sending methods no owner would honour, with the failure landing at the
/// far end where nothing pointed back at the cause.
pub(crate) fn remote_leader_method_allowed(method: &str) -> bool {
    matches!(
        method,
        "team.status"
            | "team.read"
            | "team.collect"
            | "team.reports"
            | "team.result.status"
            | "team.result.collect"
            | "team.inbox"
            | "team.message.list"
            | "team.correlation.register"
            | "team.correlation.get"
            | "team.correlation.cancel"
            | "team.send"
            | "team.broadcast"
            | "team.delegate"
            | "team.message.post"
            | "team.delegation.configure"
            | "team.task.list"
            | "team.task.get"
            | "team.task.create"
            | "team.task.update"
            | "team.task.done"
            | "team.task.block"
            | "team.task.review"
            | "team.task.unblock"
            | "team.task.approve"
            | "team.task.diff"
    ) || peer_proto::team_leader::scoped_method_allowed(method)
}

pub(crate) fn scoped_team_list_from_status(mut status: Value) -> Value {
    if let Some(result) = status.get_mut("result") {
        let team = std::mem::take(result);
        *result = json!([team]);
    }
    status
}

pub(crate) fn remote_leader_request_id_hex() -> String {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    let tail =
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed) ^ ((process::id() as u64) << 32);
    format!("{now:016x}{tail:016x}")
}

pub(crate) fn remote_leader_rpc_call(
    sock: &PathBuf,
    method: &str,
    params: Value,
    timeout: u64,
) -> Result<Value, String> {
    let deadline = Instant::now() + Duration::from_secs(timeout);
    let request_id_hex = remote_leader_request_id_hex();
    let mut route =
        remote_leader_route().ok_or_else(|| "invalid remote leader route".to_string())?;
    let proxy_params = remote_leader_proxy_params(&route, method, params.clone(), &request_id_hex)?;

    // A dropped local daemon response may be retried, but the opaque request
    // id stays fixed so the viewer returns its cached outcome and never
    // inserts text or presses Return twice.
    let first = local_rpc_call_timeout_duration(
        sock,
        "peer.leader.call",
        proxy_params.clone(),
        deadline.saturating_duration_since(Instant::now()),
    );
    let mut outer = match first {
        Ok(value) => value,
        Err(first_error) => {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                append_remote_leader_route_failure(&route, method, &request_id_hex);
                return Err(first_error);
            }
            match local_rpc_call_timeout_duration(sock, "peer.leader.call", proxy_params, remaining)
            {
                Ok(value) => value,
                Err(error) => {
                    append_remote_leader_route_failure(&route, method, &request_id_hex);
                    return Err(error);
                }
            }
        }
    };
    outer = retry_remote_leader_after_viewer_error(
        sock,
        method,
        &params,
        &request_id_hex,
        deadline,
        &mut route,
        outer,
    )?;
    let result = decode_daemon_response(outer).and_then(remote_leader_proxy_result);
    if result.is_err() {
        append_remote_leader_route_failure(&route, method, &request_id_hex);
    }
    result
}

pub(crate) fn remote_leader_rpc_call_duration(
    sock: &PathBuf,
    method: &str,
    params: Value,
    timeout: Duration,
) -> Result<Value, String> {
    remote_leader_call_typed(sock, method, params, timeout).map_err(|error| error.to_string())
}

pub(crate) fn remote_leader_call_typed(
    sock: &PathBuf,
    method: &str,
    params: Value,
    timeout: Duration,
) -> Result<Value, RemoteLeaderCallError> {
    use RemoteLeaderCallError::Hop;
    let request_id_hex = remote_leader_request_id_hex();
    let mut route =
        remote_leader_route().ok_or_else(|| Hop("invalid remote leader route".to_string()))?;
    let proxy_params =
        remote_leader_proxy_params(&route, method, params.clone(), &request_id_hex).map_err(Hop)?;
    let deadline = Instant::now() + timeout;
    let first =
        local_rpc_call_timeout_duration(sock, "peer.leader.call", proxy_params.clone(), timeout);
    let mut outer = match first {
        Ok(value) => value,
        Err(first_error) => {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                append_remote_leader_route_failure(&route, method, &request_id_hex);
                return Err(Hop(first_error));
            }
            match local_rpc_call_timeout_duration(sock, "peer.leader.call", proxy_params, remaining)
            {
                Ok(value) => value,
                Err(error) => {
                    append_remote_leader_route_failure(&route, method, &request_id_hex);
                    return Err(Hop(error));
                }
            }
        }
    };
    outer = retry_remote_leader_after_viewer_error(
        sock,
        method,
        &params,
        &request_id_hex,
        deadline,
        &mut route,
        outer,
    )
    .map_err(Hop)?;
    let result = decode_daemon_response(outer)
        .map_err(Hop)
        .and_then(|proxied| {
            remote_leader_proxy_outcome(proxied).map_err(RemoteLeaderCallError::Owner)
        });
    if result.is_err() {
        append_remote_leader_route_failure(&route, method, &request_id_hex);
    }
    result
}

pub(crate) fn remote_leader_viewer_unavailable(response: &Value) -> bool {
    matches!(
        response
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str),
        Some(
            "authorized peer viewer is not connected"
                | "authorized peer viewer is unavailable"
                | "authorized peer viewer did not reconnect"
        )
    )
}

pub(crate) fn remote_leader_route_retry_candidate(
    current: &RemoteLeaderRoute,
    response: &Value,
    refreshed: Option<RemoteLeaderRoute>,
) -> Option<RemoteLeaderRoute> {
    if !remote_leader_viewer_unavailable(response) {
        return None;
    }
    Some(refreshed.unwrap_or_else(|| current.clone()))
}

pub(crate) fn retry_remote_leader_after_viewer_error(
    sock: &PathBuf,
    method: &str,
    params: &Value,
    request_id_hex: &str,
    deadline: Instant,
    route: &mut RemoteLeaderRoute,
    mut response: Value,
) -> Result<Value, String> {
    if !remote_leader_viewer_unavailable(&response) {
        return Ok(response);
    }
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok(response);
        }
        *route = remote_leader_route_retry_candidate(route, &response, remote_leader_route())
            .expect("viewer unavailability is retryable");
        let refreshed = remote_leader_proxy_params(route, method, params.clone(), request_id_hex)?;
        response = match local_rpc_call_timeout_duration(
            sock,
            "peer.leader.call",
            refreshed,
            remaining.min(Duration::from_secs(
                peer_proto::team_leader::COMMAND_PENDING_TIMEOUT_SECS
                    + REMOTE_LEADER_TIMEOUT_MARGIN.as_secs(),
            )),
        ) {
            Ok(response) => response,
            Err(error) => {
                if deadline.saturating_duration_since(Instant::now()).is_zero() {
                    append_remote_leader_route_failure(route, method, request_id_hex);
                    return Err(error);
                }
                continue;
            }
        };
        if !remote_leader_viewer_unavailable(&response) {
            return Ok(response);
        }
    }
}

pub(crate) fn append_remote_leader_route_failure(
    route: &RemoteLeaderRoute,
    method: &str,
    request_id_hex: &str,
) {
    let Ok(path) = turn_log_path() else { return };
    let team = env::var("TERMMESH_TEAM").unwrap_or_else(|_| route.project_id.clone());
    let mut record = json!({
        "event": "task_lifecycle",
        "turn_id": request_id_hex,
        "ts": iso8601_utc_now(),
        "team": team,
        "team_uuid": route.team_uuid,
        "task_status": "route_failed",
        "task_delivery": "failed",
        "task_route": method,
    });
    if let Some(session) = current_leader_session_id() {
        record["leader_session_id"] = json!(session);
    }
    let _ = append_turn_record(&path, &record);
}

pub(crate) fn current_leader_session_id() -> Option<String> {
    if let Some(path) = env::var("TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE")
        .ok()
        .filter(|value| !value.is_empty())
    {
        if let Ok(data) = fs::read(Path::new(&path)) {
            if data.len() <= 64 * 1024 {
                if let Ok(value) = serde_json::from_slice::<Value>(&data) {
                    if let Some(session) = value["session_id"]
                        .as_str()
                        .filter(|value| !value.is_empty())
                    {
                        return Some(session.to_string());
                    }
                }
            }
        }
    }
    env::var("TERMMESH_LEADER_SESSION_ID")
        .ok()
        .filter(|value| !value.is_empty())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemoteLeaderProxyError {
    pub(crate) code: Option<String>,
    pub(crate) text: String,
}

impl std::fmt::Display for RemoteLeaderProxyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.text)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RemoteLeaderCallError {
    Owner(RemoteLeaderProxyError),
    Hop(String),
}

impl std::fmt::Display for RemoteLeaderCallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RemoteLeaderCallError::Owner(error) => error.fmt(f),
            RemoteLeaderCallError::Hop(message) => f.write_str(message),
        }
    }
}

pub(crate) fn remote_leader_proxy_result(proxied: Value) -> Result<Value, String> {
    remote_leader_proxy_outcome(proxied).map_err(|error| error.text)
}

pub(crate) fn remote_leader_proxy_outcome(proxied: Value) -> Result<Value, RemoteLeaderProxyError> {
    if !proxied["ok"].as_bool().unwrap_or(false) {
        let result = &proxied["result"];
        let error_code = result["error_code"]
            .as_str()
            .filter(|value| !value.is_empty());
        let error_message = result["error_message"]
            .as_str()
            .filter(|value| !value.is_empty());
        let mut message = match (error_code, error_message) {
            (Some(code), Some(message)) => {
                format!("remote leader proxy [{code}]: {message}")
            }
            (Some(code), None) => format!("remote leader proxy [{code}]"),
            (None, Some(message)) => format!("remote leader proxy: {message}"),
            (None, None) => "remote leader proxy returned non-ok".into(),
        };
        if matches!(error_code, Some("expired_grant" | "unknown_grant")) {
            message.push_str(
                "; reconnect or restart the remote leader pane from its owning project window",
            );
        }
        return Err(RemoteLeaderProxyError {
            code: error_code.map(String::from),
            text: message,
        });
    }
    Ok(json!({
        "ok": true,
        "result": proxied["result"].clone(),
        "remote_leader_proxy": true,
        "cached": proxied["cached"].clone(),
    }))
}

/// A `team.send`/`team.delegate` acknowledgement may declare that no Return is
/// needed: a natively-held agent's turn is submitted the moment the text write
/// lands. `None` — the field is absent, an older app — keeps the legacy
/// send_key follow-up, which the app still answers authoritatively
/// (`no_keyboard`) for callers that never learn about this field.
pub(crate) fn send_response_return_required(response: &Value) -> Option<bool> {
    response["result"]["return_required"].as_bool()
}

/// A scoped remote-leader delegate commits paste + Return in the authoritative
/// control plane, rather than through this daemon; a native assignee needs no
/// Return at all.  Never issue the legacy follow-up `team.send_key` after any
/// of these acknowledgements: for the first two it would submit the same
/// prompt a second time, for the third there is nothing to submit.
pub(crate) fn delegate_return_already_submitted(response: &Value) -> bool {
    response["remote_leader_proxy"].as_bool().unwrap_or(false)
        || response["result"]["return_submitted"]
            .as_bool()
            .unwrap_or(false)
        || send_response_return_required(response) == Some(false)
}

pub(crate) fn remote_leader_proxy_params(
    route: &RemoteLeaderRoute,
    method: &str,
    mut params: Value,
    request_id_hex: &str,
) -> Result<Value, String> {
    if method == "team.delegate" {
        // The authoritative dispatcher must commit paste + Return as one
        // request-id-deduplicated operation. Local delegates keep the legacy
        // two-RPC path; only this scoped route asks the server to submit.
        params["submit_return"] = json!(true);
    }
    Ok(json!({
        "grant_id_hex": &route.grant_id_hex,
        "project_id": &route.project_id,
        "team_uuid": &route.team_uuid,
        "expires_at_unix_secs": route.expires_at_unix_secs,
        "target_peer_id_hex": &route.target_peer_id_hex,
        "request_id_hex": request_id_hex,
        "method": method,
        "params_json": serde_json::to_string(&params).map_err(|e| e.to_string())?,
    }))
}

pub(crate) fn daemon_result(sock: &PathBuf, method: &str, params: Value) -> Result<Value, String> {
    decode_daemon_response(rpc_call(sock, method, params)?)
}

pub(crate) fn decode_daemon_response(response: Value) -> Result<Value, String> {
    if let Some(error) = response.get("error").filter(|value| !value.is_null()) {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("RPC_ERROR: daemon request failed");
        return Err(message.to_string());
    }
    response
        .get("result")
        .cloned()
        .ok_or_else(|| "PROTOCOL_ERROR: daemon response has no result".to_string())
}

pub(crate) fn local_request_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("tm-agent-{}-{nanos}", process::id())
}
