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
    workspace_update, AttachMode, AttachResult, AuthChallenge, AuthResult, CreateWorkspaceResponse,
    Envelope, Error, Hello, Pong, PtyData, SurfaceList, Workspace, WorkspaceList, WorkspaceMeta,
    WorkspaceUpdate,
};
use peer_proto::{capability, PeerCapabilities};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;
use tokio::sync::{broadcast, mpsc, Notify};
use tokio::task::JoinHandle;

use super::framing::{read_envelope, write_envelope};
use super::layout::{self, PeerHost};
use super::surface::PtySurface;

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

pub async fn run(stream: UnixStream, host: Arc<PeerHost>) -> anyhow::Result<()> {
    let (reader, writer) = stream.into_split();
    let (outgoing_tx, outgoing_rx) = mpsc::channel::<Envelope>(128);
    let seq_counter = Arc::new(AtomicU64::new(0));

    let writer_task = tokio::spawn(writer_loop(writer, outgoing_rx));
    let result = reader_loop(reader, outgoing_tx.clone(), seq_counter, host).await;
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
    host: Arc<PeerHost>,
) -> anyhow::Result<()> {
    let manager = host.pty.clone();
    let mut state = HandshakeState::Init;
    let mut attached: HashMap<Vec<u8>, AttachEntry> = HashMap::new();
    // RAII registration with the layout broadcaster; populated when the
    // handshake reaches Ready, dropped (= unregistered) with this frame.
    // Underscore: the binding exists for its Drop, it is never read.
    let mut _broadcast_guard: Option<layout::BroadcastGuard> = None;
    // Parsed once out of the client's Hello and kept for the rest of the
    // connection — plumbing only for now (see P3, docs/peer-perf-proposal.md):
    // nothing branches on it yet, but future wire changes (P8 and later)
    // need somewhere to ask "does this peer support X" before using it.
    // The `default()` placeholder is intentionally never read before the
    // Init/Hello arm overwrites it — a connection that drops before
    // sending Hello never reaches any arm that would consult it either.
    #[allow(unused_assignments)]
    let mut peer_capabilities = PeerCapabilities::default();

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
                peer_capabilities = PeerCapabilities::from_hello(hello.capabilities);
                tracing::debug!(
                    "peer capabilities: {:?} (ptydata.coalesce.v1={} replay.ring.v1={})",
                    peer_capabilities,
                    peer_capabilities.has(capability::PTYDATA_COALESCE_V1),
                    peer_capabilities.has(capability::REPLAY_RING_V1)
                );

                send(&outgoing_tx, host_hello(&seq_counter)).await?;
                let challenge = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: 0,
                    payload: Some(Payload::AuthChallenge(AuthChallenge {
                        nonce: random_peer_bytes(32),
                        supported_methods: vec!["ssh-passthrough".into()],
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
                        session_id: random_peer_bytes(16),
                    })),
                };
                send(&outgoing_tx, accept).await?;
                state = HandshakeState::Ready;
                // From Ready on, this connection receives layout pushes
                // triggered by any connection's WorkspaceControl. The guard
                // unregisters on connection teardown (any exit path).
                _broadcast_guard =
                    Some(host.clients.register(outgoing_tx.clone(), seq_counter.clone()));
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

            (HandshakeState::Ready, Payload::ListWorkspaces(_)) => {
                // A daemon-only host has no bonsplit windows to mirror — it
                // owns a flat set of forkpty surfaces arranged into one or
                // more named workspace trees. Clients (the macOS app) enter
                // every peer session through ListWorkspaces, and leaving it
                // unanswered stalls them until their 10s read timeout fires.
                //
                // M2: the roster can hold more than the single default
                // workspace (CreateWorkspaceRequest/DeleteWorkspaceRequest
                // grow/shrink it at runtime). Each entry's layout comes from
                // the same LayoutStore that WorkspaceControl mutations edit
                // and WorkspaceLayoutChanged pushes serialize, so a
                // reconnecting client sees the arrangement it (or another
                // viewer) actually made — not a fresh re-tile. A freshly
                // created, still-pane-less workspace serializes with
                // `layout: None`, which is exactly how a client is expected
                // to render an empty workspace.
                let workspaces = host
                    .list_workspaces()
                    .into_iter()
                    .map(|e| Workspace {
                        workspace_id: e.id,
                        title: e.title,
                        layout: e.layout,
                        // Empty window_id: clients read that as the legacy
                        // "single implied window" flat list, which is what
                        // a daemon host actually is.
                        window_id: Vec::new(),
                        window_title: String::new(),
                    })
                    .collect();
                let reply = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: env.seq,
                    payload: Some(Payload::WorkspaceList(WorkspaceList { workspaces })),
                };
                send(&outgoing_tx, reply).await?;
            }

            // Gated behind capability "workspace.lifecycle.v1" (see
            // peer.proto's "Workspace lifecycle" section). Unlike
            // WorkspaceControl, CreateWorkspaceRequest is a paired RPC —
            // the requester needs the host-assigned workspace_id back
            // immediately to address the workspace it just asked for
            // (e.g. a follow-up NewTabRequest.workspace_id).
            (HandshakeState::Ready, Payload::CreateWorkspaceRequest(req)) => {
                let workspace_id = host.create_workspace(req.title);
                let reply = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: env.seq,
                    payload: Some(Payload::CreateWorkspaceResponse(CreateWorkspaceResponse {
                        accepted: true,
                        reason: String::new(),
                        workspace_id,
                    })),
                };
                send(&outgoing_tx, reply).await?;
            }

            // Fire-and-forget like WorkspaceControl: no reply, paired or
            // otherwise. An empty or unknown workspace_id is adversarial-
            // or-stale input and must be safely ignored, never applied to
            // "the current" or "the default" workspace.
            (HandshakeState::Ready, Payload::RenameWorkspaceRequest(req)) => {
                if !host.rename_workspace(&req.workspace_id, req.title) {
                    tracing::warn!(
                        "RenameWorkspaceRequest for unknown/empty workspace_id {:?} ignored",
                        req.workspace_id
                    );
                }
            }

            // Fire-and-forget: the only observable result of a successful
            // delete is the WorkspaceRemoved push `PeerHost::remove_workspace`
            // broadcasts itself. An empty/unknown id or the default
            // workspace's id is safely refused (no-op), never treated as
            // "delete all" or "delete current".
            (HandshakeState::Ready, Payload::DeleteWorkspaceRequest(req)) => {
                if let Err(e) = host.remove_workspace(&req.workspace_id) {
                    tracing::warn!(
                        "DeleteWorkspaceRequest for workspace_id {:?} ignored: {e:?}",
                        req.workspace_id
                    );
                }
            }

            (HandshakeState::Ready, Payload::WorkspaceControl(ctl)) => {
                // Fire-and-forget by protocol design (peer.proto Workspace
                // control header): NEVER answer this — not on success, not
                // on refusal. The only observable result is the
                // WorkspaceLayoutChanged push apply_control schedules when
                // the tree actually changed; an invalid or refused command
                // (unknown ids, last-pane close, garbage orientation) is a
                // silent no-op exactly like the Swift host's perform*.
                host.apply_control(ctl);
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
                if let Some((cols, rows)) = clamp_pty_size(req.client_cols, req.client_rows) {
                    if let Err(e) = surface.resize(cols, rows) {
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

                // Push an initial WorkspaceMeta snapshot so the client can
                // show the remote surface's cwd / branch immediately. Future
                // dynamic updates (branch changed, ports opened) would ride
                // the same channel.
                let meta_env = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: 0,
                    payload: Some(Payload::WorkspaceUpdate(WorkspaceUpdate {
                        kind: Some(workspace_update::Kind::Meta(WorkspaceMeta {
                            branch: surface.branch.clone(),
                            cwd: surface.cwd.clone(),
                            ports: vec![],
                            latest_notification: String::new(),
                        })),
                    })),
                };
                send(&outgoing_tx, meta_env).await?;

                let entry =
                    spawn_attach_relay(surface.clone(), outgoing_tx.clone(), seq_counter.clone());
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
                    tracing::debug!("input for unattached surface {:?}", input.surface_id);
                    continue;
                };
                match input.kind {
                    Some(peer_proto::v1::input::Kind::Keys(keys)) => {
                        if let Err(e) = write_surface_input(entry.surface.clone(), keys).await {
                            tracing::warn!("PTY write failed: {e}");
                        }
                    }
                    Some(peer_proto::v1::input::Kind::Paste(p)) => {
                        if let Err(e) = write_surface_input(entry.surface.clone(), p.text).await {
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
                if let Some((cols, rows)) = clamp_pty_size(r.cols, r.rows) {
                    if let Err(e) = entry.surface.resize(cols, rows) {
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
        let replay = surface_for_task.replay_snapshot();
        let live_min_seq = replay
            .last()
            .map(|chunk| chunk.seq + chunk.bytes.len() as u64)
            .unwrap_or(0);

        // Prepend any currently-active mouse-tracking DECSET sequences ahead of the
        // snapshot: without this, a viewer attaching after the PTY already turned a
        // mouse mode on never sees the enabling escape and scroll dies on attach.
        // Swift-side counterpart: GhosttyPaneSurfaceProvider.attach's mouse-mode replay.
        let mode_prefix = surface_for_task.mode_replay_bytes();
        if !mode_prefix.is_empty() {
            let len = mode_prefix.len() as u64;
            let env = Envelope {
                seq: seq_counter.fetch_add(1, Ordering::Relaxed) + 1,
                correlation_id: 0,
                payload: Some(Payload::PtyData(PtyData {
                    surface_id: surface_for_task.surface_id.clone(),
                    byte_seq: attach_seq,
                    payload: mode_prefix,
                })),
            };
            attach_seq += len;
            if outgoing_tx.send(env).await.is_err() {
                return;
            }
        }

        for chunk in replay {
            let len = chunk.bytes.len() as u64;
            let env = Envelope {
                seq: seq_counter.fetch_add(1, Ordering::Relaxed) + 1,
                correlation_id: 0,
                payload: Some(Payload::PtyData(PtyData {
                    surface_id: surface_for_task.surface_id.clone(),
                    byte_seq: attach_seq,
                    payload: chunk.bytes,
                })),
            };
            attach_seq += len;
            if outgoing_tx.send(env).await.is_err() {
                return;
            }
        }

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
                        Ok(chunk) => {
                            if chunk.seq < live_min_seq {
                                continue;
                            }
                            let len = chunk.bytes.len() as u64;
                            let env = Envelope {
                                seq: seq_counter.fetch_add(1, Ordering::Relaxed) + 1,
                                correlation_id: 0,
                                payload: Some(Payload::PtyData(PtyData {
                                    surface_id: surface_for_task.surface_id.clone(),
                                    byte_seq: attach_seq,
                                    payload: chunk.bytes,
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
            capabilities: capability::supported_vec(),
            app_version: env!("CARGO_PKG_VERSION").into(),
        })),
    }
}

fn next_seq(seq_counter: &AtomicU64) -> u64 {
    seq_counter.fetch_add(1, Ordering::Relaxed) + 1
}

/// Best-effort hostname for the synthesised workspace title, in priority
/// order: `gethostname(2)`, then `/etc/hostname`, then `fallback`.
///
/// `$HOSTNAME` was the prior primary source, but bash keeps it as a shell
/// (non-exported) variable, not an environment variable — a systemd unit
/// (`docs/peer-linux-host.md`'s documented deployment) never sees it, so
/// that branch was dead in the deployment this daemon actually targets.
/// `gethostname(2)` is a real syscall with no such gap. Both fallback
/// paths are trimmed identically so trailing whitespace can't leak into
/// the title from either source.
pub(crate) fn hostname_or(fallback: &str) -> String {
    gethostname_string()
        .or_else(|| {
            std::fs::read_to_string("/etc/hostname")
                .ok()
                .map(|h| h.trim().to_string())
                .filter(|h| !h.is_empty())
        })
        .unwrap_or_else(|| fallback.to_string())
}

/// `gethostname(2)` via a fixed-size stack buffer — `HOST_NAME_MAX` on
/// Linux is 64 bytes; 256 leaves headroom without an allocation dance.
/// `None` on syscall failure or a non-UTF-8 / empty result.
fn gethostname_string() -> Option<String> {
    let mut buf = [0u8; 256];
    // Safety: buf is a valid, correctly-sized byte buffer for the
    // duration of the call; gethostname writes at most buf.len() bytes
    // (NUL-terminated) and returns non-zero on failure without touching
    // buf's contents in a way we rely on.
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) };
    if rc != 0 {
        return None;
    }
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    let s = std::str::from_utf8(&buf[..end]).ok()?.trim().to_string();
    (!s.is_empty()).then_some(s)
}

/// CSPRNG-backed random bytes, shared across `peer::` for anything that
/// needs an unguessable id: auth nonces / session ids here, and (M1)
/// workspace ids in `persist`/`layout` — a workspace's id must never be
/// re-derivable from its name so a rename can't accidentally change
/// which workspace a reconnecting client refers to.
pub(crate) fn random_peer_bytes(len: usize) -> Vec<u8> {
    // CSPRNG via getrandom(3) so auth nonces / session ids don't
    // carry the structural fixed bits of UUIDv4 (version+variant
    // nibbles) and don't depend on uuid crate internals to use a
    // strong source. Falls back to a deterministic-looking but still
    // unique buffer only if getrandom is somehow unavailable, which
    // shouldn't happen on supported targets.
    let mut out = vec![0u8; len];
    if getrandom::getrandom(&mut out).is_ok() {
        return out;
    }
    // Fallback: two UUIDv4 bytes per chunk. Worse than CSPRNG but
    // better than a hard panic if getrandom fails.
    let mut filled = 0;
    while filled < len {
        let bytes = uuid::Uuid::new_v4();
        let take = (len - filled).min(16);
        out[filled..filled + take].copy_from_slice(&bytes.as_bytes()[..take]);
        filled += take;
    }
    out
}

async fn write_surface_input(surface: Arc<PtySurface>, bytes: Vec<u8>) -> std::io::Result<()> {
    tokio::task::spawn_blocking(move || surface.write_all(&bytes))
        .await
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Interrupted, e.to_string()))?
}

fn clamp_pty_size(cols: u32, rows: u32) -> Option<(u16, u16)> {
    if cols == 0 || rows == 0 {
        return None;
    }
    let cols = cols.min(1000) as u16;
    let rows = rows.min(1000) as u16;
    Some((cols, rows))
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

#[cfg(test)]
mod hostname_tests {
    use super::{gethostname_string, hostname_or};

    /// F8 regression: gethostname(2) is a real syscall (unlike the prior
    /// $HOSTNAME env read, dead under the systemd deployment
    /// docs/peer-linux-host.md documents) — it must succeed on any host
    /// this test runs on and return a non-empty, trimmed name.
    #[test]
    fn gethostname_succeeds_and_is_trimmed() {
        let name = gethostname_string().expect("gethostname(2) should succeed");
        assert!(!name.is_empty());
        assert_eq!(name, name.trim(), "must already be trimmed");
    }

    /// hostname_or must prefer the real hostname over the fallback when
    /// gethostname(2) succeeds — which it always does on a real machine.
    #[test]
    fn hostname_or_prefers_real_hostname_over_fallback() {
        let result = hostname_or("unreachable-fallback-sentinel");
        assert_ne!(result, "unreachable-fallback-sentinel");
    }
}
