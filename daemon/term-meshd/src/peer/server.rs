//! Unix-socket accept loop for peer-federation host.
//!
//! Phase 2.3B: constructs a shared `PtyManager` at startup, eagerly
//! spawns a default PTY surface, and passes the manager into each
//! per-connection task.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use tokio::net::UnixListener;
use tokio::sync::watch;

use super::connection::{self, TICK_SURFACE_ID};
use super::surface::PtyManager;

pub async fn serve(path: PathBuf, shutdown_rx: watch::Receiver<bool>) -> anyhow::Result<()> {
    let manager = Arc::new(PtyManager::new());
    manager.spawn_default(TICK_SURFACE_ID.to_vec());
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
    use crate::peer::surface::PtySurface;

    fn cat_manager() -> Arc<PtyManager> {
        // `/bin/cat` is long-lived: it only exits when its stdin (the PTY
        // slave) is closed. We deliberately use it as the test child to
        // prove the AsyncFd-based reader task can be cancelled cleanly
        // when the tokio runtime drops at test end. Under the earlier
        // spawn_blocking design this would hang the test forever.
        let manager = Arc::new(PtyManager::new());
        let surface = PtySurface::spawn(
            TICK_SURFACE_ID.to_vec(),
            "cat".into(),
            "/bin/cat",
            &[],
            80,
            24,
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
