//! Unix-socket accept loop for peer-federation host.
//!
//! Phase 2.3B: constructs a shared `PtyManager` at startup, eagerly
//! spawns a default PTY surface, and passes the manager into each
//! per-connection task.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use tokio::net::UnixListener;
use tokio::sync::watch;

use super::connection;
use super::surface::PtyManager;

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
            std::fs::create_dir_all(parent)?;
        }
    }

    let listener = UnixListener::bind(&path)?;
    tracing::info!("peer-federation listening on {}", path.display());

    loop {
        tokio::select! {
            result = listener.accept() => {
                match result {
                    Ok((stream, _)) => {
                        let manager = manager.clone();
                        tokio::spawn(async move {
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

    if Path::new(&path).exists() {
        let _ = std::fs::remove_file(&path);
    }
    Ok(())
}

#[cfg(test)]
mod integration_tests {
    use super::*;
    use peer_proto::v1::envelope::Payload;
    use peer_proto::v1::{
        AttachMode, AttachSurface, Auth, Envelope, Hello, Input, ListSurfaces,
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
    #[tokio::test]
    async fn pty_surface_round_trips_input() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        const MARKER: &str = "MARKER-peer-test";
        let manager = cat_manager();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve_with_manager(sock_path_task, shutdown_rx, manager).await.unwrap();
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
                    capabilities: vec![],
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
                    capabilities: vec![],
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
        assert!(seen_on_1, "client 1 did not receive its own MARKER-ONE echo");
        assert!(seen_on_2, "client 2 did not receive MARKER-ONE from client 1");

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
        assert!(seen_on_1, "client 1 did not receive MARKER-TWO from client 2");
        assert!(seen_on_2, "client 2 did not receive its own MARKER-TWO echo");

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
                args: vec![
                    "-c".into(),
                    "printf RESPAWN-MARKER".into(),
                ],
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
                    capabilities: vec![],
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
            serve_with_manager(sp_task, shutdown_rx, manager).await.unwrap();
        });
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let (mut reader, mut writer, surface_id) = attach_one(&sock_path, "meta-client").await;
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
            serve_with_manager(sock_path_task, shutdown_rx, manager).await.unwrap();
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
                    capabilities: vec![],
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
}
