//! Per-connection state machine for peer-federation host side.
//!
//! Handshake: Init → HelloReceived → AuthSent → Ready.
//! In Ready, handles ListSurfaces / AttachSurface / DetachSurface /
//! Input / Resize / Ping / Goodbye.
//!
//! For Phase 2.2 the only surface is a single synthetic `TickSurface`
//! with a fixed surface_id; see `surface.rs`.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use peer_proto::v1::{
    AttachMode, AttachResult, AuthChallenge, AuthResult, Envelope, Error, Hello, Pong, SurfaceList,
};
use peer_proto::v1::envelope::Payload;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;
use tokio::sync::mpsc;

use super::framing::{read_envelope, write_envelope};
use super::surface::{spawn_tick_surface, tick_surface_info, AttachHandle};

pub const PROTOCOL_VERSION: &str = "1.0.0";
pub const HOST_DISPLAY_NAME_ENV: &str = "TERMMESH_PEER_DISPLAY_NAME";

/// Fixed surface_id for the Phase 2.2 tick surface. Deterministic so tests
/// don't need to call ListSurfaces before attaching.
pub const TICK_SURFACE_ID: [u8; 16] = [
    0x74, 0x69, 0x63, 0x6b, 0x2d, 0x73, 0x75, 0x72, 0x66, 0x61, 0x63, 0x65, 0x2d, 0x30, 0x30, 0x31,
];

#[derive(Debug, PartialEq, Eq)]
enum HandshakeState {
    Init,
    AuthSent,
    Ready,
}

/// Public entry for an accepted connection. Drives the handshake and
/// dispatch loop until the peer disconnects or sends Goodbye.
pub async fn run(stream: UnixStream) -> anyhow::Result<()> {
    let (reader, writer) = stream.into_split();
    let (outgoing_tx, outgoing_rx) = mpsc::channel::<Envelope>(128);
    let seq_counter = Arc::new(AtomicU64::new(0));

    let writer_task = tokio::spawn(writer_loop(writer, outgoing_rx));
    let reader_task = reader_loop(reader, outgoing_tx.clone(), seq_counter.clone());

    let result = reader_task.await;
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
) -> anyhow::Result<()> {
    let mut state = HandshakeState::Init;
    let mut attached: HashMap<Vec<u8>, AttachHandle> = HashMap::new();

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

                let host_hello = host_hello(&seq_counter);
                send(&outgoing_tx, host_hello).await?;

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
                let reply = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: env.seq,
                    payload: Some(Payload::SurfaceList(SurfaceList {
                        surfaces: vec![tick_surface_info(&TICK_SURFACE_ID)],
                    })),
                };
                send(&outgoing_tx, reply).await?;
            }

            (HandshakeState::Ready, Payload::AttachSurface(req)) => {
                if req.surface_id != TICK_SURFACE_ID {
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
                }

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

                let initial_seq = 0u64;
                let granted = match AttachMode::try_from(req.mode).unwrap_or(AttachMode::Unspecified) {
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
                        initial_seq,
                        granted_mode: granted as i32,
                    })),
                };
                send(&outgoing_tx, reply).await?;

                let handle = spawn_tick_surface(
                    req.surface_id.clone(),
                    initial_seq,
                    outgoing_tx.clone(),
                    seq_counter.clone(),
                );
                attached.insert(req.surface_id, handle);
            }

            (HandshakeState::Ready, Payload::DetachSurface(det)) => {
                if let Some(h) = attached.remove(&det.surface_id) {
                    h.cancel.notify_one();
                    let _ = h.task.await;
                }
            }

            (HandshakeState::Ready, Payload::Input(input)) => {
                match &input.kind {
                    Some(peer_proto::v1::input::Kind::Keys(keys)) => {
                        tracing::debug!(
                            "peer input on surface {:?}: {} bytes",
                            input.surface_id,
                            keys.len()
                        );
                    }
                    Some(peer_proto::v1::input::Kind::Mouse(_)) => {
                        tracing::debug!("peer mouse event on surface {:?}", input.surface_id);
                    }
                    Some(peer_proto::v1::input::Kind::Paste(p)) => {
                        tracing::debug!(
                            "peer paste on surface {:?}: {} bytes",
                            input.surface_id,
                            p.text.len()
                        );
                    }
                    None => {}
                }
            }

            (HandshakeState::Ready, Payload::Resize(r)) => {
                tracing::debug!(
                    "peer resize surface {:?} -> {}x{}",
                    r.surface_id,
                    r.cols,
                    r.rows
                );
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

    for (_, h) in attached.drain() {
        h.cancel.notify_one();
        let _ = h.task.await;
    }
    Ok(())
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

async fn send(
    tx: &mpsc::Sender<Envelope>,
    env: Envelope,
) -> anyhow::Result<()> {
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

