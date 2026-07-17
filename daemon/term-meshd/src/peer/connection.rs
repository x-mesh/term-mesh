//! Per-connection state machine for peer-federation host side.
//!
//! Handshake: Init → AuthSent → Ready.
//! In Ready, handles ListSurfaces / AttachSurface / DetachSurface /
//! Input / Resize / Ping / Goodbye.
//!
//! Phase 2.3B: surfaces are real PTYs owned by a shared `PtyManager`.
//! Each attach spawns a subscriber relay task that pumps broadcast bytes
//! into the connection's outgoing channel wrapped as `PtyData` frames.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use peer_proto::v1::envelope::Payload;
use peer_proto::v1::{
    workspace_update, AttachMode, AttachResult, AuthChallenge, AuthResult, CreateWorkspaceResponse,
    EnsureSurfaceError as WireEnsureError, EnsureSurfaceErrorCode, EnsureSurfaceRequest,
    EnsureSurfaceResponse, EnsureSurfaceRestartPolicy, EnsureSurfaceResult, Envelope, Error, Hello,
    Pong, PtyData, SurfaceList, TerminateSurfaceError as WireTerminateError,
    TerminateSurfaceErrorCode, TerminateSurfaceRequest, TerminateSurfaceResponse,
    TerminateSurfaceResult, Workspace, WorkspaceList, WorkspaceMeta, WorkspaceUpdate,
};
use peer_proto::{capability, PeerCapabilities};
use sha2::{Digest, Sha256};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;
use tokio::sync::{broadcast, mpsc, Notify, OwnedSemaphorePermit, Semaphore};
use tokio::task::JoinHandle;

use super::framing::{read_envelope, write_envelope};
use super::layout::{self, PeerHost};
use super::surface::{
    EnsureDisposition, EnsureError, EnsureOutcome, EnsureRestartPolicy, PtySurface, SurfaceSpec,
};

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
    // Request ids are one-shot for the authenticated connection. Insert before
    // starting work so two back-to-back frames cannot race through ensure.
    let mut lifecycle_request_ids: HashSet<Vec<u8>> = HashSet::new();
    // Acquired by the reader before an ensure task is spawned. Waiting here
    // applies socket backpressure instead of accumulating unbounded queued
    // tasks while keeping up to this many independent keys concurrent.
    let ensure_work_gate = EnsureWorkGate::new();
    let ensure_worker: EnsureWorker = {
        let host = host.clone();
        Arc::new(move |key, spec| host.ensure_surface(&key, &spec))
    };
    let terminate_worker: TerminateWorker = {
        let host = host.clone();
        Arc::new(move |surface_id| host.terminate_surface(&surface_id))
    };
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
                _broadcast_guard = Some(
                    host.clients
                        .register(outgoing_tx.clone(), seq_counter.clone()),
                );
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

            (HandshakeState::Ready, Payload::EnsureSurfaceRequest(req)) => {
                dispatch_ensure_surface(
                    req,
                    env.seq,
                    &mut lifecycle_request_ids,
                    &ensure_work_gate,
                    &outgoing_tx,
                    &seq_counter,
                    ensure_worker.clone(),
                )
                .await?;
            }

            (HandshakeState::Ready, Payload::TerminateSurfaceRequest(req)) => {
                dispatch_terminate_surface(
                    req,
                    env.seq,
                    &mut lifecycle_request_ids,
                    &ensure_work_gate,
                    &outgoing_tx,
                    &seq_counter,
                    terminate_worker.clone(),
                )
                .await?;
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
                        is_default: e.is_default,
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
            // broadcasts itself. An empty/unknown id is safely refused
            // (no-op), never treated as "delete all" or "delete current".
            // M3: the default workspace is deletable like any other — it
            // promotes a survivor to take its place — so the only id-based
            // refusal left is `LastWorkspace` (this would empty the
            // collection, and un-namespaced control always needs a home).
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

        // Absolute host byte offset of the end of the last chunk we forwarded.
        // Used to turn a broadcast `Lagged` drop into a visible gap: when the
        // next delivered chunk's absolute `seq` jumps past this, the broadcast
        // silently discarded the bytes in between. We advance the client-facing
        // `attach_seq` by exactly that gap so the client sees a `byte_seq`
        // discontinuity (P9 drop detection) instead of a seamless-but-corrupt
        // stream. Starts at the end of the replay snapshot.
        let mut last_abs_end = live_min_seq;
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
                            // Account for any bytes the broadcast dropped between
                            // the last forwarded chunk and this one, so the gap
                            // surfaces as a byte_seq jump on the client.
                            if chunk.seq > last_abs_end {
                                attach_seq += chunk.seq - last_abs_end;
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
                            last_abs_end = chunk.seq + len;
                            if outgoing_tx.send(env).await.is_err() {
                                break;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!("attach relay lagged, missed {n} chunks");
                            // The dropped bytes are accounted for on the next
                            // delivered chunk via its absolute `seq` (see
                            // `last_abs_end`), which advances `attach_seq` so the
                            // client detects the gap. Heal (re-snapshot) is P9.2.
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

const ENSURE_KEY_MAX_BYTES: usize = 256;
const ENSURE_PATH_MAX_BYTES: usize = 4096;
const ENSURE_ARG_MAX_COUNT: usize = 256;
const ENSURE_ARG_MAX_BYTES: usize = 64 * 1024;
const ENSURE_REQUEST_ID_BUDGET: usize = 65_536;
const ENSURE_CONCURRENCY_LIMIT: usize = 16;

#[derive(Clone)]
struct EnsureWorkGate {
    permits: Arc<Semaphore>,
}

impl EnsureWorkGate {
    fn new() -> Self {
        Self {
            permits: Arc::new(Semaphore::new(ENSURE_CONCURRENCY_LIMIT)),
        }
    }

    async fn acquire(&self) -> Result<OwnedSemaphorePermit, tokio::sync::AcquireError> {
        self.permits.clone().acquire_owned().await
    }
}

type EnsureWorker =
    Arc<dyn Fn(String, SurfaceSpec) -> Result<EnsureOutcome, EnsureError> + Send + Sync + 'static>;
type TerminateWorker = Arc<dyn Fn(Vec<u8>) -> Result<bool, EnsureError> + Send + Sync + 'static>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RequestIdAdmission {
    Accepted,
    Duplicate,
    Exhausted,
    Invalid,
}

fn admit_ensure_request_id(seen: &mut HashSet<Vec<u8>>, request_id: &[u8]) -> RequestIdAdmission {
    if request_id.len() != 16 {
        return RequestIdAdmission::Invalid;
    }
    if seen.contains(request_id) {
        return RequestIdAdmission::Duplicate;
    }
    if seen.len() >= ENSURE_REQUEST_ID_BUDGET {
        return RequestIdAdmission::Exhausted;
    }
    seen.insert(request_id.to_vec());
    RequestIdAdmission::Accepted
}

/// Exact Ready-state dispatch path used by `reader_loop`. It owns request-id
/// admission, backpressure placement, worker spawn, and correlated response
/// enqueue so those ordering invariants can be exercised without a real PTY.
async fn dispatch_ensure_surface(
    req: EnsureSurfaceRequest,
    correlation_id: u64,
    ensure_request_ids: &mut HashSet<Vec<u8>>,
    ensure_work_gate: &EnsureWorkGate,
    outgoing_tx: &mpsc::Sender<Envelope>,
    seq_counter: &Arc<AtomicU64>,
    ensure_worker: EnsureWorker,
) -> anyhow::Result<()> {
    let request_id = req.request_id.clone();
    match admit_ensure_request_id(ensure_request_ids, &request_id) {
        RequestIdAdmission::Exhausted => {
            let response = failed_ensure_response(
                request_id,
                EnsureSurfaceErrorCode::RequestTooLarge,
                "validate",
                "connection request_id budget exhausted",
            );
            return send_ensure_response(outgoing_tx, seq_counter, correlation_id, response).await;
        }
        RequestIdAdmission::Duplicate => {
            let response = failed_ensure_response(
                request_id,
                EnsureSurfaceErrorCode::DuplicateRequestId,
                "validate",
                "request_id already consumed",
            );
            return send_ensure_response(outgoing_tx, seq_counter, correlation_id, response).await;
        }
        RequestIdAdmission::Accepted => {}
        // Invalid-length ids are deliberately not inserted into the one-shot
        // set; validation returns INVALID_REQUEST for each malformed frame.
        RequestIdAdmission::Invalid => {}
    }

    let Ok(ensure_permit) = ensure_work_gate.acquire().await else {
        let response = failed_ensure_response(
            request_id,
            EnsureSurfaceErrorCode::Internal,
            "internal",
            "ensure concurrency gate closed",
        );
        return send_ensure_response(outgoing_tx, seq_counter, correlation_id, response).await;
    };

    let tx = outgoing_tx.clone();
    let seq = seq_counter.clone();
    tokio::spawn(async move {
        let started = Instant::now();
        let request_hash = ensure_request_id_hash(&request_id);
        let safe_cwd = safe_log_cwd(&req.cwd);
        let response = match validate_ensure_request(req) {
            Ok((key, spec)) => {
                match tokio::task::spawn_blocking(move || ensure_worker(key, spec)).await {
                    Ok(result) => ensure_response_from_result(request_id, result),
                    Err(_) => failed_ensure_response(
                        request_id,
                        EnsureSurfaceErrorCode::Internal,
                        "internal",
                        "ensure worker failed",
                    ),
                }
            }
            Err(response) => response,
        };
        tracing::info!(
            request_id_hash = %request_hash,
            result = ?EnsureSurfaceResult::try_from(response.result).ok(),
            surface_id = %short_id(&response.surface_id),
            cwd = %safe_cwd,
            error_code = ?response.error.as_ref().and_then(|error| EnsureSurfaceErrorCode::try_from(error.code).ok()),
            elapsed_ms = started.elapsed().as_millis() as u64,
            "peer ensure completed"
        );
        let _ =
            send_ensure_response_with_permit(&tx, &seq, correlation_id, response, ensure_permit)
                .await;
    });
    Ok(())
}

async fn dispatch_terminate_surface(
    req: TerminateSurfaceRequest,
    correlation_id: u64,
    lifecycle_request_ids: &mut HashSet<Vec<u8>>,
    work_gate: &EnsureWorkGate,
    outgoing_tx: &mpsc::Sender<Envelope>,
    seq_counter: &Arc<AtomicU64>,
    terminate_worker: TerminateWorker,
) -> anyhow::Result<()> {
    let request_id = req.request_id.clone();
    let surface_id = req.surface_id.clone();
    match admit_ensure_request_id(lifecycle_request_ids, &request_id) {
        RequestIdAdmission::Duplicate => {
            return send_terminate_response(
                outgoing_tx,
                seq_counter,
                correlation_id,
                failed_terminate_response(
                    request_id,
                    surface_id,
                    TerminateSurfaceErrorCode::DuplicateRequestId,
                    "validate",
                    "request_id already consumed",
                ),
            )
            .await;
        }
        RequestIdAdmission::Exhausted => {
            return send_terminate_response(
                outgoing_tx,
                seq_counter,
                correlation_id,
                failed_terminate_response(
                    request_id,
                    surface_id,
                    TerminateSurfaceErrorCode::Internal,
                    "internal",
                    "connection request_id budget exhausted",
                ),
            )
            .await;
        }
        RequestIdAdmission::Accepted => {}
        RequestIdAdmission::Invalid => {
            return send_terminate_response(
                outgoing_tx,
                seq_counter,
                correlation_id,
                failed_terminate_response(
                    request_id,
                    surface_id,
                    TerminateSurfaceErrorCode::InvalidRequest,
                    "validate",
                    "request_id must be exactly 16 bytes",
                ),
            )
            .await;
        }
    }
    if surface_id.len() != 16 {
        return send_terminate_response(
            outgoing_tx,
            seq_counter,
            correlation_id,
            failed_terminate_response(
                request_id,
                surface_id,
                TerminateSurfaceErrorCode::InvalidRequest,
                "validate",
                "surface_id must be exactly 16 bytes",
            ),
        )
        .await;
    }

    let Ok(permit) = work_gate.acquire().await else {
        return send_terminate_response(
            outgoing_tx,
            seq_counter,
            correlation_id,
            failed_terminate_response(
                request_id,
                surface_id,
                TerminateSurfaceErrorCode::Internal,
                "internal",
                "surface lifecycle gate closed",
            ),
        )
        .await;
    };
    let tx = outgoing_tx.clone();
    let seq = seq_counter.clone();
    tokio::spawn(async move {
        let response = match tokio::task::spawn_blocking({
            let surface_id = surface_id.clone();
            move || terminate_worker(surface_id)
        })
        .await
        {
            Ok(Ok(true)) => TerminateSurfaceResponse {
                request_id,
                result: TerminateSurfaceResult::Terminated as i32,
                surface_id,
                error: None,
            },
            Ok(Ok(false)) => TerminateSurfaceResponse {
                request_id,
                result: TerminateSurfaceResult::NotFound as i32,
                surface_id,
                error: None,
            },
            Ok(Err(_)) | Err(_) => failed_terminate_response(
                request_id,
                surface_id,
                TerminateSurfaceErrorCode::Internal,
                "terminate",
                "surface termination failed",
            ),
        };
        let _ =
            send_terminate_response_with_permit(&tx, &seq, correlation_id, response, permit).await;
    });
    Ok(())
}

fn failed_terminate_response(
    request_id: Vec<u8>,
    surface_id: Vec<u8>,
    code: TerminateSurfaceErrorCode,
    stage: &'static str,
    safe_context: &'static str,
) -> TerminateSurfaceResponse {
    TerminateSurfaceResponse {
        request_id,
        result: TerminateSurfaceResult::Failed as i32,
        surface_id,
        error: Some(WireTerminateError {
            code: code as i32,
            stage: stage.into(),
            safe_context: safe_context.into(),
        }),
    }
}

fn validate_ensure_request(
    req: EnsureSurfaceRequest,
) -> Result<(String, SurfaceSpec), EnsureSurfaceResponse> {
    let request_id = req.request_id.clone();
    let invalid = |context: &'static str| {
        failed_ensure_response(
            request_id.clone(),
            EnsureSurfaceErrorCode::InvalidRequest,
            "validate",
            context,
        )
    };
    let too_large = |context: &'static str| {
        failed_ensure_response(
            request_id.clone(),
            EnsureSurfaceErrorCode::RequestTooLarge,
            "validate",
            context,
        )
    };

    if req.request_id.len() != 16 {
        return Err(invalid("request_id must be exactly 16 bytes"));
    }
    if req.key.is_empty() {
        return Err(invalid("key must not be empty"));
    }
    if req.key.len() > ENSURE_KEY_MAX_BYTES {
        return Err(too_large("key exceeds 256 UTF-8 bytes"));
    }
    if req.key.contains('\0') {
        return Err(invalid("key contains NUL"));
    }
    if req.cwd.is_empty() || !std::path::Path::new(&req.cwd).is_absolute() {
        return Err(invalid("cwd must be an absolute path"));
    }
    if req.cwd.len() > ENSURE_PATH_MAX_BYTES {
        return Err(too_large("cwd exceeds 4096 UTF-8 bytes"));
    }
    if req.cwd.contains('\0') {
        return Err(invalid("cwd contains NUL"));
    }
    if req.executable.is_empty() || !std::path::Path::new(&req.executable).is_absolute() {
        return Err(invalid("executable must be an absolute path"));
    }
    if req.executable.len() > ENSURE_PATH_MAX_BYTES {
        return Err(too_large("executable exceeds 4096 UTF-8 bytes"));
    }
    if req.executable.contains('\0') {
        return Err(invalid("executable contains NUL"));
    }
    if req.args.len() > ENSURE_ARG_MAX_COUNT {
        return Err(too_large("args exceed 256 entries"));
    }
    if req.args.iter().any(|arg| arg.len() > ENSURE_ARG_MAX_BYTES) {
        return Err(too_large("argument exceeds 65536 UTF-8 bytes"));
    }
    if req.args.iter().any(|arg| arg.contains('\0')) {
        return Err(invalid("argument contains NUL"));
    }

    let restart_policy = match EnsureSurfaceRestartPolicy::try_from(req.restart_policy) {
        Ok(EnsureSurfaceRestartPolicy::Never) => EnsureRestartPolicy::Never,
        Ok(EnsureSurfaceRestartPolicy::OnDaemonRestart) => EnsureRestartPolicy::OnDaemonRestart,
        _ => return Err(invalid("restart_policy is invalid or unspecified")),
    };
    Ok((
        req.key,
        SurfaceSpec {
            cwd: req.cwd,
            executable: req.executable,
            args: req.args,
            restart_policy,
        },
    ))
}

fn ensure_response_from_result(
    request_id: Vec<u8>,
    result: Result<super::surface::EnsureOutcome, EnsureError>,
) -> EnsureSurfaceResponse {
    match result {
        Ok(outcome) => EnsureSurfaceResponse {
            request_id,
            result: match outcome.disposition {
                EnsureDisposition::Created => EnsureSurfaceResult::Created,
                EnsureDisposition::Reused => EnsureSurfaceResult::Reused,
                EnsureDisposition::Recreated => EnsureSurfaceResult::Recreated,
            } as i32,
            surface_id: outcome.surface_id,
            instance_id: outcome.instance_id,
            generation: outcome.generation,
            pid: u32::try_from(outcome.pid).unwrap_or_default(),
            spec_hash: outcome.spec_hash.to_vec(),
            error: None,
        },
        Err(EnsureError::SpecConflict {
            surface_id,
            requested_spec_hash,
            ..
        }) => EnsureSurfaceResponse {
            request_id,
            result: EnsureSurfaceResult::SpecConflict as i32,
            surface_id,
            spec_hash: requested_spec_hash.to_vec(),
            error: Some(wire_ensure_error(
                EnsureSurfaceErrorCode::SpecConflict,
                "reconcile",
                "existing surface uses a different specification",
                0,
                0,
                0,
            )),
            ..Default::default()
        },
        Err(EnsureError::Spawn(error)) => spawn_error_response(request_id, &error),
        Err(EnsureError::InvalidKey(reason)) => failed_ensure_response(
            request_id,
            EnsureSurfaceErrorCode::InvalidRequest,
            "validate",
            reason,
        ),
        Err(EnsureError::NotRunning(surface_id)) => EnsureSurfaceResponse {
            request_id,
            result: EnsureSurfaceResult::Failed as i32,
            surface_id,
            error: Some(wire_ensure_error(
                EnsureSurfaceErrorCode::Internal,
                "reconcile",
                "surface is not running",
                0,
                0,
                0,
            )),
            ..Default::default()
        },
        Err(EnsureError::Persistence(_)) => failed_ensure_response(
            request_id,
            EnsureSurfaceErrorCode::Internal,
            "persist",
            "surface state could not be persisted",
        ),
        Err(EnsureError::Internal(_)) => failed_ensure_response(
            request_id,
            EnsureSurfaceErrorCode::Internal,
            "internal",
            "surface ensure failed",
        ),
    }
}

fn spawn_error_response(request_id: Vec<u8>, error: &std::io::Error) -> EnsureSurfaceResponse {
    let message = error.to_string();
    let (code, stage, context, exit_code, signal, os_error) = if message == "CWD_NOT_FOUND" {
        (
            EnsureSurfaceErrorCode::CwdNotFound,
            "chdir",
            "cwd not found",
            0,
            0,
            0,
        )
    } else if message == "CWD_NOT_DIRECTORY" {
        (
            EnsureSurfaceErrorCode::CwdNotDirectory,
            "chdir",
            "cwd is not a directory",
            0,
            0,
            0,
        )
    } else if message == "CWD_PERMISSION_DENIED" {
        (
            EnsureSurfaceErrorCode::CwdPermissionDenied,
            "chdir",
            "cwd is inaccessible",
            0,
            0,
            0,
        )
    } else if message == "COMMAND_NOT_FOUND" {
        (
            EnsureSurfaceErrorCode::CommandNotFound,
            "exec",
            "command not found",
            0,
            0,
            0,
        )
    } else if message == "COMMAND_PERMISSION_DENIED" {
        (
            EnsureSurfaceErrorCode::CommandPermissionDenied,
            "exec",
            "command is not executable",
            0,
            0,
            0,
        )
    } else if message == "EXEC_HANDSHAKE_TRUNCATED" {
        (
            EnsureSurfaceErrorCode::ExecHandshakeTruncated,
            "exec_handshake",
            "exec handshake truncated",
            0,
            0,
            0,
        )
    } else if message == "EXEC_HANDSHAKE_INVALID_STAGE" {
        (
            EnsureSurfaceErrorCode::ExecHandshakeInvalidStage,
            "exec_handshake",
            "exec handshake reported an invalid stage",
            0,
            0,
            0,
        )
    } else if message == "EXEC_HANDSHAKE_TIMEOUT" {
        (
            EnsureSurfaceErrorCode::ExecHandshakeTimeout,
            "exec_handshake",
            "exec readiness deadline exceeded",
            0,
            0,
            0,
        )
    } else if message == "COMMAND_EXITED(unknown)" {
        (
            EnsureSurfaceErrorCode::CommandExited,
            "startup",
            "command exited during startup",
            0,
            0,
            0,
        )
    } else if let Some(value) = coded_number(&message, "COMMAND_EXITED(") {
        (
            EnsureSurfaceErrorCode::CommandExited,
            "startup",
            "command exited during startup",
            value,
            0,
            0,
        )
    } else if let Some(value) = coded_number(&message, "COMMAND_SIGNALED(") {
        (
            EnsureSurfaceErrorCode::CommandSignaled,
            "startup",
            "command terminated during startup",
            0,
            value,
            0,
        )
    } else if let Some(value) = coded_number(&message, "COMMAND_EXEC_ERROR(") {
        (
            EnsureSurfaceErrorCode::CommandExecError,
            "exec",
            "exec failed",
            0,
            0,
            value,
        )
    } else if let Some(value) = coded_number(&message, "CWD_ERROR(") {
        (
            EnsureSurfaceErrorCode::CwdError,
            "chdir",
            "chdir failed",
            0,
            0,
            value,
        )
    } else {
        (
            EnsureSurfaceErrorCode::Internal,
            "spawn",
            "surface spawn failed",
            0,
            0,
            error.raw_os_error().unwrap_or_default(),
        )
    };

    EnsureSurfaceResponse {
        request_id,
        result: EnsureSurfaceResult::Failed as i32,
        error: Some(wire_ensure_error(
            code, stage, context, exit_code, signal, os_error,
        )),
        ..Default::default()
    }
}

fn coded_number(message: &str, prefix: &str) -> Option<i32> {
    message
        .strip_prefix(prefix)?
        .strip_suffix(')')?
        .parse()
        .ok()
}

fn failed_ensure_response(
    request_id: Vec<u8>,
    code: EnsureSurfaceErrorCode,
    stage: &'static str,
    context: &'static str,
) -> EnsureSurfaceResponse {
    EnsureSurfaceResponse {
        request_id,
        result: EnsureSurfaceResult::Failed as i32,
        error: Some(wire_ensure_error(code, stage, context, 0, 0, 0)),
        ..Default::default()
    }
}

fn wire_ensure_error(
    code: EnsureSurfaceErrorCode,
    stage: &'static str,
    safe_context: &'static str,
    exit_code: i32,
    signal: i32,
    os_error: i32,
) -> WireEnsureError {
    WireEnsureError {
        code: code as i32,
        stage: stage.into(),
        safe_context: safe_context.into(),
        exit_code,
        signal,
        os_error,
    }
}

async fn send_ensure_response(
    tx: &mpsc::Sender<Envelope>,
    seq_counter: &AtomicU64,
    correlation_id: u64,
    response: EnsureSurfaceResponse,
) -> anyhow::Result<()> {
    send(
        tx,
        Envelope {
            seq: next_seq(seq_counter),
            correlation_id,
            payload: Some(Payload::EnsureSurfaceResponse(response)),
        },
    )
    .await
}

/// Keep one concurrency slot owned until the correlated response has entered
/// the writer queue. Dropping it after host work but before this await would
/// let the reader admit more work while completed responses still accumulate.
async fn send_ensure_response_with_permit(
    tx: &mpsc::Sender<Envelope>,
    seq_counter: &AtomicU64,
    correlation_id: u64,
    response: EnsureSurfaceResponse,
    _permit: OwnedSemaphorePermit,
) -> anyhow::Result<()> {
    send_ensure_response(tx, seq_counter, correlation_id, response).await
}

async fn send_terminate_response(
    tx: &mpsc::Sender<Envelope>,
    seq_counter: &AtomicU64,
    correlation_id: u64,
    response: TerminateSurfaceResponse,
) -> anyhow::Result<()> {
    send(
        tx,
        Envelope {
            seq: next_seq(seq_counter),
            correlation_id,
            payload: Some(Payload::TerminateSurfaceResponse(response)),
        },
    )
    .await
}

async fn send_terminate_response_with_permit(
    tx: &mpsc::Sender<Envelope>,
    seq_counter: &AtomicU64,
    correlation_id: u64,
    response: TerminateSurfaceResponse,
    _permit: OwnedSemaphorePermit,
) -> anyhow::Result<()> {
    send_terminate_response(tx, seq_counter, correlation_id, response).await
}

fn ensure_request_id_hash(request_id: &[u8]) -> String {
    let digest = Sha256::digest(request_id);
    digest[..6]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn short_id(id: &[u8]) -> String {
    id.iter()
        .take(6)
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn safe_log_cwd(cwd: &str) -> String {
    if cwd.len() <= ENSURE_PATH_MAX_BYTES
        && cwd.starts_with('/')
        && !cwd.contains(['\n', '\r', '\0'])
    {
        cwd.to_string()
    } else {
        "<invalid>".into()
    }
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

#[cfg(test)]
mod ensure_tests {
    use std::collections::HashSet;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Condvar, Mutex};
    use std::time::Duration;

    use peer_proto::v1::envelope::Payload;
    use peer_proto::v1::{
        EnsureSurfaceErrorCode, EnsureSurfaceRequest, EnsureSurfaceResponse,
        EnsureSurfaceRestartPolicy, EnsureSurfaceResult,
    };
    use tokio::sync::mpsc;

    use super::{
        admit_ensure_request_id, dispatch_ensure_surface, ensure_response_from_result,
        send_ensure_response, spawn_error_response, validate_ensure_request, EnsureWorkGate,
        EnsureWorker, HandshakeState, RequestIdAdmission, ENSURE_CONCURRENCY_LIMIT,
        ENSURE_REQUEST_ID_BUDGET,
    };
    use crate::peer::surface::EnsureError;

    fn valid_request() -> EnsureSurfaceRequest {
        EnsureSurfaceRequest {
            request_id: vec![0x11; 16],
            key: "runner-smoke".into(),
            cwd: "/app/runner".into(),
            executable: "/bin/sh".into(),
            args: vec!["-lc".into(), "exec cargo test".into()],
            restart_policy: EnsureSurfaceRestartPolicy::OnDaemonRestart as i32,
        }
    }

    #[test]
    fn validates_wire_limits_and_restart_policy_without_echoing_input() {
        let (_, spec) = validate_ensure_request(valid_request()).expect("valid request");
        assert_eq!(spec.cwd, "/app/runner");

        let mut malformed = valid_request();
        malformed.request_id.pop();
        let error = validate_ensure_request(malformed)
            .expect_err("short request id")
            .error
            .expect("structured error");
        assert_eq!(error.code, EnsureSurfaceErrorCode::InvalidRequest as i32);

        let mut oversized = valid_request();
        oversized.args = vec!["x".repeat(65_537)];
        let error = validate_ensure_request(oversized)
            .expect_err("oversized arg")
            .error
            .expect("structured error");
        assert_eq!(error.code, EnsureSurfaceErrorCode::RequestTooLarge as i32);
        assert!(error.safe_context.len() < 128);
        assert!(!error.safe_context.contains(&"x".repeat(256)));

        let mut unspecified = valid_request();
        unspecified.restart_policy = EnsureSurfaceRestartPolicy::Unspecified as i32;
        let error = validate_ensure_request(unspecified)
            .expect_err("unspecified policy")
            .error
            .expect("structured error");
        assert_eq!(error.code, EnsureSurfaceErrorCode::InvalidRequest as i32);
    }

    #[test]
    fn request_ids_are_one_shot_and_connection_memory_is_bounded() {
        let mut seen = HashSet::new();
        let id = vec![0x22; 16];
        assert_eq!(
            admit_ensure_request_id(&mut seen, &id),
            RequestIdAdmission::Accepted
        );
        assert_eq!(
            admit_ensure_request_id(&mut seen, &id),
            RequestIdAdmission::Duplicate
        );
        seen.clear();
        for value in 0..ENSURE_REQUEST_ID_BUDGET {
            let mut unique = vec![0u8; 16];
            unique[..8].copy_from_slice(&(value as u64).to_be_bytes());
            assert_eq!(
                admit_ensure_request_id(&mut seen, &unique),
                RequestIdAdmission::Accepted
            );
        }
        assert_eq!(
            admit_ensure_request_id(&mut seen, &[0xff; 16]),
            RequestIdAdmission::Exhausted
        );
    }

    #[test]
    fn stable_spawn_taxonomy_preserves_numeric_details() {
        let exited = std::io::Error::other("COMMAND_EXITED(42)");
        let response = spawn_error_response(vec![1; 16], &exited);
        let error = response.error.expect("exit error");
        assert_eq!(error.code, EnsureSurfaceErrorCode::CommandExited as i32);
        assert_eq!(error.exit_code, 42);

        let signaled = std::io::Error::other("COMMAND_SIGNALED(15)");
        let response = spawn_error_response(vec![2; 16], &signaled);
        let error = response.error.expect("signal error");
        assert_eq!(error.code, EnsureSurfaceErrorCode::CommandSignaled as i32);
        assert_eq!(error.signal, 15);

        let exec = std::io::Error::other("COMMAND_EXEC_ERROR(8)");
        let response = spawn_error_response(vec![3; 16], &exec);
        let error = response.error.expect("exec error");
        assert_eq!(error.code, EnsureSurfaceErrorCode::CommandExecError as i32);
        assert_eq!(error.os_error, 8);
    }

    #[test]
    fn conflict_maps_to_wire_result_without_live_process_claim() {
        let response = ensure_response_from_result(
            vec![4; 16],
            Err(EnsureError::SpecConflict {
                surface_id: vec![5; 16],
                existing_spec_hash: [6; 32],
                requested_spec_hash: [7; 32],
            }),
        );
        assert_eq!(response.result, EnsureSurfaceResult::SpecConflict as i32);
        assert_eq!(response.surface_id, vec![5; 16]);
        assert_eq!(response.pid, 0);
        assert_eq!(response.spec_hash, vec![7; 32]);
    }

    #[tokio::test]
    async fn concurrent_responses_may_reorder_but_keep_exact_correlation() {
        let (tx, mut rx) = mpsc::channel(2);
        let seq = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));

        let slow_tx = tx.clone();
        let slow_seq = seq.clone();
        let slow = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(20)).await;
            send_ensure_response(
                &slow_tx,
                &slow_seq,
                101,
                EnsureSurfaceResponse {
                    request_id: vec![1; 16],
                    result: EnsureSurfaceResult::Reused as i32,
                    ..Default::default()
                },
            )
            .await
            .expect("slow response");
        });
        send_ensure_response(
            &tx,
            &seq,
            202,
            EnsureSurfaceResponse {
                request_id: vec![2; 16],
                result: EnsureSurfaceResult::Created as i32,
                ..Default::default()
            },
        )
        .await
        .expect("fast response");

        let first = rx.recv().await.expect("first");
        let second = rx.recv().await.expect("second");
        slow.await.expect("slow task");
        assert_eq!((first.correlation_id, second.correlation_id), (202, 101));
        assert!(matches!(
            first.payload,
            Some(Payload::EnsureSurfaceResponse(_))
        ));
        assert!(matches!(
            second.payload,
            Some(Payload::EnsureSurfaceResponse(_))
        ));
    }

    #[tokio::test]
    async fn ready_dispatch_backpressures_seventeenth_frame_until_response_enqueue() {
        let state = HandshakeState::Ready;
        assert_eq!(state, HandshakeState::Ready, "exercise authenticated path");
        let gate = EnsureWorkGate::new();
        let mut frames = Vec::new();
        for value in 0..=ENSURE_CONCURRENCY_LIMIT {
            let mut request = valid_request();
            request.request_id = (value as u128).to_be_bytes().to_vec();
            validate_ensure_request(request.clone()).expect("all 17 requests are valid");
            frames.push(peer_proto::v1::Envelope {
                seq: value as u64 + 1,
                correlation_id: 0,
                payload: Some(Payload::EnsureSurfaceRequest(request)),
            });
        }

        let (tx, mut rx) = mpsc::channel(1);
        tx.send(peer_proto::v1::Envelope::default())
            .await
            .expect("prefill writer queue");
        let seq = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let entered = Arc::new(AtomicUsize::new(0));
        let releases = Arc::new((Mutex::new(0usize), Condvar::new()));
        let worker: EnsureWorker = Arc::new({
            let entered = entered.clone();
            let releases = releases.clone();
            move |_, _| {
                entered.fetch_add(1, Ordering::SeqCst);
                let (lock, wake) = &*releases;
                let mut available = lock.lock().expect("release lock");
                while *available == 0 {
                    available = wake.wait(available).expect("release wait");
                }
                *available -= 1;
                Err(EnsureError::Internal("test worker completed"))
            }
        });

        let mut seen = HashSet::new();
        for frame in frames.drain(..ENSURE_CONCURRENCY_LIMIT) {
            let correlation_id = frame.seq;
            let Payload::EnsureSurfaceRequest(request) = frame.payload.expect("payload") else {
                panic!("wrong payload");
            };
            dispatch_ensure_surface(
                request,
                correlation_id,
                &mut seen,
                &gate,
                &tx,
                &seq,
                worker.clone(),
            )
            .await
            .expect("dispatch first 16 Ready frames");
        }
        tokio::time::timeout(Duration::from_secs(2), async {
            while entered.load(Ordering::SeqCst) != ENSURE_CONCURRENCY_LIMIT {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("first 16 workers enter");

        let frame = frames.pop().expect("17th frame");
        let correlation_id = frame.seq;
        let Payload::EnsureSurfaceRequest(request) = frame.payload.expect("payload") else {
            panic!("wrong payload");
        };
        let seventeenth =
            dispatch_ensure_surface(request, correlation_id, &mut seen, &gate, &tx, &seq, worker);
        tokio::pin!(seventeenth);
        assert!(
            tokio::time::timeout(Duration::from_millis(20), &mut seventeenth)
                .await
                .is_err(),
            "production dispatch must block before spawning worker 17"
        );
        assert_eq!(entered.load(Ordering::SeqCst), ENSURE_CONCURRENCY_LIMIT);

        // Complete one worker while the writer queue is full. The production
        // response helper must retain its permit across the blocked enqueue.
        {
            let (lock, wake) = &*releases;
            *lock.lock().expect("release lock") += 1;
            wake.notify_one();
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(
            tokio::time::timeout(Duration::from_millis(20), &mut seventeenth)
                .await
                .is_err(),
            "worker 17 must wait until response enqueue, not worker return"
        );
        assert_eq!(entered.load(Ordering::SeqCst), ENSURE_CONCURRENCY_LIMIT);

        rx.recv().await.expect("drain writer queue capacity");
        tokio::time::timeout(Duration::from_secs(1), &mut seventeenth)
            .await
            .expect("response enqueue releases capacity")
            .expect("17th Ready frame dispatches");
        tokio::time::timeout(Duration::from_secs(1), async {
            while entered.load(Ordering::SeqCst) != ENSURE_CONCURRENCY_LIMIT + 1 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("17th worker enters after enqueue");
        let response = rx.recv().await.expect("correlated response queued");
        assert!((1..=ENSURE_CONCURRENCY_LIMIT as u64).contains(&response.correlation_id));

        // Release the remaining 16 workers and drain their responses so no
        // blocking worker or dispatch task leaks out of the test runtime.
        {
            let (lock, wake) = &*releases;
            *lock.lock().expect("release lock") += ENSURE_CONCURRENCY_LIMIT;
            wake.notify_all();
        }
        for _ in 0..ENSURE_CONCURRENCY_LIMIT {
            rx.recv().await.expect("remaining correlated response");
        }
    }
}

#[cfg(test)]
mod terminate_tests {
    use std::collections::HashSet;
    use std::sync::atomic::AtomicU64;
    use std::sync::{Arc, Mutex};

    use peer_proto::v1::envelope::Payload;
    use peer_proto::v1::{
        EnsureSurfaceErrorCode, EnsureSurfaceRequest, EnsureSurfaceRestartPolicy,
        EnsureSurfaceResult, TerminateSurfaceErrorCode, TerminateSurfaceRequest,
        TerminateSurfaceResult,
    };
    use tokio::sync::mpsc;

    use super::{
        dispatch_ensure_surface, dispatch_terminate_surface, EnsureWorkGate, EnsureWorker,
        TerminateWorker,
    };

    #[tokio::test]
    async fn ready_terminate_is_exact_correlated_idempotent_and_one_shot() {
        let exact_surface = vec![0x91; 16];
        let observed = Arc::new(Mutex::new(Vec::new()));
        let worker: TerminateWorker = Arc::new({
            let exact_surface = exact_surface.clone();
            let observed = observed.clone();
            move |surface_id| {
                observed
                    .lock()
                    .expect("observed lock")
                    .push(surface_id.clone());
                Ok(surface_id == exact_surface)
            }
        });
        let gate = EnsureWorkGate::new();
        let (tx, mut rx) = mpsc::channel(8);
        let seq = Arc::new(AtomicU64::new(0));
        let mut seen = HashSet::new();
        let request = TerminateSurfaceRequest {
            request_id: vec![1; 16],
            surface_id: exact_surface.clone(),
        };

        dispatch_terminate_surface(
            request.clone(),
            501,
            &mut seen,
            &gate,
            &tx,
            &seq,
            worker.clone(),
        )
        .await
        .expect("dispatch terminate");
        let response = rx.recv().await.expect("terminated response");
        assert_eq!(response.correlation_id, 501);
        let Some(Payload::TerminateSurfaceResponse(response)) = response.payload else {
            panic!("wrong response payload");
        };
        assert_eq!(response.result, TerminateSurfaceResult::Terminated as i32);
        assert_eq!(response.surface_id, exact_surface);

        dispatch_terminate_surface(request, 502, &mut seen, &gate, &tx, &seq, worker.clone())
            .await
            .expect("dispatch duplicate");
        let response = rx.recv().await.expect("duplicate response");
        assert_eq!(response.correlation_id, 502);
        let Some(Payload::TerminateSurfaceResponse(response)) = response.payload else {
            panic!("wrong duplicate payload");
        };
        assert_eq!(response.result, TerminateSurfaceResult::Failed as i32);
        assert_eq!(
            response.error.expect("duplicate error").code,
            TerminateSurfaceErrorCode::DuplicateRequestId as i32
        );

        dispatch_terminate_surface(
            TerminateSurfaceRequest {
                request_id: vec![2; 16],
                surface_id: vec![0x92; 16],
            },
            503,
            &mut seen,
            &gate,
            &tx,
            &seq,
            worker,
        )
        .await
        .expect("dispatch missing");
        let response = rx.recv().await.expect("not-found response");
        let Some(Payload::TerminateSurfaceResponse(response)) = response.payload else {
            panic!("wrong not-found payload");
        };
        assert_eq!(response.result, TerminateSurfaceResult::NotFound as i32);
        assert!(response.error.is_none());
        assert_eq!(observed.lock().expect("observed lock").len(), 2);
    }

    #[tokio::test]
    async fn malformed_terminate_returns_one_correlated_failure_without_worker() {
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let worker: TerminateWorker = Arc::new({
            let calls = calls.clone();
            move |_| {
                calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Ok(true)
            }
        });
        let gate = EnsureWorkGate::new();
        let (tx, mut rx) = mpsc::channel(2);
        let seq = Arc::new(AtomicU64::new(0));
        let mut seen = HashSet::new();
        dispatch_terminate_surface(
            TerminateSurfaceRequest {
                request_id: vec![3; 16],
                surface_id: vec![4; 15],
            },
            601,
            &mut seen,
            &gate,
            &tx,
            &seq,
            worker,
        )
        .await
        .expect("malformed response");
        let response = rx.recv().await.expect("failure response");
        assert_eq!(response.correlation_id, 601);
        let Some(Payload::TerminateSurfaceResponse(response)) = response.payload else {
            panic!("wrong failure payload");
        };
        assert_eq!(response.result, TerminateSurfaceResult::Failed as i32);
        assert_eq!(
            response.error.expect("invalid error").code,
            TerminateSurfaceErrorCode::InvalidRequest as i32
        );
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 0);
        assert!(rx.try_recv().is_err(), "exactly one response");
    }

    #[tokio::test]
    async fn request_id_is_one_shot_across_ensure_and_terminate_both_directions() {
        let gate = EnsureWorkGate::new();
        let (tx, mut rx) = mpsc::channel(8);
        let seq = Arc::new(AtomicU64::new(0));
        let ensure_worker: EnsureWorker =
            Arc::new(|_, _| Err(super::EnsureError::Internal("test ensure completed")));
        let terminate_worker: TerminateWorker = Arc::new(|_| Ok(false));
        let ensure_request = |request_id: Vec<u8>| EnsureSurfaceRequest {
            request_id,
            key: "cross-operation".into(),
            cwd: "/app/runner".into(),
            executable: "/bin/sh".into(),
            args: Vec::new(),
            restart_policy: EnsureSurfaceRestartPolicy::OnDaemonRestart as i32,
        };

        let first_id = vec![0xa1; 16];
        let mut seen = HashSet::new();
        dispatch_ensure_surface(
            ensure_request(first_id.clone()),
            701,
            &mut seen,
            &gate,
            &tx,
            &seq,
            ensure_worker.clone(),
        )
        .await
        .expect("ensure first");
        let ensure_response = rx.recv().await.expect("ensure response");
        assert_eq!(ensure_response.correlation_id, 701);
        dispatch_terminate_surface(
            TerminateSurfaceRequest {
                request_id: first_id,
                surface_id: vec![0xb1; 16],
            },
            702,
            &mut seen,
            &gate,
            &tx,
            &seq,
            terminate_worker.clone(),
        )
        .await
        .expect("terminate duplicate");
        let duplicate = rx.recv().await.expect("terminate duplicate response");
        let Some(Payload::TerminateSurfaceResponse(duplicate)) = duplicate.payload else {
            panic!("wrong terminate duplicate payload");
        };
        assert_eq!(duplicate.result, TerminateSurfaceResult::Failed as i32);
        assert_eq!(
            duplicate.error.expect("duplicate error").code,
            TerminateSurfaceErrorCode::DuplicateRequestId as i32
        );

        let second_id = vec![0xa2; 16];
        let mut seen = HashSet::new();
        dispatch_terminate_surface(
            TerminateSurfaceRequest {
                request_id: second_id.clone(),
                surface_id: vec![0xb2; 16],
            },
            703,
            &mut seen,
            &gate,
            &tx,
            &seq,
            terminate_worker,
        )
        .await
        .expect("terminate first");
        let terminate_response = rx.recv().await.expect("terminate response");
        assert_eq!(terminate_response.correlation_id, 703);
        dispatch_ensure_surface(
            ensure_request(second_id),
            704,
            &mut seen,
            &gate,
            &tx,
            &seq,
            ensure_worker,
        )
        .await
        .expect("ensure duplicate");
        let duplicate = rx.recv().await.expect("ensure duplicate response");
        let Some(Payload::EnsureSurfaceResponse(duplicate)) = duplicate.payload else {
            panic!("wrong ensure duplicate payload");
        };
        assert_eq!(duplicate.result, EnsureSurfaceResult::Failed as i32);
        assert_eq!(
            duplicate.error.expect("duplicate error").code,
            EnsureSurfaceErrorCode::DuplicateRequestId as i32
        );
    }
}
