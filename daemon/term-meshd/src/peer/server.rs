//! Unix-socket accept loop for peer-federation host.
//!
//! Phase 2.3B: constructs a shared `PtyManager` at startup, eagerly
//! spawns a default PTY surface, and passes the manager into each
//! per-connection task.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use tokio::net::UnixListener;
use tokio::sync::{watch, Semaphore};
use tokio::task::JoinSet;

use super::connection;
use super::layout::{PeerHost, DAEMON_WORKSPACE};
use super::persist;
use super::surface::PtyManager;
use crate::supervisor::{shutdown_supervised, spawn_supervised};

/// Default ceiling on concurrent peer-federation connections.
///
/// This is not a pane limit, but it behaves like one: every attached pane
/// holds a connection for its whole lifetime, and workspace mirrors,
/// consoles and short-lived surface probes draw from the same pool. So the
/// real number of panes a client can hold open on this host is this value
/// minus whatever else it has connected.
///
/// 16 was low enough to be reached in ordinary use — a workspace with a
/// dozen remote panes could not open one more connection, which broke the
/// shell-cleanup sweep at exactly the moment a crowded host needed it.
/// The cap still exists to bound what a single client can make the daemon
/// hold; it is not meant to be a limit anyone reaches by working normally.
///
/// Override at startup with `TERMMESH_PEER_MAX_CONNECTIONS`.
const DEFAULT_MAX_PEER_CONNECTIONS: usize = 64;

/// The configured connection ceiling. Read once at accept-loop start:
/// the semaphore is sized from it, so a later change to the environment
/// would not be honoured anyway.
///
/// A malformed or zero value falls back to the default rather than
/// refusing to boot — a host that comes up with the wrong ceiling is far
/// easier to notice and correct than one that does not come up at all.
fn max_peer_connections() -> usize {
    parse_max_peer_connections(std::env::var(MAX_CONNECTIONS_VAR).ok().as_deref())
}

const MAX_CONNECTIONS_VAR: &str = "TERMMESH_PEER_MAX_CONNECTIONS";

/// Split from `max_peer_connections` so the parse is testable without
/// mutating process-wide environment from a test that runs in parallel
/// with every other test in this module.
fn parse_max_peer_connections(raw: Option<&str>) -> usize {
    let Some(raw) = raw else {
        return DEFAULT_MAX_PEER_CONNECTIONS;
    };
    match raw.trim().parse::<usize>() {
        Ok(value) if value > 0 => value,
        _ => {
            tracing::warn!(
                "{MAX_CONNECTIONS_VAR}={raw:?} is not a positive integer; \
                 using {DEFAULT_MAX_PEER_CONNECTIONS}"
            );
            DEFAULT_MAX_PEER_CONNECTIONS
        }
    }
}

/// Production entry point (the only caller is `main.rs`). Unlike
/// `serve_with_manager` (used throughout this module's own tests, and by
/// any other in-process caller that just wants a working host), this
/// boots the host through the M1 persistence path: a named-workspace
/// collection loaded from `persist::default_workspaces_path()`,
/// reconciled against `TERMMESH_PEER_WORKSPACES` /
/// `TERMMESH_PEER_WORKSPACE_TITLE`, and persisted back. Keeping that
/// disk I/O out of `serve_with_manager` means the ~20 tests that call it
/// directly never touch (or race on) the real on-disk workspaces file.
pub async fn serve(
    path: PathBuf,
    shutdown_rx: watch::Receiver<bool>,
    monitor_rx: watch::Receiver<Option<crate::monitor::SystemSnapshot>>,
    teams: Arc<tokio::sync::Mutex<crate::headless::HeadlessManager>>,
    agents: Arc<crate::agent::AgentSessionManager>,
) -> anyhow::Result<()> {
    let manager = Arc::new(PtyManager::new());
    manager.spawn_from_config();
    let workspaces_path = persist::default_workspaces_path();
    let default_name_fallback = connection::hostname_or(DAEMON_WORKSPACE);
    let entries = persist::boot(&workspaces_path, &default_name_fallback);
    let host = Arc::new(PeerHost::with_workspaces(manager, entries));
    super::install_remote_leader_router(&host.clients);
    // Restored non-default workspaces come back with an empty tree
    // (only {id, name} is persisted — shells are daemon children). Seed
    // each a first pane so every workspace is immediately attachable,
    // instead of surfacing "no panes" on the client's first open.
    host.seed_empty_workspaces();
    // M2: create/rename/delete workspace-lifecycle RPCs persist through
    // this path — wired here (rather than baked into `with_workspaces`)
    // so that constructor stays I/O-free for every test/embedder caller.
    host.set_persist_path(workspaces_path);
    // Only the daemon has a monitor; the test/embedder constructors below
    // leave the host without one and simply never push HostStats.
    host.set_monitor(monitor_rx);
    // Only the daemon has agent teams; without this the host answers no
    // ListTeams and never advertises team.roster.v1.
    host.set_teams(teams);
    // And the task board, which is what `team.task.diff` reads a worktree path
    // out of. Wired here for the same reason as the manager above: only the
    // daemon has one, and a host without it says so rather than guessing.
    host.set_agents(agents);
    serve_with_host(path, shutdown_rx, host).await
}

/// Test/embedding entry point: builds a host with `PeerHost::new` (a
/// single default workspace, no persistence, no env vars) around
/// `manager` and serves it. Behavior is unchanged from before M1 for
/// every existing caller of this function. `main.rs` calls `serve`
/// instead, so in a non-test build this function's only callers are this
/// module's own integration tests — `#[allow(dead_code)]` for the same
/// reason `PeerHost::new` carries it.
#[allow(dead_code)]
pub async fn serve_with_manager(
    path: PathBuf,
    shutdown_rx: watch::Receiver<bool>,
    manager: Arc<PtyManager>,
) -> anyhow::Result<()> {
    // The host owns the layout tree the manager's surfaces are arranged
    // in; connections share it so WorkspaceControl mutations made over
    // one connection are visible (and pushable) to all of them.
    let host = Arc::new(PeerHost::new(manager));
    serve_with_host(path, shutdown_rx, host).await
}

/// Shared accept loop, parameterized on an already-constructed host so
/// `serve` (persistence-backed) and `serve_with_manager` (persistence-
/// free) can share every bit of socket/connection plumbing below.
async fn serve_with_host(
    path: PathBuf,
    mut shutdown_rx: watch::Receiver<bool>,
    host: Arc<PeerHost>,
) -> anyhow::Result<()> {
    super::install_remote_leader_router(&host.clients);
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            harden_parent_directory(parent)?;
        }
    }

    // Bind under a tight umask so the socket file is created at 0600
    // from the start; the post-bind chmod is kept as belt-and-braces
    // for the (already narrow) window between bind() and the umask
    // restore. Closes the bind-time TOCTOU on multi-user systems.
    let listener = bind_with_tight_umask(&path)?;
    harden_socket_permissions(&path);
    tracing::info!("peer-federation listening on {}", path.display());
    let max_connections = max_peer_connections();
    tracing::info!("peer-federation connection ceiling: {max_connections}");
    let connection_permits = Arc::new(Semaphore::new(max_connections));
    let owner_uid = current_uid();
    let mut connection_tasks = JoinSet::new();

    loop {
        tokio::select! {
            result = listener.accept() => {
                match result {
                    Ok((stream, _)) => {
                        // UID gate: only the daemon's own user — or root —
                        // may attach, even if a permissive parent directory
                        // or chmod race exposed the socket file to other
                        // users on the host.
                        let peer = peer_uid(&stream);
                        if !peer.is_some_and(|uid| peer_uid_allowed(uid, owner_uid)) {
                            tracing::warn!(
                                "rejecting peer connection from uid {} \
                                 (only uid {owner_uid} or root may attach)",
                                peer.map_or_else(|| "<unknown>".to_string(), |u| u.to_string())
                            );
                            drop(stream);
                            continue;
                        }
                        let Ok(permit) = connection_permits.clone().try_acquire_owned() else {
                            // Name the ceiling and the way out. The client
                            // sees only its handshake read returning EOF,
                            // which is indistinguishable from a dead host —
                            // this line is the sole record of the real cause.
                            tracing::warn!(
                                "peer connection limit reached ({max_connections}); \
                                 closing new client — raise {MAX_CONNECTIONS_VAR} \
                                 to allow more"
                            );
                            drop(stream);
                            continue;
                        };
                        let host = host.clone();
                        spawn_supervised(&mut connection_tasks, async move {
                            let _permit = permit;
                            if let Err(e) = connection::run(stream, host).await {
                                tracing::warn!("peer connection ended with error: {e}");
                            }
                        });
                    }
                    Err(e) => {
                        tracing::error!("peer accept error: {e}");
                    }
                }
            }
            _ = shutdown_rx.changed() => {
                tracing::info!("peer server shutting down");
                break;
            }
        }
    }
    shutdown_supervised(&mut connection_tasks, "peer").await;

    // Host surfaces are `$SHELL -l` children of this daemon (surface.rs:8) and
    // nothing else in the shutdown sequence reaps them: the daemon's own
    // teardown covers headless agents and agent sessions only. Without this a
    // whole generation of pane shells survives the daemon, reparents to PID 1
    // and keeps holding its PTY — enough daemon exits and ptmx runs out.
    // `shutdown_forcibly` escalates SIGHUP → SIGKILL, which is what a macOS
    // forkpty session leader that ignores SIGHUP actually needs (surface.rs:432).
    let surfaces = host.pty.list();
    if !surfaces.is_empty() {
        let count = surfaces.len();
        // Signal everything first, wait ONCE, then force whatever is left.
        //
        // Calling `shutdown_forcibly` in a plain loop would pay that call's
        // grace window per surface (10 × 10ms), so ~50 surfaces alone reach the
        // 5s budget `main.rs` wraps this task in — the tail of the list would
        // never be reaped and would orphan exactly as before, and worst of all
        // it would fail hardest when there are most surfaces to reclaim. One
        // shared grace window makes the cost flat: a cooperative shell exits
        // during it, and the second pass only escalates the stragglers (already
        // exited children return immediately).
        //
        // Blocking sleep, so keep it off the async executor — same shape the
        // daemon uses for agent-session teardown.
        let joined = tokio::task::spawn_blocking(move || {
            for surface in &surfaces {
                surface.hangup();
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
            for surface in &surfaces {
                surface.shutdown_forcibly();
            }
        })
        .await;
        match joined {
            Ok(()) => tracing::info!("terminated {count} peer surface(s)"),
            // Never claim success on a teardown that did not finish: the whole
            // point of this block is that surviving children become orphans.
            Err(e) => tracing::warn!(
                "peer surface teardown did not complete ({e}) — \
                 up to {count} surface(s) may survive as orphans"
            ),
        }
    }

    if Path::new(&path).exists() {
        let _ = std::fs::remove_file(&path);
    }
    Ok(())
}

#[cfg(unix)]
fn harden_socket_permissions(path: &Path) {
    use std::os::unix::fs::PermissionsExt;

    if let Ok(metadata) = std::fs::metadata(path) {
        let mut perms = metadata.permissions();
        perms.set_mode(0o600);
        let _ = std::fs::set_permissions(path, perms);
    }
}

#[cfg(not(unix))]
fn harden_socket_permissions(_path: &Path) {}

/// Ensure the socket's parent directory exists and is safe to bind
/// inside. There are three accepted cases:
/// 1. Parent doesn't exist → create + 0700 (our own).
/// 2. Parent exists and is owned by us → tighten to 0700, idempotent.
/// 3. Parent exists, isn't owned by us, but has the sticky bit set
///    (e.g. `/tmp` itself, mode 01777) → trust the kernel's
///    sticky-bit semantics; the socket file's 0600 mode is what
///    actually gates other users.
/// Anything else (a pre-existing dir at our expected path that we
/// don't own and isn't sticky-bit-protected) is treated as a hostile
/// drop-in and refused.
///
/// `metadata()` follows symlinks, which is what we want — system
/// `/tmp` is itself a symlink to `/private/tmp` on macOS and we
/// can't refuse that.
#[cfg(unix)]
fn harden_parent_directory(parent: &Path) -> anyhow::Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    if !parent.exists() {
        std::fs::create_dir_all(parent)?;
    }
    let meta = std::fs::metadata(parent)?;
    if !meta.is_dir() {
        anyhow::bail!(
            "peer-federation socket parent {} is not a directory",
            parent.display()
        );
    }
    let owner_uid = current_uid();
    let mode = meta.mode();
    let is_ours = meta.uid() == owner_uid;
    let is_sticky_world = mode & 0o1000 != 0; // S_ISVTX
    if is_ours {
        if mode & 0o777 != 0o700 {
            let mut perms = meta.permissions();
            perms.set_mode(0o700);
            std::fs::set_permissions(parent, perms)?;
        }
    } else if is_sticky_world {
        // System tmp dir; trust the kernel.
    } else {
        anyhow::bail!(
            "peer-federation socket parent directory {} is not owned by uid {} (got uid {}); refusing to bind",
            parent.display(),
            owner_uid,
            meta.uid()
        );
    }
    Ok(())
}

#[cfg(not(unix))]
fn harden_parent_directory(parent: &Path) -> anyhow::Result<()> {
    if !parent.exists() {
        std::fs::create_dir_all(parent)?;
    }
    Ok(())
}

#[cfg(unix)]
fn current_uid() -> u32 {
    // Safe: getuid() never fails and has no side effects.
    unsafe { libc::getuid() }
}

#[cfg(not(unix))]
fn current_uid() -> u32 {
    0
}

/// Bind the listener with a tight umask so the socket file is mode
/// 0600 immediately, eliminating the bind→chmod TOCTOU window that
/// exists when the kernel uses the process umask to derive the
/// initial permissions.
#[cfg(unix)]
fn bind_with_tight_umask(path: &Path) -> std::io::Result<UnixListener> {
    // libc::umask is process-global. We restore on success and on the
    // unwind path so other threads that bind files concurrently aren't
    // affected for longer than the bind() syscall itself.
    let prev = unsafe { libc::umask(0o077) };
    let result = UnixListener::bind(path);
    unsafe { libc::umask(prev) };
    result
}

#[cfg(not(unix))]
fn bind_with_tight_umask(path: &Path) -> std::io::Result<UnixListener> {
    UnixListener::bind(path)
}

/// Whether a peer with `peer_uid` may attach to a daemon owned by
/// `owner_uid`.
///
/// The gate exists to keep *other unprivileged users* off the socket. Root
/// is not one of them: it can already read this process's memory, its
/// socket, and its files, so refusing it buys nothing — and it broke the
/// installer's own root path. `install-linux.sh` running as root installs a
/// system unit with `User=term-mesh`, so the daemon owns uid 996 while
/// every ssh-based client arrives as uid 0 and was rejected outright.
/// The host looked dead: the client only ever sees its handshake read
/// return EOF, and nothing but this daemon's log said why.
fn peer_uid_allowed(peer_uid: u32, owner_uid: u32) -> bool {
    peer_uid == owner_uid || peer_uid == 0
}

/// The connected peer's effective uid, or `None` when it cannot be
/// established — on any platform/syscall failure the caller fails closed.
#[cfg(target_os = "macos")]
fn peer_uid(stream: &tokio::net::UnixStream) -> Option<u32> {
    use std::os::fd::AsRawFd;

    // Darwin's LOCAL_PEERCRED returns `xucred`. The first useful
    // field (`cr_uid`) is the connected peer's effective uid.
    #[repr(C)]
    struct Xucred {
        cr_version: libc::c_uint,
        cr_uid: libc::uid_t,
        cr_ngroups: libc::c_short,
        cr_groups: [libc::gid_t; 16],
    }
    const LOCAL_PEERCRED: libc::c_int = 0x001;
    const SOL_LOCAL: libc::c_int = 0;

    let fd = stream.as_raw_fd();
    let mut cred = std::mem::MaybeUninit::<Xucred>::zeroed();
    let mut len = std::mem::size_of::<Xucred>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            fd,
            SOL_LOCAL,
            LOCAL_PEERCRED,
            cred.as_mut_ptr() as *mut libc::c_void,
            &mut len,
        )
    };
    if rc != 0 {
        return None;
    }
    let cred = unsafe { cred.assume_init() };
    Some(cred.cr_uid)
}

#[cfg(target_os = "linux")]
fn peer_uid(stream: &tokio::net::UnixStream) -> Option<u32> {
    use std::os::fd::AsRawFd;

    let fd = stream.as_raw_fd();
    let mut cred = std::mem::MaybeUninit::<libc::ucred>::zeroed();
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            cred.as_mut_ptr() as *mut libc::c_void,
            &mut len,
        )
    };
    if rc != 0 {
        return None;
    }
    let cred = unsafe { cred.assume_init() };
    Some(cred.uid)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn peer_uid(_stream: &tokio::net::UnixStream) -> Option<u32> {
    // Conservative default: refuse all connections on platforms where
    // we can't verify the peer's uid.
    None
}

#[cfg(test)]
mod integration_tests {
    use super::*;

    /// A ceiling read from the environment, and the reasons to ignore one.
    ///
    /// Zero is rejected rather than honoured: a semaphore with no permits
    /// refuses every client, so a host booted that way would look exactly
    /// like a host that is down, with nothing to distinguish the two.
    #[test]
    fn connection_ceiling_falls_back_on_anything_unusable() {
        assert_eq!(parse_max_peer_connections(Some("128")), 128);
        assert_eq!(parse_max_peer_connections(Some("  128  ")), 128);
        for unusable in [None, Some(""), Some("0"), Some("-1"), Some("many")] {
            assert_eq!(
                parse_max_peer_connections(unusable),
                DEFAULT_MAX_PEER_CONNECTIONS,
                "expected fallback for {unusable:?}"
            );
        }
    }
    /// The uid gate must keep other unprivileged users out while letting
    /// root in. `install-linux.sh` run as root installs a system unit with
    /// `User=term-mesh`, so the daemon owns a service uid (996 on
    /// jwserver69) and every ssh client arrives as uid 0; rejecting root
    /// made that whole install path unreachable, and the client saw only
    /// EOF.
    #[test]
    fn uid_gate_admits_the_owner_and_root_and_nobody_else() {
        let owner = 996;
        assert!(peer_uid_allowed(owner, owner), "the daemon's own user");
        assert!(peer_uid_allowed(0, owner), "root, e.g. an ssh-forwarded client");
        assert!(!peer_uid_allowed(1000, owner), "an unrelated local user");
        assert!(!peer_uid_allowed(997, owner), "an adjacent service account");
    }

    /// A root-owned daemon (the plain `sudo`/container case) must not
    /// suddenly accept everyone just because root is allowed.
    #[test]
    fn uid_gate_owned_by_root_still_refuses_other_users() {
        assert!(peer_uid_allowed(0, 0));
        assert!(!peer_uid_allowed(501, 0));
    }

    /// A surface the host made on request goes away once nobody holds it, and
    /// one the operator declared does not.
    ///
    /// The distinction is the whole point: a spawned shell exists for whoever
    /// asked, and when their app dies nothing else refers to it — that is how
    /// a machine ends up carrying login shells days old, one per crash. A
    /// declared surface is published for anyone, and an empty one is idle.
    #[tokio::test]
    async fn reaps_a_spawned_surface_once_nobody_is_attached() {
        std::env::set_var("TERMMESH_PEER_ABANDONED_GRACE_MS", "150");
        let manager = Arc::new(crate::peer::surface::PtyManager::new());
        let declared = b"declared-surface".to_vec();
        let spawned = b"spawned-surface".to_vec();
        let spec = |title: &str| crate::peer::surface::SpawnSpec {
            title: title.into(),
            command: "/bin/cat".into(),
            args: vec![],
            cols: 80,
            rows: 24,
            cwd: None,
        };
        manager.register_and_spawn(declared.clone(), spec("declared"));
        manager.register_and_spawn_ephemeral(spawned.clone(), spec("spawned"));
        let host = Arc::new(PeerHost::new(manager.clone()));

        for id in [&declared, &spawned] {
            manager.note_attached(id);
            assert_eq!(manager.note_detached(id), 0);
            crate::peer::connection::reap_if_abandoned(&host, id);
        }

        tokio::time::sleep(std::time::Duration::from_millis(600)).await;
        let alive = |id: &[u8]| manager.list().iter().any(|s| s.surface_id == id);
        assert!(
            alive(&declared),
            "a declared surface is the operator's, not ours to reclaim"
        );
        assert!(
            !alive(&spawned),
            "a surface we asked the host to make must not outlive the asking"
        );
        std::env::remove_var("TERMMESH_PEER_ABANDONED_GRACE_MS");
    }

    /// Detaching is not leaving for good. A client that comes back inside the
    /// grace — a dropped link, a restart — finds its pane still there.
    #[tokio::test]
    async fn a_reconnect_inside_the_grace_saves_the_surface() {
        std::env::set_var("TERMMESH_PEER_ABANDONED_GRACE_MS", "300");
        let manager = Arc::new(crate::peer::surface::PtyManager::new());
        let sid = b"rejoined-surface".to_vec();
        manager.register_and_spawn_ephemeral(
            sid.clone(),
            crate::peer::surface::SpawnSpec {
                title: "rejoined".into(),
                command: "/bin/cat".into(),
                args: vec![],
                cols: 80,
                rows: 24,
                cwd: None,
            },
        );
        let host = Arc::new(PeerHost::new(manager.clone()));
        manager.note_attached(&sid);
        assert_eq!(manager.note_detached(&sid), 0);
        crate::peer::connection::reap_if_abandoned(&host, &sid);
        manager.note_attached(&sid);

        tokio::time::sleep(std::time::Duration::from_millis(700)).await;
        assert!(
            manager.list().iter().any(|s| s.surface_id == sid),
            "a reconnect inside the grace must cancel the reap"
        );
        std::env::remove_var("TERMMESH_PEER_ABANDONED_GRACE_MS");
    }

    use peer_proto::v1::envelope::Payload;
    use peer_proto::v1::{
        AttachMode, AttachSurface, Auth, Envelope, Hello, Input, ListSurfaces, ScrollbackRequest,
    };
    use tempfile::TempDir;
    use tokio::net::UnixStream;

    use crate::peer::connection::PROTOCOL_VERSION;
    use crate::peer::framing::{read_envelope, write_envelope};
    use crate::peer::surface::{surface_id_from_name, PtySurface};

    fn cat_manager() -> Arc<PtyManager> {
        // `/bin/cat` is long-lived: it only exits when its stdin (the PTY
        // slave) is closed. We deliberately use it as the test child to
        // prove the AsyncFd-based reader task can be cancelled cleanly
        // when the tokio runtime drops at test end. Under the earlier
        // spawn_blocking design this would hang the test forever.
        let manager = Arc::new(PtyManager::new());
        let surface = PtySurface::spawn(
            surface_id_from_name("shell"),
            "cat".into(),
            "/bin/cat",
            &[],
            80,
            24,
            None,
        )
        .expect("spawn /bin/cat");
        manager.insert_surface(surface);
        manager
    }

    /// Attach to a long-lived `/bin/cat` PTY; send keystrokes as Input and
    /// verify they come back through PtyData. This exercises the full
    /// bidirectional path plus AsyncFd's cancellation behavior at test end.
    /// team.call.v1 over the real wire: the allow-list refuses lifecycle,
    /// the shared vocabulary translates to headless terms, and a method that
    /// is allowed but not a single daemon op is reported honestly.
    #[tokio::test]
    async fn team_call_enforces_allow_list_and_translates_over_the_wire() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        let manager = cat_manager();
        let host = Arc::new(PeerHost::new(manager));
        let teams = Arc::new(tokio::sync::Mutex::new(
            crate::headless::HeadlessManager::new(),
        ));
        teams
            .lock()
            .await
            .insert_team_for_tests("remote-demo", "uuid-1", "/root/demo", vec![]);
        host.set_teams(teams);

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let host_task = host.clone();
        let server_task = tokio::spawn(async move {
            serve_with_host(sock_path_task, shutdown_rx, host_task)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let stream = UnixStream::connect(&sock_path).await.unwrap();
        let (mut reader, mut writer) = stream.into_split();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 1,
                correlation_id: 0,
                payload: Some(Payload::Hello(Hello {
                    protocol_version: PROTOCOL_VERSION.into(),
                    peer_id: vec![0x11; 16],
                    display_name: "integration-test".into(),
                    capabilities: peer_proto::capability::supported_vec(),
                    app_version: "test".into(),
                    cli_bin_dirs: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let host_hello = read_envelope(&mut reader).await.unwrap();
        match host_hello.payload {
            Some(Payload::Hello(h)) => assert!(
                h.capabilities
                    .iter()
                    .any(|c| c == peer_proto::capability::TEAM_CALL_V1),
                "host with a team manager must advertise team.call.v1"
            ),
            other => panic!("expected Hello, got {other:?}"),
        }
        let _ = read_envelope(&mut reader).await.unwrap();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 2,
                correlation_id: 0,
                payload: Some(Payload::Auth(Auth {
                    method: "ssh-passthrough".into(),
                    token_id: vec![],
                    signature: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();

        async fn team_call(
            reader: &mut (impl tokio::io::AsyncRead + Unpin),
            writer: &mut (impl tokio::io::AsyncWrite + Unpin),
            seq: u64,
            method: &str,
            params_json: &str,
        ) -> peer_proto::v1::TeamCallResponse {
            write_envelope(
                writer,
                &Envelope {
                    seq,
                    correlation_id: 0,
                    payload: Some(Payload::TeamCallRequest(
                        peer_proto::v1::TeamCallRequest {
                            method: method.into(),
                            params_json: params_json.into(),
                        },
                    )),
                },
            )
            .await
            .unwrap();
            match read_envelope(reader).await.unwrap().payload {
                Some(Payload::TeamCallResponse(r)) => r,
                other => panic!("expected TeamCallResponse, got {other:?}"),
            }
        }

        // Refused: creating a team spawns processes and takes a directory.
        let refused = team_call(&mut reader, &mut writer, 3, "team.create", "{}").await;
        assert!(!refused.ok);
        assert_eq!(refused.error_code, "method_not_allowed");

        // Translated: team.list maps to the headless roster.
        let listed = team_call(&mut reader, &mut writer, 4, "team.list", "{}").await;
        assert!(listed.ok, "team.list failed: {}", listed.error_message);
        assert!(listed.result_json.contains("remote-demo"));

        // Translated but the agent does not exist — a host error, not a
        // refusal: the method was allowed, the target was simply absent.
        let missing = team_call(
            &mut reader,
            &mut writer,
            5,
            "team.send",
            r#"{"team_name":"remote-demo","agent_name":"ghost","text":"hi"}"#,
        )
        .await;
        assert!(!missing.ok);
        assert_eq!(missing.error_code, "host_error");

        // Allowed in vocabulary, not a single daemon op.
        let unsupported = team_call(&mut reader, &mut writer, 6, "team.collect", "{}").await;
        assert!(!unsupported.ok);
        assert_eq!(unsupported.error_code, "unsupported_on_host");

        let _ = shutdown_tx.send(true);
        server_task.abort();
    }

    /// `team.task.diff` over the real wire, against a real repository.
    ///
    /// This is the whole point of the method: work done on this machine is
    /// reviewable from another one. So the host gets a task board holding a
    /// task with a real worktree, and the caller — which knows only a task id —
    /// gets back a patch it could compute a digest against.
    #[tokio::test]
    async fn task_diff_travels_the_wire_and_refuses_what_it_cannot_read() {
        use std::process::Command as SyncCommand;

        fn git(dir: &std::path::Path, args: &[&str]) {
            let out = SyncCommand::new("git")
                .args(args)
                .current_dir(dir)
                .env("GIT_AUTHOR_NAME", "T")
                .env("GIT_AUTHOR_EMAIL", "t@t")
                .env("GIT_COMMITTER_NAME", "T")
                .env("GIT_COMMITTER_EMAIL", "t@t")
                .output()
                .expect("git");
            assert!(
                out.status.success(),
                "git {args:?}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
        }

        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        // The work, on this machine.
        let repo = tmp.path().join("repo");
        std::fs::create_dir(&repo).unwrap();
        git(&repo, &["init", "-q", "-b", "main"]);
        std::fs::write(repo.join("a.txt"), "one\n").unwrap();
        git(&repo, &["add", "-A"]);
        git(&repo, &["commit", "-qm", "base"]);
        git(&repo, &["checkout", "-q", "-b", "feat/thing"]);
        std::fs::write(repo.join("a.txt"), "one\ntwo\n").unwrap();
        git(&repo, &["commit", "-qam", "the work"]);

        // The board that knows where it is. Only the host reads this; the
        // caller never names the directory.
        let board = Arc::new(
            crate::agent::AgentSessionManager::new(tmp.path().join("agents.db"))
                .expect("agent db"),
        );
        let task = board
            .task_create(crate::agent::TaskCreateParams {
                title: "the work".into(),
                description: None,
                priority: None,
                created_by: None,
                deps: None,
                fix_budget: None,
                worktree_policy: None,
            })
            .expect("task");
        board
            .task_update(crate::agent::TaskUpdateParams {
                id: task.id.clone(),
                title: None,
                description: None,
                status: None,
                priority: None,
                assignee: None,
                worktree_policy: None,
                worktree_path: Some(repo.to_str().unwrap().to_string()),
                worktree_branch: Some("feat/thing".into()),
                worktree_parent: Some("main".into()),
                worktree_created: None,
                worktree_reused: None,
                worktree_init: None,
                worktree_finished_at_ms: None,
                worktree_finish_mode: None,
                worktree_removed: None,
            })
            .expect("worktree recorded");

        let host = Arc::new(PeerHost::new(cat_manager()));
        let teams = Arc::new(tokio::sync::Mutex::new(
            crate::headless::HeadlessManager::new(),
        ));
        host.set_teams(teams);
        host.set_agents(board);

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let host_task = host.clone();
        let server_task = tokio::spawn(async move {
            serve_with_host(sock_path_task, shutdown_rx, host_task)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let stream = UnixStream::connect(&sock_path).await.unwrap();
        let (mut reader, mut writer) = stream.into_split();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 1,
                correlation_id: 0,
                payload: Some(Payload::Hello(Hello {
                    protocol_version: PROTOCOL_VERSION.into(),
                    peer_id: vec![0x22; 16],
                    display_name: "reviewer".into(),
                    capabilities: peer_proto::capability::supported_vec(),
                    app_version: "test".into(),
                    cli_bin_dirs: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 2,
                correlation_id: 0,
                payload: Some(Payload::Auth(Auth {
                    method: "ssh-passthrough".into(),
                    token_id: vec![],
                    signature: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();

        async fn call(
            reader: &mut (impl tokio::io::AsyncRead + Unpin),
            writer: &mut (impl tokio::io::AsyncWrite + Unpin),
            seq: u64,
            params_json: &str,
        ) -> peer_proto::v1::TeamCallResponse {
            write_envelope(
                writer,
                &Envelope {
                    seq,
                    correlation_id: 0,
                    payload: Some(Payload::TeamCallRequest(
                        peer_proto::v1::TeamCallRequest {
                            method: "team.task.diff".into(),
                            params_json: params_json.into(),
                        },
                    )),
                },
            )
            .await
            .unwrap();
            match read_envelope(reader).await.unwrap().payload {
                Some(Payload::TeamCallResponse(r)) => r,
                other => panic!("expected TeamCallResponse, got {other:?}"),
            }
        }

        let answered = call(
            &mut reader,
            &mut writer,
            3,
            &format!(r#"{{"task_id":"{}"}}"#, task.id),
        )
        .await;
        assert!(answered.ok, "diff failed: {}", answered.error_message);

        let value: serde_json::Value = serde_json::from_str(&answered.result_json).unwrap();
        assert_eq!(value["head_sha"].as_str().unwrap().len(), 40);
        assert!(value["diff_digest"]
            .as_str()
            .unwrap()
            .starts_with("sha256:"));
        assert!(value["patch"].as_str().unwrap().contains("+two"));
        assert!(value["numstat"].as_str().unwrap().contains("a.txt"));
        assert_eq!(value["branch"].as_str().unwrap(), "feat/thing");
        assert_eq!(value["truncated"].as_bool().unwrap(), false);

        // A task this host does not have is an error with a reason, never an
        // empty success — the board would read that as "nothing changed",
        // which is an approvable state.
        let unknown = call(&mut reader, &mut writer, 4, r#"{"task_id":"tsk_nobody"}"#).await;
        assert!(!unknown.ok);
        assert!(unknown.result_json.is_empty());

        // And a path is not a parameter, on the wire as much as anywhere.
        let no_id = call(&mut reader, &mut writer, 5, r#"{"worktree_path":"/etc"}"#).await;
        assert!(!no_id.ok);
        assert_eq!(no_id.error_code, "invalid_params");

        let _ = shutdown_tx.send(true);
        server_task.abort();
    }

    /// `team.task.diff` against a real daemon on another machine.
    ///
    /// The test above proves the method works over a real socket in one
    /// process. This proves it works over the link people actually use: a
    /// reviewer on one machine reading a patch out of a worktree on another,
    /// through an SSH-forwarded peer socket.
    ///
    /// `#[ignore]` because it needs a host this repository cannot start.
    /// Point it at one and run it:
    ///
    /// ```sh
    /// ssh -N -L /tmp/tm-peer-live.sock:/run/user/0/tm-peer.sock root@host &
    /// TM_PEER_SOCK=/tmp/tm-peer-live.sock TM_TASK_ID=<id> TM_EXPECT_DIGEST=<sha256 hex> \\
    ///   cargo test -p term-meshd --bin term-meshd a_patch_can_be_read_off_another_machine \\
    ///   -- --ignored --nocapture
    /// ```
    #[tokio::test]
    #[ignore = "needs a live peer host; see the doc comment"]
    async fn a_patch_can_be_read_off_another_machine() {
        let sock = std::env::var("TM_PEER_SOCK").expect("TM_PEER_SOCK");
        let task_id = std::env::var("TM_TASK_ID").expect("TM_TASK_ID");

        let stream = UnixStream::connect(&sock)
            .await
            .unwrap_or_else(|e| panic!("connect {sock}: {e}"));
        let (mut reader, mut writer) = stream.into_split();

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 1,
                correlation_id: 0,
                payload: Some(Payload::Hello(Hello {
                    protocol_version: PROTOCOL_VERSION.into(),
                    peer_id: vec![0x33; 16],
                    display_name: "live-review".into(),
                    capabilities: peer_proto::capability::supported_vec(),
                    app_version: "live".into(),
                    cli_bin_dirs: vec![],
                })),
            },
        )
        .await
        .expect("hello");

        // A live host pushes HostStats and layout frames on its own schedule,
        // so nothing here may assume the next frame is the answer. The
        // in-process test never saw this: that host has no monitor wired in.
        async fn hello_of(
            reader: &mut (impl tokio::io::AsyncRead + Unpin),
        ) -> peer_proto::v1::Hello {
            for _ in 0..20 {
                match read_envelope(reader).await.expect("frame").payload {
                    Some(Payload::Hello(h)) => return h,
                    _ => continue,
                }
            }
            panic!("no Hello in the first 20 frames");
        }

        let h = hello_of(&mut reader).await;
        println!("host: {} ({})", h.display_name, h.app_version);
        assert!(
            h.capabilities
                .iter()
                .any(|c| c == peer_proto::capability::TEAM_CALL_V1),
            "host does not advertise team.call.v1: {:?}",
            h.capabilities
        );

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 2,
                correlation_id: 0,
                payload: Some(Payload::Auth(Auth {
                    method: "ssh-passthrough".into(),
                    token_id: vec![],
                    signature: vec![],
                })),
            },
        )
        .await
        .expect("auth");

        async fn diff(
            reader: &mut (impl tokio::io::AsyncRead + Unpin),
            writer: &mut (impl tokio::io::AsyncWrite + Unpin),
            seq: u64,
            params_json: String,
        ) -> peer_proto::v1::TeamCallResponse {
            write_envelope(
                writer,
                &Envelope {
                    seq,
                    correlation_id: 0,
                    payload: Some(Payload::TeamCallRequest(
                        peer_proto::v1::TeamCallRequest {
                            method: "team.task.diff".into(),
                            params_json,
                        },
                    )),
                },
            )
            .await
            .expect("request");
            // Skip whatever the host happened to be pushing.
            for _ in 0..50 {
                if let Some(Payload::TeamCallResponse(r)) =
                    read_envelope(reader).await.expect("response").payload
                {
                    return r;
                }
            }
            panic!("no TeamCallResponse in the next 50 frames");
        }

        let answered = diff(
            &mut reader,
            &mut writer,
            3,
            format!(r#"{{"task_id":"{task_id}"}}"#),
        )
        .await;
        assert!(answered.ok, "diff failed: {}", answered.error_message);

        // Printed verbatim so the app's decoder can be pinned against the bytes
        // a real host actually sent, rather than against a hand-written fixture.
        if let Ok(path) = std::env::var("TM_SAVE_PAYLOAD") {
            std::fs::write(&path, &answered.result_json).expect("save payload");
            println!("payload saved to {path}");
        }
        let value: serde_json::Value = serde_json::from_str(&answered.result_json).expect("json");
        println!(
            "head={} base={} branch={}\ndigest={} truncated={}",
            value["head_sha"], value["base_sha"], value["branch"], value["diff_digest"],
            value["truncated"]
        );
        println!("--- numstat ---\n{}", value["numstat"].as_str().unwrap_or(""));
        println!("--- name_status ---\n{}", value["name_status"].as_str().unwrap_or(""));
        println!("--- patch ---\n{}", value["patch"].as_str().unwrap_or(""));

        assert_eq!(value["head_sha"].as_str().unwrap().len(), 40);
        assert!(!value["patch"].as_str().unwrap().is_empty());
        assert!(!value["numstat"].as_str().unwrap().is_empty());

        // The digest is what an approval cites, so it is checked against the
        // host's own `git diff | sha256sum` rather than merely being present.
        if let Ok(expected) = std::env::var("TM_EXPECT_DIGEST") {
            assert_eq!(
                value["diff_digest"].as_str().unwrap(),
                format!("sha256:{expected}"),
                "the digest must be exactly SHA-256 of `git diff base..head` stdout"
            );
        }

        // An unknown task is an error with a reason, never an empty success —
        // the board would read that as "nothing changed", an approvable state.
        let unknown = diff(
            &mut reader,
            &mut writer,
            4,
            r#"{"task_id":"tsk_definitely_not_there"}"#.into(),
        )
        .await;
        assert!(!unknown.ok, "an unknown task must not answer ok");
        assert!(unknown.result_json.is_empty());
        println!("unknown task -> {} {}", unknown.error_code, unknown.error_message);

        // And a path is not a parameter, across the link as much as in process.
        let no_id = diff(&mut reader, &mut writer, 5, r#"{"worktree_path":"/etc"}"#.into()).await;
        assert!(!no_id.ok);
        assert_eq!(no_id.error_code, "invalid_params");
        println!("path-only -> {} {}", no_id.error_code, no_id.error_message);
    }

    /// A team is invisible in the layout tree, so a client can only learn
    /// where a project's leader sits by asking. This drives the real wire:
    /// handshake, auth, then ListTeams against a host wired to a team
    /// manager holding one team.
    #[tokio::test]
    async fn list_teams_reports_the_hosts_teams_over_the_wire() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");
        // A real repository, so the host resolves a project root for it.
        let repo = tmp.path().join("demo-project");
        std::fs::create_dir_all(repo.join("src")).unwrap();
        std::fs::create_dir(repo.join(".git")).unwrap();

        let manager = cat_manager();
        let host = Arc::new(PeerHost::new(manager));
        let teams = Arc::new(tokio::sync::Mutex::new(
            crate::headless::HeadlessManager::new(),
        ));
        teams.lock().await.insert_team_for_tests(
            "remote-demo",
            "uuid-remote-demo",
            repo.join("src").to_str().unwrap(),
            vec!["explorer".to_string()],
        );
        host.set_teams(teams);

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let host_task = host.clone();
        let server_task = tokio::spawn(async move {
            serve_with_host(sock_path_task, shutdown_rx, host_task)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let stream = UnixStream::connect(&sock_path).await.unwrap();
        let (mut reader, mut writer) = stream.into_split();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 1,
                correlation_id: 0,
                payload: Some(Payload::Hello(Hello {
                    protocol_version: PROTOCOL_VERSION.into(),
                    peer_id: vec![0x11; 16],
                    display_name: "integration-test".into(),
                    capabilities: peer_proto::capability::supported_vec(),
                    app_version: "test".into(),
                    cli_bin_dirs: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let host_hello = read_envelope(&mut reader).await.unwrap();
        // The capability is what tells a client it may ask at all.
        match host_hello.payload {
            Some(Payload::Hello(h)) => assert!(
                h.capabilities
                    .iter()
                    .any(|c| c == peer_proto::capability::TEAM_ROSTER_V1),
                "host with a team manager must advertise team.roster.v1"
            ),
            other => panic!("expected Hello, got {other:?}"),
        }
        let _ = read_envelope(&mut reader).await.unwrap();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 2,
                correlation_id: 0,
                payload: Some(Payload::Auth(Auth {
                    method: "ssh-passthrough".into(),
                    token_id: vec![],
                    signature: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 3,
                correlation_id: 0,
                payload: Some(Payload::ListTeams(peer_proto::v1::ListTeams {})),
            },
        )
        .await
        .unwrap();
        let reply = read_envelope(&mut reader).await.unwrap();
        let listed = match reply.payload {
            Some(Payload::TeamList(tl)) => tl.teams,
            other => panic!("expected TeamList, got {other:?}"),
        };

        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "remote-demo");
        assert_eq!(listed[0].agent_names, vec!["explorer".to_string()]);
        // The host resolves the repo root itself — a client staring at the
        // working directory could not tell it from a subdirectory.
        assert_eq!(listed[0].project_root, repo.to_string_lossy());

        let _ = shutdown_tx.send(true);
        server_task.abort();
    }

    #[tokio::test]
    async fn pty_surface_round_trips_input() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        const MARKER: &str = "MARKER-peer-test";
        let manager = cat_manager();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager)
                .await
                .unwrap();
        });

        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let stream = UnixStream::connect(&sock_path).await.unwrap();
        let (mut reader, mut writer) = stream.into_split();

        // Handshake.
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 1,
                correlation_id: 0,
                payload: Some(Payload::Hello(Hello {
                    protocol_version: PROTOCOL_VERSION.into(),
                    peer_id: vec![0x11; 16],
                    display_name: "integration-test".into(),
                    capabilities: peer_proto::capability::supported_vec(),
                    app_version: "test".into(),
                    cli_bin_dirs: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 2,
                correlation_id: 0,
                payload: Some(Payload::Auth(Auth {
                    method: "ssh-passthrough".into(),
                    token_id: vec![],
                    signature: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();

        // List + attach.
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 3,
                correlation_id: 0,
                payload: Some(Payload::ListSurfaces(ListSurfaces {})),
            },
        )
        .await
        .unwrap();
        let list_reply = read_envelope(&mut reader).await.unwrap();
        let surfaces = match list_reply.payload {
            Some(Payload::SurfaceList(sl)) => sl.surfaces,
            other => panic!("expected SurfaceList, got {other:?}"),
        };
        assert!(!surfaces.is_empty(), "server did not expose any surfaces");
        let surface_id = surfaces[0].surface_id.clone();

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 4,
                correlation_id: 0,
                payload: Some(Payload::AttachSurface(AttachSurface {
                    surface_id: surface_id.clone(),
                    mode: AttachMode::CoWrite as i32,
                    client_cols: 80,
                    client_rows: 24,
                    resume_from_seq: 0,
                })),
            },
        )
        .await
        .unwrap();
        let attach_reply = read_envelope(&mut reader).await.unwrap();
        match attach_reply.payload {
            Some(Payload::AttachResult(r)) => assert!(r.accepted, "attach rejected: {}", r.reason),
            other => panic!("expected AttachResult, got {other:?}"),
        }

        // Send MARKER through as Input. /bin/cat in a PTY echoes it back via
        // both the PTY's default ECHO termios and cat's own stdin→stdout.
        // Either path puts MARKER into the PtyData stream.
        let mut payload = MARKER.as_bytes().to_vec();
        payload.push(b'\n');
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 5,
                correlation_id: 0,
                payload: Some(Payload::Input(Input {
                    surface_id: surface_id.clone(),
                    kind: Some(peer_proto::v1::input::Kind::Keys(payload)),
                })),
            },
        )
        .await
        .unwrap();

        let mut aggregated = Vec::<u8>::new();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            let env = match tokio::time::timeout(remaining, read_envelope(&mut reader)).await {
                Ok(Ok(env)) => env,
                _ => break,
            };
            if let Some(Payload::PtyData(p)) = env.payload {
                aggregated.extend_from_slice(&p.payload);
                if aggregated
                    .windows(MARKER.len())
                    .any(|w| w == MARKER.as_bytes())
                {
                    break;
                }
            }
        }
        let text = String::from_utf8_lossy(&aggregated);
        assert!(
            text.contains(MARKER),
            "did not observe MARKER in PTY output; saw: {text:?}"
        );

        // Explicitly close the client side so the server's connection task
        // observes EOF and its AttachEntry relay tasks drop their
        // Arc<PtySurface>. Combined with the child having exited (which
        // lets the reader thread hit EOF naturally), this gives tokio a
        // clean path to shut the runtime down at test end.
        drop(reader);
        drop(writer);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    #[tokio::test]
    async fn attach_replays_pre_attach_output() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        const MARKER: &[u8] = b"PREATTACH-PROMPT";
        let manager = Arc::new(PtyManager::new());
        let surface = PtySurface::spawn(
            surface_id_from_name("preattach"),
            "preattach".into(),
            "/bin/sh",
            &["-c", "printf PREATTACH-PROMPT; sleep 5"],
            80,
            24,
            None,
        )
        .expect("spawn preattach surface");

        for _ in 0..50 {
            let replay = surface.replay_snapshot();
            if replay
                .iter()
                .flat_map(|chunk| chunk.bytes.iter().copied())
                .collect::<Vec<_>>()
                .windows(MARKER.len())
                .any(|w| w == MARKER)
            {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        manager.insert_surface(surface);

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sp_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sp_task, shutdown_rx, manager)
                .await
                .unwrap();
        });

        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, writer, _surface_id) = attach_one(&sock_path, "replay-test").await;
        let seen = wait_for_marker(&mut reader, MARKER, std::time::Duration::from_secs(3)).await;
        assert!(seen, "pre-attach PTY output was not replayed to the relay");

        drop(reader);
        drop(writer);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// Read PtyData frames until `want` appears, returning everything
    /// aggregated so far — lets a test assert on what was ABSENT from the
    /// stream, which `wait_for_marker`'s bool cannot.
    async fn collect_pty_until_marker(
        reader: &mut tokio::net::unix::OwnedReadHalf,
        want: &[u8],
        timeout: std::time::Duration,
    ) -> Vec<u8> {
        let deadline = tokio::time::Instant::now() + timeout;
        let mut aggregated = Vec::<u8>::new();
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return aggregated;
            }
            let env = match tokio::time::timeout(remaining, read_envelope(reader)).await {
                Ok(Ok(e)) => e,
                _ => return aggregated,
            };
            if let Some(Payload::PtyData(p)) = env.payload {
                aggregated.extend_from_slice(&p.payload);
                if aggregated.windows(want.len()).any(|w| w == want) {
                    return aggregated;
                }
            }
        }
    }

    /// Spawn a surface whose visible line was overwritten in place (CR, no
    /// LF), serve it, attach fresh, and return the aggregated first bytes.
    async fn attach_overwritten_line_surface(name: &str) -> Vec<u8> {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        let manager = Arc::new(PtyManager::new());
        let surface = PtySurface::spawn(
            surface_id_from_name(name),
            name.into(),
            "/bin/sh",
            &["-c", "printf 'OLDMARKER\\rNEWMARKER99'; sleep 5"],
            80,
            24,
            None,
        )
        .expect("spawn overwritten-line surface");

        // Wait until the overwrite has flowed through the reader (ring
        // holds the raw history including OLDMARKER).
        for _ in 0..100 {
            let replay = surface.replay_snapshot();
            let bytes: Vec<u8> = replay
                .iter()
                .flat_map(|chunk| chunk.bytes.iter().copied())
                .collect();
            if bytes.windows(11).any(|w| w == b"NEWMARKER99") {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        manager.insert_surface(surface);

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sp_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sp_task, shutdown_rx, manager).await.unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, writer, _sid) = attach_one(&sock_path, name).await;
        let got = collect_pty_until_marker(
            &mut reader,
            b"NEWMARKER99",
            std::time::Duration::from_secs(3),
        )
        .await;

        drop(reader);
        drop(writer);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
        got
    }

    /// Serializes every test that READS OR WRITES
    /// `TERMMESH_PEER_FRESH_ATTACH_MODE`. Env is process-global: the kill
    /// switch test setting `=bytes` for its second scenario would otherwise
    /// race a concurrently-attaching gating test into the bytes path
    /// (observed: GridSnapshot count 0 under the full parallel suite).
    static FRESH_MODE_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// Drain frames briefly, splitting GridSnapshot payloads from PtyData
    /// payloads, so a gating test can assert which path carried the screen.
    async fn collect_typed_and_pty(
        reader: &mut tokio::net::unix::OwnedReadHalf,
        want: &[u8],
        timeout: std::time::Duration,
    ) -> (Vec<Vec<u8>>, Vec<u8>) {
        let deadline = tokio::time::Instant::now() + timeout;
        let mut snapshots: Vec<Vec<u8>> = Vec::new();
        let mut pty = Vec::<u8>::new();
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return (snapshots, pty);
            }
            let env = match tokio::time::timeout(remaining, read_envelope(reader)).await {
                Ok(Ok(e)) => e,
                _ => return (snapshots, pty),
            };
            match env.payload {
                Some(Payload::GridSnapshot(g)) => {
                    let done = g.ansi.windows(want.len()).any(|w| w == want);
                    snapshots.push(g.ansi);
                    if done {
                        return (snapshots, pty);
                    }
                }
                Some(Payload::PtyData(p)) => {
                    pty.extend_from_slice(&p.payload);
                    if pty.windows(want.len()).any(|w| w == want) {
                        return (snapshots, pty);
                    }
                }
                _ => {}
            }
        }
    }

    /// grid.snapshot.v1 gating, both halves that involve the typed path
    /// (the legacy halves live in `fresh_attach_renders_...` and the
    /// `effective_resume_from_seq` unit tests):
    ///
    /// - An advertising client's FRESH attach receives the screen as a
    ///   GridSnapshot envelope — rendered state, no overwritten history —
    ///   and NOT as a PtyData snapshot.
    /// - The same client's RESUME attach receives no GridSnapshot at all:
    ///   resume is served from the byte ring, typed or not.
    #[tokio::test]
    async fn grid_snapshot_gates_on_capability_and_freshness() {
        let _env = FRESH_MODE_ENV_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        let manager = Arc::new(PtyManager::new());
        let surface = PtySurface::spawn(
            surface_id_from_name("typed-gate"),
            "typed-gate".into(),
            "/bin/sh",
            &["-c", "printf 'OLDMARKER\\rNEWMARKER99'; sleep 5"],
            80,
            24,
            None,
        )
        .expect("spawn typed-gate surface");
        let sid = surface.surface_id.clone();
        for _ in 0..100 {
            let ready = surface
                .replay_snapshot()
                .iter()
                .flat_map(|c| c.bytes.iter().copied())
                .collect::<Vec<_>>()
                .windows(11)
                .any(|w| w == b"NEWMARKER99");
            if ready {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        manager.insert_surface(surface);

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sp_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sp_task, shutdown_rx, manager).await.unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        // Fresh attach, advertising the capability.
        let (mut reader, writer, _sid) = attach_full(
            &sock_path,
            "typed-fresh",
            Some(sid.clone()),
            peer_proto::capability::supported_vec(),
            0,
        )
        .await;
        let (snapshots, pty) = collect_typed_and_pty(
            &mut reader,
            b"NEWMARKER99",
            std::time::Duration::from_secs(15),
        )
        .await;
        assert_eq!(
            snapshots.len(),
            1,
            "typed fresh attach must carry the screen in exactly one GridSnapshot"
        );
        let ansi = &snapshots[0];
        assert!(ansi.windows(11).any(|w| w == b"NEWMARKER99"));
        assert!(
            !ansi.windows(9).any(|w| w == b"OLDMARKER"),
            "GridSnapshot must be a render, not byte history"
        );
        assert!(
            !pty.windows(11).any(|w| w == b"NEWMARKER99"),
            "the screen must not ALSO arrive as a PtyData snapshot"
        );
        drop(reader);
        drop(writer);

        // Resume attach from the same advertising client: byte-ring path,
        // no GridSnapshot.
        let (mut reader, writer, _sid) = attach_full(
            &sock_path,
            "typed-resume",
            Some(sid.clone()),
            peer_proto::capability::supported_vec(),
            1, // any nonzero host seq inside the ring
        )
        .await;
        let (snapshots, pty) = collect_typed_and_pty(
            &mut reader,
            b"NEWMARKER99",
            std::time::Duration::from_secs(15),
        )
        .await;
        assert!(
            snapshots.is_empty(),
            "resume must never be served as a GridSnapshot"
        );
        assert!(
            pty.windows(11).any(|w| w == b"NEWMARKER99"),
            "resume must replay ring bytes as PtyData"
        );
        drop(reader);
        drop(writer);

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// On-demand scrollback round trip, and its capability gate: an
    /// advertising client's request renders a past window; a legacy
    /// client's identical request is silently ignored.
    #[tokio::test]
    async fn scrollback_request_round_trips_and_gates_on_capability() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        let manager = Arc::new(PtyManager::new());
        let surface = PtySurface::spawn(
            surface_id_from_name("sb-gate"),
            "sb-gate".into(),
            "/bin/sh",
            &["-c", "for i in $(seq 1 40); do echo SBLINE-$i; done; sleep 5"],
            80,
            24,
            None,
        )
        .expect("spawn sb-gate surface");
        let sid = surface.surface_id.clone();
        for _ in 0..150 {
            if let Some((snap, _)) = surface.screen_snapshot() {
                if snap.windows(9).any(|w| w == b"SBLINE-40") {
                    break;
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        manager.insert_surface(surface);

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sp_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sp_task, shutdown_rx, manager).await.unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        async fn request_scrollback(
            writer: &mut tokio::net::unix::OwnedWriteHalf,
            sid: &[u8],
            offset: u32,
        ) {
            write_envelope(
                writer,
                &Envelope {
                    seq: 100,
                    correlation_id: 0,
                    payload: Some(Payload::ScrollbackRequest(ScrollbackRequest {
                        surface_id: sid.to_vec(),
                        offset_rows: offset,
                    })),
                },
            )
            .await
            .unwrap();
        }

        async fn wait_chunk(
            reader: &mut tokio::net::unix::OwnedReadHalf,
            timeout: std::time::Duration,
        ) -> Option<peer_proto::v1::ScrollbackChunk> {
            let deadline = tokio::time::Instant::now() + timeout;
            loop {
                let remaining =
                    deadline.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero() {
                    return None;
                }
                match tokio::time::timeout(remaining, read_envelope(reader)).await {
                    Ok(Ok(env)) => {
                        if let Some(Payload::ScrollbackChunk(c)) = env.payload {
                            return Some(c);
                        }
                    }
                    _ => return None,
                }
            }
        }

        // Advertising client: window 10 rows up contains scrolled-out lines.
        let (mut reader, mut writer, _sid) = attach_full(
            &sock_path,
            "sb-typed",
            Some(sid.clone()),
            peer_proto::capability::supported_vec(),
            0,
        )
        .await;
        request_scrollback(&mut writer, &sid, 10).await;
        let chunk = wait_chunk(&mut reader, std::time::Duration::from_secs(10))
            .await
            .expect("advertising client must receive a ScrollbackChunk");
        assert_eq!(chunk.offset_rows, 10);
        assert!(chunk.total_scrollback_rows >= 10);
        assert!(
            chunk.ansi.windows(9).any(|w| w == b"SBLINE-25")
                || chunk.ansi.windows(9).any(|w| w == b"SBLINE-30"),
            "window must contain scrolled-out lines"
        );
        drop(reader);
        drop(writer);

        // Legacy client: same request, no reply.
        let (mut reader, mut writer, _sid) =
            attach_surface_by(&sock_path, "sb-legacy", Some(sid.clone())).await;
        request_scrollback(&mut writer, &sid, 10).await;
        assert!(
            wait_chunk(&mut reader, std::time::Duration::from_secs(1))
                .await
                .is_none(),
            "a non-advertising client's scrollback request must be ignored"
        );
        drop(reader);
        drop(writer);

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// The tmux-model contract, plus its kill switch — one test on purpose:
    /// `TERMMESH_PEER_FRESH_ATTACH_MODE` is process-global env, and a
    /// sibling test racing the flag would flake.
    ///
    /// Scenario A (default): a fresh attach receives the RENDERED screen.
    /// A line overwritten in place (CR, no LF) must not resurface — under
    /// byte replay it always did, which is exactly the "old find scrolls
    /// past again" bug at 1-line scale.
    ///
    /// Scenario B (`=bytes`): the switch restores the byte-history tail,
    /// so the overwritten text IS present again.
    #[tokio::test]
    async fn fresh_attach_renders_screen_and_kill_switch_restores_bytes() {
        let _env = FRESH_MODE_ENV_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // A — snapshot path (default).
        let got = attach_overwritten_line_surface("snap-fresh").await;
        assert!(
            got.windows(11).any(|w| w == b"NEWMARKER99"),
            "snapshot attach must contain the final screen line"
        );
        assert!(
            !got.windows(9).any(|w| w == b"OLDMARKER"),
            "snapshot attach must NOT contain the overwritten byte history"
        );
        // And it is a real state render: vt100's contents_formatted always
        // leads with clear+home, so the viewer starts from a clean grid.
        assert!(
            got.windows(6).any(|w| w == b"\x1b[H\x1b[J"),
            "snapshot must begin with vt100's clear+home preamble"
        );

        // B — kill switch forces the pre-snapshot byte tail.
        std::env::set_var("TERMMESH_PEER_FRESH_ATTACH_MODE", "bytes");
        let got = attach_overwritten_line_surface("bytes-fresh").await;
        std::env::remove_var("TERMMESH_PEER_FRESH_ATTACH_MODE");
        assert!(
            got.windows(9).any(|w| w == b"OLDMARKER"),
            "bytes mode must replay raw history including the overwritten text"
        );
    }

    #[tokio::test]
    async fn ctrl_c_input_reaches_attached_pty() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        let manager = Arc::new(PtyManager::new());
        let surface = PtySurface::spawn(
            surface_id_from_name("sigint"),
            "sigint".into(),
            "/bin/sh",
            &[
                "-c",
                "trap 'printf GOT-SIGINT; exit 0' INT; while :; do sleep 10; done",
            ],
            80,
            24,
            None,
        )
        .expect("spawn sigint surface");
        manager.insert_surface(surface);

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sp_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sp_task, shutdown_rx, manager)
                .await
                .unwrap();
        });

        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, mut writer, surface_id) = attach_one(&sock_path, "sigint-test").await;
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 5,
                correlation_id: 0,
                payload: Some(Payload::Input(Input {
                    surface_id,
                    kind: Some(peer_proto::v1::input::Kind::Keys(vec![0x03])),
                })),
            },
        )
        .await
        .unwrap();

        let seen = wait_for_marker(
            &mut reader,
            b"GOT-SIGINT",
            std::time::Duration::from_secs(3),
        )
        .await;
        assert!(seen, "Ctrl-C byte did not interrupt the attached PTY");

        drop(reader);
        drop(writer);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// Issue 1 fix: when a TUI in the remote PTY emits a terminal query
    /// like CSI 6n (cursor position report), the daemon must answer it
    /// itself by writing a synthesized reply back to the PTY master,
    /// AND must strip the query from the bytes broadcast to clients.
    /// Otherwise the local Ghostty would answer over the SSH round trip
    /// and the answer would land in the remote shell as bogus input
    /// ("zsh: command not found: 11", etc.).
    #[tokio::test]
    async fn cpr_query_is_answered_locally_and_not_broadcast() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        let manager = Arc::new(PtyManager::new());
        // The shell emits the CPR query, then `dd` reads exactly the 6
        // bytes of the synthesized reply (`\x1b[1;1R`) from stdin, then
        // prints them inside `GOT[...]`. The PTY is put into raw mode
        // first so `dd` can return on byte boundaries instead of waiting
        // for a newline (canonical mode blocks until '\n', and the
        // response has none). If the daemon didn't write the reply,
        // `dd` would block forever and the marker never appears.
        //
        // The leading sleep pushes the whole exchange PAST the attach
        // below, so GOT[...] arrives on the LIVE stream. This test asserts
        // byte-stream properties (QueryFilter answered locally, stripped
        // from broadcast); the attach-time grid snapshot would re-render
        // the screen instead — the echoed ESC[1;1R is consumed by the
        // emulator as a CPR *response*, never entering the grid — so the
        // raw marker only exists on the live path.
        let surface = PtySurface::spawn(
            surface_id_from_name("query"),
            "query".into(),
            "/bin/sh",
            &[
                "-c",
                "stty -icanon -echo min 1 time 0 2>/dev/null; sleep 0.5; printf '\\033[6n'; reply=$(dd bs=1 count=6 2>/dev/null); printf 'GOT[%s]\\n' \"$reply\"; sleep 2",
            ],
            80,
            24,
            None,
        )
        .expect("spawn query surface");
        manager.insert_surface(surface);

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sp_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sp_task, shutdown_rx, manager)
                .await
                .unwrap();
        });

        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, writer, _surface_id) = attach_one(&sock_path, "query-test").await;

        // Drain frames for up to 5s, accumulating payload bytes. We
        // need both: the GOT[...] marker (proves the daemon answered)
        // AND the absence of the raw `\x1b[6n` bytes (proves the query
        // was stripped from broadcast).
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut aggregated = Vec::<u8>::new();
        let marker = b"GOT[\x1b[1;1R]";
        let query = b"\x1b[6n";
        while tokio::time::Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            let env = match tokio::time::timeout(remaining, read_envelope(&mut reader)).await {
                Ok(Ok(e)) => e,
                _ => break,
            };
            if let Some(Payload::PtyData(p)) = env.payload {
                aggregated.extend_from_slice(&p.payload);
                if aggregated.windows(marker.len()).any(|w| w == marker) {
                    break;
                }
            }
        }

        assert!(
            aggregated.windows(marker.len()).any(|w| w == marker),
            "shell did not receive the synthesized CPR reply on stdin (got bytes: {:?})",
            aggregated
        );
        assert!(
            !aggregated.windows(query.len()).any(|w| w == query),
            "raw CPR query leaked into the client broadcast (got bytes: {:?})",
            aggregated
        );

        drop(reader);
        drop(writer);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// Drive the full handshake + attach path for one client against
    /// `sock_path`, returning the split stream halves and the chosen
    /// surface_id. Used by the multi-client test below.
    /// Attach as a LEGACY client: everything current builds support EXCEPT
    /// grid.snapshot.v1. Most integration tests assert on the raw PtyData
    /// stream (replay content, mode prefixes, byte ordering), and those
    /// assertions describe the untyped path — the one a pre-snapshot client
    /// still exercises. Typed-path behavior has its own explicit tests.
    async fn attach_one(
        sock_path: &std::path::Path,
        display: &str,
    ) -> (
        tokio::net::unix::OwnedReadHalf,
        tokio::net::unix::OwnedWriteHalf,
        Vec<u8>,
    ) {
        attach_with_caps(sock_path, display, None, legacy_caps()).await
    }

    fn legacy_caps() -> Vec<String> {
        peer_proto::capability::supported_vec()
            .into_iter()
            .filter(|c| c != peer_proto::capability::GRID_SNAPSHOT_V1)
            .collect()
    }

    /// `attach_one`, but optionally targeting a KNOWN surface id instead of
    /// "the first listed one". A surface whose child dies instantly can drop
    /// out of ListSurfaces before the client's list lands (observed
    /// deterministically on Linux), and a respawn test doesn't care about
    /// the roster — it cares that AttachSurface revives the id it names.
    async fn attach_surface_by(
        sock_path: &std::path::Path,
        display: &str,
        want_id: Option<Vec<u8>>,
    ) -> (
        tokio::net::unix::OwnedReadHalf,
        tokio::net::unix::OwnedWriteHalf,
        Vec<u8>,
    ) {
        attach_with_caps(sock_path, display, want_id, legacy_caps()).await
    }

    /// The full-control attach: explicit surface targeting AND an explicit
    /// capability list, so a test can be an old client, a new client, or
    /// anything in between.
    async fn attach_with_caps(
        sock_path: &std::path::Path,
        display: &str,
        want_id: Option<Vec<u8>>,
        caps: Vec<String>,
    ) -> (
        tokio::net::unix::OwnedReadHalf,
        tokio::net::unix::OwnedWriteHalf,
        Vec<u8>,
    ) {
        attach_full(sock_path, display, want_id, caps, 0).await
    }

    async fn attach_full(
        sock_path: &std::path::Path,
        display: &str,
        want_id: Option<Vec<u8>>,
        caps: Vec<String>,
        resume_from_seq: u64,
    ) -> (
        tokio::net::unix::OwnedReadHalf,
        tokio::net::unix::OwnedWriteHalf,
        Vec<u8>,
    ) {
        let stream = UnixStream::connect(sock_path).await.unwrap();
        let (mut reader, mut writer) = stream.into_split();

        let mut peer_id = display.as_bytes().to_vec();
        peer_id.resize(16, 0);
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 1,
                correlation_id: 0,
                payload: Some(Payload::Hello(Hello {
                    protocol_version: PROTOCOL_VERSION.into(),
                    peer_id,
                    display_name: display.into(),
                    capabilities: caps,
                    app_version: "test".into(),
                    cli_bin_dirs: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap(); // host hello
        let _ = read_envelope(&mut reader).await.unwrap(); // challenge

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 2,
                correlation_id: 0,
                payload: Some(Payload::Auth(Auth {
                    method: "ssh-passthrough".into(),
                    token_id: vec![],
                    signature: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap(); // auth result

        let surface_id = match want_id {
            Some(id) => id,
            None => {
                write_envelope(
                    &mut writer,
                    &Envelope {
                        seq: 3,
                        correlation_id: 0,
                        payload: Some(Payload::ListSurfaces(ListSurfaces {})),
                    },
                )
                .await
                .unwrap();
                let list_reply = read_envelope(&mut reader).await.unwrap();
                let surfaces = match list_reply.payload {
                    Some(Payload::SurfaceList(sl)) => sl.surfaces,
                    other => panic!("{display}: expected SurfaceList, got {other:?}"),
                };
                assert!(
                    !surfaces.is_empty(),
                    "{display}: host listed no surfaces"
                );
                surfaces[0].surface_id.clone()
            }
        };

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 4,
                correlation_id: 0,
                payload: Some(Payload::AttachSurface(AttachSurface {
                    surface_id: surface_id.clone(),
                    mode: AttachMode::CoWrite as i32,
                    client_cols: 80,
                    client_rows: 24,
                    resume_from_seq,
                })),
            },
        )
        .await
        .unwrap();
        let attach_reply = read_envelope(&mut reader).await.unwrap();
        match attach_reply.payload {
            Some(Payload::AttachResult(r)) => {
                assert!(r.accepted, "{display}: attach rejected: {}", r.reason)
            }
            other => panic!("{display}: expected AttachResult, got {other:?}"),
        }

        (reader, writer, surface_id)
    }

    /// Read PtyData frames from `reader` into a buffer until `marker`
    /// appears (returns true) or the timeout elapses (returns false).
    async fn wait_for_marker(
        reader: &mut tokio::net::unix::OwnedReadHalf,
        marker: &[u8],
        timeout: std::time::Duration,
    ) -> bool {
        let deadline = tokio::time::Instant::now() + timeout;
        let mut aggregated = Vec::<u8>::new();
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return false;
            }
            let env = match tokio::time::timeout(remaining, read_envelope(reader)).await {
                Ok(Ok(e)) => e,
                _ => return false,
            };
            if let Some(Payload::PtyData(p)) = env.payload {
                aggregated.extend_from_slice(&p.payload);
                if aggregated.windows(marker.len()).any(|w| w == marker) {
                    return true;
                }
            }
        }
    }

    /// Two clients attach to the same surface with CO_WRITE; input from
    /// either client must fan out to both, and a detach by one client
    /// must leave the other fully operational.
    #[tokio::test]
    async fn two_clients_co_write_same_surface() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        let manager = cat_manager();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sp_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sp_task, shutdown_rx, manager)
                .await
                .unwrap();
        });

        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut r1, mut w1, surface_id) = attach_one(&sock_path, "client-one").await;
        let (mut r2, mut w2, _) = attach_one(&sock_path, "client-two").await;

        // Input from client 1 must reach both readers.
        write_envelope(
            &mut w1,
            &Envelope {
                seq: 5,
                correlation_id: 0,
                payload: Some(Payload::Input(Input {
                    surface_id: surface_id.clone(),
                    kind: Some(peer_proto::v1::input::Kind::Keys(b"MARKER-ONE\n".to_vec())),
                })),
            },
        )
        .await
        .unwrap();

        let timeout = std::time::Duration::from_secs(3);
        let seen_on_1 = wait_for_marker(&mut r1, b"MARKER-ONE", timeout).await;
        let seen_on_2 = wait_for_marker(&mut r2, b"MARKER-ONE", timeout).await;
        assert!(
            seen_on_1,
            "client 1 did not receive its own MARKER-ONE echo"
        );
        assert!(
            seen_on_2,
            "client 2 did not receive MARKER-ONE from client 1"
        );

        // Input from client 2 must reach both readers.
        write_envelope(
            &mut w2,
            &Envelope {
                seq: 5,
                correlation_id: 0,
                payload: Some(Payload::Input(Input {
                    surface_id: surface_id.clone(),
                    kind: Some(peer_proto::v1::input::Kind::Keys(b"MARKER-TWO\n".to_vec())),
                })),
            },
        )
        .await
        .unwrap();

        let seen_on_1 = wait_for_marker(&mut r1, b"MARKER-TWO", timeout).await;
        let seen_on_2 = wait_for_marker(&mut r2, b"MARKER-TWO", timeout).await;
        assert!(
            seen_on_1,
            "client 1 did not receive MARKER-TWO from client 2"
        );
        assert!(
            seen_on_2,
            "client 2 did not receive its own MARKER-TWO echo"
        );

        // Detach client 1 by dropping its stream halves. Client 2 must
        // still be able to round-trip input.
        drop(r1);
        drop(w1);
        // Give the server a moment to observe EOF on client 1's connection.
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        write_envelope(
            &mut w2,
            &Envelope {
                seq: 6,
                correlation_id: 0,
                payload: Some(Payload::Input(Input {
                    surface_id: surface_id.clone(),
                    kind: Some(peer_proto::v1::input::Kind::Keys(
                        b"MARKER-AFTER-DETACH\n".to_vec(),
                    )),
                })),
            },
        )
        .await
        .unwrap();

        let seen_after = wait_for_marker(&mut r2, b"MARKER-AFTER-DETACH", timeout).await;
        assert!(
            seen_after,
            "client 2 lost the surface after client 1 detached"
        );

        drop(r2);
        drop(w2);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// Register a respawn spec for a child that exits immediately; verify
    /// that a subsequent attach respawns the surface and PtyData flows
    /// again. This is the regression guard for the UX bug where typing
    /// `exit` in a session left the default surface permanently dead.
    #[tokio::test]
    async fn surface_respawns_after_child_exit() {
        use crate::peer::surface::SpawnSpec;

        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        let manager = Arc::new(PtyManager::new());
        let sid = surface_id_from_name("short-lived");
        // Child prints MARKER and exits immediately. Every respawn produces
        // a fresh MARKER-bearing child.
        manager.register_and_spawn(
            sid.clone(),
            SpawnSpec {
                title: "short-lived".into(),
                command: "/bin/sh".into(),
                args: vec!["-c".into(), "printf RESPAWN-MARKER".into()],
                cols: 80,
                rows: 24,
                cwd: None,
            },
        );

        // Wait for the first child to exit so the surface's `dead` flag
        // flips before we attempt our attach.
        for _ in 0..50 {
            let still_alive = manager
                .get_or_respawn(&sid)
                .map(|s| !s.dead.load(std::sync::atomic::Ordering::Acquire))
                .unwrap_or(false);
            // Break the moment we observe a live post-respawn surface OR
            // the initial one is dead and respawn hasn't happened yet.
            // (get_or_respawn itself revives it, so this tight loop can't
            // sit on a dead one for long.)
            if still_alive {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sp_task = sock_path.clone();
        let manager_for_task = manager.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sp_task, shutdown_rx, manager_for_task)
                .await
                .unwrap();
        });

        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, _writer, _surface_id) =
            attach_surface_by(&sock_path, "respawn-test", Some(sid.clone())).await;

        // After attach, the fresh (respawned) child prints RESPAWN-MARKER.
        let seen = wait_for_marker(
            &mut reader,
            b"RESPAWN-MARKER",
            std::time::Duration::from_secs(3),
        )
        .await;
        assert!(
            seen,
            "RESPAWN-MARKER did not arrive after a dead-surface attach"
        );

        drop(reader);
        drop(_writer);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// Register three independent surfaces, list them, verify each is
    /// present and attach to a specific one by name.
    #[tokio::test]
    async fn lists_and_attaches_multiple_surfaces_by_name() {
        use crate::peer::surface::SpawnSpec;

        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        let manager = Arc::new(PtyManager::new());
        for name in ["alpha", "bravo", "charlie"] {
            manager.register_and_spawn(
                surface_id_from_name(name),
                SpawnSpec {
                    title: name.into(),
                    command: "/bin/sh".into(),
                    // Each child writes a name-specific marker then sleeps.
                    args: vec![
                        "-c".into(),
                        format!(
                            "for _ in 1 2 3 4 5 6 7 8 9 10; do printf 'HELLO-{name}'; sleep 0.1; done"
                        ),
                    ],
                    cols: 80,
                    rows: 24,
                    cwd: None,
                },
            );
        }

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sp_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sp_task, shutdown_rx, manager)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        // Handshake + ListSurfaces: expect all three titles in the reply.
        let stream = UnixStream::connect(&sock_path).await.unwrap();
        let (mut reader, mut writer) = stream.into_split();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 1,
                correlation_id: 0,
                payload: Some(Payload::Hello(Hello {
                    protocol_version: PROTOCOL_VERSION.into(),
                    peer_id: vec![0; 16],
                    display_name: "list-test".into(),
                    capabilities: peer_proto::capability::supported_vec(),
                    app_version: "test".into(),
                    cli_bin_dirs: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 2,
                correlation_id: 0,
                payload: Some(Payload::Auth(Auth {
                    method: "ssh-passthrough".into(),
                    token_id: vec![],
                    signature: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 3,
                correlation_id: 0,
                payload: Some(Payload::ListSurfaces(ListSurfaces {})),
            },
        )
        .await
        .unwrap();
        let list_reply = read_envelope(&mut reader).await.unwrap();
        let titles: Vec<String> = match list_reply.payload {
            Some(Payload::SurfaceList(sl)) => sl.surfaces.into_iter().map(|s| s.title).collect(),
            other => panic!("expected SurfaceList, got {other:?}"),
        };
        assert_eq!(
            titles,
            vec!["alpha".to_string(), "bravo".into(), "charlie".into()],
            "surfaces not sorted by title or missing entries"
        );

        // Attach specifically to `bravo` by its derived id; verify the
        // bravo-specific marker appears on the stream.
        let bravo_id = surface_id_from_name("bravo");
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 4,
                correlation_id: 0,
                payload: Some(Payload::AttachSurface(AttachSurface {
                    surface_id: bravo_id.clone(),
                    mode: AttachMode::CoWrite as i32,
                    client_cols: 80,
                    client_rows: 24,
                    resume_from_seq: 0,
                })),
            },
        )
        .await
        .unwrap();
        let attach_reply = read_envelope(&mut reader).await.unwrap();
        match attach_reply.payload {
            Some(Payload::AttachResult(r)) => assert!(r.accepted, "attach rejected: {}", r.reason),
            other => panic!("expected AttachResult, got {other:?}"),
        }

        let seen = wait_for_marker(
            &mut reader,
            b"HELLO-bravo",
            std::time::Duration::from_secs(3),
        )
        .await;
        assert!(seen, "never observed bravo-specific marker");

        drop(reader);
        drop(writer);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// After a successful attach, the server pushes a `WorkspaceUpdate.meta`
    /// frame with the surface's captured cwd. `branch` is whatever git
    /// reports for that cwd (empty when not a repo). Exercises both the
    /// proto field additions on SurfaceInfo and the on-attach push path.
    #[tokio::test]
    async fn attach_pushes_workspace_meta() {
        use crate::peer::surface::SpawnSpec;
        use peer_proto::v1::{workspace_update, WorkspaceUpdate};

        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");
        // Use the tempdir as the spawn cwd; it's definitely NOT a git repo
        // so branch should come back empty — a stable assertion regardless
        // of where the test runs.
        let spawn_cwd = tmp.path().to_string_lossy().into_owned();

        let manager = Arc::new(PtyManager::new());
        let sid = surface_id_from_name("meta-test");
        manager.register_and_spawn(
            sid.clone(),
            SpawnSpec {
                title: "meta-test".into(),
                command: "/bin/sh".into(),
                args: vec![
                    "-c".into(),
                    "for _ in 1 2 3 4 5 6 7 8 9 10; do printf '.'; sleep 0.1; done".into(),
                ],
                cols: 80,
                rows: 24,
                cwd: Some(spawn_cwd.clone()),
            },
        );

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sp_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sp_task, shutdown_rx, manager)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, writer, surface_id) = attach_one(&sock_path, "meta-client").await;
        assert_eq!(surface_id, sid);

        // The next envelope after AttachResult should be the pushed
        // WorkspaceUpdate.meta. It may be followed by PtyData frames,
        // so we scan for up to 3 envelopes or a short timeout.
        let mut meta_seen: Option<(String, String)> = None;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(3);
        for _ in 0..6 {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            let env = match tokio::time::timeout(remaining, read_envelope(&mut reader)).await {
                Ok(Ok(e)) => e,
                _ => break,
            };
            if let Some(Payload::WorkspaceUpdate(WorkspaceUpdate {
                kind: Some(workspace_update::Kind::Meta(m)),
            })) = env.payload
            {
                meta_seen = Some((m.cwd, m.branch));
                break;
            }
        }
        let (cwd, branch) =
            meta_seen.expect("WorkspaceUpdate.meta never arrived after AttachResult");
        // Resolve both sides rather than comparing strings: the host reads
        // the directory from the OS, which hands back the real path, while
        // the spec recorded whatever it was given — and on macOS a temp dir
        // is handed out as /var/... but resolves to /private/var/... .
        let reported = std::fs::canonicalize(&cwd).expect("reported cwd exists");
        let expected = std::fs::canonicalize(&spawn_cwd).expect("spawn cwd exists");
        assert_eq!(
            reported, expected,
            "meta cwd did not match the registered SpawnSpec cwd"
        );
        assert_eq!(
            branch, "",
            "expected empty branch for non-repo cwd, got {branch:?}"
        );

        drop(reader);
        drop(writer);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    #[tokio::test]
    async fn rejects_unknown_surface() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        let manager = cat_manager();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager)
                .await
                .unwrap();
        });

        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let stream = UnixStream::connect(&sock_path).await.unwrap();
        let (mut reader, mut writer) = stream.into_split();

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 1,
                correlation_id: 0,
                payload: Some(Payload::Hello(Hello {
                    protocol_version: PROTOCOL_VERSION.into(),
                    peer_id: vec![0x22; 16],
                    display_name: "integration-test".into(),
                    capabilities: peer_proto::capability::supported_vec(),
                    app_version: "test".into(),
                    cli_bin_dirs: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 2,
                correlation_id: 0,
                payload: Some(Payload::Auth(Auth {
                    method: "ssh-passthrough".into(),
                    token_id: vec![],
                    signature: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 3,
                correlation_id: 0,
                payload: Some(Payload::AttachSurface(AttachSurface {
                    surface_id: vec![0xFF; 16],
                    mode: AttachMode::ReadOnly as i32,
                    client_cols: 80,
                    client_rows: 24,
                    resume_from_seq: 0,
                })),
            },
        )
        .await
        .unwrap();

        let result = read_envelope(&mut reader).await.unwrap();
        match result.payload {
            Some(Payload::AttachResult(r)) => {
                assert!(!r.accepted);
                assert!(r.reason.contains("not found"));
            }
            other => panic!("expected AttachResult, got {other:?}"),
        }

        drop(reader);
        drop(writer);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// Connects, sends a Hello with the given `capabilities`, drives the
    /// rest of the handshake (Auth), and reports whether it was accepted.
    /// Used by the adversarial-capabilities test below to check several
    /// payloads against the same running server without repeating the
    /// connect/Hello/Auth boilerplate each time.
    async fn handshake_with_capabilities(
        sock_path: &std::path::Path,
        capabilities: Vec<String>,
    ) -> bool {
        let stream = UnixStream::connect(sock_path).await.unwrap();
        let (mut reader, mut writer) = stream.into_split();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 1,
                correlation_id: 0,
                payload: Some(Payload::Hello(Hello {
                    protocol_version: PROTOCOL_VERSION.into(),
                    peer_id: vec![0x55; 16],
                    display_name: "adversarial-capabilities-test".into(),
                    capabilities,
                    app_version: "test".into(),
                    cli_bin_dirs: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap(); // host hello
        let _ = read_envelope(&mut reader).await.unwrap(); // auth challenge

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 2,
                correlation_id: 0,
                payload: Some(Payload::Auth(Auth {
                    method: "ssh-passthrough".into(),
                    token_id: vec![],
                    signature: vec![],
                })),
            },
        )
        .await
        .unwrap();

        let result = read_envelope(&mut reader).await.unwrap();
        matches!(result.payload, Some(Payload::AuthResult(r)) if r.accepted)
    }

    /// P3 capability plumbing: a client's `Hello.capabilities` is
    /// attacker/bug-controlled input arriving straight off the wire, so
    /// the handshake must complete normally no matter what's in it --
    /// empty (today's/legacy behavior, must be unchanged), full of
    /// capability strings this build has never heard of (forward-compat),
    /// or an absurdly long list (a buggy or hostile peer). None of these
    /// should reject, slow, or crash the handshake. This exercises the
    /// real `connection::run` path end to end (not just `PeerCapabilities`
    /// in isolation, which `peer-proto`'s own unit tests already cover) --
    /// the field arrives over the wire before any validation could reject
    /// it structurally.
    #[tokio::test]
    async fn handshake_survives_adversarial_client_capabilities() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        let manager = Arc::new(PtyManager::new());
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        // Empty: today's/legacy fallback -- must behave exactly as before P3.
        assert!(
            handshake_with_capabilities(&sock_path, vec![]).await,
            "handshake with empty capabilities (legacy peer) should still succeed"
        );

        // Unknown + duplicate + empty-string entries: forward-compat, never rejected.
        assert!(
            handshake_with_capabilities(
                &sock_path,
                vec![
                    "totally.unknown.v1".into(),
                    "totally.unknown.v1".into(),
                    "".into(),
                ]
            )
            .await,
            "handshake with unknown/duplicate capability strings should still succeed"
        );

        // Thousands of entries: must not slow down, hang, or crash the handshake.
        let many: Vec<String> = (0..5000).map(|i| format!("cap.{i}.v1")).collect();
        assert!(
            handshake_with_capabilities(&sock_path, many).await,
            "handshake with a very large capabilities list should still succeed"
        );

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// Attach-time mode replay (peer-headless-mode-replay): when the PTY
    /// already has mouse-tracking DECSET modes active before a client ever
    /// attaches, `spawn_attach_relay` (connection.rs) must inject those
    /// DECSET bytes as the very first PtyData frame, ahead of the replay
    /// snapshot. Otherwise a viewer that attaches late never sees the
    /// enabling escape and mouse/scroll routing silently breaks. Modes are
    /// observed by `QueryFilter` in the PTY reader loop and mirrored into
    /// `PtySurface::modes` (surface.rs); `mode_replay_bytes()` serializes
    /// them back out in ascending order for the prefix frame.
    #[tokio::test]
    async fn attach_replays_active_mode_prefix_before_snapshot() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        const MARKER: &[u8] = b"MODEMARKER-preattach";
        // 1002 = button-event mouse tracking, 1006 = SGR extended
        // coordinates -- both are in QueryFilter's tracked-mode set, and
        // BTreeSet iteration order in mode_replay_bytes() matches the
        // ascending order the child sets them in here.
        const MODE_PREFIX: &[u8] = b"\x1b[?1002h\x1b[?1006h";

        let manager = Arc::new(PtyManager::new());
        let surface = PtySurface::spawn(
            surface_id_from_name("mode-preattach"),
            "mode-preattach".into(),
            "/bin/sh",
            &[
                "-c",
                "printf '\\033[?1002h\\033[?1006h'; printf 'MODEMARKER-preattach'; sleep 5",
            ],
            80,
            24,
            None,
        )
        .expect("spawn mode-preattach surface");

        // Poll until both the DECSET pair has been observed by QueryFilter
        // (mode_replay_bytes non-empty) AND the marker has landed in the
        // replay snapshot. These two printf calls usually land in the same
        // read() as one chunk, but nothing guarantees that, so poll for
        // both independently rather than assuming a single-chunk race.
        for _ in 0..100 {
            let modes_ready = !surface.mode_replay_bytes().is_empty();
            let marker_ready = surface
                .replay_snapshot()
                .iter()
                .flat_map(|chunk| chunk.bytes.iter().copied())
                .collect::<Vec<_>>()
                .windows(MARKER.len())
                .any(|w| w == MARKER);
            if modes_ready && marker_ready {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(
            !surface.mode_replay_bytes().is_empty(),
            "mode was never observed by QueryFilter before insert"
        );
        manager.insert_surface(surface);

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sp_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sp_task, shutdown_rx, manager)
                .await
                .unwrap();
        });

        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, writer, _surface_id) = attach_one(&sock_path, "mode-replay-test").await;

        // Collect every PtyData frame after attach (ignoring the
        // WorkspaceUpdate.meta push that precedes them), tracking each
        // frame's byte_seq, until the marker shows up in the concatenated
        // payload bytes.
        let mut frames: Vec<(u64, Vec<u8>)> = Vec::new();
        let mut aggregated = Vec::<u8>::new();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            let env = match tokio::time::timeout(remaining, read_envelope(&mut reader)).await {
                Ok(Ok(e)) => e,
                _ => break,
            };
            if let Some(Payload::PtyData(p)) = env.payload {
                aggregated.extend_from_slice(&p.payload);
                frames.push((p.byte_seq, p.payload));
                if aggregated.windows(MARKER.len()).any(|w| w == MARKER) {
                    break;
                }
            }
        }
        assert!(
            aggregated.windows(MARKER.len()).any(|w| w == MARKER),
            "marker never arrived after attach; saw {} PtyData frame(s)",
            frames.len()
        );

        // The mode prefix must precede the marker in what the client
        // actually received. We check first-occurrence index rather than
        // "is it the first frame's content" because the snapshot chunk
        // itself still carries the *original*, unstripped DECSET bytes the
        // child wrote (QueryFilter only strips terminal queries, not mode
        // toggles) -- so the prefix can legitimately appear a second time
        // inside the snapshot. Since the injected prefix frame is always
        // enqueued before the snapshot chunks, the first occurrence must be
        // the injected one.
        let prefix_idx = aggregated
            .windows(MODE_PREFIX.len())
            .position(|w| w == MODE_PREFIX)
            .expect("mode prefix bytes never appeared in attach stream");
        let marker_idx = aggregated
            .windows(MARKER.len())
            .position(|w| w == MARKER)
            .expect("marker bytes never appeared in attach stream");
        assert!(
            prefix_idx < marker_idx,
            "mode prefix (idx {prefix_idx}) did not precede marker (idx {marker_idx})"
        );

        // byte_seq continuity: the first PtyData frame on attach starts at
        // 0 (spawn_attach_relay's attach_seq), and each subsequent frame's
        // byte_seq matches the accumulated payload length so far.
        assert_eq!(
            frames.first().map(|(seq, _)| *seq),
            Some(0),
            "first PtyData frame on attach must start at byte_seq 0"
        );
        let mut running = 0u64;
        for (seq, payload) in &frames {
            assert_eq!(
                *seq, running,
                "byte_seq gap/overlap detected in attach frame sequence"
            );
            running += payload.len() as u64;
        }

        drop(reader);
        drop(writer);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// Companion to `attach_replays_active_mode_prefix_before_snapshot`: a
    /// surface whose child never toggles a tracked mouse mode must NOT get
    /// an injected mode-prefix frame at all -- the first PtyData frame on
    /// attach is just the ordinary snapshot/live output, with no leading
    /// `ESC[?` bytes.
    #[tokio::test]
    async fn attach_omits_mode_prefix_for_plain_shell() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        const MARKER: &[u8] = b"PLAINMARKER-nomodes";

        let manager = Arc::new(PtyManager::new());
        let surface = PtySurface::spawn(
            surface_id_from_name("plain-shell"),
            "plain-shell".into(),
            "/bin/sh",
            &["-c", "printf 'PLAINMARKER-nomodes'; sleep 5"],
            80,
            24,
            None,
        )
        .expect("spawn plain-shell surface");

        for _ in 0..50 {
            let replay_ready = surface
                .replay_snapshot()
                .iter()
                .flat_map(|chunk| chunk.bytes.iter().copied())
                .collect::<Vec<_>>()
                .windows(MARKER.len())
                .any(|w| w == MARKER);
            if replay_ready {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(
            surface.mode_replay_bytes().is_empty(),
            "plain shell must not have any tracked mode active before attach"
        );
        manager.insert_surface(surface);

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sp_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sp_task, shutdown_rx, manager)
                .await
                .unwrap();
        });

        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, writer, _surface_id) = attach_one(&sock_path, "plain-shell-test").await;

        // Capture the first PtyData frame's payload and keep draining until
        // the marker arrives, mirroring `wait_for_marker`'s loop but also
        // retaining the first frame for the no-prefix assertion below.
        let mut first_pty_payload: Option<Vec<u8>> = None;
        let mut aggregated = Vec::<u8>::new();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            let env = match tokio::time::timeout(remaining, read_envelope(&mut reader)).await {
                Ok(Ok(e)) => e,
                _ => break,
            };
            if let Some(Payload::PtyData(p)) = env.payload {
                if first_pty_payload.is_none() {
                    first_pty_payload = Some(p.payload.clone());
                }
                aggregated.extend_from_slice(&p.payload);
                if aggregated.windows(MARKER.len()).any(|w| w == MARKER) {
                    break;
                }
            }
        }
        assert!(
            aggregated.windows(MARKER.len()).any(|w| w == MARKER),
            "marker never arrived after attach"
        );

        let _ = first_pty_payload.expect("no PtyData frame arrived after attach");
        // The grid snapshot legitimately opens with input-mode state
        // (cursor visibility, keypad, bracketed paste — vt100's
        // input_mode_formatted), so "starts with ESC[?" no longer means a
        // mode prefix. What must still never appear on a surface with no
        // active tracked mode is a mouse-tracking DECSET — the only thing
        // `mode_replay_bytes` exists to replay.
        for mode in [1000u16, 1002, 1003, 1005, 1006, 1015, 1016] {
            let seq = format!("\x1b[?{mode}h");
            assert!(
                !aggregated
                    .windows(seq.as_bytes().len())
                    .any(|w| w == seq.as_bytes()),
                "unexpected mouse-mode enable {seq:?} on a surface with no active mode"
            );
        }

        drop(reader);
        drop(writer);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    // ---- WorkspaceControl (layout mutation + broadcast) ----

    use peer_proto::v1::workspace_control;
    use peer_proto::v1::{
        ActivateTabRequest, ClosePaneRequest, ListWorkspaces, SplitPaneRequest, WorkspaceControl,
    };
    use tokio::net::unix::{OwnedReadHalf as TestReadHalf, OwnedWriteHalf as TestWriteHalf};

    async fn handshake(sock_path: &std::path::Path) -> (TestReadHalf, TestWriteHalf) {
        let stream = UnixStream::connect(sock_path).await.unwrap();
        let (mut reader, mut writer) = stream.into_split();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 1,
                correlation_id: 0,
                payload: Some(Payload::Hello(Hello {
                    protocol_version: PROTOCOL_VERSION.into(),
                    peer_id: vec![0x22; 16],
                    display_name: "wc-test".into(),
                    capabilities: peer_proto::capability::supported_vec(),
                    app_version: "test".into(),
                    cli_bin_dirs: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 2,
                correlation_id: 0,
                payload: Some(Payload::Auth(Auth {
                    method: "ssh-passthrough".into(),
                    token_id: vec![],
                    signature: vec![],
                })),
            },
        )
        .await
        .unwrap();
        let _ = read_envelope(&mut reader).await.unwrap();
        (reader, writer)
    }

    /// First pane's surface id from a fresh ListWorkspaces round trip.
    async fn first_pane_id(reader: &mut TestReadHalf, writer: &mut TestWriteHalf) -> Vec<u8> {
        write_envelope(
            writer,
            &Envelope {
                seq: 3,
                correlation_id: 0,
                payload: Some(Payload::ListWorkspaces(ListWorkspaces {})),
            },
        )
        .await
        .unwrap();
        loop {
            let env = read_envelope(reader).await.unwrap();
            if let Some(Payload::WorkspaceList(wl)) = env.payload {
                let layout = wl.workspaces[0].layout.clone().expect("layout present");
                return leftmost_pane(&layout);
            }
        }
    }

    fn leftmost_pane(layout: &peer_proto::v1::WorkspaceLayout) -> Vec<u8> {
        match layout.node.as_ref().unwrap() {
            peer_proto::v1::workspace_layout::Node::Pane(p) => p.surface_id.clone(),
            peer_proto::v1::workspace_layout::Node::Split(s) => {
                leftmost_pane(s.first.as_ref().unwrap())
            }
        }
    }

    fn count_panes(layout: &peer_proto::v1::WorkspaceLayout) -> usize {
        match layout.node.as_ref().unwrap() {
            peer_proto::v1::workspace_layout::Node::Pane(_) => 1,
            peer_proto::v1::workspace_layout::Node::Split(s) => {
                count_panes(s.first.as_ref().unwrap()) + count_panes(s.second.as_ref().unwrap())
            }
        }
    }

    /// Wait for the next layout push, skipping unrelated frames. `None`
    /// on timeout — which some tests treat as the expected outcome.
    async fn next_layout_push(
        reader: &mut TestReadHalf,
        window: std::time::Duration,
    ) -> Option<peer_proto::v1::WorkspaceLayout> {
        let deadline = tokio::time::Instant::now() + window;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return None;
            }
            match tokio::time::timeout(remaining, read_envelope(reader)).await {
                Err(_) | Ok(Err(_)) => return None,
                Ok(Ok(env)) => {
                    if let Some(Payload::WorkspaceUpdate(wu)) = env.payload {
                        if let Some(peer_proto::v1::workspace_update::Kind::WorkspaceLayout(wlc)) =
                            wu.kind
                        {
                            return wlc.layout;
                        }
                    }
                }
            }
        }
    }

    fn control(seq: u64, kind: workspace_control::Kind) -> Envelope {
        Envelope {
            seq,
            correlation_id: 0,
            payload: Some(Payload::WorkspaceControl(WorkspaceControl {
                kind: Some(kind),
            })),
        }
    }

    const PUSH_WINDOW: std::time::Duration = std::time::Duration::from_secs(3);

    /// One client splits; the mutation lands in the tree and the layout
    /// push reaches BOTH connections — the requester and a bystander.
    #[tokio::test]
    async fn workspace_control_split_pushes_to_all_clients() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");
        let manager = cat_manager();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut r1, mut w1) = handshake(&sock_path).await;
        let (mut r2, _w2) = handshake(&sock_path).await;

        let pane = first_pane_id(&mut r1, &mut w1).await;
        write_envelope(
            &mut w1,
            &control(
                4,
                workspace_control::Kind::SplitPane(SplitPaneRequest {
                    pane_id: pane.clone(),
                    orientation: "horizontal".into(),
                }),
            ),
        )
        .await
        .unwrap();

        let l1 = next_layout_push(&mut r1, PUSH_WINDOW)
            .await
            .expect("requester got push");
        let l2 = next_layout_push(&mut r2, PUSH_WINDOW)
            .await
            .expect("bystander got push");
        assert_eq!(count_panes(&l1), 2);
        assert_eq!(count_panes(&l2), 2);
        // The original pane survived with its identity intact.
        assert_eq!(leftmost_pane(&l1), pane);

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// Requests that change nothing must not fan a push out: activating
    /// the already-active tab, closing the last pane (refused), and a
    /// garbage orientation are all silent no-ops.
    #[tokio::test]
    async fn workspace_control_noop_requests_do_not_push() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");
        let manager = cat_manager();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, mut writer) = handshake(&sock_path).await;
        let pane = first_pane_id(&mut reader, &mut writer).await;

        // Re-activating the active tab.
        write_envelope(
            &mut writer,
            &control(
                4,
                workspace_control::Kind::ActivateTab(ActivateTabRequest {
                    pane_id: pane.clone(),
                    surface_id: pane.clone(),
                }),
            ),
        )
        .await
        .unwrap();
        // Closing the sole pane (refused).
        write_envelope(
            &mut writer,
            &control(
                5,
                workspace_control::Kind::ClosePane(ClosePaneRequest {
                    pane_id: pane.clone(),
                }),
            ),
        )
        .await
        .unwrap();
        // Garbage orientation (F4).
        write_envelope(
            &mut writer,
            &control(
                6,
                workspace_control::Kind::SplitPane(SplitPaneRequest {
                    pane_id: pane.clone(),
                    orientation: "diagonal".into(),
                }),
            ),
        )
        .await
        .unwrap();

        // Well past the 120ms debounce: nothing may arrive.
        let push = next_layout_push(&mut reader, std::time::Duration::from_millis(600)).await;
        assert!(
            push.is_none(),
            "no-op control leaked a layout push: {push:?}"
        );

        // The tree is intact: the pane is still there and closable-checks
        // did not corrupt anything.
        let still = first_pane_id(&mut reader, &mut writer).await;
        assert_eq!(still, pane);

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// Two clients mutate concurrently; the layout Mutex serializes them
    /// and the debounced push carries a tree containing both splits.
    #[tokio::test]
    async fn workspace_control_concurrent_splits_serialize() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");
        let manager = cat_manager();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut r1, mut w1) = handshake(&sock_path).await;
        let (mut r2, mut w2) = handshake(&sock_path).await;
        let pane = first_pane_id(&mut r1, &mut w1).await;

        // Both clients split the same pane at once.
        let split = |pane_id: Vec<u8>, orientation: &str| {
            control(
                7,
                workspace_control::Kind::SplitPane(SplitPaneRequest {
                    pane_id,
                    orientation: orientation.into(),
                }),
            )
        };
        let env_h = split(pane.clone(), "horizontal");
        let env_v = split(pane.clone(), "vertical");
        let (a, b) = tokio::join!(
            write_envelope(&mut w1, &env_h),
            write_envelope(&mut w2, &env_v),
        );
        a.unwrap();
        b.unwrap();

        // Eventually a push whose tree holds all 3 panes reaches both
        // clients (the debounce may fold the two mutations into one push).
        let deadline = tokio::time::Instant::now() + PUSH_WINDOW;
        let mut latest = None;
        while tokio::time::Instant::now() < deadline {
            match next_layout_push(&mut r1, std::time::Duration::from_millis(500)).await {
                Some(l) => {
                    let done = count_panes(&l) == 3;
                    latest = Some(l);
                    if done {
                        break;
                    }
                }
                None => break,
            }
        }
        let l1 = latest.expect("client 1 got a push");
        assert_eq!(count_panes(&l1), 3, "both splits landed");
        let l2 = next_layout_push(&mut r2, PUSH_WINDOW)
            .await
            .expect("client 2 got a push");
        assert_eq!(count_panes(&l2), 3);

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// F2 regression: closing an ephemeral (split-spawned) pane must be
    /// permanent for this daemon lifetime — a raw AttachSurface for the
    /// same id, bypassing WorkspaceControl entirely, must not resurrect
    /// it. Before the fix, remove() left the respawn spec in place and
    /// get_or_respawn happily revived it.
    #[tokio::test]
    async fn closed_ephemeral_pane_does_not_respawn_via_direct_attach() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");
        let manager = cat_manager();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, mut writer) = handshake(&sock_path).await;
        let base_pane = first_pane_id(&mut reader, &mut writer).await;

        write_envelope(
            &mut writer,
            &control(
                4,
                workspace_control::Kind::SplitPane(SplitPaneRequest {
                    pane_id: base_pane.clone(),
                    orientation: "horizontal".into(),
                }),
            ),
        )
        .await
        .unwrap();
        let layout = next_layout_push(&mut reader, PUSH_WINDOW)
            .await
            .expect("split pushed");
        assert_eq!(count_panes(&layout), 2);
        // The ephemeral pane is whichever leaf isn't the original base pane.
        let ephemeral_id = other_pane(&layout, &base_pane);

        write_envelope(
            &mut writer,
            &control(
                5,
                workspace_control::Kind::ClosePane(ClosePaneRequest {
                    pane_id: ephemeral_id.clone(),
                }),
            ),
        )
        .await
        .unwrap();
        let after_close = next_layout_push(&mut reader, PUSH_WINDOW)
            .await
            .expect("close pushed");
        assert_eq!(
            count_panes(&after_close),
            1,
            "ephemeral pane removed from the tree"
        );

        // Directly attach the closed id, bypassing WorkspaceControl.
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 6,
                correlation_id: 0,
                payload: Some(Payload::AttachSurface(AttachSurface {
                    surface_id: ephemeral_id,
                    mode: AttachMode::CoWrite as i32,
                    client_cols: 80,
                    client_rows: 24,
                    resume_from_seq: 0,
                })),
            },
        )
        .await
        .unwrap();
        let attach_reply = read_envelope(&mut reader).await.unwrap();
        match attach_reply.payload {
            Some(Payload::AttachResult(r)) => {
                assert!(
                    !r.accepted,
                    "closed ephemeral surface must not respawn via direct attach"
                )
            }
            other => panic!("expected AttachResult, got {other:?}"),
        }

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    fn other_pane(layout: &peer_proto::v1::WorkspaceLayout, known: &[u8]) -> Vec<u8> {
        match layout.node.as_ref().unwrap() {
            peer_proto::v1::workspace_layout::Node::Pane(p) => p.surface_id.clone(),
            peer_proto::v1::workspace_layout::Node::Split(s) => {
                let first = other_pane(s.first.as_ref().unwrap(), known);
                if first != known {
                    first
                } else {
                    other_pane(s.second.as_ref().unwrap(), known)
                }
            }
        }
    }

    // ---- M2 workspace-lifecycle wire (handlers now live in this build) ----

    /// M2 handler-arrival regression: `CreateWorkspaceRequest` used to fall
    /// through the Ready-state catch-all because connection.rs had no
    /// handler arm for it yet (see this test's pre-M2 history: it used to
    /// assert the OPPOSITE — that the payload was silently ignored). Now
    /// that the handler is wired up, the daemon must answer with an
    /// accepted `CreateWorkspaceResponse` carrying a fresh workspace_id,
    /// and the connection must stay perfectly healthy afterward — proven
    /// by a normal Ping/Pong round trip immediately following it.
    #[tokio::test]
    async fn create_workspace_request_is_now_handled_and_connection_stays_healthy() {
        use peer_proto::v1::{CreateWorkspaceRequest, CreateWorkspaceResponse, Ping, Pong};

        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");
        let manager = Arc::new(PtyManager::new());
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, mut writer) = handshake(&sock_path).await;

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 3,
                correlation_id: 0,
                payload: Some(Payload::CreateWorkspaceRequest(CreateWorkspaceRequest {
                    title: "handled-probe".into(),
                })),
            },
        )
        .await
        .unwrap();
        let create_reply = read_envelope(&mut reader).await.unwrap();
        match create_reply.payload {
            Some(Payload::CreateWorkspaceResponse(CreateWorkspaceResponse {
                accepted,
                workspace_id,
                ..
            })) => {
                assert!(accepted, "CreateWorkspaceRequest must now be accepted");
                assert!(
                    !workspace_id.is_empty(),
                    "a real workspace_id must be assigned"
                );
            }
            other => panic!("expected CreateWorkspaceResponse, got {other:?}"),
        }

        // The connection must stay healthy: a subsequent Ping still gets a
        // Pong right after.
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 4,
                correlation_id: 0,
                payload: Some(Payload::Ping(Ping { nonce: 424242 })),
            },
        )
        .await
        .unwrap();

        let reply = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            read_envelope(&mut reader),
        )
        .await
        .expect("connection died / timed out after CreateWorkspaceRequest")
        .expect("read_envelope failed after CreateWorkspaceRequest");
        match reply.payload {
            Some(Payload::Pong(Pong { nonce })) => assert_eq!(nonce, 424242),
            other => panic!("expected Pong after CreateWorkspaceRequest, got {other:?}"),
        }

        drop(reader);
        drop(writer);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// Like `next_layout_push`, but also returns the workspace_id the push
    /// was stamped with, and skips a transient empty-layout push (e.g. the
    /// one `CreateWorkspaceRequest` itself schedules for a still pane-less
    /// workspace) so callers reliably observe the push that actually
    /// carries the pane/tree change they triggered.
    async fn next_scoped_layout_push(
        reader: &mut TestReadHalf,
        window: std::time::Duration,
    ) -> Option<(Vec<u8>, peer_proto::v1::WorkspaceLayout)> {
        let deadline = tokio::time::Instant::now() + window;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return None;
            }
            match tokio::time::timeout(remaining, read_envelope(reader)).await {
                Err(_) | Ok(Err(_)) => return None,
                Ok(Ok(env)) => {
                    if let Some(Payload::WorkspaceUpdate(wu)) = env.payload {
                        if let Some(peer_proto::v1::workspace_update::Kind::WorkspaceLayout(wlc)) =
                            wu.kind
                        {
                            if let Some(layout) = wlc.layout {
                                return Some((wlc.workspace_id, layout));
                            }
                        }
                    }
                }
            }
        }
    }

    /// Waits for a `WorkspaceUpdate.workspace_removed` push, returning the
    /// removed workspace_id. `None` on timeout.
    async fn next_workspace_removed(
        reader: &mut TestReadHalf,
        window: std::time::Duration,
    ) -> Option<Vec<u8>> {
        let deadline = tokio::time::Instant::now() + window;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return None;
            }
            match tokio::time::timeout(remaining, read_envelope(reader)).await {
                Err(_) | Ok(Err(_)) => return None,
                Ok(Ok(env)) => {
                    if let Some(Payload::WorkspaceUpdate(wu)) = env.payload {
                        if let Some(peer_proto::v1::workspace_update::Kind::WorkspaceRemoved(wr)) =
                            wu.kind
                        {
                            return Some(wr.workspace_id);
                        }
                    }
                }
            }
        }
    }

    /// (a) `CreateWorkspaceRequest` returns a fresh, non-empty workspace_id,
    /// and a subsequent `ListWorkspaces` reflects the daemon's full
    /// N-workspace roster (default + the new one), each with the title it
    /// was created/booted with.
    #[tokio::test]
    async fn create_workspace_adds_to_roster() {
        use peer_proto::v1::{CreateWorkspaceRequest, CreateWorkspaceResponse};

        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");
        let manager = cat_manager();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, mut writer) = handshake(&sock_path).await;

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 3,
                correlation_id: 0,
                payload: Some(Payload::CreateWorkspaceRequest(CreateWorkspaceRequest {
                    title: "dev".into(),
                })),
            },
        )
        .await
        .unwrap();
        let new_id = match read_envelope(&mut reader).await.unwrap().payload {
            Some(Payload::CreateWorkspaceResponse(CreateWorkspaceResponse {
                accepted,
                workspace_id,
                ..
            })) => {
                assert!(accepted);
                assert!(!workspace_id.is_empty());
                workspace_id
            }
            other => panic!("expected CreateWorkspaceResponse, got {other:?}"),
        };

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 4,
                correlation_id: 0,
                payload: Some(Payload::ListWorkspaces(ListWorkspaces {})),
            },
        )
        .await
        .unwrap();
        let workspaces = match read_envelope(&mut reader).await.unwrap().payload {
            Some(Payload::WorkspaceList(wl)) => wl.workspaces,
            other => panic!("expected WorkspaceList, got {other:?}"),
        };
        assert_eq!(workspaces.len(), 2, "default + newly created workspace");
        let created = workspaces
            .iter()
            .find(|w| w.workspace_id == new_id)
            .expect("new workspace present in roster");
        assert_eq!(created.title, "dev");
        assert!(
            created.layout.is_some(),
            "a created workspace is seeded with its first pane"
        );

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// (b) Mutating a NON-default workspace's tree scopes the resulting
    /// `WorkspaceLayoutChanged` push to THAT workspace's id, never always
    /// the default (`schedule_layout_push`'s per-workspace stamping),
    /// exercised end to end: seed a brand-new workspace's first pane via
    /// `NewTabRequest.workspace_id`, then split that pane, and confirm
    /// both resulting pushes carry the new workspace's id.
    #[tokio::test]
    async fn workspace_control_push_is_scoped_to_target_workspace() {
        use peer_proto::v1::{CreateWorkspaceRequest, CreateWorkspaceResponse, NewTabRequest};

        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");
        let manager = cat_manager();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, mut writer) = handshake(&sock_path).await;

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 3,
                correlation_id: 0,
                payload: Some(Payload::CreateWorkspaceRequest(CreateWorkspaceRequest {
                    title: "second".into(),
                })),
            },
        )
        .await
        .unwrap();
        let ws2 = match read_envelope(&mut reader).await.unwrap().payload {
            Some(Payload::CreateWorkspaceResponse(CreateWorkspaceResponse {
                workspace_id,
                ..
            })) => workspace_id,
            other => panic!("expected CreateWorkspaceResponse, got {other:?}"),
        };

        // Seed ws2's first pane via NewTabRequest.workspace_id (pane_id is
        // empty/unresolvable since ws2 has no panes yet).
        write_envelope(
            &mut writer,
            &control(
                4,
                workspace_control::Kind::NewTab(NewTabRequest {
                    pane_id: vec![],
                    workspace_id: ws2.clone(),
                }),
            ),
        )
        .await
        .unwrap();
        let (push_ws, layout) = next_scoped_layout_push(&mut reader, PUSH_WINDOW)
            .await
            .expect("seed pane push");
        assert_eq!(
            push_ws, ws2,
            "seed-pane push must be stamped with ws2's id, not the default"
        );
        let seeded_pane = leftmost_pane(&layout);

        // Now split that pane; the resulting push must ALSO carry ws2's id.
        write_envelope(
            &mut writer,
            &control(
                5,
                workspace_control::Kind::SplitPane(SplitPaneRequest {
                    pane_id: seeded_pane,
                    orientation: "horizontal".into(),
                }),
            ),
        )
        .await
        .unwrap();
        let (push_ws2, layout2) = next_scoped_layout_push(&mut reader, PUSH_WINDOW)
            .await
            .expect("split push");
        assert_eq!(
            push_ws2, ws2,
            "split push must also be stamped with ws2's id"
        );
        assert_eq!(count_panes(&layout2), 2);

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// (c) `DeleteWorkspaceRequest` tears down every surface the target
    /// workspace's tree held, broadcasts `WorkspaceRemoved`, and drops the
    /// workspace from a subsequent `ListWorkspaces` roster.
    #[tokio::test]
    async fn delete_workspace_tears_down_surfaces_and_broadcasts_removal() {
        use peer_proto::v1::{
            CreateWorkspaceRequest, CreateWorkspaceResponse, DeleteWorkspaceRequest, NewTabRequest,
        };

        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");
        let manager = cat_manager();
        let manager_check = manager.clone();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, mut writer) = handshake(&sock_path).await;

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 3,
                correlation_id: 0,
                payload: Some(Payload::CreateWorkspaceRequest(CreateWorkspaceRequest {
                    title: "scratch".into(),
                })),
            },
        )
        .await
        .unwrap();
        let ws2 = match read_envelope(&mut reader).await.unwrap().payload {
            Some(Payload::CreateWorkspaceResponse(CreateWorkspaceResponse {
                workspace_id,
                ..
            })) => workspace_id,
            other => panic!("expected CreateWorkspaceResponse, got {other:?}"),
        };

        write_envelope(
            &mut writer,
            &control(
                4,
                workspace_control::Kind::NewTab(NewTabRequest {
                    pane_id: vec![],
                    workspace_id: ws2.clone(),
                }),
            ),
        )
        .await
        .unwrap();
        let (_, layout) = next_scoped_layout_push(&mut reader, PUSH_WINDOW)
            .await
            .expect("seed pane push");
        let seeded_pane = leftmost_pane(&layout);

        assert!(
            manager_check
                .list()
                .iter()
                .any(|s| s.surface_id == seeded_pane),
            "seeded pane must be a real, registered PTY before delete"
        );

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 5,
                correlation_id: 0,
                payload: Some(Payload::DeleteWorkspaceRequest(DeleteWorkspaceRequest {
                    workspace_id: ws2.clone(),
                })),
            },
        )
        .await
        .unwrap();

        let removed = next_workspace_removed(&mut reader, PUSH_WINDOW)
            .await
            .expect("WorkspaceRemoved push");
        assert_eq!(removed, ws2);

        assert!(
            !manager_check
                .list()
                .iter()
                .any(|s| s.surface_id == seeded_pane),
            "deleted workspace's pane must be torn down from the PTY manager"
        );

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 6,
                correlation_id: 0,
                payload: Some(Payload::ListWorkspaces(ListWorkspaces {})),
            },
        )
        .await
        .unwrap();
        let workspaces = match read_envelope(&mut reader).await.unwrap().payload {
            Some(Payload::WorkspaceList(wl)) => wl.workspaces,
            other => panic!("expected WorkspaceList, got {other:?}"),
        };
        assert_eq!(workspaces.len(), 1, "only the default workspace remains");

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// (d) M3: deleting the ONLY workspace left must be refused — even
    /// though it happens to be the default (a fresh boot has exactly one
    /// workspace, so this is unavoidably the `LastWorkspace` case, not a
    /// default-specific refusal; deleting the default when another
    /// workspace exists is now allowed, see `layout::tests::
    /// remove_default_workspace_promotes_survivor_and_tears_down_old_default_surfaces`).
    /// No `WorkspaceRemoved` push, no roster change, and the connection
    /// stays healthy (proven by a Ping/Pong round trip right after).
    #[tokio::test]
    async fn delete_last_workspace_is_refused() {
        use peer_proto::v1::{DeleteWorkspaceRequest, Ping, Pong};

        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");
        let manager = cat_manager();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, mut writer) = handshake(&sock_path).await;
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 3,
                correlation_id: 0,
                payload: Some(Payload::ListWorkspaces(ListWorkspaces {})),
            },
        )
        .await
        .unwrap();
        let default_id = match read_envelope(&mut reader).await.unwrap().payload {
            Some(Payload::WorkspaceList(wl)) => wl.workspaces[0].workspace_id.clone(),
            other => panic!("expected WorkspaceList, got {other:?}"),
        };

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 4,
                correlation_id: 0,
                payload: Some(Payload::DeleteWorkspaceRequest(DeleteWorkspaceRequest {
                    workspace_id: default_id,
                })),
            },
        )
        .await
        .unwrap();

        let removed =
            next_workspace_removed(&mut reader, std::time::Duration::from_millis(500)).await;
        assert!(
            removed.is_none(),
            "last workspace deletion must be refused, got {removed:?}"
        );

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 5,
                correlation_id: 0,
                payload: Some(Payload::Ping(Ping { nonce: 99 })),
            },
        )
        .await
        .unwrap();
        match read_envelope(&mut reader).await.unwrap().payload {
            Some(Payload::Pong(Pong { nonce })) => assert_eq!(nonce, 99),
            other => panic!("expected Pong, got {other:?}"),
        }

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }

    /// (e) `RenameWorkspaceRequest`/`DeleteWorkspaceRequest` against an
    /// unknown workspace_id are silent no-ops: no `WorkspaceRemoved`
    /// push, no roster change, and the default workspace's title is not
    /// hijacked by the bogus rename.
    #[tokio::test]
    async fn rename_and_delete_unknown_workspace_id_are_noops() {
        use peer_proto::v1::{DeleteWorkspaceRequest, RenameWorkspaceRequest};

        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");
        let manager = cat_manager();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager)
                .await
                .unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, mut writer) = handshake(&sock_path).await;
        let ghost_id = vec![0xEE; 16];

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 3,
                correlation_id: 0,
                payload: Some(Payload::RenameWorkspaceRequest(RenameWorkspaceRequest {
                    workspace_id: ghost_id.clone(),
                    title: "hijacked".into(),
                })),
            },
        )
        .await
        .unwrap();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 4,
                correlation_id: 0,
                payload: Some(Payload::DeleteWorkspaceRequest(DeleteWorkspaceRequest {
                    workspace_id: ghost_id,
                })),
            },
        )
        .await
        .unwrap();

        let removed =
            next_workspace_removed(&mut reader, std::time::Duration::from_millis(500)).await;
        assert!(
            removed.is_none(),
            "unknown workspace_id delete must be a silent no-op"
        );

        write_envelope(
            &mut writer,
            &Envelope {
                seq: 5,
                correlation_id: 0,
                payload: Some(Payload::ListWorkspaces(ListWorkspaces {})),
            },
        )
        .await
        .unwrap();
        let workspaces = match read_envelope(&mut reader).await.unwrap().payload {
            Some(Payload::WorkspaceList(wl)) => wl.workspaces,
            other => panic!("expected WorkspaceList, got {other:?}"),
        };
        assert_eq!(
            workspaces.len(),
            1,
            "roster untouched by no-op rename/delete"
        );
        assert_eq!(
            workspaces[0].title, DAEMON_WORKSPACE,
            "default title must not have been hijacked"
        );

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }
}
