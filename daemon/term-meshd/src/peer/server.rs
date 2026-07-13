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
use super::surface::PtyManager;
use crate::supervisor::{shutdown_supervised, spawn_supervised};

const MAX_PEER_CONNECTIONS: usize = 16;

pub async fn serve(path: PathBuf, shutdown_rx: watch::Receiver<bool>) -> anyhow::Result<()> {
    let manager = Arc::new(PtyManager::new());
    manager.spawn_from_config();
    serve_with_manager(path, shutdown_rx, manager).await
}

pub async fn serve_with_manager(
    path: PathBuf,
    mut shutdown_rx: watch::Receiver<bool>,
    manager: Arc<PtyManager>,
) -> anyhow::Result<()> {
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
    let connection_permits = Arc::new(Semaphore::new(MAX_PEER_CONNECTIONS));
    let owner_uid = current_uid();
    let mut connection_tasks = JoinSet::new();

    loop {
        tokio::select! {
            result = listener.accept() => {
                match result {
                    Ok((stream, _)) => {
                        // UID gate: only same-user processes may attach
                        // to this socket, even if a permissive parent
                        // directory or chmod race exposed the file to
                        // other users on the host.
                        if !peer_uid_matches(&stream, owner_uid) {
                            tracing::warn!(
                                "rejecting peer connection from foreign uid \
                                 (only uid {owner_uid} may attach)"
                            );
                            drop(stream);
                            continue;
                        }
                        let Ok(permit) = connection_permits.clone().try_acquire_owned() else {
                            tracing::warn!("peer connection limit reached; closing new client");
                            drop(stream);
                            continue;
                        };
                        let manager = manager.clone();
                        spawn_supervised(&mut connection_tasks, async move {
                            let _permit = permit;
                            if let Err(e) = connection::run(stream, manager).await {
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

/// Compare the connected peer's effective uid against `expected_uid`.
/// Returns `true` only when we positively confirm the match; on any
/// platform/syscall failure we fail closed (return `false`).
#[cfg(target_os = "macos")]
fn peer_uid_matches(stream: &tokio::net::UnixStream, expected_uid: u32) -> bool {
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
        return false;
    }
    let cred = unsafe { cred.assume_init() };
    cred.cr_uid == expected_uid
}

#[cfg(target_os = "linux")]
fn peer_uid_matches(stream: &tokio::net::UnixStream, expected_uid: u32) -> bool {
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
        return false;
    }
    let cred = unsafe { cred.assume_init() };
    cred.uid == expected_uid
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn peer_uid_matches(_stream: &tokio::net::UnixStream, _expected_uid: u32) -> bool {
    // Conservative default: refuse all connections on platforms where
    // we can't verify the peer's uid.
    false
}

#[cfg(test)]
mod integration_tests {
    use super::*;
    use peer_proto::v1::envelope::Payload;
    use peer_proto::v1::{AttachMode, AttachSurface, Auth, Envelope, Hello, Input, ListSurfaces};
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
        let surface = PtySurface::spawn(
            surface_id_from_name("query"),
            "query".into(),
            "/bin/sh",
            &[
                "-c",
                "stty -icanon -echo min 1 time 0 2>/dev/null; printf '\\033[6n'; reply=$(dd bs=1 count=6 2>/dev/null); printf 'GOT[%s]\\n' \"$reply\"; sleep 2",
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
    async fn attach_one(
        sock_path: &std::path::Path,
        display: &str,
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
                    capabilities: peer_proto::capability::supported_vec(),
                    app_version: "test".into(),
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

        let (mut reader, _writer, _surface_id) = attach_one(&sock_path, "respawn-test").await;

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
        assert_eq!(
            cwd, spawn_cwd,
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

        let (mut reader, writer, _surface_id) =
            attach_one(&sock_path, "plain-shell-test").await;

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

        let first_payload = first_pty_payload.expect("no PtyData frame arrived after attach");
        assert!(
            !first_payload.starts_with(b"\x1b[?"),
            "unexpected mode-prefix escape on a surface with no active mode: {first_payload:?}"
        );

        drop(reader);
        drop(writer);
        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), server_task).await;
    }
}
