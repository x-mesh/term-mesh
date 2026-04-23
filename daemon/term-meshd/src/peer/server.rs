//! Unix-socket accept loop for peer-federation host.
//!
//! Invoked from term-meshd's main when `TERMMESH_PEER_SOCKET` is set.
//! The socket path is expected to be inside a user-private directory;
//! binding permissions are left as the process umask default for PoC.

use std::path::{Path, PathBuf};

use tokio::net::UnixListener;
use tokio::sync::watch;

use super::connection;

pub async fn serve(path: PathBuf, mut shutdown_rx: watch::Receiver<bool>) -> anyhow::Result<()> {
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
                        tokio::spawn(async move {
                            if let Err(e) = connection::run(stream).await {
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
    use peer_proto::v1::{
        envelope, AttachMode, AttachSurface, Auth, Envelope, Hello, ListSurfaces,
    };
    use peer_proto::v1::envelope::Payload;
    use tempfile::TempDir;
    use tokio::net::UnixStream;

    use crate::peer::connection::{PROTOCOL_VERSION, TICK_SURFACE_ID};
    use crate::peer::framing::{read_envelope, write_envelope};

    #[tokio::test]
    async fn host_serves_tick_surface_end_to_end() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve(sock_path_task, shutdown_rx).await.unwrap();
        });

        // Wait for the socket file to appear (bind is synchronous on the server side
        // but the task may not have reached it yet).
        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let stream = UnixStream::connect(&sock_path).await.unwrap();
        let (mut reader, mut writer) = stream.into_split();

        // --- Handshake ---
        let client_hello = Envelope {
            seq: 1,
            correlation_id: 0,
            payload: Some(Payload::Hello(Hello {
                protocol_version: PROTOCOL_VERSION.into(),
                peer_id: vec![0x11; 16],
                display_name: "integration-test".into(),
                capabilities: vec![],
                app_version: "test".into(),
            })),
        };
        write_envelope(&mut writer, &client_hello).await.unwrap();

        let host_hello = read_envelope(&mut reader).await.unwrap();
        assert!(matches!(host_hello.payload, Some(Payload::Hello(_))));

        let challenge = read_envelope(&mut reader).await.unwrap();
        assert!(matches!(challenge.payload, Some(Payload::AuthChallenge(_))));

        let client_auth = Envelope {
            seq: 2,
            correlation_id: 0,
            payload: Some(Payload::Auth(Auth {
                method: "ssh-passthrough".into(),
                token_id: vec![],
                signature: vec![],
            })),
        };
        write_envelope(&mut writer, &client_auth).await.unwrap();

        let auth_result = read_envelope(&mut reader).await.unwrap();
        match auth_result.payload {
            Some(Payload::AuthResult(r)) => assert!(r.accepted, "auth rejected: {}", r.reason),
            other => panic!("expected AuthResult, got {other:?}"),
        }

        // --- ListSurfaces ---
        let list = Envelope {
            seq: 3,
            correlation_id: 0,
            payload: Some(Payload::ListSurfaces(ListSurfaces {})),
        };
        write_envelope(&mut writer, &list).await.unwrap();
        let surface_list = read_envelope(&mut reader).await.unwrap();
        match surface_list.payload {
            Some(Payload::SurfaceList(sl)) => {
                assert_eq!(sl.surfaces.len(), 1);
                assert_eq!(sl.surfaces[0].surface_id, TICK_SURFACE_ID);
            }
            other => panic!("expected SurfaceList, got {other:?}"),
        }

        // --- AttachSurface ---
        let attach = Envelope {
            seq: 4,
            correlation_id: 0,
            payload: Some(Payload::AttachSurface(AttachSurface {
                surface_id: TICK_SURFACE_ID.to_vec(),
                mode: AttachMode::CoWrite as i32,
                client_cols: 80,
                client_rows: 24,
                resume_from_seq: 0,
            })),
        };
        write_envelope(&mut writer, &attach).await.unwrap();
        let attach_result = read_envelope(&mut reader).await.unwrap();
        match attach_result.payload {
            Some(Payload::AttachResult(r)) => {
                assert!(r.accepted);
                assert_eq!(r.surface_id, TICK_SURFACE_ID);
            }
            other => panic!("expected AttachResult, got {other:?}"),
        }

        // --- Receive at least one PtyData tick (within 2s) ---
        let pty = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            read_envelope(&mut reader),
        )
        .await
        .expect("did not receive PtyData in time")
        .unwrap();
        match pty.payload {
            Some(Payload::PtyData(p)) => {
                let text = String::from_utf8_lossy(&p.payload);
                assert!(text.contains("[host] tick"), "unexpected payload: {text}");
                assert_eq!(p.surface_id, TICK_SURFACE_ID);
            }
            other => panic!("expected PtyData, got {other:?}"),
        }

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(2), server_task).await;
    }

    #[tokio::test]
    async fn rejects_unknown_surface() {
        let tmp = TempDir::new().unwrap();
        let sock_path = tmp.path().join("peer.sock");

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let sock_path_task = sock_path.clone();
        let server_task = tokio::spawn(async move {
            serve(sock_path_task, shutdown_rx).await.unwrap();
        });

        for _ in 0..50 {
            if sock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let stream = UnixStream::connect(&sock_path).await.unwrap();
        let (mut reader, mut writer) = stream.into_split();

        // Minimal handshake.
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

        // Attach a surface id that does not exist.
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

        shutdown_tx.send(true).unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(2), server_task).await;
    }
}
