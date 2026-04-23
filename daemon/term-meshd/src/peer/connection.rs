//! Per-connection state machine for peer-federation host side.
//!
//! Handshake: Init → AuthSent → Ready.
//! In Ready, handles ListSurfaces / AttachSurface / DetachSurface /
//! Input / Resize / Ping / Goodbye.
//!
//! Phase 2.3B: surfaces are real PTYs owned by a shared `PtyManager`.
//! Each attach spawns a subscriber relay task that pumps broadcast bytes
//! into the connection's outgoing channel wrapped as `PtyData` frames.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use peer_proto::v1::envelope::Payload;
use peer_proto::v1::{
    AttachMode, AttachResult, AuthChallenge, AuthResult, Envelope, Error, Hello, Pong, PtyData,
    SurfaceList,
};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;
use tokio::sync::{broadcast, mpsc, Notify};
use tokio::task::JoinHandle;

use super::framing::{read_envelope, write_envelope};
use super::surface::{PtyManager, PtySurface};

pub const PROTOCOL_VERSION: &str = "1.0.0";
pub const HOST_DISPLAY_NAME_ENV: &str = "TERMMESH_PEER_DISPLAY_NAME";

#[derive(Debug, PartialEq, Eq)]
enum HandshakeState {
    Init,
    AuthSent,
    Ready,
}

struct AttachEntry {
    surface: Arc<PtySurface>,
    task: JoinHandle<()>,
    cancel: Arc<Notify>,
}

pub async fn run(stream: UnixStream, manager: Arc<PtyManager>) -> anyhow::Result<()> {
    let (reader, writer) = stream.into_split();
    let (outgoing_tx, outgoing_rx) = mpsc::channel::<Envelope>(128);
    let seq_counter = Arc::new(AtomicU64::new(0));

    let writer_task = tokio::spawn(writer_loop(writer, outgoing_rx));
    let result = reader_loop(reader, outgoing_tx.clone(), seq_counter, manager).await;
    drop(outgoing_tx);
    let _ = writer_task.await;
    result
}

async fn writer_loop(mut writer: OwnedWriteHalf, mut rx: mpsc::Receiver<Envelope>) {
    while let Some(env) = rx.recv().await {
        if let Err(e) = write_envelope(&mut writer, &env).await {
            tracing::debug!("peer writer error: {e}");
            break;
        }
    }
}

async fn reader_loop(
    mut reader: OwnedReadHalf,
    outgoing_tx: mpsc::Sender<Envelope>,
    seq_counter: Arc<AtomicU64>,
    manager: Arc<PtyManager>,
) -> anyhow::Result<()> {
    let mut state = HandshakeState::Init;
    let mut attached: HashMap<Vec<u8>, AttachEntry> = HashMap::new();

    loop {
        let env = match read_envelope(&mut reader).await {
            Ok(e) => e,
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                tracing::debug!("peer closed connection");
                break;
            }
            Err(e) => {
                tracing::warn!("peer read error: {e}");
                break;
            }
        };

        let Some(payload) = env.payload else {
            send_error(&outgoing_tx, 102, "envelope missing payload").await;
            continue;
        };

        match (&state, payload) {
            (HandshakeState::Init, Payload::Hello(hello)) => {
                if !major_compatible(&hello.protocol_version, PROTOCOL_VERSION) {
                    send_error(
                        &outgoing_tx,
                        104,
                        &format!(
                            "version mismatch: host {PROTOCOL_VERSION}, client {}",
                            hello.protocol_version
                        ),
                    )
                    .await;
                    break;
                }
                tracing::info!(
                    "peer connected: name={:?} app_version={:?}",
                    hello.display_name,
                    hello.app_version
                );

                send(&outgoing_tx, host_hello(&seq_counter)).await?;
                let challenge = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: 0,
                    payload: Some(Payload::AuthChallenge(AuthChallenge {
                        nonce: vec![0u8; 32],
                        supported_methods: vec!["ssh-passthrough".into(), "token-ed25519".into()],
                    })),
                };
                send(&outgoing_tx, challenge).await?;
                state = HandshakeState::AuthSent;
            }

            (HandshakeState::Init, _) => {
                send_error(&outgoing_tx, 103, "expected Hello first").await;
                break;
            }

            (HandshakeState::AuthSent, Payload::Auth(auth)) => {
                if auth.method != "ssh-passthrough" {
                    let err = Envelope {
                        seq: next_seq(&seq_counter),
                        correlation_id: env.seq,
                        payload: Some(Payload::AuthResult(AuthResult {
                            accepted: false,
                            reason: format!("unsupported auth method: {}", auth.method),
                            session_id: vec![],
                        })),
                    };
                    send(&outgoing_tx, err).await?;
                    break;
                }
                let accept = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: env.seq,
                    payload: Some(Payload::AuthResult(AuthResult {
                        accepted: true,
                        reason: String::new(),
                        session_id: uuid::Uuid::new_v4().as_bytes().to_vec(),
                    })),
                };
                send(&outgoing_tx, accept).await?;
                state = HandshakeState::Ready;
                tracing::info!("peer authenticated (ssh-passthrough)");
            }

            (HandshakeState::AuthSent, _) => {
                send_error(&outgoing_tx, 103, "expected Auth").await;
                break;
            }

            (HandshakeState::Ready, Payload::ListSurfaces(_)) => {
                let surfaces = manager.list().iter().map(|s| s.info()).collect();
                let reply = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: env.seq,
                    payload: Some(Payload::SurfaceList(SurfaceList { surfaces })),
                };
                send(&outgoing_tx, reply).await?;
            }

            (HandshakeState::Ready, Payload::AttachSurface(req)) => {
                // get_or_respawn revives a registered surface whose child
                // has exited (e.g., the user typed `exit` in a previous
                // attach). Unknown ids or respawn failures fall through
                // to the "surface not found" reply below.
                let Some(surface) = manager.get_or_respawn(&req.surface_id) else {
                    let reply = Envelope {
                        seq: next_seq(&seq_counter),
                        correlation_id: env.seq,
                        payload: Some(Payload::AttachResult(AttachResult {
                            accepted: false,
                            reason: "surface not found".into(),
                            surface_id: req.surface_id.clone(),
                            initial_seq: 0,
                            granted_mode: AttachMode::Unspecified as i32,
                        })),
                    };
                    send(&outgoing_tx, reply).await?;
                    continue;
                };

                if attached.contains_key(&req.surface_id) {
                    let reply = Envelope {
                        seq: next_seq(&seq_counter),
                        correlation_id: env.seq,
                        payload: Some(Payload::AttachResult(AttachResult {
                            accepted: false,
                            reason: "already attached".into(),
                            surface_id: req.surface_id.clone(),
                            initial_seq: 0,
                            granted_mode: AttachMode::Unspecified as i32,
                        })),
                    };
                    send(&outgoing_tx, reply).await?;
                    continue;
                }

                // Apply client-requested size. Multi-client policy beyond
                // last-writer-wins is deferred to Phase 2.3B-c.
                if req.client_cols > 0 && req.client_rows > 0 {
                    if let Err(e) = surface.resize(req.client_cols as u16, req.client_rows as u16) {
                        tracing::warn!("resize on attach failed: {e}");
                    }
                }

                let granted =
                    match AttachMode::try_from(req.mode).unwrap_or(AttachMode::Unspecified) {
                        AttachMode::CoWrite | AttachMode::TakeOver => AttachMode::CoWrite,
                        _ => AttachMode::ReadOnly,
                    };

                let reply = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: env.seq,
                    payload: Some(Payload::AttachResult(AttachResult {
                        accepted: true,
                        reason: String::new(),
                        surface_id: req.surface_id.clone(),
                        initial_seq: 0,
                        granted_mode: granted as i32,
                    })),
                };
                send(&outgoing_tx, reply).await?;

                let entry = spawn_attach_relay(
                    surface.clone(),
                    outgoing_tx.clone(),
                    seq_counter.clone(),
                );
                attached.insert(req.surface_id, entry);
            }

            (HandshakeState::Ready, Payload::DetachSurface(det)) => {
                if let Some(entry) = attached.remove(&det.surface_id) {
                    entry.cancel.notify_one();
                    let _ = entry.task.await;
                }
            }

            (HandshakeState::Ready, Payload::Input(input)) => {
                let Some(entry) = attached.get(&input.surface_id) else {
                    tracing::debug!(
                        "input for unattached surface {:?}",
                        input.surface_id
                    );
                    continue;
                };
                match input.kind {
                    Some(peer_proto::v1::input::Kind::Keys(keys)) => {
                        if let Err(e) = entry.surface.write(&keys) {
                            tracing::warn!("PTY write failed: {e}");
                        }
                    }
                    Some(peer_proto::v1::input::Kind::Paste(p)) => {
                        if let Err(e) = entry.surface.write(&p.text) {
                            tracing::warn!("PTY paste-write failed: {e}");
                        }
                    }
                    Some(peer_proto::v1::input::Kind::Mouse(_)) => {
                        // Mouse events need xterm-style encoding; defer to 2.3B-c.
                        tracing::debug!("mouse event ignored (not yet implemented)");
                    }
                    None => {}
                }
            }

            (HandshakeState::Ready, Payload::Resize(r)) => {
                let Some(entry) = attached.get(&r.surface_id) else {
                    continue;
                };
                if r.cols > 0 && r.rows > 0 {
                    if let Err(e) = entry.surface.resize(r.cols as u16, r.rows as u16) {
                        tracing::warn!("resize failed: {e}");
                    }
                }
            }

            (HandshakeState::Ready, Payload::Ping(p)) => {
                let reply = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: env.seq,
                    payload: Some(Payload::Pong(Pong { nonce: p.nonce })),
                };
                send(&outgoing_tx, reply).await?;
            }

            (HandshakeState::Ready, Payload::Goodbye(g)) => {
                tracing::info!("peer said goodbye: {}", g.reason);
                break;
            }

            (HandshakeState::Ready, other) => {
                tracing::debug!("unhandled Ready-state payload: {other:?}");
            }
        }
    }

    for (_, entry) in attached.drain() {
        entry.cancel.notify_one();
        let _ = entry.task.await;
    }
    Ok(())
}

fn spawn_attach_relay(
    surface: Arc<PtySurface>,
    outgoing_tx: mpsc::Sender<Envelope>,
    seq_counter: Arc<AtomicU64>,
) -> AttachEntry {
    let cancel = Arc::new(Notify::new());
    let cancel_for_task = cancel.clone();
    let surface_for_task = surface.clone();
    let mut subscriber = surface.subscribe();

    let task = tokio::spawn(async move {
        let mut attach_seq = 0u64;
        loop {
            tokio::select! {
                biased;
                _ = cancel_for_task.notified() => break,
                _ = surface_for_task.dead_notify.notified() => {
                    tracing::info!("surface died, detaching relay");
                    break;
                }
                res = subscriber.recv() => {
                    match res {
                        Ok(bytes) => {
                            let len = bytes.len() as u64;
                            let env = Envelope {
                                seq: seq_counter.fetch_add(1, Ordering::Relaxed) + 1,
                                correlation_id: 0,
                                payload: Some(Payload::PtyData(PtyData {
                                    surface_id: surface_for_task.surface_id.clone(),
                                    byte_seq: attach_seq,
                                    payload: bytes,
                                })),
                            };
                            attach_seq += len;
                            if outgoing_tx.send(env).await.is_err() {
                                break;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!("attach relay lagged, missed {n} chunks");
                            // Protocol-level re-sync (GridSnapshot) lands in a later phase.
                            continue;
                        }
                        Err(broadcast::error::RecvError::Closed) => {
                            tracing::info!("broadcast closed, detaching relay");
                            break;
                        }
                    }
                }
            }
        }
    });

    AttachEntry {
        surface,
        task,
        cancel,
    }
}

fn host_hello(seq_counter: &AtomicU64) -> Envelope {
    let display = std::env::var(HOST_DISPLAY_NAME_ENV)
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "term-mesh-host".into());
    let peer_id = uuid::Uuid::new_v4().as_bytes().to_vec();
    Envelope {
        seq: next_seq(seq_counter),
        correlation_id: 0,
        payload: Some(Payload::Hello(Hello {
            protocol_version: PROTOCOL_VERSION.into(),
            peer_id,
            display_name: display,
            capabilities: vec![],
            app_version: env!("CARGO_PKG_VERSION").into(),
        })),
    }
}

fn next_seq(seq_counter: &AtomicU64) -> u64 {
    seq_counter.fetch_add(1, Ordering::Relaxed) + 1
}

fn major_compatible(a: &str, b: &str) -> bool {
    a.split('.').next() == b.split('.').next()
}

async fn send(tx: &mpsc::Sender<Envelope>, env: Envelope) -> anyhow::Result<()> {
    tx.send(env)
        .await
        .map_err(|e| anyhow::anyhow!("peer outgoing channel closed: {e}"))
}

async fn send_error(tx: &mpsc::Sender<Envelope>, code: u32, message: &str) {
    let env = Envelope {
        seq: 0,
        correlation_id: 0,
        payload: Some(Payload::Error(Error {
            code,
            message: message.into(),
            correlation_id_bytes: vec![],
        })),
    };
    let _ = tx.send(env).await;
}
