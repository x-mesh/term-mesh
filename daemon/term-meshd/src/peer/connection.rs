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
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use peer_proto::v1::envelope::Payload;
use peer_proto::v1::{
    workspace_update, AttachMode, AttachResult, AuthChallenge, AuthResult, CreateWorkspaceResponse,
    EnsureSurfaceError as WireEnsureError, EnsureSurfaceErrorCode, EnsureSurfaceRequest,
    EnsureSurfaceResponse, EnsureSurfaceRestartPolicy, EnsureSurfaceResult, Envelope, Error,
    GridSnapshot, Hello, HostStats, Pong, PtyData, ScrollbackChunk, SurfaceExited, SurfaceList,
    Team, TeamCallResponse, TeamList, TeamMember, TerminateSurfaceError as WireTerminateError,
    TerminateSurfaceErrorCode, TerminateSurfaceRequest, TerminateSurfaceResponse,
    TerminateSurfaceResult, UpsertProjectPresentationResponse, Workspace, WorkspaceList,
    WorkspaceListChanged, WorkspaceMeta, WorkspaceUpdate,
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
    EnsureDisposition, EnsureError, EnsureOutcome, EnsureRestartPolicy, PtyChunk, PtySurface,
    ResumeReplay, SurfaceKind, SurfaceSpec,
};
use crate::headless::cli_builder::executable_bin_dir;
use crate::monitor::SystemSnapshot;

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
    // This connection's key in each surface's winsize-arbitration map (one
    // attach per surface per connection, so connection identity is enough).
    // Every size this client sends goes through `request_size` under this id
    // and is dropped again on detach/disconnect, so a departing viewer
    // returns the grid to the survivors instead of leaving its size behind.
    static NEXT_SIZE_REQUESTER: AtomicU64 = AtomicU64::new(1);
    let size_requester = NEXT_SIZE_REQUESTER.fetch_add(1, Ordering::Relaxed);
    // Request ids are one-shot for the authenticated connection. Insert before
    // starting work so two back-to-back frames cannot race through ensure.
    let mut lifecycle_request_ids: HashSet<Vec<u8>> = HashSet::new();
    // Acquired by the reader before an ensure task is spawned. Waiting here
    // applies socket backpressure instead of accumulating unbounded queued
    // tasks while keeping up to this many independent keys concurrent.
    let ensure_work_gate = EnsureWorkGate::new();
    let ensure_worker: EnsureWorker = {
        let host = host.clone();
        Arc::new(move |key, spec, env| {
            if spec.kind == SurfaceKind::Agent {
                host.pty.ensure_with_env(&key, &spec, &env)
            } else if env.is_empty() {
                host.ensure_surface(&key, &spec)
            } else {
                // Environment-bearing ensured surfaces are native agents in
                // this protocol version; do not silently create an untracked
                // terminal outside the workspace layout.
                Err(EnsureError::Internal("terminal ensure env is unsupported"))
            }
        })
    };
    let terminate_worker: TerminateWorker = {
        let host = host.clone();
        Arc::new(move |surface_id| host.terminate_surface(&surface_id))
    };
    // RAII registration with the layout broadcaster; populated when the
    // handshake reaches Ready, dropped (= unregistered) with this frame.
    // Underscore: the binding exists for its Drop, it is never read.
    let mut broadcast_guard: Option<layout::BroadcastGuard> = None;
    // Shared with the Broadcaster so a roster push can skip connections that
    // never subscribed. Written here, read there.
    let wants_workspace_roster = Arc::new(AtomicBool::new(false));
    // Started at Ready for a client that asked for stats; aborted when this
    // loop returns, on every exit path (see the abort below).
    let mut host_stats_task: Option<JoinHandle<()>> = None;
    // Parsed once out of the client's Hello and kept for the rest of the
    // connection — plumbing only for now (see P3, docs/peer-perf-proposal.md):
    // nothing branches on it yet, but future wire changes (P8 and later)
    // need somewhere to ask "does this peer support X" before using it.
    // The `default()` placeholder is intentionally never read before the
    // Init/Hello arm overwrites it — a connection that drops before
    // sending Hello never reaches any arm that would consult it either.
    #[allow(unused_assignments)]
    let mut peer_capabilities = PeerCapabilities::default();
    let mut peer_id = Vec::new();
    // Current identity followed by bounded rotation aliases. Aliases are
    // consulted only for durable Project presentation ownership.
    let mut project_owner_peer_ids: Vec<Vec<u8>> = Vec::new();

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
                if hello.peer_id.len() != 16 {
                    send_error(&outgoing_tx, 102, "peer_id must be 16 bytes").await;
                    break;
                }
                if hello.project_owner_aliases.len() > 8
                    || hello.project_owner_aliases.iter().any(|id| id.len() != 16)
                {
                    send_error(
                        &outgoing_tx,
                        102,
                        "project_owner_aliases must contain at most 8 16-byte ids",
                    )
                    .await;
                    break;
                }
                peer_id = hello.peer_id;
                project_owner_peer_ids = vec![peer_id.clone()];
                for alias in hello.project_owner_aliases {
                    if !project_owner_peer_ids.contains(&alias) {
                        project_owner_peer_ids.push(alias);
                    }
                }
                peer_capabilities = PeerCapabilities::from_hello(hello.capabilities);
                tracing::debug!(
                    "peer capabilities: {:?} (ptydata.coalesce.v1={} replay.ring.v1={})",
                    peer_capabilities,
                    peer_capabilities.has(capability::PTYDATA_COALESCE_V1),
                    peer_capabilities.has(capability::REPLAY_RING_V1)
                );

                send(
                    &outgoing_tx,
                    host_hello(&seq_counter, host.team_manager().is_some()),
                )
                .await?;
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
                broadcast_guard = Some(host.clients.register_with_roster_flag(
                    outgoing_tx.clone(),
                    seq_counter.clone(),
                    peer_id.clone(),
                    Arc::clone(&wants_workspace_roster),
                ));
                // Only for a client that advertised host.stats.v1; everyone
                // else costs nothing. Aborted on teardown below rather than
                // left to notice the closed channel on its next sample.
                host_stats_task = spawn_host_stats_push(
                    &host,
                    &peer_capabilities,
                    outgoing_tx.clone(),
                    seq_counter.clone(),
                );
                tracing::info!("peer authenticated (ssh-passthrough)");
            }

            (HandshakeState::AuthSent, _) => {
                send_error(&outgoing_tx, 103, "expected Auth").await;
                break;
            }

            (HandshakeState::Ready, Payload::ListSurfaces(_)) => {
                // surface.agent.v1 gate (a) of two — see peer.proto's
                // SurfaceInfo: to a client that did not advertise the
                // capability, an agent surface is reported with
                // `attachable = false` so an older viewer's existing
                // attachable filter hides it for free, and it never feeds
                // an NDJSON stream to a terminal renderer. The row itself
                // still travels (type, title, cwd) — only attach is off
                // the table. Gate (b) is the AttachSurface refusal below,
                // for a client that ignores the listing.
                let agent_capable = peer_capabilities.has(capability::SURFACE_AGENT_V1);
                let surfaces = manager
                    .list()
                    .iter()
                    .map(|s| {
                        let mut info = s.info();
                        if !agent_capable && s.kind() == SurfaceKind::Agent {
                            info.attachable = false;
                        }
                        info
                    })
                    .collect();
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
                    &peer_capabilities,
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

            (HandshakeState::Ready, Payload::ListTeams(_)) => {
                // A team is invisible in the layout tree — it is a fact about
                // which pane leads which work, not about how panes are
                // arranged — so a client that wants to know where a project's
                // leader sits has no way to derive it from workspaces alone.
                // This answers that and nothing else: no command crosses here.
                let mut teams = match host.team_manager() {
                    Some(manager) => {
                        let guard = manager.lock().await;
                        guard
                            .list_teams()
                            .into_iter()
                            .map(|team| Team {
                                name: team.name.clone(),
                                team_uuid: team.team_uuid.clone(),
                                working_directory: team.working_directory.clone(),
                                project_root: super::layout::project_root_for(
                                    &team.working_directory,
                                ),
                                agent_names: team.agents.clone(),
                                created_at_unix_secs: team.created_at,
                                ..Default::default()
                            })
                            .collect()
                    }
                    // A host built without a team manager advertises no
                    // team.roster.v1, so this is only reachable from a client
                    // that asked anyway; an empty roster is the honest answer.
                    None => Vec::new(),
                };
                let live_surfaces: HashMap<Vec<u8>, peer_proto::v1::SurfaceInfo> = host
                    .pty
                    .list()
                    .into_iter()
                    .filter_map(|surface| {
                        let info = surface.info();
                        let mut info = info;
                        info.foreground_busy_known = peer_capabilities
                            .has(capability::SURFACE_FOREGROUND_V1);
                        info.attachable.then_some((surface.surface_id.clone(), info))
                    })
                    .collect();
                let project_owner_hex: HashSet<String> =
                    project_owner_peer_ids.iter().map(hex::encode).collect();
                for manifest in host.project_presentations() {
                    let Ok(leader_surface_id) = hex::decode(&manifest.leader_surface_id) else {
                        continue;
                    };
                    let members = manifest
                        .members
                        .iter()
                        .filter_map(|member| {
                            let surface_id = hex::decode(&member.surface_id).ok()?;
                            live_surfaces
                                .contains_key(&surface_id)
                                .then_some(TeamMember {
                                    name: member.name.clone(),
                                    agent_instance_id: member.agent_instance_id.clone(),
                                    cli: member.cli.clone(),
                                    model: member.model.clone(),
                                    agent_type: member.agent_type.clone(),
                                    color: member.color.clone(),
                                    working_directory: member.working_directory.clone(),
                                    surface_id,
                                    surface_type: member.surface_type.clone(),
                                })
                        })
                        .collect::<Vec<TeamMember>>();
                    if let Some(team) = teams
                        .iter_mut()
                        .find(|team| team.team_uuid == manifest.team_uuid)
                    {
                        team.project_id = manifest.project_id;
                        team.leader_surface_id = leader_surface_id;
                        team.agent_names =
                            members.iter().map(|member| member.name.clone()).collect();
                        team.members = members;
                        team.presentation_revision = manifest.revision;
                        team.delegation_configured = manifest.delegation_configured;
                        team.delegation_effective = manifest.delegation_effective;
                        team.delegation_pending = manifest.delegation_pending;
                        team.leader_cli = manifest.leader_cli;
                        team.leader_model = manifest.leader_model;
                        team.created_at_unix_secs = manifest.created_at_unix_secs;
                        team.presentation_owned_by_requester =
                            project_owner_hex.contains(&manifest.owner_peer_id);
                        if let Some(info) = live_surfaces.get(&team.leader_surface_id) {
                            team.leader_process_active = info.foreground_busy;
                            team.leader_process_active_known = info.foreground_busy_known;
                        } else {
                            // The surface roster is authoritative: a durable
                            // manifest may outlive its processes across a
                            // daemon restart, and that absence is itself a
                            // known inactive state. Keep the persisted leader
                            // id so the owner can classify and bootstrap it.
                            team.leader_process_active = false;
                            team.leader_process_active_known = true;
                        }
                        if team.project_root.is_empty() {
                            team.project_root = manifest.project_root;
                        }
                    } else {
                        let leader_info = live_surfaces.get(&leader_surface_id);
                        teams.push(Team {
                            name: manifest.team_name,
                            team_uuid: manifest.team_uuid,
                            working_directory: manifest.working_directory,
                            project_root: manifest.project_root,
                            agent_names: members.iter().map(|member| member.name.clone()).collect(),
                            created_at_unix_secs: manifest.created_at_unix_secs,
                            leader_surface_id,
                            members,
                            project_id: manifest.project_id,
                            presentation_revision: manifest.revision,
                            presentation_owned_by_requester: project_owner_hex
                                .contains(&manifest.owner_peer_id),
                            leader_process_active: leader_info
                                .is_some_and(|info| info.foreground_busy),
                            leader_process_active_known: leader_info
                                .map_or(true, |info| info.foreground_busy_known),
                            delegation_configured: manifest.delegation_configured,
                            delegation_effective: manifest.delegation_effective,
                            delegation_pending: manifest.delegation_pending,
                            leader_cli: manifest.leader_cli,
                            leader_model: manifest.leader_model,
                        });
                    }
                }
                let reply = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: env.seq,
                    payload: Some(Payload::TeamList(TeamList { teams })),
                };
                send(&outgoing_tx, reply).await?;
            }

            (HandshakeState::Ready, Payload::UpsertProjectPresentationRequest(request)) => {
                let (response, presentation_changed) = if !peer_capabilities
                    .has(capability::PROJECT_PRESENTATION_V1)
                {
                    (
                        UpsertProjectPresentationResponse {
                            request_id: request.request_id,
                            ok: false,
                            error_code: "capability_unavailable".into(),
                            error_message: "project.presentation.v1 was not negotiated".into(),
                            ..Default::default()
                        },
                        false,
                    )
                } else if request.request_id.len() != 16 {
                    (
                        UpsertProjectPresentationResponse {
                            request_id: request.request_id,
                            ok: false,
                            error_code: "invalid_request".into(),
                            error_message: "request_id must be 16 bytes".into(),
                            ..Default::default()
                        },
                        false,
                    )
                } else if !lifecycle_request_ids.insert(request.request_id.clone()) {
                    (
                        UpsertProjectPresentationResponse {
                            request_id: request.request_id,
                            ok: false,
                            error_code: "duplicate_request_id".into(),
                            error_message: "request_id was already used on this connection".into(),
                            ..Default::default()
                        },
                        false,
                    )
                } else if !request.delete_project_id.is_empty() {
                    if request.project.is_some() {
                        (
                            UpsertProjectPresentationResponse {
                                request_id: request.request_id,
                                ok: false,
                                error_code: "invalid_manifest".into(),
                                error_message:
                                    "project and delete_project_id are mutually exclusive".into(),
                                ..Default::default()
                            },
                            false,
                        )
                    } else {
                        // Retiring a manifest also drops the durable reference
                        // that kept its surfaces out of the abandoned-surface
                        // reap, so each one is re-evaluated here; otherwise a
                        // deleted project would strand every spawned pane it
                        // had named. The ids come back FROM the delete rather
                        // than from a read before it: the record removed under
                        // the lock is the only one whose surfaces this call may
                        // release, and a concurrent replace must not be able to
                        // redirect the reap at another manifest's panes.
                        match host.delete_project_presentation_with_released(
                            &project_owner_peer_ids,
                            &request.delete_project_id,
                        ) {
                            Ok(released) => {
                                let changed = released.is_some();
                                (
                                    UpsertProjectPresentationResponse {
                                        request_id: request.request_id,
                                        ok: true,
                                        ..Default::default()
                                    },
                                    changed,
                                )
                            }
                            Err(code) => (
                                UpsertProjectPresentationResponse {
                                    request_id: request.request_id,
                                    ok: false,
                                    error_code: code.into(),
                                    error_message: "project presentation deletion was rejected"
                                        .into(),
                                    ..Default::default()
                                },
                                false,
                            ),
                        }
                    }
                } else if let Some(project) = request.project.as_ref() {
                    match host
                        .upsert_project_presentation_with_released(&project_owner_peer_ids, project)
                    {
                        Ok((revision, changed, released)) => {
                            for surface_id in &released {
                                reap_if_abandoned(&host, surface_id);
                            }
                            (
                                UpsertProjectPresentationResponse {
                                    request_id: request.request_id,
                                    ok: true,
                                    revision,
                                    ..Default::default()
                                },
                                changed,
                            )
                        }
                        Err(code) => (
                            UpsertProjectPresentationResponse {
                                request_id: request.request_id,
                                ok: false,
                                error_code: code.into(),
                                error_message: "project presentation was rejected".into(),
                                ..Default::default()
                            },
                            false,
                        ),
                    }
                } else {
                    (
                        UpsertProjectPresentationResponse {
                            request_id: request.request_id,
                            ok: false,
                            error_code: "invalid_manifest".into(),
                            error_message: "project is required".into(),
                            ..Default::default()
                        },
                        false,
                    )
                };
                send(
                    &outgoing_tx,
                    Envelope {
                        seq: next_seq(&seq_counter),
                        correlation_id: env.seq,
                        payload: Some(Payload::UpsertProjectPresentationResponse(response)),
                    },
                )
                .await?;
                if presentation_changed {
                    // The workspace roster stream also acts as a cheap
                    // invalidation signal for the team roster. Its payload is
                    // already understood by connected clients, which then
                    // perform a debounced ListTeams refresh.
                    host.broadcast_workspace_roster();
                }
            }

            (HandshakeState::Ready, Payload::TeamCallRequest(request)) => {
                // The allow-list is the security boundary of team.call.v1,
                // uniform across host types (mirror of the Swift host's
                // PeerTeamCall). It is checked HERE, before anything touches
                // the manager: a refusal must not depend on the translation
                // below being reached.
                let response = if !team_call_allowed(&request.method) {
                    TeamCallResponse {
                        ok: false,
                        result_json: String::new(),
                        error_code: "method_not_allowed".to_string(),
                        error_message: format!("{} is not callable by a peer", request.method),
                    }
                } else if let Some(manager) = host.team_manager() {
                    run_headless_team_call(
                        &manager,
                        host.agent_store().as_ref(),
                        &request.method,
                        &request.params_json,
                    )
                    .await
                } else {
                    TeamCallResponse {
                        ok: false,
                        result_json: String::new(),
                        error_code: "host_error".to_string(),
                        error_message: "host has no team subsystem".to_string(),
                    }
                };
                let reply = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: env.seq,
                    payload: Some(Payload::TeamCallResponse(response)),
                };
                send(&outgoing_tx, reply).await?;
            }

            (HandshakeState::Ready, Payload::TeamLeaderCommandResponse(response)) => {
                // Only the exact connection that received the reverse request
                // may satisfy it, and it must echo that request envelope's seq
                // as correlation_id. A sibling or hostile viewer cannot win a
                // request_id race.
                if let Some(guard) = &broadcast_guard {
                    let accepted = host.clients.resolve_team_leader(
                        guard.connection_id(),
                        env.correlation_id,
                        response,
                    );
                    if !accepted {
                        tracing::warn!("ignored mismatched peer leader response");
                    }
                }
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

            (HandshakeState::Ready, Payload::SubscribeWorkspaceList(_)) => {
                // The first pushed snapshot is the subscription acknowledgement
                // and authoritative baseline. It avoids a response RPC racing
                // the receive loop that will consume future pushes.
                if !peer_capabilities.has(capability::WORKSPACE_LIST_SUBSCRIBE_V1) {
                    send_error(
                        &outgoing_tx,
                        106,
                        "workspace roster subscription not negotiated",
                    )
                    .await;
                    continue;
                }
                // Flip before the baseline goes out. Layout pushes only reach
                // subscribers now, so a connection that never asks stays out
                // of the roster fan-out entirely.
                wants_workspace_roster.store(true, Ordering::Relaxed);
                let workspaces = host.workspace_roster();
                send(
                    &outgoing_tx,
                    Envelope {
                        seq: next_seq(&seq_counter),
                        correlation_id: 0,
                        payload: Some(Payload::WorkspaceListChanged(WorkspaceListChanged {
                            workspaces,
                        })),
                    },
                )
                .await?;
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
                // surface.agent.v1 gate (b) of two: a client that did not
                // advertise the capability MUST NOT be attached to an agent
                // surface — its renderer would paint the NDJSON stream as
                // terminal bytes. Refused explicitly (spec: peer.proto's
                // SurfaceInfo, docs/peer-federation-protocol.md) rather than
                // silently, so a misbehaving client that skipped the
                // ListSurfaces attachable filter gets a diagnosable answer.
                // Decided BEFORE `get_or_respawn`, from the registry alone
                // (`registered_kind`: current instance or respawn spec, no
                // spawning): a refused attach must not revive a dead
                // declared agent surface as a side effect — that would
                // manufacture an orphan child the refused client could
                // never reach. Unknown ids answer `None` here and fall
                // through to the "surface not found" reply below.
                if !peer_capabilities.has(capability::SURFACE_AGENT_V1)
                    && manager.registered_kind(&req.surface_id) == Some(SurfaceKind::Agent)
                {
                    let reply = Envelope {
                        seq: next_seq(&seq_counter),
                        correlation_id: env.seq,
                        payload: Some(Payload::AttachResult(AttachResult {
                            accepted: false,
                            reason: "agent surface requires capability surface.agent.v1".into(),
                            surface_id: req.surface_id.clone(),
                            initial_seq: 0,
                            granted_mode: AttachMode::Unspecified as i32,
                        })),
                    };
                    send(&outgoing_tx, reply).await?;
                    continue;
                }

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

                // Gate (b) re-checked on the actual instance: the registry
                // answer above is not atomic with the respawn — a terminate +
                // re-ensure under the same key can flip the kind in between
                // (the deterministic surface id survives the flip). The
                // pre-respawn check prevents the spawn side effect; this one
                // is the authoritative refusal.
                if !peer_capabilities.has(capability::SURFACE_AGENT_V1)
                    && surface.kind() == SurfaceKind::Agent
                {
                    let reply = Envelope {
                        seq: next_seq(&seq_counter),
                        correlation_id: env.seq,
                        payload: Some(Payload::AttachResult(AttachResult {
                            accepted: false,
                            reason: "agent surface requires capability surface.agent.v1".into(),
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

                // Register the client-requested size with the surface's
                // winsize arbitration (min across attachers, tmux-style) —
                // see `PtySurface::request_size`.
                if let Some((cols, rows)) = clamp_pty_size(req.client_cols, req.client_rows) {
                    if let Err(e) = surface.request_size(size_requester, cols, rows, false) {
                        tracing::warn!("resize on attach failed: {e}");
                    }
                }

                let granted =
                    match AttachMode::try_from(req.mode).unwrap_or(AttachMode::Unspecified) {
                        AttachMode::CoWrite | AttachMode::TakeOver => AttachMode::CoWrite,
                        _ => AttachMode::ReadOnly,
                    };

                // R1 (peer-relay-bulk-loss): resolve the resume request and
                // capture the exact snapshot the relay task below will
                // stream, in this same synchronous spot — see
                // `spawn_attach_relay`'s doc comment for the full wire↔host
                // seq mapping this sets up. `subscribe()` MUST happen before
                // the replay snapshot is read (not after): any PTY output
                // produced in between land in both, and `spawn_attach_relay`
                // dedupes the overlap via `live_min_seq` — reversing the
                // order would open a window where such bytes land in
                // neither and are lost.
                let resume_from_seq =
                    effective_resume_from_seq(&peer_capabilities, req.resume_from_seq);
                let subscriber = surface.subscribe();
                // Three-way split (tmux model):
                // - Resume asks for an exact range and is served from the
                //   full ring — the client already has a screen and wants
                //   the missing bytes, not a re-render.
                // - A fresh attach gets the CURRENT SCREEN, rendered by the
                //   host's own emulator (`screen_snapshot`). Replaying byte
                //   history here was the root of two bugs at once: the full
                //   ring re-streamed an old `find` on every open, and the
                //   bounded 64 KiB tail blanked idle TUIs whose last full
                //   repaint had scrolled out of the window.
                // - `TERMMESH_PEER_FRESH_ATTACH_MODE=bytes` (or a poisoned
                //   screen lock) falls back to the pre-snapshot tail so the
                //   new path is revertible in the field without a rebuild.
                // - An AGENT surface takes the byte paths by construction,
                //   with no kind branch here: `screen_snapshot()` is `None`
                //   (no grid → never a typed GridSnapshot, whatever the
                //   client advertised), `mode_replay_bytes()` is empty (no
                //   DEC modes → no mode-prefix frame), and the earlier
                //   `request_size` was a no-op (no winsize). A fresh attach
                //   replays the ring tail — chunks are whole NDJSON lines
                //   (the agent reader pushes line-aligned, splitting only a
                //   line over AGENT_CHUNK_MAX_BYTES so no frame can breach
                //   MAX_FRAME_BYTES), and the tail cuts on chunk
                //   boundaries, so a reconnect can never split an
                //   ordinarily-sized event in half. Resume/replay-ring
                //   semantics below are byte-identical to a terminal
                //   surface.
                //
                // The snapshot is packaged as a single synthetic `PtyChunk`
                // whose `seq` is BACKDATED by its own length — the same
                // wrapping trick the Swift host uses (`tapSeq &- count`,
                // GhosttyPaneSurfaceProvider). `live_min_seq` (chunk end)
                // then lands exactly on `snap_seq`, so live-chunk dedup and
                // `initial_seq` fall out of the existing arithmetic below
                // with no special cases. May wrap on a young surface; the
                // client's resume math is wrapping too (`&+`), so the
                // round-trip stays exact.
                // A grid.snapshot.v1 client gets the screen as a TYPED
                // GridSnapshot message instead of untyped PtyData — that is
                // what lets it clear stale local scrollback (ESC[3J) and
                // reset its wire-gap baseline, neither of which is safe to
                // infer from a byte stream. Everyone else gets the same
                // bytes on the Stage-1 PtyData path.
                let typed_snapshot_ok = peer_capabilities.has(capability::GRID_SNAPSHOT_V1);
                // (untyped ANSI chunks, typed (ansi, snap_seq) — exactly one
                // of the two carries the fresh screen.)
                let (replay, typed_snapshot) = if resume_from_seq != 0 {
                    match surface.replay_snapshot_from(resume_from_seq) {
                        ResumeReplay::Exact(bytes) => (bytes, None),
                        // A terminal resume outside the retained ring must
                        // repaint the current screen. Feeding the ring tail
                        // into an existing viewer re-executes cursor controls
                        // and makes old output visibly scroll past again.
                        ResumeReplay::Unavailable if surface.kind() == SurfaceKind::Pty => {
                            match surface.screen_snapshot() {
                                Some((bytes, snap_seq))
                                    if !bytes.is_empty() && typed_snapshot_ok =>
                                {
                                    (Vec::new(), Some((bytes, snap_seq)))
                                }
                                Some((bytes, snap_seq)) if !bytes.is_empty() => (
                                    vec![PtyChunk {
                                        seq: snap_seq.wrapping_sub(bytes.len() as u64),
                                        bytes,
                                    }],
                                    None,
                                ),
                                _ => (Vec::new(), None),
                            }
                        }
                        // AgentSession restarts its non-idempotent NDJSON
                        // consumer when initial_seq differs from the requested
                        // resume point, so retaining the old full-ring fallback
                        // is correct for agent surfaces.
                        ResumeReplay::Unavailable => (surface.replay_snapshot(), None),
                    }
                } else if fresh_attach_uses_bytes() {
                    (surface.replay_snapshot_fresh(), None)
                } else {
                    match surface.screen_snapshot() {
                        Some((bytes, snap_seq)) if !bytes.is_empty() && typed_snapshot_ok => {
                            (Vec::new(), Some((bytes, snap_seq)))
                        }
                        Some((bytes, snap_seq)) if !bytes.is_empty() => {
                            // Untyped path: package as a single synthetic
                            // PtyChunk whose seq is BACKDATED by its own
                            // length — the Swift host's wrapping trick — so
                            // live_min_seq (chunk end) lands exactly on
                            // snap_seq and dedup/initial_seq fall out of the
                            // existing arithmetic. May wrap on a young
                            // surface; the client's resume math wraps too.
                            (
                                vec![PtyChunk {
                                    seq: snap_seq.wrapping_sub(bytes.len() as u64),
                                    bytes,
                                }],
                                None,
                            )
                        }
                        _ => (surface.replay_snapshot_fresh(), None),
                    }
                };
                // On the typed path the mode prefix (mouse DECSET 1015/1016,
                // which vt100 does not model) is folded into the snapshot's
                // own ANSI instead of riding a separate wire-seq-0 PtyData:
                // the snapshot already re-establishes every other input mode,
                // and a typed client starts its wire space at the first LIVE
                // byte.
                let mode_prefix = if typed_snapshot.is_some() {
                    Vec::new()
                } else {
                    surface.mode_replay_bytes()
                };
                // Absolute host seq (`PtyChunk::seq` space) that this
                // attach's wire `byte_seq == 0` maps to, reported back as
                // `initial_seq` so the client can translate any wire
                // byte_seq `w` it later observes into that same absolute
                // space via `initial_seq + w` — the value it must send back
                // as a future `resume_from_seq`. Not the seq of the first
                // wire byte itself: `mode_prefix` bytes are synthetic
                // (re-derived escape codes, never counted in host seq
                // space) and are prepended ahead of seq 0 the same way
                // they're prepended ahead of wire byte_seq 0 below, so the
                // real data's baseline is pushed back by their length.
                //
                // Typed path: the snapshot spends no wire seq at all, so
                // wire 0 IS the snapshot's consistency point.
                let initial_seq = match &typed_snapshot {
                    Some((_, snap_seq)) => *snap_seq,
                    None => {
                        let attach_base = replay
                            .first()
                            .map(|chunk| chunk.seq)
                            .unwrap_or_else(|| surface.current_byte_seq());
                        attach_base.saturating_sub(mode_prefix.len() as u64)
                    }
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

                // Typed keyframe, right after AttachResult and ahead of the
                // relay task's live stream, so the first thing a
                // grid.snapshot.v1 client renders is the screen. The mouse
                // DECSET prefix (1015/1016 — the two modes vt100 does not
                // model) is folded in ahead of the render; every other input
                // mode is already inside `state_formatted()`'s output.
                let snapshot_floor = match &typed_snapshot {
                    Some((snapshot_bytes, snap_seq)) => {
                        let mut ansi = surface.mode_replay_bytes();
                        ansi.extend_from_slice(snapshot_bytes);
                        let grid_env = Envelope {
                            seq: next_seq(&seq_counter),
                            correlation_id: 0,
                            payload: Some(Payload::GridSnapshot(GridSnapshot {
                                surface_id: req.surface_id.clone(),
                                byte_seq: *snap_seq,
                                cols: surface.cols.load(Ordering::Relaxed),
                                rows: surface.rows.load(Ordering::Relaxed),
                                alt_screen: snapshot_bytes.starts_with(b"\x1b[?1049h"),
                                cursor: None,
                                ansi,
                            })),
                        };
                        send(&outgoing_tx, grid_env).await?;
                        *snap_seq
                    }
                    None => 0,
                };

                // Push an initial WorkspaceMeta snapshot so the client can
                // show the remote surface's cwd / branch immediately. Future
                // dynamic updates (branch changed, ports opened) would ride
                // the same channel.
                let attach_info = surface.info();
                let meta_env = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: 0,
                    payload: Some(Payload::WorkspaceUpdate(WorkspaceUpdate {
                        kind: Some(workspace_update::Kind::Meta(WorkspaceMeta {
                            branch: attach_info.branch,
                            cwd: attach_info.cwd,
                            ports: vec![],
                            latest_notification: String::new(),
                        })),
                    })),
                };
                send(&outgoing_tx, meta_env).await?;

                let entry = spawn_attach_relay(
                    surface.clone(),
                    outgoing_tx.clone(),
                    seq_counter.clone(),
                    subscriber,
                    replay,
                    mode_prefix,
                    snapshot_floor,
                    peer_capabilities.has(capability::SURFACE_EXIT_V1),
                );
                host.pty.note_attached(&req.surface_id);
                attached.insert(req.surface_id, entry);
            }

            (HandshakeState::Ready, Payload::ScrollbackRequest(req)) => {
                // Part of the grid model (capability "grid.snapshot.v1"):
                // only a client that renders the typed snapshot has the
                // empty local scrollback these windows fill. A request from
                // anyone else — or for a surface this connection has not
                // attached — is dropped, matching the Ready-state
                // unhandled-payload convention rather than erroring.
                if !peer_capabilities.has(capability::GRID_SNAPSHOT_V1) {
                    continue;
                }
                let Some(entry) = attached.get(&req.surface_id) else {
                    continue;
                };
                let Some((ansi, effective, at_top, total)) =
                    entry.surface.scrollback_render(req.offset_rows)
                else {
                    continue;
                };
                let reply = Envelope {
                    seq: next_seq(&seq_counter),
                    correlation_id: env.seq,
                    payload: Some(Payload::ScrollbackChunk(ScrollbackChunk {
                        surface_id: req.surface_id.clone(),
                        offset_rows: effective,
                        ansi,
                        at_top,
                        total_scrollback_rows: total,
                    })),
                };
                send(&outgoing_tx, reply).await?;
            }

            (HandshakeState::Ready, Payload::DetachSurface(det)) => {
                if let Some(entry) = attached.remove(&det.surface_id) {
                    reap_if_abandoned(&host, &det.surface_id);
                    entry.surface.drop_size_request(size_requester);
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
                        // Typing marks this connection as the one driving the
                        // PTY, which is what wins winsize arbitration — see
                        // `PtySurface::note_input`. Before the write, so a
                        // size-sensitive redraw the input provokes already
                        // happens at the typist's size.
                        //
                        // Both calls are kind-routed inside the surface: on
                        // an agent surface `note_input` is a no-op (no
                        // winsize to arbitrate) and the write lands on the
                        // agent child's stdin instead of a PTY master —
                        // that is how a viewer's turn input reaches the
                        // bridge. Mouse stays ignored for both kinds.
                        entry.surface.note_input(size_requester);
                        if let Err(e) = write_surface_input(entry.surface.clone(), keys).await {
                            tracing::warn!("PTY write failed: {e}");
                            send_surface_input_error(
                                &outgoing_tx,
                                &seq_counter,
                                env.seq,
                                &input.surface_id,
                                &e,
                            )
                            .await?;
                        }
                    }
                    Some(peer_proto::v1::input::Kind::Paste(p)) => {
                        entry.surface.note_input(size_requester);
                        if let Err(e) = write_surface_input(entry.surface.clone(), p.text).await {
                            tracing::warn!("PTY paste-write failed: {e}");
                            send_surface_input_error(
                                &outgoing_tx,
                                &seq_counter,
                                env.seq,
                                &input.surface_id,
                                &e,
                            )
                            .await?;
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
                    if let Err(e) =
                        entry
                            .surface
                            .request_size(size_requester, cols, rows, r.claim_authority)
                    {
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

    for (surface_id, entry) in attached.drain() {
        entry.surface.drop_size_request(size_requester);
        entry.cancel.notify_one();
        let _ = entry.task.await;
        // Whether the peer said goodbye or its process vanished, this
        // connection is no longer holding the surface.
        reap_if_abandoned(&host, &surface_id);
    }
    // Aborted rather than awaited: it is parked on the monitor's next
    // sample, which is seconds away, and it holds nothing that needs
    // unwinding.
    if let Some(task) = host_stats_task.take() {
        task.abort();
    }
    Ok(())
}

/// Flatten one monitor sample into the wire shape.
///
/// Per-interface and per-disk detail is summed away on purpose: a viewer
/// showing "how busy is that machine" wants one number per axis, and
/// sending the full breakdown would put an unbounded list on a message
/// that repeats every couple of seconds.
fn host_stats_from(snapshot: &SystemSnapshot) -> HostStats {
    let (net_rx, net_tx) = snapshot
        .network_io
        .iter()
        .fold((0f64, 0f64), |(rx, tx), io| {
            (rx + io.rx_rate, tx + io.tx_rate)
        });
    HostStats {
        // `load_avg` is [1m, 5m, 15m]. All three travel: the 1-minute
        // figure says how busy the machine is, and the other two say
        // whether that is a spike or a trend.
        load_1m: snapshot.load_avg[0],
        load_5m: snapshot.load_avg[1],
        load_15m: snapshot.load_avg[2],
        cpu_count: snapshot.cpu_count as u32,
        memory_percent: snapshot.memory_percent,
        memory_used_bytes: snapshot.used_memory_bytes,
        memory_total_bytes: snapshot.total_memory_bytes,
        disk_read_bytes_per_sec: snapshot.disk_read_bytes_per_sec,
        disk_write_bytes_per_sec: snapshot.disk_write_bytes_per_sec,
        // Rates are already per-second and non-negative; the cast is only
        // narrowing a float the monitor computed by dividing a byte delta.
        net_rx_bytes_per_sec: net_rx.max(0.0) as u64,
        net_tx_bytes_per_sec: net_tx.max(0.0) as u64,
        // Absolute capacity, so a viewer can warn before a peer runs out of
        // room. Zero total means the host could not measure it.
        disk_total_bytes: snapshot.disk_total_bytes,
        disk_available_bytes: snapshot.disk_available_bytes,
    }
}

/// Forward the host's system stats to one client for as long as it stays
/// connected.
///
/// Driven by the monitor's own sampling rather than a timer of its own, so
/// the wire cadence is whatever the daemon already measures at and a
/// connection never pushes a value it has already sent. Returning without
/// spawning is the normal path for a client that did not ask for stats.
fn spawn_host_stats_push(
    host: &Arc<PeerHost>,
    peer_capabilities: &PeerCapabilities,
    outgoing_tx: mpsc::Sender<Envelope>,
    seq_counter: Arc<AtomicU64>,
) -> Option<JoinHandle<()>> {
    if !peer_capabilities.has(capability::HOST_STATS_V1) {
        return None;
    }
    let mut monitor_rx = host.monitor_receiver()?;

    Some(tokio::spawn(async move {
        loop {
            // Waits for a sample the monitor produced after this receiver
            // last looked, so a slow client cannot accumulate a backlog of
            // identical frames.
            if monitor_rx.changed().await.is_err() {
                return; // monitor gone: daemon is shutting down
            }
            let Some(stats) = monitor_rx.borrow_and_update().as_ref().map(host_stats_from) else {
                continue; // no sample taken yet
            };
            let env = Envelope {
                seq: next_seq(&seq_counter),
                correlation_id: 0,
                payload: Some(Payload::HostStats(stats)),
            };
            // A closed channel means the connection is gone; stats are the
            // least important thing on it, so give up rather than retry.
            if outgoing_tx.send(env).await.is_err() {
                return;
            }
        }
    }))
}

/// Whether an `AttachSurface.resume_from_seq` should be honored for this
/// peer, or ignored in favor of a fresh full-snapshot attach.
///
/// ## The wire↔host seq mapping (R1, peer-relay-bulk-loss)
///
/// Two seq spaces meet at this boundary and must not be confused:
///
/// - **Wire `byte_seq`** (`PtyData.byte_seq`, `attach_seq` below): reset to
///   0 at the start of EVERY attach (see the loop below), then advanced by
///   real bytes sent AND by any broadcast-`Lagged` gap width — so it stays
///   a faithful, self-consistent counter for gap detection within one
///   attach, but a value observed on one attach means nothing on the next.
/// - **Host absolute seq** (`PtyChunk::seq`, `PtySurface::byte_seq`): a
///   single monotonic counter for the surface's entire lifetime, shared by
///   every attach. This is what `ReplayBuffer`/`replay_snapshot_from` cut
///   on.
///
/// `resume_from_seq` and `AttachResult.initial_seq` are defined to live in
/// the **host absolute** space, not the wire space — this is the missing
/// half that makes the pairing usable: `initial_seq` tells the client the
/// absolute seq its wire `byte_seq == 0` corresponds to for THIS attach, so
/// for any wire `byte_seq = w` it later processes it can compute the
/// absolute position as `initial_seq + w` — entirely client-side, with no
/// host state to remember across a dead attach. When the client reattaches
/// after a gap, it sends that computed absolute value back as
/// `resume_from_seq`, and the host below can pass it straight to
/// `replay_snapshot_from` — no further conversion needed, because the
/// client already did the translation using the seq mapping this attach
/// establishes.
///
/// Gated on `replay.ring.v1`: a peer that never advertised it may predate
/// this mapping entirely (e.g. it could carry a stale/unrelated value in
/// the field), so a nonzero `resume_from_seq` from it is ignored rather
/// than trusted — falls back to a fresh full-snapshot attach, exactly
/// today's pre-resume behavior. Old-peer fallback nuance beyond this gate
/// is t6's scope.
/// Kill switch for the grid-snapshot fresh-attach path.
///
/// `TERMMESH_PEER_FRESH_ATTACH_MODE=bytes` forces the pre-snapshot behavior
/// (the bounded ring tail) so a field problem in the screen model can be
/// reverted without a rebuild — mirroring `TERMMESH_PEER_REPLAY_BYTES`'s
/// role for ring capacity. Unset, or any other value, selects the snapshot.
/// Read per attach: attaches are rare, and a restartless toggle would not
/// survive the daemon's env snapshot anyway.
fn fresh_attach_uses_bytes() -> bool {
    fresh_attach_mode_is_bytes(
        std::env::var("TERMMESH_PEER_FRESH_ATTACH_MODE")
            .ok()
            .as_deref(),
    )
}

/// Pure decision half of [`fresh_attach_uses_bytes`], split for tests: env
/// mutation is process-global and races parallel tests, so the parsing is
/// exercised directly instead.
fn fresh_attach_mode_is_bytes(value: Option<&str>) -> bool {
    value.is_some_and(|v| v.trim().eq_ignore_ascii_case("bytes"))
}

fn effective_resume_from_seq(capabilities: &PeerCapabilities, requested: u64) -> u64 {
    if requested != 0 && capabilities.has(capability::REPLAY_RING_V1) {
        requested
    } else {
        0
    }
}

fn spawn_attach_relay(
    surface: Arc<PtySurface>,
    outgoing_tx: mpsc::Sender<Envelope>,
    seq_counter: Arc<AtomicU64>,
    mut subscriber: broadcast::Receiver<PtyChunk>,
    replay: Vec<PtyChunk>,
    mode_prefix: Vec<u8>,
    // Live-dedup floor when `replay` carries nothing: on the typed
    // GridSnapshot path the screen travels outside this task entirely, so
    // chunks the snapshot already contains (broadcast between subscribe()
    // and the snapshot read) must still be dropped below this seq.
    snapshot_floor: u64,
    send_surface_exit: bool,
) -> AttachEntry {
    let cancel = Arc::new(Notify::new());
    let cancel_for_task = cancel.clone();
    let surface_for_task = surface.clone();

    let task = tokio::spawn(async move {
        let mut attach_seq = 0u64;
        // `wrapping_add`, not `+`: a fresh-attach grid snapshot is packaged
        // as one synthetic chunk whose seq is BACKDATED by its own length
        // (see the attach handler), which on a young surface wraps below
        // zero. Re-adding the length is the modular inverse that lands
        // exactly back on the snapshot's consistency seq — the same
        // arithmetic contract the Swift host documents for its tap seq, and
        // the same trap (`+` on a wrapped anchor) that crashed the client
        // in PeerRelaySession.performResumeHeal before it moved to `&+`.
        let live_min_seq = replay
            .last()
            .map(|chunk| chunk.seq.wrapping_add(chunk.bytes.len() as u64))
            .unwrap_or(snapshot_floor);

        // Prepend any currently-active mouse-tracking DECSET sequences ahead of the
        // snapshot: without this, a viewer attaching after the PTY already turned a
        // mouse mode on never sees the enabling escape and scroll dies on attach.
        // Swift-side counterpart: GhosttyPaneSurfaceProvider.attach's mouse-mode replay.
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
        // Flips when the surface dies. The child's FINAL output can still be
        // sitting in the broadcast channel at that moment — the reader
        // broadcasts and only then observes EOF — and the biased arm below
        // would otherwise win the race against `recv()` and drop it on the
        // floor. Instead of breaking, switch to draining what is already
        // queued and exit on Empty, so the last bytes a process wrote before
        // exiting reach the viewer. (Flaky repro before this existed:
        // `surface_respawns_after_child_exit`, where the respawned child's
        // entire lifetime fits inside that race window.)
        let mut surface_dead = surface_for_task.dead.load(Ordering::Acquire);
        let mut observed_exit = false;
        loop {
            let res = if surface_dead {
                match subscriber.try_recv() {
                    Ok(chunk) => Ok(chunk),
                    Err(broadcast::error::TryRecvError::Lagged(n)) => {
                        Err(broadcast::error::RecvError::Lagged(n))
                    }
                    Err(_) => {
                        // Empty or Closed: the backlog is flushed.
                        tracing::info!("surface died, detaching relay");
                        observed_exit = true;
                        break;
                    }
                }
            } else {
                tokio::select! {
                    biased;
                    _ = cancel_for_task.notified() => break,
                    _ = surface_for_task.dead_notify.notified() => {
                        surface_dead = true;
                        continue;
                    }
                    // `Notify::notify_waiters` does not retain a permit. The
                    // atomic re-check closes the attach-vs-death window even
                    // when death happened just before this waiter registered.
                    _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {
                        if surface_for_task.dead.load(Ordering::Acquire) {
                            surface_dead = true;
                        }
                        continue;
                    }
                    res = subscriber.recv() => res,
                }
            };
            {
                {
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
        if observed_exit && send_surface_exit {
            let exit = surface_for_task.exit_info();
            let env = Envelope {
                seq: seq_counter.fetch_add(1, Ordering::Relaxed) + 1,
                correlation_id: 0,
                payload: Some(Payload::SurfaceExited(SurfaceExited {
                    surface_id: surface_for_task.surface_id.clone(),
                    exit_code: exit.exit_code,
                    signal: exit.signal,
                    reason: exit.reason.to_string(),
                })),
            };
            let _ = outgoing_tx.send(env).await;
        }
    });

    AttachEntry {
        surface,
        task,
        cancel,
    }
}

/// Mirror of the Swift host's `PeerTeamCall.allowedMethods`
/// (swift/PeerProto/Sources/PeerProto/PeerTeamCall.swift). The two MUST stay
/// in lockstep: this is the security boundary of team.call.v1, and it has to
/// mean the same thing whichever host answers. Everything here acts inside a
/// team the host already owns — nothing spawns a process, names a path, or
/// creates/destroys a team.
/// How long an abandoned surface is kept before it is reclaimed.
///
/// Long enough that a client reconnecting — a dropped link, an app restart —
/// finds its pane still there. Short enough that a client which is never
/// coming back does not leave a shell running for days.
fn abandoned_surface_grace() -> std::time::Duration {
    // Overridable so a test can watch a reap happen instead of asserting that
    // a timer was set. Operators get the default; nothing documents the knob.
    std::env::var("TERMMESH_PEER_ABANDONED_GRACE_MS")
        .ok()
        .and_then(|raw| raw.parse::<u64>().ok())
        .map(std::time::Duration::from_millis)
        .unwrap_or(std::time::Duration::from_secs(60))
}

/// Reclaim a surface this host spawned once nobody is attached to it.
///
/// A surface created on a peer's request exists for whoever asked. When they
/// all go, nothing refers to it, and until now the shell inside ran until the
/// daemon did — one per client crash, each still holding whatever had been
/// started in it. Declared surfaces are left alone: the operator published
/// those for anyone to attach to, and an empty one is simply idle.
///
/// The wait matters as much as the reap. Detaching is not the same as leaving
/// for good, and killing on the last detach would take the pane away from
/// someone whose network hiccuped. The count is checked again at the end of
/// it, so a reconnect inside the grace cancels the whole thing.
pub(crate) fn reap_if_abandoned(host: &Arc<PeerHost>, surface_id: &[u8]) {
    if host.pty.attacher_count(surface_id) > 0 {
        return;
    }
    if !host.pty.is_ephemeral(surface_id) {
        return;
    }
    // A published project manifest refers to this surface for as long as it
    // exists, which is the whole point of project.presentation.v1: the Mac
    // that created the project is disposable, and the next viewer must find
    // the same live panes. Reclaiming one because its publisher went away
    // would delete the project out from under everyone else.
    if host.presentation_references_surface(surface_id) {
        return;
    }
    let host = Arc::downgrade(host);
    let sid = surface_id.to_vec();
    let grace = abandoned_surface_grace();
    tokio::spawn(async move {
        tokio::time::sleep(grace).await;
        let Some(host) = host.upgrade() else { return };
        if host.pty.attacher_count(&sid) > 0 {
            return;
        }
        if !host.pty.is_ephemeral(&sid) {
            return;
        }
        // Re-checked with the count: a manifest published during the grace
        // claims the surface just as much as one published before it.
        if host.presentation_references_surface(&sid) {
            return;
        }
        tracing::info!(
            "reclaiming abandoned surface {:?} — no peer attached for {:?}",
            &sid[..sid.len().min(4)],
            grace
        );
        // Killing the process is the whole job: its death wakes the ephemeral
        // watcher already parked on it, which takes the surface out of the
        // workspace tree, the roster and the reverse index, and pushes the new
        // layout. Doing any of that here would be a second implementation of
        // the same cleanup, racing the first.
        host.pty.remove(&sid);
    });
}

/// The `team.*` methods a peer may call — the Rust half of the contract in
/// `PeerTeamCall.swift`, which carries the full reasoning.
///
/// A ceiling, not a scope: it bounds what a peer may do to what the local
/// control socket can already do, and deliberately does not bound WHICH team
/// it does it to (the team is named in the request and resolved as given).
/// Sound only because a peer is always another machine the same person owns;
/// `team.leader.v1` scopes its caller with a registered grant because that
/// caller is an autonomous process rather than a person.
const TEAM_CALL_ALLOWED_METHODS: &[&str] = &[
    "team.status",
    "team.list",
    "team.read",
    "team.collect",
    "team.reports",
    "team.result.status",
    "team.result.collect",
    "team.inbox",
    "team.message.list",
    "team.correlation.register",
    "team.correlation.get",
    "team.correlation.cancel",
    "team.send",
    "team.broadcast",
    "team.delegate",
    "team.message.post",
    "team.task.list",
    "team.task.get",
    "team.task.create",
    "team.task.update",
    "team.task.done",
    "team.task.block",
    "team.task.review",
    "team.task.unblock",
    "team.task.approve",
    // Reads what a task changed. The only method here that reaches the
    // filesystem: the host resolves the worktree from the task row the peer
    // names — no path, ref or command comes from the caller — and runs a fixed
    // read. See the Swift mirror for the full reasoning.
    "team.task.diff",
];

pub(crate) fn team_call_allowed(method: &str) -> bool {
    TEAM_CALL_ALLOWED_METHODS.contains(&method)
}

/// `team.leader.v1` starts with the generic peer ceiling and adds only the
/// operations protected by a project/team-bound grant. Keep this
/// separate from `team_call_allowed`: widening generic peer calls would let
/// an unscoped machine spawn processes.
pub(crate) fn team_leader_call_allowed(method: &str) -> bool {
    method != "team.list"
        && (team_call_allowed(method) || peer_proto::team_leader::scoped_method_allowed(method))
}

/// Run one allow-listed `team.*` method against a headless team manager.
///
/// The peer speaks one vocabulary (`team.*`) regardless of host type, so a
/// headless host translates each call into its own `headless.*` terms. Only
/// the methods that ARE single daemon operations are implemented; the rest of
/// the allow-list is app-composed (delegate fans out sends; collect gathers
/// many reads) and is honestly reported as unsupported here rather than faked.
async fn run_headless_team_call(
    manager: &Arc<tokio::sync::Mutex<crate::headless::HeadlessManager>>,
    agents: Option<&Arc<crate::agent::AgentSessionManager>>,
    method: &str,
    params_json: &str,
) -> TeamCallResponse {
    fn ok(result: serde_json::Value) -> TeamCallResponse {
        TeamCallResponse {
            ok: true,
            result_json: result.to_string(),
            error_code: String::new(),
            error_message: String::new(),
        }
    }
    fn err(code: &str, message: String) -> TeamCallResponse {
        TeamCallResponse {
            ok: false,
            result_json: String::new(),
            error_code: code.to_string(),
            error_message: message,
        }
    }

    let params: serde_json::Value = if params_json.trim().is_empty() {
        serde_json::json!({})
    } else {
        match serde_json::from_str(params_json) {
            Ok(v) => v,
            Err(e) => return err("invalid_params", format!("params_json: {e}")),
        }
    };
    let team = params.get("team_name").and_then(|v| v.as_str());
    let agent = params.get("agent_name").and_then(|v| v.as_str());

    match method {
        "team.list" => {
            let mgr = manager.lock().await;
            ok(serde_json::json!({ "teams": mgr.list_teams() }))
        }
        "team.send" => {
            let (Some(team), Some(agent)) = (team, agent) else {
                return err(
                    "invalid_params",
                    "team.send needs team_name and agent_name".into(),
                );
            };
            let Some(text) = params.get("text").and_then(|v| v.as_str()) else {
                return err("invalid_params", "team.send needs text".into());
            };
            let mut mgr = manager.lock().await;
            let Some(agent_id) = mgr.resolve_agent_id(team, agent) else {
                return err("host_error", format!("no such agent: {team}/{agent}"));
            };
            match mgr.send_message(&agent_id, &format!("{text}\n")).await {
                Ok(()) => ok(serde_json::json!({ "status": "ok" })),
                Err(e) => err("host_error", e),
            }
        }
        "team.read" => {
            let (Some(team), Some(agent)) = (team, agent) else {
                return err(
                    "invalid_params",
                    "team.read needs team_name and agent_name".into(),
                );
            };
            let lines = params
                .get("lines")
                .and_then(|v| v.as_u64())
                .map(|n| n as usize)
                .unwrap_or(50);
            let mut mgr = manager.lock().await;
            let Some(agent_id) = mgr.resolve_agent_id(team, agent) else {
                return err("host_error", format!("no such agent: {team}/{agent}"));
            };
            match mgr.read_output(&agent_id, lines).await {
                Ok(rows) => ok(serde_json::json!({ "lines": rows })),
                Err(e) => err("host_error", e),
            }
        }
        "team.status" => {
            let (Some(team), Some(agent)) = (team, agent) else {
                return err(
                    "invalid_params",
                    "team.status needs team_name and agent_name".into(),
                );
            };
            let mut mgr = manager.lock().await;
            let Some(agent_id) = mgr.resolve_agent_id(team, agent) else {
                return err("host_error", format!("no such agent: {team}/{agent}"));
            };
            match mgr.status(&agent_id).await {
                Ok(info) => match serde_json::to_value(info) {
                    Ok(value) => ok(value),
                    Err(e) => err("host_error", e.to_string()),
                },
                Err(e) => err("host_error", e),
            }
        }
        // The one method that reads a repository. What makes it safe is what
        // it does NOT accept: the caller names a task, and this host resolves
        // the directory from its own board. A path parameter would let a peer
        // read any repository on this machine; an argument parameter would let
        // it run git with flags that write.
        "team.task.diff" => {
            let Some(task_id) = params.get("task_id").and_then(|v| v.as_str()) else {
                return err("invalid_params", "team.task.diff needs task_id".into());
            };
            let Some(agents) = agents else {
                return err(
                    "unsupported_on_host",
                    "this host has no task board to read a worktree from".into(),
                );
            };
            let task = match agents.task_get(task_id) {
                Ok(task) => task,
                Err(e) => return err("host_error", e),
            };
            match crate::task_diff::read(
                task.worktree_path.as_deref(),
                task.worktree_parent.as_deref(),
            )
            .await
            {
                Ok(diff) => match serde_json::to_value(diff) {
                    Ok(value) => ok(value),
                    Err(e) => err("host_error", e.to_string()),
                },
                // A task with no worktree, or one whose worktree is gone, is an
                // error with a reason — never an empty success that a caller
                // would read as "nothing changed" and approve.
                Err(e) => err(e.code(), e.message()),
            }
        }
        // Allowed in the shared vocabulary, but not a single daemon op — the
        // app composes these from many sends/reads. Honest beats faked.
        other => err(
            "unsupported_on_host",
            format!("{other} is not implemented by a headless host"),
        ),
    }
}

fn host_hello(seq_counter: &AtomicU64, has_teams: bool) -> Envelope {
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
            // Only a host that actually has a team manager can answer
            // ListTeams; advertising it otherwise would invite a client to
            // ask a question this process cannot answer.
            capabilities: capability::supported_vec()
                .into_iter()
                .filter(|c| {
                    has_teams || (c != capability::TEAM_ROSTER_V1 && c != capability::TEAM_CALL_V1)
                })
                .collect(),
            app_version: env!("CARGO_PKG_VERSION").into(),
            cli_bin_dirs: executable_bin_dir().into_iter().collect(),
            // This process *is* the session owner: it serves this protocol on
            // the socket it was told to, and it outlives whatever started it.
            // Naming it lets a client reach sessions here directly instead of
            // guessing a path from a socket layout it does not control.
            session_host_socket: std::env::var("TERMMESH_PEER_SOCKET").unwrap_or_default(),
            project_owner_aliases: vec![],
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

/// Turn delivery failures must be visible to the viewer. In particular, a
/// full agent stdin queue is intentional backpressure, not permission to
/// silently discard the user's turn. Code 100 is the protocol's
/// surface-fatal fallback; the envelope correlation points at the Input
/// frame and `correlation_id_bytes` identifies its surface.
async fn send_surface_input_error(
    tx: &mpsc::Sender<Envelope>,
    seq_counter: &AtomicU64,
    input_seq: u64,
    surface_id: &[u8],
    error: &std::io::Error,
) -> anyhow::Result<()> {
    let message = match error.kind() {
        std::io::ErrorKind::WouldBlock => "surface input queue full",
        std::io::ErrorKind::BrokenPipe => "surface input channel closed",
        _ => "surface input write failed",
    };
    send(
        tx,
        Envelope {
            seq: next_seq(seq_counter),
            correlation_id: input_seq,
            payload: Some(Payload::Error(Error {
                code: 100,
                message: message.into(),
                correlation_id_bytes: surface_id.to_vec(),
            })),
        },
    )
    .await
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
const ENSURE_ENV_MAX_COUNT: usize = 64;
const ENSURE_ENV_KEY_MAX_BYTES: usize = 128;
const ENSURE_ENV_VALUE_MAX_BYTES: usize = 4096;
const ENSURE_ENV_TOTAL_MAX_BYTES: usize = 64 * 1024;
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

type EnsureWorker = Arc<
    dyn Fn(String, SurfaceSpec, Vec<(String, String)>) -> Result<EnsureOutcome, EnsureError>
        + Send
        + Sync
        + 'static,
>;
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
/// admission, the `surface.agent.v1` ensure gate, backpressure placement,
/// worker spawn, and correlated response enqueue so those ordering
/// invariants can be exercised without a real PTY.
async fn dispatch_ensure_surface(
    req: EnsureSurfaceRequest,
    correlation_id: u64,
    peer_capabilities: &PeerCapabilities,
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

    // surface.agent.v1 ensure gate: peer.proto's EnsureSurfaceRequest.kind
    // says senders MUST NOT send "agent" to a host without the capability —
    // and this connection's Hello is the same contract in the other
    // direction. A client that never advertised it could not attach the
    // surface it is asking for (the AttachSurface gate refuses it), so
    // honoring the ensure would only manufacture an orphan agent process.
    // Refused before any worker (= any spawn) runs. Unknown kind strings
    // still take the normal validate path below.
    if SurfaceKind::from_wire(&req.kind) == Some(SurfaceKind::Agent)
        && !peer_capabilities.has(capability::SURFACE_AGENT_V1)
    {
        let response = failed_ensure_response(
            request_id,
            EnsureSurfaceErrorCode::InvalidRequest,
            "validate",
            "kind \"agent\" requires capability surface.agent.v1",
        );
        return send_ensure_response(outgoing_tx, seq_counter, correlation_id, response).await;
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
            Ok((key, spec, env)) => {
                match tokio::task::spawn_blocking(move || ensure_worker(key, spec, env)).await {
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
) -> Result<(String, SurfaceSpec, Vec<(String, String)>), EnsureSurfaceResponse> {
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
    if req.env.len() > ENSURE_ENV_MAX_COUNT {
        return Err(too_large("env exceeds 64 entries"));
    }
    let mut env: Vec<(String, String)> = req.env.into_iter().collect();
    env.sort_by(|a, b| a.0.cmp(&b.0));
    let mut env_total = 0usize;
    for (key, value) in &env {
        if key.is_empty()
            || !key.bytes().enumerate().all(|(index, byte)| {
                byte == b'_' || byte.is_ascii_alphabetic() || (index > 0 && byte.is_ascii_digit())
            })
        {
            return Err(invalid("env key is not a portable identifier"));
        }
        if key.len() > ENSURE_ENV_KEY_MAX_BYTES {
            return Err(too_large("env key exceeds 128 UTF-8 bytes"));
        }
        if value.len() > ENSURE_ENV_VALUE_MAX_BYTES {
            return Err(too_large("env value exceeds 4096 UTF-8 bytes"));
        }
        if value.contains('\0') {
            return Err(invalid("env value contains NUL"));
        }
        env_total = env_total
            .saturating_add(key.len())
            .saturating_add(value.len());
        if env_total > ENSURE_ENV_TOTAL_MAX_BYTES {
            return Err(too_large("env exceeds 65536 UTF-8 bytes"));
        }
    }

    let restart_policy = match EnsureSurfaceRestartPolicy::try_from(req.restart_policy) {
        Ok(EnsureSurfaceRestartPolicy::Never) => EnsureRestartPolicy::Never,
        Ok(EnsureSurfaceRestartPolicy::OnDaemonRestart) => EnsureRestartPolicy::OnDaemonRestart,
        _ => return Err(invalid("restart_policy is invalid or unspecified")),
    };
    // Empty decodes to `Pty` — the only kind that predates the field, so an
    // older sender keeps meaning "terminal" without saying so. An unknown
    // string is refused here rather than defaulted: silently spawning the
    // wrong kind would hand a viewer a byte stream its renderer cannot
    // interpret (peer.proto, EnsureSurfaceRequest.kind).
    let Some(kind) = SurfaceKind::from_wire(&req.kind) else {
        return Err(invalid("kind must be empty, \"terminal\", or \"agent\""));
    };
    // The wire request carries no agent_cli field: the label rides the
    // bridge-shaped `--cli <name>` argument the ensure caller already sends
    // (the daemon spawns `executable`/`args` verbatim either way — this is
    // display metadata, not dispatch). Best-effort: absent flag → empty
    // label, and `SurfaceInfo.agent_cli` documents empty as valid. It joins
    // the spec hash via `SurfaceSpec::canonical_hash`, so relabeling the
    // CLI behind a key conflicts instead of reusing a surface that reports
    // the old label.
    let agent_cli = if kind == SurfaceKind::Agent {
        agent_cli_from_args(&req.args)
    } else {
        String::new()
    };
    Ok((
        req.key,
        SurfaceSpec {
            cwd: req.cwd,
            executable: req.executable,
            args: req.args,
            restart_policy,
            kind,
            agent_cli,
        },
        env,
    ))
}

/// The CLI label an agent ensure is bridging, read out of the request's own
/// argument vector (`--cli codex` or `--cli=codex`) — see the call site in
/// [`validate_ensure_request`] for why the wire has no dedicated field.
fn agent_cli_from_args(args: &[String]) -> String {
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if let Some(value) = arg.strip_prefix("--cli=") {
            return value.to_string();
        }
        if arg == "--cli" {
            return iter.next().cloned().unwrap_or_default();
        }
    }
    String::new()
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
mod input_error_tests {
    use std::io;
    use std::sync::atomic::AtomicU64;

    use peer_proto::v1::envelope::Payload;
    use tokio::sync::mpsc;

    use super::send_surface_input_error;

    #[tokio::test]
    async fn queue_overflow_is_correlated_and_visible_on_the_wire() {
        let (tx, mut rx) = mpsc::channel(1);
        let seq = AtomicU64::new(40);
        let surface_id = vec![0x7a; 16];
        send_surface_input_error(
            &tx,
            &seq,
            91,
            &surface_id,
            &io::Error::new(io::ErrorKind::WouldBlock, "queue full"),
        )
        .await
        .expect("send input rejection");

        let envelope = rx.recv().await.expect("wire error");
        assert_eq!(envelope.seq, 41);
        assert_eq!(envelope.correlation_id, 91);
        match envelope.payload {
            Some(Payload::Error(error)) => {
                assert_eq!(error.code, 100);
                assert_eq!(error.message, "surface input queue full");
                assert_eq!(error.correlation_id_bytes, surface_id);
            }
            other => panic!("expected visible Error, got {other:?}"),
        }
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
        admit_ensure_request_id, agent_cli_from_args, dispatch_ensure_surface,
        ensure_response_from_result, send_ensure_response, spawn_error_response,
        validate_ensure_request, EnsureWorkGate, EnsureWorker, HandshakeState, RequestIdAdmission,
        ENSURE_CONCURRENCY_LIMIT, ENSURE_ENV_MAX_COUNT, ENSURE_REQUEST_ID_BUDGET,
    };
    use crate::peer::surface::{EnsureError, SurfaceKind};
    use peer_proto::{capability, PeerCapabilities};

    fn valid_request() -> EnsureSurfaceRequest {
        EnsureSurfaceRequest {
            request_id: vec![0x11; 16],
            key: "runner-smoke".into(),
            cwd: "/app/runner".into(),
            executable: "/bin/sh".into(),
            args: vec!["-lc".into(), "exec cargo test".into()],
            restart_policy: EnsureSurfaceRestartPolicy::OnDaemonRestart as i32,
            kind: String::new(),
            env: Default::default(),
        }
    }

    fn all_capabilities() -> PeerCapabilities {
        PeerCapabilities::from_hello(capability::supported_vec())
    }

    fn capabilities_without_agent() -> PeerCapabilities {
        PeerCapabilities::from_hello(
            capability::supported_vec()
                .into_iter()
                .filter(|c| c != capability::SURFACE_AGENT_V1)
                .collect(),
        )
    }

    #[test]
    fn validates_wire_limits_and_restart_policy_without_echoing_input() {
        let (_, spec, _) = validate_ensure_request(valid_request()).expect("valid request");
        assert_eq!(spec.cwd, "/app/runner");

        let mut malformed = valid_request();
        malformed.request_id.pop();
        let error = validate_ensure_request(malformed)
            .expect_err("short request id")
            .error
            .expect("structured error");
        assert_eq!(error.code, EnsureSurfaceErrorCode::InvalidRequest as i32);

        let mut with_env = valid_request();
        with_env
            .env
            .insert("PROFILE_TOKEN".into(), "present".into());
        let (_, env_spec, env) = validate_ensure_request(with_env).expect("valid env");
        assert_eq!(env, vec![("PROFILE_TOKEN".into(), "present".into())]);
        assert_ne!(
            env_spec.canonical_hash(),
            env_spec.canonical_hash_with_env(&env)
        );

        let mut invalid_env = valid_request();
        invalid_env.env.insert("BAD=KEY".into(), "secret".into());
        let error = validate_ensure_request(invalid_env)
            .expect_err("invalid env key")
            .error
            .expect("structured error");
        assert_eq!(error.code, EnsureSurfaceErrorCode::InvalidRequest as i32);

        let mut too_many_env = valid_request();
        too_many_env.env = (0..=ENSURE_ENV_MAX_COUNT)
            .map(|index| (format!("KEY_{index}"), "v".into()))
            .collect();
        let error = validate_ensure_request(too_many_env)
            .expect_err("too many env entries")
            .error
            .expect("structured error");
        assert_eq!(error.code, EnsureSurfaceErrorCode::RequestTooLarge as i32);

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

    /// `EnsureSurfaceRequest.kind` wiring: empty stays terminal (the only
    /// kind that predates the field), "agent" flows into the spec with its
    /// CLI label read from the bridge-shaped args, and an unknown kind is
    /// refused rather than silently defaulted to the wrong renderer.
    #[test]
    fn ensure_kind_parses_agent_labels_the_cli_and_refuses_unknown_kinds() {
        let (_, spec, _) = validate_ensure_request(valid_request()).expect("empty kind");
        assert_eq!(spec.kind, SurfaceKind::Pty);
        assert_eq!(spec.agent_cli, "");

        let mut agent = valid_request();
        agent.kind = "agent".into();
        agent.args = vec![
            "--cli".into(),
            "codex".into(),
            "--cwd".into(),
            "/app/runner".into(),
        ];
        let (_, spec, _) = validate_ensure_request(agent).expect("agent kind");
        assert_eq!(spec.kind, SurfaceKind::Agent);
        assert_eq!(spec.agent_cli, "codex");

        // A terminal ensure never grows a label, even from bridge-shaped
        // args — agent_cli is agent-only spec identity.
        let mut terminal = valid_request();
        terminal.kind = "terminal".into();
        terminal.args = vec!["--cli".into(), "codex".into()];
        let (_, spec, _) = validate_ensure_request(terminal).expect("explicit terminal");
        assert_eq!(spec.kind, SurfaceKind::Pty);
        assert_eq!(spec.agent_cli, "");

        let mut unknown = valid_request();
        unknown.kind = "browser".into();
        let error = validate_ensure_request(unknown)
            .expect_err("unknown kind")
            .error
            .expect("structured error");
        assert_eq!(error.code, EnsureSurfaceErrorCode::InvalidRequest as i32);
    }

    /// Both spellings the bridge accepts, and the honest empty label when
    /// the flag is absent or truncated — never a panic on adversarial args.
    #[test]
    fn agent_cli_label_reads_both_flag_forms_and_degrades_to_empty() {
        let pair = |args: &[&str]| {
            agent_cli_from_args(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
        };
        assert_eq!(pair(&["--cli", "codex", "--model", "gpt"]), "codex");
        assert_eq!(pair(&["--cli=kiro"]), "kiro");
        assert_eq!(pair(&["--model", "gpt"]), "");
        assert_eq!(pair(&["--cli"]), "", "truncated flag pair");
        assert_eq!(pair(&[]), "");
    }

    /// surface.agent.v1 ensure gate (interface contract, peer.proto's
    /// EnsureSurfaceRequest.kind): kind="agent" from a connection whose
    /// Hello never advertised the capability is refused at dispatch,
    /// before the worker — and therefore before any process — runs; the
    /// byte-identical request under an advertising connection reaches the
    /// worker. Without the gate the daemon would spawn an agent child the
    /// requester can never attach (its AttachSurface is refused): an
    /// orphan by construction.
    #[tokio::test]
    async fn agent_ensure_without_the_capability_is_refused_before_the_worker() {
        let gate = EnsureWorkGate::new();
        let (tx, mut rx) = mpsc::channel(4);
        let seq = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let spawned = Arc::new(AtomicUsize::new(0));
        let worker: EnsureWorker = Arc::new({
            let spawned = spawned.clone();
            move |_, _, _| {
                spawned.fetch_add(1, Ordering::SeqCst);
                Err(EnsureError::Internal("test worker completed"))
            }
        });
        let mut agent_request = valid_request();
        agent_request.kind = "agent".into();

        let mut seen = HashSet::new();
        dispatch_ensure_surface(
            agent_request.clone(),
            801,
            &capabilities_without_agent(),
            &mut seen,
            &gate,
            &tx,
            &seq,
            worker.clone(),
        )
        .await
        .expect("dispatch refused agent ensure");
        let response = rx.recv().await.expect("refusal response");
        assert_eq!(response.correlation_id, 801);
        let Some(Payload::EnsureSurfaceResponse(response)) = response.payload else {
            panic!("wrong refusal payload");
        };
        assert_eq!(response.result, EnsureSurfaceResult::Failed as i32);
        let error = response.error.expect("structured refusal error");
        assert_eq!(error.code, EnsureSurfaceErrorCode::InvalidRequest as i32);
        assert!(
            error.safe_context.contains("surface.agent.v1"),
            "refusal must name the missing capability: {}",
            error.safe_context
        );
        assert_eq!(
            spawned.load(Ordering::SeqCst),
            0,
            "no worker — and therefore no process — may run for a refused agent ensure"
        );

        // The identical request from an advertising connection passes the
        // gate and reaches the worker (fresh request_id: one-shot set).
        agent_request.request_id = vec![0x77; 16];
        dispatch_ensure_surface(
            agent_request,
            802,
            &all_capabilities(),
            &mut seen,
            &gate,
            &tx,
            &seq,
            worker,
        )
        .await
        .expect("dispatch capable agent ensure");
        let response = rx.recv().await.expect("capable response");
        assert_eq!(response.correlation_id, 802);
        assert_eq!(
            spawned.load(Ordering::SeqCst),
            1,
            "advertised capability must let the agent ensure through"
        );
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
            move |_, _, _| {
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
                &all_capabilities(),
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
        let capabilities = all_capabilities();
        let seventeenth = dispatch_ensure_surface(
            request,
            correlation_id,
            &capabilities,
            &mut seen,
            &gate,
            &tx,
            &seq,
            worker,
        );
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
    use tokio::sync::{mpsc, watch};

    use crate::monitor::SystemSnapshot;
    use crate::peer::surface::PtyManager;
    use peer_proto::{capability, PeerCapabilities};

    use super::{
        dispatch_ensure_surface, dispatch_terminate_surface, host_stats_from,
        spawn_host_stats_push, EnsureWorkGate, EnsureWorker, PeerHost, TerminateWorker,
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
            Arc::new(|_, _, _| Err(super::EnsureError::Internal("test ensure completed")));
        let terminate_worker: TerminateWorker = Arc::new(|_| Ok(false));
        let ensure_request = |request_id: Vec<u8>| EnsureSurfaceRequest {
            request_id,
            key: "cross-operation".into(),
            cwd: "/app/runner".into(),
            executable: "/bin/sh".into(),
            args: Vec::new(),
            restart_policy: EnsureSurfaceRestartPolicy::OnDaemonRestart as i32,
            kind: String::new(),
            env: Default::default(),
        };

        let capabilities = PeerCapabilities::from_hello(capability::supported_vec());
        let first_id = vec![0xa1; 16];
        let mut seen = HashSet::new();
        dispatch_ensure_surface(
            ensure_request(first_id.clone()),
            701,
            &capabilities,
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
            &capabilities,
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

    fn snapshot_with_network(interfaces: Vec<(&str, f64, f64)>) -> SystemSnapshot {
        SystemSnapshot {
            timestamp_ms: 0,
            total_memory_bytes: 16_000_000_000,
            used_memory_bytes: 8_000_000_000,
            memory_percent: 50.0,
            cpu_count: 8,
            cpu_usage_percent: 12.5,
            disk_total_bytes: 500_000_000_000,
            disk_available_bytes: 20_000_000_000,
            disk_read_bytes_per_sec: 1_024,
            disk_write_bytes_per_sec: 2_048,
            processes: Vec::new(),
            alerts: Vec::new(),
            load_avg: [1.5, 1.0, 0.5],
            swap_total: 0,
            swap_used: 0,
            network_io: interfaces
                .into_iter()
                .map(|(name, rx_rate, tx_rate)| crate::monitor::NetworkIO {
                    name: name.to_string(),
                    rx_bytes: 0,
                    tx_bytes: 0,
                    rx_rate,
                    tx_rate,
                })
                .collect(),
            per_core_cpu: Vec::new(),
            disk_space: Vec::new(),
            anomalies: Vec::new(),
        }
    }

    /// A machine has more than one interface, and reporting whichever one
    /// happened to be first would under-report the traffic by however much
    /// the others carried.
    #[test]
    fn host_stats_sums_every_network_interface() {
        let snapshot = snapshot_with_network(vec![
            ("lo", 100.0, 200.0),
            ("eth0", 1_000.0, 2_000.0),
            ("tailscale0", 50.0, 25.0),
        ]);

        let stats = host_stats_from(&snapshot);

        assert_eq!(stats.net_rx_bytes_per_sec, 1_150);
        assert_eq!(stats.net_tx_bytes_per_sec, 2_225);
    }

    /// A viewer cannot warn about a peer running out of room unless capacity
    /// actually travels — the rate fields alone never show a full disk.
    #[test]
    fn host_stats_carries_disk_capacity() {
        let stats = host_stats_from(&snapshot_with_network(vec![("eth0", 1.0, 1.0)]));

        assert_eq!(stats.disk_total_bytes, 500_000_000_000);
        assert_eq!(stats.disk_available_bytes, 20_000_000_000);
    }

    /// A host with no interfaces up must report zero rather than refuse to
    /// produce a sample — the other fields are still worth showing.
    #[test]
    fn host_stats_reports_zero_when_no_interfaces() {
        let stats = host_stats_from(&snapshot_with_network(Vec::new()));

        assert_eq!(stats.net_rx_bytes_per_sec, 0);
        assert_eq!(stats.net_tx_bytes_per_sec, 0);
        assert_eq!(stats.load_1m, 1.5);
        assert_eq!(stats.cpu_count, 8);
    }

    /// The 1-minute figure is the one that tracks what is happening now;
    /// picking the wrong element of `load_avg` would show a number that
    /// lags minutes behind the machine.
    #[test]
    fn host_stats_takes_the_one_minute_load() {
        let stats = host_stats_from(&snapshot_with_network(Vec::new()));

        assert_eq!(stats.load_1m, 1.5, "load_avg[0], not the 5m or 15m figure");
    }

    /// A client that never asked for stats must not be sent any, so an
    /// older viewer talking to a new daemon sees exactly what it did
    /// before this feature existed.
    #[test]
    fn no_stats_task_without_the_capability() {
        let host = Arc::new(PeerHost::new(Arc::new(PtyManager::new())));
        let (tx, _rx) = watch::channel(None);
        host.set_monitor(tx.subscribe());
        let (outgoing_tx, _outgoing_rx) = mpsc::channel(8);

        let task = spawn_host_stats_push(
            &host,
            &PeerCapabilities::from_hello(vec![capability::REPLAY_RING_V1.to_string()]),
            outgoing_tx,
            Arc::new(AtomicU64::new(0)),
        );

        assert!(
            task.is_none(),
            "capability absent — nothing should be spawned"
        );
    }

    /// A host with no monitor wired (every test constructor, and any
    /// embedder) must also stay silent, even for a client that asked.
    #[test]
    fn no_stats_task_without_a_monitor() {
        let host = Arc::new(PeerHost::new(Arc::new(PtyManager::new())));
        let (outgoing_tx, _outgoing_rx) = mpsc::channel(8);

        let task = spawn_host_stats_push(
            &host,
            &PeerCapabilities::from_hello(vec![capability::HOST_STATS_V1.to_string()]),
            outgoing_tx,
            Arc::new(AtomicU64::new(0)),
        );

        assert!(task.is_none(), "no monitor — nothing to push");
    }

    /// The push carries the monitor's samples, and only samples: a client
    /// that asked gets a frame per tick, not a frame per poll.
    #[tokio::test]
    async fn stats_task_pushes_one_frame_per_sample() {
        let host = Arc::new(PeerHost::new(Arc::new(PtyManager::new())));
        let (monitor_tx, monitor_rx) = watch::channel(None);
        host.set_monitor(monitor_rx);
        let (outgoing_tx, mut outgoing_rx) = mpsc::channel(8);

        let task = spawn_host_stats_push(
            &host,
            &PeerCapabilities::from_hello(vec![capability::HOST_STATS_V1.to_string()]),
            outgoing_tx,
            Arc::new(AtomicU64::new(0)),
        )
        .expect("capability and monitor both present");

        monitor_tx
            .send(Some(snapshot_with_network(vec![("eth0", 10.0, 20.0)])))
            .expect("first sample");

        let env = outgoing_rx.recv().await.expect("a frame for the sample");
        let Some(Payload::HostStats(stats)) = env.payload else {
            panic!("expected HostStats");
        };
        assert_eq!(stats.net_rx_bytes_per_sec, 10);
        assert_eq!(stats.memory_percent, 50.0);

        task.abort();
    }
}

/// R1 (peer-relay-bulk-loss): `effective_resume_from_seq` is the capability
/// gate for the wire↔host seq mapping — see its doc comment above
/// `spawn_attach_relay` for the full design. The actual ring-cutting
/// behavior (`resume_from_seq != 0` replays only what's after that point)
/// lives one level down and is covered on the real `PtySurface` type in
/// `surface.rs`'s `replay_snapshot_from_on_a_real_surface_cuts_at_the_resume_point`;
/// this module covers only the decision of whether to honor the field at
/// all for a given peer.
#[cfg(test)]
mod resume_tests {
    use peer_proto::{capability, PeerCapabilities};

    use super::effective_resume_from_seq;

    #[test]
    fn resume_is_honored_when_capability_present_and_seq_nonzero() {
        let caps = PeerCapabilities::from_hello(vec![capability::REPLAY_RING_V1.to_string()]);
        assert_eq!(effective_resume_from_seq(&caps, 42), 42);
    }

    #[test]
    fn resume_is_ignored_without_the_capability() {
        // A peer that never advertised replay.ring.v1 (older build, or one
        // that predates this field's meaning) — its resume_from_seq is not
        // trusted, matching a fresh full-snapshot attach exactly.
        let caps = PeerCapabilities::default();
        assert_eq!(effective_resume_from_seq(&caps, 42), 0);
    }

    #[test]
    fn zero_requested_seq_is_a_fresh_attach_regardless_of_capability() {
        let caps = PeerCapabilities::from_hello(vec![capability::REPLAY_RING_V1.to_string()]);
        assert_eq!(effective_resume_from_seq(&caps, 0), 0);
    }

    /// R6 (peer-relay-bulk-loss, capability gating + old-peer compat): the
    /// realistic old-client shape — an older build's `AttachSurface` never
    /// populates `resume_from_seq` (the field defaults to 0 on the wire)
    /// AND never advertised `replay.ring.v1` in `Hello.capabilities`. Both
    /// facts hold at once here, unlike the two tests above which vary only
    /// one factor — this is the actual combination an old client produces
    /// against this (new) host, and it must resolve to a fresh
    /// full-snapshot attach exactly like every pre-R1 attach did.
    #[test]
    fn old_client_default_of_no_capability_and_zero_seq_is_a_fresh_attach() {
        let caps = PeerCapabilities::default();
        assert_eq!(effective_resume_from_seq(&caps, 0), 0);
    }
}

#[cfg(test)]
mod team_leader_capability_tests {
    use std::path::Path;
    use std::sync::atomic::AtomicU64;

    use peer_proto::{capability, v1::envelope::Payload};

    use super::{executable_bin_dir, host_hello};

    #[test]
    fn no_team_host_still_advertises_reverse_remote_leader_route() {
        let hello = host_hello(&AtomicU64::new(0), false);
        let Some(Payload::Hello(hello)) = hello.payload else {
            panic!("host hello must contain Hello payload");
        };

        assert!(
            hello.capabilities.iter().any(|cap| cap == capability::TEAM_LEADER_V1),
            "a daemon without a local team manager still routes scoped leader calls back to the viewer"
        );
        assert!(!hello
            .capabilities
            .iter()
            .any(|cap| cap == capability::TEAM_ROSTER_V1));
        assert!(!hello
            .capabilities
            .iter()
            .any(|cap| cap == capability::TEAM_CALL_V1));
    }

    #[test]
    fn host_hello_advertises_its_authenticated_cli_bin_directory() {
        let envelope = host_hello(&AtomicU64::new(0), false);
        let Some(Payload::Hello(hello)) = envelope.payload else {
            panic!("host hello must contain Hello payload");
        };
        assert!(hello
            .capabilities
            .iter()
            .any(|cap| cap == capability::HOST_CLI_BIN_DIRS_V1));
        assert_eq!(
            hello.cli_bin_dirs,
            executable_bin_dir().into_iter().collect::<Vec<_>>()
        );
        assert!(hello
            .cli_bin_dirs
            .iter()
            .all(|path| !path.is_empty() && Path::new(path).is_absolute()));
    }
}

#[cfg(test)]
mod team_call_allow_list_tests {
    use super::{team_call_allowed, team_leader_call_allowed, TEAM_CALL_ALLOWED_METHODS};

    /// The allow-list is the security boundary of `team.call.v1`, and it is
    /// written twice — here and in the Swift host's `PeerTeamCall`. Two copies
    /// of a security boundary drift; nothing was checking that they agree, so
    /// a method added to one host would have been silently callable on one
    /// machine and refused on the other.
    ///
    /// Reading the Swift source is crude but it is the only thing that can
    /// actually fail when the two disagree.
    #[test]
    fn swift_and_rust_team_call_allow_lists_match() {
        let swift = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../swift/PeerProto/Sources/PeerProto/PeerTeamCall.swift");
        let source = std::fs::read_to_string(&swift)
            .unwrap_or_else(|e| panic!("read {}: {e}", swift.display()));
        let body = source
            .split_once("allowedMethods: Set<String> = [")
            .expect("the allow-list literal")
            .1
            .split_once(']')
            .expect("its closing bracket")
            .0;

        let mut mirrored: Vec<String> = body
            .lines()
            // Drop the rationale comments; only the quoted names are the list.
            .filter_map(|line| {
                let line = line.trim();
                if line.starts_with("//") {
                    return None;
                }
                let start = line.find('"')? + 1;
                let end = start + line[start..].find('"')?;
                Some(line[start..end].to_string())
            })
            .collect();
        mirrored.sort();
        assert!(!mirrored.is_empty(), "parsed nothing out of the Swift list");
        let mut rust: Vec<String> = TEAM_CALL_ALLOWED_METHODS
            .iter()
            .map(|method| (*method).to_string())
            .collect();
        rust.sort();
        assert_eq!(mirrored, rust, "Swift and Rust allow-lists diverged");
    }

    /// Every method a leader may send has to reach a handler at the owner.
    ///
    /// The other tests in this module diff one allow-list against another.
    /// None of them can see whether the app answers, which is how a method
    /// got allow-listed on all three sides and still died at the far end as
    /// `unknown_method` — the exact failure this family exists to prevent.
    #[test]
    fn every_leader_method_reaches_an_owner_side_handler() {
        let swift = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Sources/TerminalController.swift");
        let source = std::fs::read_to_string(&swift)
            .unwrap_or_else(|e| panic!("read {}: {e}", swift.display()));

        fn quoted(body: &str) -> Vec<String> {
            body.lines()
                .map(str::trim)
                .filter(|line| !line.starts_with("//"))
                .filter_map(|line| {
                    let start = line.find('"')? + 1;
                    let end = start + line[start..].find('"')?;
                    Some(line[start..end].to_string())
                })
                .collect()
        }

        fn case_labels(body: &str) -> Vec<String> {
            body.lines()
                .map(str::trim)
                .filter(|line| line.starts_with("case \""))
                .flat_map(quoted)
                .collect()
        }
        fn section<'a>(source: &'a str, start: &str, end: &str) -> &'a str {
            source
                .split_once(start)
                .unwrap_or_else(|| panic!("{start} not found"))
                .1
                .split_once(end)
                .unwrap_or_else(|| panic!("end of {start} not found"))
                .0
        }

        // `teamDataCommands` only decides the ROUTE (TerminalController's
        // `peerTeamCommandAsync`); the handlers are a separate switch in
        // `dispatchTeamDataCommandDirect`. Reading the set alone would call a
        // method served when it is merely routed to a switch that drops it,
        // so both halves are read and required to agree.
        let data_set = quoted(section(
            &source,
            "static let teamDataCommands",
            "\n    ]",
        ));
        let data_cases = case_labels(section(
            &source,
            "private func dispatchTeamDataCommandDirect",
            "\n    }",
        ));
        let ui_cases = case_labels(section(
            &source,
            "private func processTeamUICommandAsync",
            "\n    }",
        ));

        let mut routed = data_set.clone();
        routed.sort();
        let mut handled = data_cases.clone();
        handled.sort();
        assert_eq!(
            routed, handled,
            "teamDataCommands and dispatchTeamDataCommandDirect disagree: a \
             method routed to the data path with no case there is dropped"
        );

        let mut served = data_cases;
        served.extend(ui_cases);
        assert!(
            served.len() > 20,
            "parsed too little out of the dispatchers: {served:?}"
        );

        // Allow-listed with no handler in the Swift app. The two are not the
        // same shape of hole:
        //
        // `team.task.diff` already works when the owner is a headless daemon
        // — `run_headless_team_call` serves it above — and it has live
        // senders (`ReviewBoardCoordinatorService` and this crate's peer
        // server), so only an app-owned project answers unknown_method. Its
        // fix is an app handler mirroring the headless one.
        //
        // `team.reports` has no sender anywhere; it is allow-listed surface
        // nothing calls yet.
        //
        // Both are named so this guard stays live. Remove an entry the moment
        // its handler lands.
        const UNIMPLEMENTED: &[&str] = &["team.reports", "team.task.diff"];

        let mut missing: Vec<&str> = TEAM_CALL_ALLOWED_METHODS
            .iter()
            .copied()
            .chain(peer_proto::team_leader::SCOPED_METHODS.iter().copied())
            .filter(|method| *method != "team.list")
            .filter(|method| !served.iter().any(|s| s == method))
            .collect();
        missing.sort();
        missing.dedup();
        let mut known: Vec<&str> = UNIMPLEMENTED.to_vec();
        known.sort();
        assert_eq!(
            missing, known,
            "a leader-callable method has no handler at the owner (or a listed \
             exception was implemented and should be removed from UNIMPLEMENTED)"
        );
    }

    #[test]
    fn swift_and_rust_scoped_leader_allow_lists_match() {
        let swift = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../swift/PeerProto/Sources/PeerProto/PeerTeamLeader.swift");
        let source = std::fs::read_to_string(&swift)
            .unwrap_or_else(|e| panic!("read {}: {e}", swift.display()));
        let body = source
            .split_once("scopedMethods: Set<String> = [")
            .expect("the scoped leader allow-list literal")
            .1
            .split_once(']')
            .expect("its closing bracket")
            .0;

        let mut mirrored: Vec<String> = body
            .lines()
            // Drop the rationale comments; only the quoted names are the list.
            // Without this the parser would read a method name out of any
            // comment that happens to quote one, and the only thing keeping
            // that from happening would be a note asking humans not to.
            .filter_map(|line| {
                let line = line.trim();
                if line.starts_with("//") {
                    return None;
                }
                let start = line.find('\"')? + 1;
                let end = start + line[start..].find('\"')?;
                Some(line[start..end].to_string())
            })
            .collect();
        mirrored.sort();
        assert!(
            !mirrored.is_empty(),
            "parsed nothing out of the Swift scoped leader list"
        );
        let mut rust: Vec<String> = peer_proto::team_leader::SCOPED_METHODS
            .iter()
            .map(|method| (*method).to_string())
            .collect();
        rust.sort();
        assert_eq!(
            mirrored, rust,
            "Swift and Rust scoped leader allow-lists diverged"
        );
    }

    /// The reason `team.task.diff` was allowed at all: it names no path and no
    /// command. Guarding the refusals explicitly keeps a later "just one more
    /// method" from quietly crossing the line.
    #[test]
    fn nothing_that_spawns_a_process_is_callable_by_a_peer() {
        for method in [
            "team.create",
            "team.destroy",
            "team.attach",
            "team.detach",
            "team.add_agent",
            "team.restart",
        ] {
            assert!(!team_call_allowed(method), "{method} must stay out");
        }
        assert!(team_call_allowed("team.task.diff"));
    }

    #[test]
    fn scoped_leader_methods_match_the_cli_allow_list() {
        let cli = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../term-mesh-cli/src/tm_agent.rs");
        let source =
            std::fs::read_to_string(&cli).unwrap_or_else(|e| panic!("read {}: {e}", cli.display()));
        let body = source
            .split_once("fn remote_leader_method_allowed(method: &str) -> bool {")
            .expect("CLI remote-leader allow-list")
            .1
            .split_once("\n}")
            .expect("CLI allow-list closing brace")
            .0;
        let mut cli_methods: Vec<&str> = body
            .lines()
            // Same reason as the Swift mirror above: the match arm carries
            // rationale comments, and a quoted method name inside one is not
            // a list entry.
            .filter_map(|line| {
                let line = line.trim();
                if line.starts_with("//") {
                    return None;
                }
                let start = line.find('\"')? + 1;
                let end = start + line[start..].find('\"')?;
                Some(&line[start..end])
            })
            .collect();
        // Only the generic half is compared. The CLI no longer spells the
        // grant-scoped methods out at all — `remote_leader_method_allowed`
        // ORs in `peer_proto::team_leader::scoped_method_allowed`, so that
        // half cannot drift by construction and there is nothing here to
        // diff it against.
        let mut daemon_methods: Vec<&str> = TEAM_CALL_ALLOWED_METHODS
            .iter()
            .copied()
            .filter(|method| *method != "team.list")
            .collect();
        cli_methods.sort();
        daemon_methods.sort();

        assert_eq!(cli_methods, daemon_methods);
        assert!(team_call_allowed("team.correlation.register"));
        assert!(team_call_allowed("team.correlation.get"));
        assert!(team_call_allowed("team.correlation.cancel"));
        assert!(!team_call_allowed("team.send_key"));
        assert!(team_call_allowed("team.task.done"));
        assert!(!team_call_allowed("team.task.reassign"));
    }

    #[test]
    fn scoped_leader_gate_allows_granted_operations_without_opening_generic_peer_access() {
        assert!(team_leader_call_allowed("team.add_agent"));
        assert!(team_leader_call_allowed("team.send_key"));
        assert!(!team_call_allowed("team.add_agent"));
        for method in [
            "team.list",
            "team.create",
            "team.destroy",
            "team.attach",
            "team.restart",
            "team.preset.list",
        ] {
            assert!(!team_leader_call_allowed(method), "{method}");
        }
        assert!(team_leader_call_allowed("team.delegate"));
    }
}

/// `team.task.diff` as a peer actually reaches it.
///
/// The module-level tests below the allow-list prove the method is *callable*;
/// these prove what it does with what a caller can control — which is only a
/// task id, by design.
#[cfg(test)]
mod team_task_diff_tests {
    use super::*;

    fn manager() -> Arc<tokio::sync::Mutex<crate::headless::HeadlessManager>> {
        Arc::new(tokio::sync::Mutex::new(
            crate::headless::HeadlessManager::new(),
        ))
    }

    fn board() -> Arc<crate::agent::AgentSessionManager> {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.keep().join("agents.db");
        Arc::new(crate::agent::AgentSessionManager::new(path).expect("agent db"))
    }

    #[tokio::test]
    async fn it_needs_a_task_id_and_nothing_else_is_accepted() {
        let board = board();
        // A path is not a parameter. Passing one must not make it a parameter:
        // the call still fails for the missing task id rather than reading the
        // directory the caller named.
        let response = run_headless_team_call(
            &manager(),
            Some(&board),
            "team.task.diff",
            r#"{"team_name":"ws","worktree_path":"/etc"}"#,
        )
        .await;
        assert!(!response.ok);
        assert_eq!(response.error_code, "invalid_params");
        assert!(
            response.error_message.contains("task_id"),
            "{}",
            response.error_message
        );
    }

    #[tokio::test]
    async fn a_host_with_no_task_board_says_so_rather_than_guessing_a_directory() {
        let response =
            run_headless_team_call(&manager(), None, "team.task.diff", r#"{"task_id":"tsk_1"}"#)
                .await;
        assert!(!response.ok);
        assert_eq!(response.error_code, "unsupported_on_host");
    }

    #[tokio::test]
    async fn a_task_this_host_does_not_have_is_an_error_not_an_empty_diff() {
        let board = board();
        let response = run_headless_team_call(
            &manager(),
            Some(&board),
            "team.task.diff",
            r#"{"task_id":"tsk_nobody"}"#,
        )
        .await;
        assert!(!response.ok, "result was {}", response.result_json);
        assert_eq!(response.error_code, "host_error");
        assert!(response.result_json.is_empty());
    }

    /// A task the board has but that never got a worktree. The failure has to
    /// carry a reason: an empty success here would read to the review board as
    /// "nothing changed", which is an approvable state.
    #[tokio::test]
    async fn a_task_with_no_worktree_reports_why() {
        let board = board();
        let task = board
            .task_create(crate::agent::TaskCreateParams {
                title: "no worktree".into(),
                description: None,
                priority: None,
                created_by: None,
                deps: None,
                fix_budget: None,
                worktree_policy: None,
            })
            .expect("task");

        let response = run_headless_team_call(
            &manager(),
            Some(&board),
            "team.task.diff",
            &format!(r#"{{"task_id":"{}"}}"#, task.id),
        )
        .await;

        assert!(!response.ok);
        assert_eq!(response.error_code, "no_worktree");
        assert!(
            response.error_message.contains("no worktree recorded"),
            "{}",
            response.error_message
        );
    }
}

/// Agent surfaces over the real wire: the full `run()` connection loop
/// against a `PtyManager` that owns non-PTY children, driven from the
/// client side of a socketpair.
///
/// Covers the two `surface.agent.v1` gates (SurfaceList demotion + attach
/// refusal), the happy path a capable viewer takes (attach → Input turn →
/// echoed PtyData → detach → replay reattach), and the contracts agent
/// surfaces inherit unchanged from terminals: duplicate-attach refusal,
/// dead-surface respawn on attach, and the out-of-ring resume fallback.
#[cfg(test)]
mod agent_surface_tests {
    use std::sync::atomic::Ordering;
    use std::sync::Arc;
    use std::time::Duration;

    use peer_proto::capability;
    use peer_proto::v1::envelope::Payload;
    use peer_proto::v1::{
        AttachMode, AttachSurface, Auth, DetachSurface, Envelope, Hello, Input, ListSurfaces,
        ListTeams, Ping, SubscribeWorkspaceList, SurfaceList, Team, TeamMember,
        UpsertProjectPresentationRequest,
    };
    use tempfile::TempDir;
    use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
    use tokio::net::UnixStream;

    use super::{run, PeerHost, PROTOCOL_VERSION};
    use crate::peer::framing::{read_envelope, write_envelope};
    use crate::peer::surface::{
        surface_id_from_name, EnsureRestartPolicy, PtyManager, PtySurface, SurfaceKind, SurfaceSpec,
    };

    const IO_TIMEOUT: Duration = Duration::from_secs(30);

    /// `/bin/cat` as the agent child: long-lived, and it echoes stdin back
    /// to stdout, so a turn written to the bridge's stdin reappears as a
    /// newline-terminated NDJSON-shaped line — both directions of the pipe
    /// contract in one deterministic process.
    fn cat_agent_spec() -> SurfaceSpec {
        SurfaceSpec {
            cwd: "/tmp".into(),
            executable: "/bin/cat".into(),
            args: Vec::new(),
            restart_policy: EnsureRestartPolicy::OnDaemonRestart,
            kind: SurfaceKind::Agent,
            agent_cli: "codex".into(),
        }
    }

    fn script_agent_spec(script: &str) -> SurfaceSpec {
        SurfaceSpec {
            cwd: "/tmp".into(),
            executable: "/bin/sh".into(),
            args: vec!["-c".into(), script.into()],
            restart_policy: EnsureRestartPolicy::OnDaemonRestart,
            kind: SurfaceKind::Agent,
            agent_cli: "codex".into(),
        }
    }

    fn capabilities_without_agent() -> Vec<String> {
        capability::supported_vec()
            .into_iter()
            .filter(|c| c != capability::SURFACE_AGENT_V1)
            .collect()
    }

    /// Socketpair against the production `run()` loop, handshaken through
    /// Hello/Auth with the given client capabilities. The returned halves
    /// are the CLIENT side.
    async fn handshake(
        host: Arc<PeerHost>,
        capabilities: Vec<String>,
    ) -> (OwnedReadHalf, OwnedWriteHalf) {
        handshake_as(host, capabilities, vec![0x42; 16]).await
    }

    async fn handshake_as(
        host: Arc<PeerHost>,
        capabilities: Vec<String>,
        peer_id: Vec<u8>,
    ) -> (OwnedReadHalf, OwnedWriteHalf) {
        handshake_as_with_owner_aliases(host, capabilities, peer_id, vec![]).await
    }

    async fn handshake_as_with_owner_aliases(
        host: Arc<PeerHost>,
        capabilities: Vec<String>,
        peer_id: Vec<u8>,
        project_owner_aliases: Vec<Vec<u8>>,
    ) -> (OwnedReadHalf, OwnedWriteHalf) {
        let (client, server) = UnixStream::pair().expect("socketpair");
        tokio::spawn(async move {
            let _ = run(server, host).await;
        });
        let (mut reader, mut writer) = client.into_split();
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 1,
                correlation_id: 0,
                payload: Some(Payload::Hello(Hello {
                    protocol_version: PROTOCOL_VERSION.into(),
                    peer_id,
                    display_name: "agent-surface-test".into(),
                    capabilities,
                    app_version: "test".into(),
                    cli_bin_dirs: vec![],
                    session_host_socket: String::new(),
                    project_owner_aliases,
                })),
            },
        )
        .await
        .expect("send hello");
        let _ = recv(&mut reader).await; // host hello
        let _ = recv(&mut reader).await; // auth challenge
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
        .expect("send auth");
        match recv(&mut reader).await.payload {
            Some(Payload::AuthResult(result)) => assert!(result.accepted, "{}", result.reason),
            other => panic!("expected AuthResult, got {other:?}"),
        }
        (reader, writer)
    }

    /// The creating Mac is disposable; the daemon-owned manifest is not.
    /// Publish from one authenticated installation, drop that connection,
    /// then prove a different installation discovers the exact live surface
    /// ids and can attach without EnsureSurface or spawning anything.
    #[tokio::test]
    async fn project_manifest_is_discoverable_and_attachable_from_another_peer() {
        let tmp = TempDir::new().expect("temp dir");
        let manager = Arc::new(PtyManager::new());
        let leader = PtySurface::spawn(
            surface_id_from_name("durable-project-leader"),
            "durable-project-leader".into(),
            "/bin/cat",
            &[],
            80,
            24,
            None,
        )
        .expect("spawn leader");
        let leader_id = leader.surface_id.clone();
        manager.insert_surface(leader);
        let member_id = manager
            .ensure("durable-project-member", &cat_agent_spec())
            .expect("ensure agent")
            .surface_id;

        let host = Arc::new(PeerHost::new(manager.clone()));
        host.set_persist_path(tmp.path().join("peer-workspaces.json"));

        let (mut owner_reader, mut owner_writer) =
            handshake_as(host.clone(), capability::supported_vec(), vec![0x42; 16]).await;
        let (mut notification_reader, mut notification_writer) =
            handshake_as(host.clone(), capability::supported_vec(), vec![0x44; 16]).await;
        write_envelope(
            &mut notification_writer,
            &Envelope {
                seq: 9,
                correlation_id: 0,
                payload: Some(Payload::SubscribeWorkspaceList(SubscribeWorkspaceList {})),
            },
        )
        .await
        .expect("subscribe before publish");
        assert!(matches!(
            recv(&mut notification_reader).await.payload,
            Some(Payload::WorkspaceListChanged(_))
        ));
        write_envelope(
            &mut owner_writer,
            &Envelope {
                seq: 10,
                correlation_id: 0,
                payload: Some(Payload::UpsertProjectPresentationRequest(
                    UpsertProjectPresentationRequest {
                        request_id: vec![0x10; 16],
                        delete_project_id: String::new(),
                        project: Some(Team {
                            name: "durable-demo".into(),
                            team_uuid: "uuid-durable-demo".into(),
                            working_directory: "/tmp".into(),
                            project_root: "/tmp".into(),
                            agent_names: vec!["worker".into()],
                            leader_cli: "codex".into(),
                            leader_model: "gpt-5.6-sol".into(),
                            leader_surface_id: leader_id.clone(),
                            members: vec![TeamMember {
                                name: "worker".into(),
                                agent_instance_id: "worker-instance".into(),
                                cli: "codex".into(),
                                working_directory: "/tmp".into(),
                                surface_id: member_id.clone(),
                                surface_type: "agent".into(),
                                ..Default::default()
                            }],
                            project_id: "team:uuid-durable-demo".into(),
                            ..Default::default()
                        }),
                    },
                )),
            },
        )
        .await
        .expect("publish manifest");
        match recv(&mut owner_reader).await.payload {
            Some(Payload::UpsertProjectPresentationResponse(response)) => {
                assert!(response.ok, "{}", response.error_code);
                assert_eq!(response.revision, 1);
            }
            other => panic!("expected upsert response, got {other:?}"),
        }
        assert!(
            matches!(
                recv(&mut notification_reader).await.payload,
                Some(Payload::WorkspaceListChanged(_))
            ),
            "manifest upsert must invalidate connected roster subscribers"
        );
        drop(owner_reader);
        drop(owner_writer);

        let reloaded_host = Arc::new(PeerHost::new(manager));
        reloaded_host.set_persist_path(tmp.path().join("peer-workspaces.json"));
        let (mut viewer_reader, mut viewer_writer) = handshake_as(
            reloaded_host.clone(),
            capability::supported_vec(),
            vec![0x43; 16],
        )
        .await;
        write_envelope(
            &mut viewer_writer,
            &Envelope {
                seq: 20,
                correlation_id: 0,
                payload: Some(Payload::ListTeams(ListTeams {})),
            },
        )
        .await
        .expect("list projects");
        let project = match recv(&mut viewer_reader).await.payload {
            Some(Payload::TeamList(list)) => {
                assert_eq!(list.teams.len(), 1);
                list.teams.into_iter().next().expect("project")
            }
            other => panic!("expected team list, got {other:?}"),
        };
        assert_eq!(project.name, "durable-demo");
        assert_eq!(project.leader_cli, "codex");
        assert_eq!(project.leader_model, "gpt-5.6-sol");
        assert_eq!(project.leader_surface_id, leader_id);
        assert_eq!(project.members.len(), 1);
        assert_eq!(project.members[0].surface_id, member_id);
        assert!(!project.presentation_owned_by_requester);
        assert!(project.leader_process_active_known);
        assert!(
            project.leader_process_active,
            "the fixture's foreground /bin/cat workload must be advertised as active"
        );

        write_envelope(
            &mut viewer_writer,
            &Envelope {
                seq: 21,
                correlation_id: 0,
                payload: Some(Payload::UpsertProjectPresentationRequest(
                    UpsertProjectPresentationRequest {
                        request_id: vec![0x11; 16],
                        delete_project_id: "team:uuid-durable-demo".into(),
                        project: None,
                    },
                )),
            },
        )
        .await
        .expect("reject viewer deletion");
        match recv(&mut viewer_reader).await.payload {
            Some(Payload::UpsertProjectPresentationResponse(response)) => {
                assert!(!response.ok);
                assert_eq!(response.error_code, "not_owner");
            }
            other => panic!("expected delete response, got {other:?}"),
        }

        let attached = attach(
            &mut viewer_reader,
            &mut viewer_writer,
            22,
            member_id.clone(),
            0,
        )
        .await;
        assert!(attached.accepted, "{}", attached.reason);

        host.terminate_surface(&member_id)
            .expect("terminate member");
        assert!(
            matches!(
                recv(&mut notification_reader).await.payload,
                Some(Payload::WorkspaceListChanged(_))
            ),
            "referenced surface death must invalidate connected roster subscribers"
        );
        write_envelope(
            &mut viewer_writer,
            &Envelope {
                seq: 23,
                correlation_id: 0,
                payload: Some(Payload::ListTeams(ListTeams {})),
            },
        )
        .await
        .expect("list after member exit");
        let list = loop {
            match recv(&mut viewer_reader).await.payload {
                Some(Payload::TeamList(list)) => break list,
                // The preceding attach can leave ordinary stream metadata in
                // flight before the correlated list response.
                Some(Payload::WorkspaceUpdate(_))
                | Some(Payload::PtyData(_))
                | Some(Payload::SurfaceExited(_)) => continue,
                other => panic!("expected team list, got {other:?}"),
            }
        };
        assert_eq!(list.teams.len(), 1, "a live leader keeps the project discoverable");
        assert_eq!(list.teams[0].leader_surface_id, leader_id);
        assert!(
            list.teams[0].members.is_empty(),
            "dead members must be omitted instead of respawned by discovery"
        );

        let (mut owner_reader, mut owner_writer) = handshake_as_with_owner_aliases(
            reloaded_host,
            capability::supported_vec(),
            vec![0x45; 16],
            vec![vec![0x42; 16]],
        )
        .await;
        write_envelope(
            &mut owner_writer,
            &Envelope {
                seq: 30,
                correlation_id: 0,
                payload: Some(Payload::UpsertProjectPresentationRequest(
                    UpsertProjectPresentationRequest {
                        request_id: vec![0x12; 16],
                        delete_project_id: "team:uuid-durable-demo".into(),
                        project: None,
                    },
                )),
            },
        )
        .await
        .expect("delete manifest after owner identity rotation");
        match recv(&mut owner_reader).await.payload {
            Some(Payload::UpsertProjectPresentationResponse(response)) => {
                assert!(response.ok, "{}", response.error_code);
            }
            other => panic!("expected delete response, got {other:?}"),
        }
        assert!(crate::peer::persist::load_project_presentations(
            &crate::peer::persist::project_presentations_path(
                &tmp.path().join("peer-workspaces.json")
            )
        )
        .is_empty());
    }

    #[tokio::test]
    async fn project_manifest_without_live_surfaces_remains_discoverable() {
        let tmp = TempDir::new().expect("temp dir");
        let manager = Arc::new(PtyManager::new());
        let leader = PtySurface::spawn(
            surface_id_from_name("manifest-only-project-leader"),
            "manifest-only-project-leader".into(),
            "/bin/cat",
            &[],
            80,
            24,
            None,
        )
        .expect("spawn leader");
        let leader_id = leader.surface_id.clone();
        manager.insert_surface(leader);
        let member_id = manager
            .ensure("manifest-only-project-member", &cat_agent_spec())
            .expect("ensure member")
            .surface_id;
        let persist_path = tmp.path().join("peer-workspaces.json");
        let host = Arc::new(PeerHost::new(manager));
        host.set_persist_path(persist_path.clone());

        let owner_id = vec![0x52; 16];
        let (mut owner_reader, mut owner_writer) =
            handshake_as(host, capability::supported_vec(), owner_id.clone()).await;
        write_envelope(
            &mut owner_writer,
            &Envelope {
                seq: 10,
                correlation_id: 0,
                payload: Some(Payload::UpsertProjectPresentationRequest(
                    UpsertProjectPresentationRequest {
                        request_id: vec![0x20; 16],
                        delete_project_id: String::new(),
                        project: Some(Team {
                            name: "manifest-only-demo".into(),
                            team_uuid: "uuid-manifest-only-demo".into(),
                            working_directory: "/tmp/manifest-only".into(),
                            project_root: "/tmp".into(),
                            agent_names: vec!["worker".into()],
                            created_at_unix_secs: 1234,
                            leader_surface_id: leader_id.clone(),
                            members: vec![TeamMember {
                                name: "worker".into(),
                                agent_instance_id: "worker-instance".into(),
                                cli: "claude".into(),
                                model: "claude-sonnet-5".into(),
                                working_directory: "/tmp/manifest-only".into(),
                                surface_id: member_id,
                                surface_type: "agent".into(),
                                ..Default::default()
                            }],
                            project_id: "team:uuid-manifest-only-demo".into(),
                            delegation_configured: "guarded".into(),
                            delegation_effective: "leader-first".into(),
                            delegation_pending: "delegated".into(),
                            leader_cli: "codex".into(),
                            leader_model: "gpt-5.6-sol".into(),
                            ..Default::default()
                        }),
                    },
                )),
            },
        )
        .await
        .expect("publish manifest");
        match recv(&mut owner_reader).await.payload {
            Some(Payload::UpsertProjectPresentationResponse(response)) => {
                assert!(response.ok, "{}", response.error_code);
                assert_eq!(response.revision, 1);
            }
            other => panic!("expected upsert response, got {other:?}"),
        }
        drop(owner_reader);
        drop(owner_writer);

        // Model a daemon restart where durable presentation state reloads
        // before any of its old surfaces have been restored.
        let reloaded_host = Arc::new(PeerHost::new(Arc::new(PtyManager::new())));
        reloaded_host.set_persist_path(persist_path);
        let (mut reloaded_reader, mut reloaded_writer) =
            handshake_as(reloaded_host, capability::supported_vec(), owner_id).await;
        write_envelope(
            &mut reloaded_writer,
            &Envelope {
                seq: 20,
                correlation_id: 0,
                payload: Some(Payload::ListTeams(ListTeams {})),
            },
        )
        .await
        .expect("list manifest-only project");
        let project = match recv(&mut reloaded_reader).await.payload {
            Some(Payload::TeamList(list)) => {
                assert_eq!(
                    list.teams.len(),
                    1,
                    "manifest must not be skipped or duplicated"
                );
                list.teams
                    .into_iter()
                    .next()
                    .expect("manifest-only project")
            }
            other => panic!("expected team list, got {other:?}"),
        };

        assert_eq!(project.name, "manifest-only-demo");
        assert_eq!(project.team_uuid, "uuid-manifest-only-demo");
        assert_eq!(project.project_id, "team:uuid-manifest-only-demo");
        assert_eq!(project.working_directory, "/tmp/manifest-only");
        assert_eq!(project.project_root, "/tmp");
        assert_eq!(project.created_at_unix_secs, 1234);
        assert_eq!(project.presentation_revision, 1);
        assert!(project.presentation_owned_by_requester);
        assert_eq!(project.leader_surface_id, leader_id);
        assert_eq!(project.leader_cli, "codex");
        assert_eq!(project.leader_model, "gpt-5.6-sol");
        assert_eq!(project.delegation_configured, "guarded");
        assert_eq!(project.delegation_effective, "leader-first");
        assert_eq!(project.delegation_pending, "delegated");
        assert!(project.agent_names.is_empty());
        assert!(project.members.is_empty());
        assert!(project.leader_process_active_known);
        assert!(!project.leader_process_active);
    }

    async fn recv(reader: &mut OwnedReadHalf) -> Envelope {
        tokio::time::timeout(IO_TIMEOUT, read_envelope(reader))
            .await
            .expect("frame within timeout")
            .expect("read envelope")
    }

    async fn list_surfaces(
        reader: &mut OwnedReadHalf,
        writer: &mut OwnedWriteHalf,
        seq: u64,
    ) -> SurfaceList {
        write_envelope(
            writer,
            &Envelope {
                seq,
                correlation_id: 0,
                payload: Some(Payload::ListSurfaces(ListSurfaces {})),
            },
        )
        .await
        .expect("send ListSurfaces");
        match recv(reader).await.payload {
            Some(Payload::SurfaceList(list)) => list,
            other => panic!("expected SurfaceList, got {other:?}"),
        }
    }

    /// Request an attach and read up to the AttachResult. Nothing is
    /// expected in between on these quiet fixtures, so anything else is a
    /// contract violation worth failing on.
    async fn attach(
        reader: &mut OwnedReadHalf,
        writer: &mut OwnedWriteHalf,
        seq: u64,
        surface_id: Vec<u8>,
        resume_from_seq: u64,
    ) -> peer_proto::v1::AttachResult {
        write_envelope(
            writer,
            &Envelope {
                seq,
                correlation_id: 0,
                payload: Some(Payload::AttachSurface(AttachSurface {
                    surface_id,
                    mode: AttachMode::CoWrite as i32,
                    client_cols: 120,
                    client_rows: 40,
                    resume_from_seq,
                })),
            },
        )
        .await
        .expect("send attach");
        match recv(reader).await.payload {
            Some(Payload::AttachResult(result)) => result,
            other => panic!("expected AttachResult, got {other:?}"),
        }
    }

    async fn send_keys(writer: &mut OwnedWriteHalf, seq: u64, surface_id: Vec<u8>, keys: Vec<u8>) {
        write_envelope(
            writer,
            &Envelope {
                seq,
                correlation_id: 0,
                payload: Some(Payload::Input(Input {
                    surface_id,
                    kind: Some(peer_proto::v1::input::Kind::Keys(keys)),
                })),
            },
        )
        .await
        .expect("send input");
    }

    /// Accumulate PtyData payloads for `surface_id` until `expected` bytes
    /// arrived, asserting each frame's wire `byte_seq` tiles the stream
    /// from 0 (fresh attach wire space). Non-PtyData meta frames
    /// (WorkspaceUpdate) are skipped; a GridSnapshot is a hard failure —
    /// agent surfaces must never produce one.
    async fn collect_pty_data(
        reader: &mut OwnedReadHalf,
        surface_id: &[u8],
        expected: usize,
    ) -> Vec<u8> {
        let mut acc = Vec::with_capacity(expected);
        let mut wire_bytes = 0_u64;
        while acc.len() < expected {
            match recv(reader).await.payload {
                Some(Payload::PtyData(data)) => {
                    assert_eq!(data.surface_id, surface_id);
                    assert_eq!(
                        data.byte_seq, wire_bytes,
                        "wire byte_seq must tile the payload bytes"
                    );
                    wire_bytes += data.payload.len() as u64;
                    if serde_json::from_slice(&data.payload)
                        .ok()
                        .as_ref()
                        .is_some_and(tm_agent_bridge::location::is_environment_diagnostic)
                    {
                        continue;
                    }
                    acc.extend_from_slice(&data.payload);
                }
                Some(Payload::WorkspaceUpdate(_)) => continue,
                Some(Payload::GridSnapshot(_)) => {
                    panic!("agent surface produced a GridSnapshot")
                }
                other => panic!("unexpected frame while collecting PtyData: {other:?}"),
            }
        }
        acc
    }

    /// Gate (a) + (b), from the client that motivates them: a viewer that
    /// never advertised `surface.agent.v1` sees the agent surface demoted
    /// to attachable=false (while its terminal neighbor stays attachable),
    /// has an attach attempt refused with the capability named, and —
    /// adversarially ignoring both answers — gets its Input for the
    /// refused surface dropped without killing the connection.
    #[tokio::test]
    async fn unadvertised_client_is_demoted_refused_and_survives_its_own_input() {
        let manager = Arc::new(PtyManager::new());
        let agent_id = manager
            .ensure("agent-gate", &cat_agent_spec())
            .expect("ensure agent")
            .surface_id;
        let terminal = PtySurface::spawn(
            surface_id_from_name("terminal-neighbor"),
            "terminal-neighbor".into(),
            "/bin/cat",
            &[],
            80,
            24,
            None,
        )
        .expect("spawn terminal cat");
        manager.insert_surface(terminal);
        let host = Arc::new(PeerHost::new(manager.clone()));

        let (mut reader, mut writer) = handshake(host, capabilities_without_agent()).await;

        let list = list_surfaces(&mut reader, &mut writer, 10).await;
        let agent_row = list
            .surfaces
            .iter()
            .find(|s| s.surface_type == "agent")
            .expect("agent surface listed");
        assert!(
            !agent_row.attachable,
            "agent surface must be demoted for a client without surface.agent.v1"
        );
        assert_eq!(
            agent_row.agent_cli, "codex",
            "demotion changes attachability, not identity"
        );
        let terminal_row = list
            .surfaces
            .iter()
            .find(|s| s.surface_type == "terminal")
            .expect("terminal surface listed");
        assert!(
            terminal_row.attachable,
            "demotion must not leak onto terminal surfaces"
        );

        let refused = attach(&mut reader, &mut writer, 11, agent_id.clone(), 0).await;
        assert!(!refused.accepted);
        assert!(
            refused.reason.contains("surface.agent.v1"),
            "refusal must name the missing capability: {}",
            refused.reason
        );

        // Adversarial follow-up: input for the surface it was refused is
        // dropped (no attach entry), and the connection stays healthy.
        send_keys(&mut writer, 12, agent_id, b"ignored\n".to_vec()).await;
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 13,
                correlation_id: 0,
                payload: Some(Payload::Ping(Ping { nonce: 7 })),
            },
        )
        .await
        .expect("send ping");
        match recv(&mut reader).await.payload {
            Some(Payload::Pong(pong)) => assert_eq!(pong.nonce, 7),
            other => panic!("expected Pong after ignored input, got {other:?}"),
        }
    }

    /// The capable-viewer happy path: attach (no GridSnapshot, no
    /// mode-prefix frame), a turn written as Input.keys reaches the agent
    /// child's stdin and echoes back as a line-aligned PtyData chunk, and
    /// after detach a fresh reattach replays the same bytes from the ring.
    #[tokio::test]
    async fn advertised_client_round_trips_a_turn_and_replays_on_reattach() {
        let manager = Arc::new(PtyManager::new());
        let agent_id = manager
            .ensure("agent-turn", &cat_agent_spec())
            .expect("ensure agent")
            .surface_id;
        let host = Arc::new(PeerHost::new(manager.clone()));

        let (mut reader, mut writer) = handshake(host, capability::supported_vec()).await;

        let list = list_surfaces(&mut reader, &mut writer, 10).await;
        let row = list
            .surfaces
            .iter()
            .find(|s| s.surface_id == agent_id)
            .expect("agent surface listed");
        assert_eq!(row.surface_type, "agent");
        assert_eq!(row.agent_cli, "codex");
        assert!(row.attachable, "capable client sees the honest value");

        let granted = attach(&mut reader, &mut writer, 11, agent_id.clone(), 0).await;
        assert!(granted.accepted, "{}", granted.reason);
        assert_eq!(granted.granted_mode, AttachMode::CoWrite as i32);
        assert_eq!(granted.initial_seq, 0, "nothing produced before attach");

        // The frame right after AttachResult must be the WorkspaceMeta
        // push — NOT a GridSnapshot (no grid) and NOT a mode-prefix
        // PtyData (no DEC modes): the two skips the agent path promises.
        match recv(&mut reader).await.payload {
            Some(Payload::WorkspaceUpdate(_)) => {}
            other => panic!("expected WorkspaceMeta right after AttachResult, got {other:?}"),
        }

        let turn = b"{\"type\":\"user\",\"text\":\"ping\"}\n".to_vec();
        send_keys(&mut writer, 12, agent_id.clone(), turn.clone()).await;
        let echoed = collect_pty_data(&mut reader, &agent_id, turn.len()).await;
        assert_eq!(echoed, turn, "turn input must echo back through the child");

        // Detach, reattach fresh: the ring replays the same bytes, in the
        // new attach's own wire seq space, from the same initial_seq base.
        write_envelope(
            &mut writer,
            &Envelope {
                seq: 13,
                correlation_id: 0,
                payload: Some(Payload::DetachSurface(DetachSurface {
                    surface_id: agent_id.clone(),
                })),
            },
        )
        .await
        .expect("send detach");
        let regranted = attach(&mut reader, &mut writer, 14, agent_id.clone(), 0).await;
        assert!(regranted.accepted, "{}", regranted.reason);
        assert_eq!(
            regranted.initial_seq, 0,
            "replay starts at the ring's first chunk"
        );
        let replayed = collect_pty_data(&mut reader, &agent_id, turn.len()).await;
        assert_eq!(replayed, turn, "reattach must replay the buffered turn");

        manager.remove(&agent_id);
    }

    #[tokio::test]
    async fn surface_exit_is_pushed_after_the_final_agent_output() {
        let manager = Arc::new(PtyManager::new());
        let agent_id = manager
            .ensure(
                "agent-exit-event",
                &script_agent_spec(r#"read _; printf 'final\n'; exit 7"#),
            )
            .expect("ensure agent")
            .surface_id;
        let host = Arc::new(PeerHost::new(manager.clone()));
        let (mut reader, mut writer) = handshake(host, capability::supported_vec()).await;
        let granted = attach(&mut reader, &mut writer, 20, agent_id.clone(), 0).await;
        assert!(granted.accepted, "{}", granted.reason);
        match recv(&mut reader).await.payload {
            Some(Payload::WorkspaceUpdate(_)) => {}
            other => panic!("expected WorkspaceMeta, got {other:?}"),
        }
        send_keys(&mut writer, 21, agent_id.clone(), b"go\n".to_vec()).await;

        let mut saw_final = false;
        loop {
            match recv(&mut reader).await.payload {
                Some(Payload::PtyData(data)) => {
                    assert_eq!(data.surface_id, agent_id);
                    if data.payload == b"final\n" {
                        saw_final = true;
                    }
                }
                Some(Payload::SurfaceExited(exit)) => {
                    assert!(saw_final, "exit must follow the final PtyData");
                    assert_eq!(exit.surface_id, agent_id);
                    assert_eq!(exit.exit_code, 7);
                    assert_eq!(exit.signal, 0);
                    assert_eq!(exit.reason, "exited");
                    break;
                }
                Some(Payload::WorkspaceUpdate(_)) => {}
                other => panic!("unexpected frame before SurfaceExited: {other:?}"),
            }
        }
        manager.remove(&agent_id);
    }

    #[tokio::test]
    async fn surface_exit_is_not_pushed_without_the_capability() {
        let manager = Arc::new(PtyManager::new());
        let agent_id = manager
            .ensure(
                "agent-exit-event-gated",
                &script_agent_spec(r#"read _; printf 'final\n'; exit 7"#),
            )
            .expect("ensure agent")
            .surface_id;
        let host = Arc::new(PeerHost::new(manager.clone()));
        let capabilities = capability::supported_vec()
            .into_iter()
            .filter(|value| value != capability::SURFACE_EXIT_V1)
            .collect();
        let (mut reader, mut writer) = handshake(host, capabilities).await;
        let granted = attach(&mut reader, &mut writer, 30, agent_id.clone(), 0).await;
        assert!(granted.accepted, "{}", granted.reason);
        match recv(&mut reader).await.payload {
            Some(Payload::WorkspaceUpdate(_)) => {}
            other => panic!("expected WorkspaceMeta, got {other:?}"),
        }
        send_keys(&mut writer, 31, agent_id.clone(), b"go\n".to_vec()).await;
        let final_data = collect_pty_data(&mut reader, &agent_id, b"final\n".len()).await;
        assert_eq!(final_data, b"final\n");

        let unexpected = tokio::time::timeout(
            std::time::Duration::from_millis(200),
            read_envelope(&mut reader),
        )
        .await;
        assert!(
            unexpected.is_err(),
            "SurfaceExited must be gated by surface.exit.v1"
        );
        manager.remove(&agent_id);
    }

    /// One attach per surface per connection — same contract as terminals,
    /// proven for the agent kind.
    #[tokio::test]
    async fn duplicate_agent_attach_is_refused() {
        let manager = Arc::new(PtyManager::new());
        let agent_id = manager
            .ensure("agent-dup", &cat_agent_spec())
            .expect("ensure agent")
            .surface_id;
        let host = Arc::new(PeerHost::new(manager.clone()));

        let (mut reader, mut writer) = handshake(host, capability::supported_vec()).await;
        let first = attach(&mut reader, &mut writer, 10, agent_id.clone(), 0).await;
        assert!(first.accepted, "{}", first.reason);
        match recv(&mut reader).await.payload {
            Some(Payload::WorkspaceUpdate(_)) => {}
            other => panic!("expected WorkspaceMeta, got {other:?}"),
        }

        let second = attach(&mut reader, &mut writer, 11, agent_id.clone(), 0).await;
        assert!(!second.accepted);
        assert_eq!(second.reason, "already attached");

        manager.remove(&agent_id);
    }

    /// `get_or_respawn` for the agent kind, both halves of its existing
    /// contract (unchanged from terminals):
    ///
    /// - a DECLARED surface (`register_and_spawn`, respawn spec on file)
    ///   whose child died is revived by a raw attach, and the revived
    ///   child's output reaches the viewer — this drives
    ///   `spawn_from_spec`'s Agent branch through the respawn path;
    /// - an ENSURED surface registers no respawn spec, so a dead one
    ///   answers "surface not found" — its revival path is a fresh
    ///   EnsureSurfaceRequest (RECREATED), never a raw attach.
    #[tokio::test]
    async fn attaching_a_dead_agent_surface_follows_the_respawn_contract() {
        let manager = Arc::new(PtyManager::new());

        let declared_id = surface_id_from_name("agent-declared");
        manager.register_and_spawn(
            declared_id.clone(),
            crate::peer::surface::SpawnSpec {
                title: "agent-declared".into(),
                command: "/bin/sh".into(),
                args: vec!["-c".into(), r#"printf 'gen\n'"#.into()],
                cols: 80,
                rows: 24,
                cwd: Some("/tmp".into()),
                kind: SurfaceKind::Agent,
                agent_cli: "codex".into(),
            },
        );
        let ensured = manager
            .ensure("agent-ensured", &script_agent_spec(r#"printf 'gen\n'"#))
            .expect("ensure agent");
        let ensured_id = ensured.surface_id.clone();

        // Both children exit right after their one line; wait for both
        // first instances to die.
        let declared_surface = manager
            .list()
            .into_iter()
            .find(|s| s.surface_id == declared_id)
            .expect("declared surface registered");
        tokio::time::timeout(IO_TIMEOUT, async {
            while !declared_surface.dead.load(Ordering::Acquire)
                || !ensured.surface.dead.load(Ordering::Acquire)
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("both first instances must die");

        let host = Arc::new(PeerHost::new(manager.clone()));
        let (mut reader, mut writer) = handshake(host, capability::supported_vec()).await;

        let granted = attach(&mut reader, &mut writer, 10, declared_id.clone(), 0).await;
        assert!(
            granted.accepted,
            "dead declared agent must respawn, not vanish: {}",
            granted.reason
        );
        let line = collect_pty_data(&mut reader, &declared_id, b"gen\n".len()).await;
        assert_eq!(line, b"gen\n".to_vec());

        let refused = attach(&mut reader, &mut writer, 11, ensured_id.clone(), 0).await;
        assert!(
            !refused.accepted,
            "no respawn spec — raw attach cannot revive"
        );
        assert_eq!(refused.reason, "surface not found");

        manager.remove(&declared_id);
        manager.remove(&ensured_id);
    }

    /// Gate (b) ordering: the capability refusal is decided BEFORE
    /// `get_or_respawn`, so an unadvertised client's attach attempt at a
    /// dead DECLARED agent surface is refused without reviving it — the
    /// revived child would be an orphan (spawned for a client that can
    /// never attach it), and it would sit there generating output until
    /// something else noticed.
    #[tokio::test]
    async fn unadvertised_attach_does_not_respawn_a_dead_agent_surface() {
        let manager = Arc::new(PtyManager::new());
        let declared_id = surface_id_from_name("agent-dead-gate");
        manager.register_and_spawn(
            declared_id.clone(),
            crate::peer::surface::SpawnSpec {
                title: "agent-dead-gate".into(),
                command: "/bin/sh".into(),
                args: vec!["-c".into(), r#"printf 'gen\n'"#.into()],
                cols: 80,
                rows: 24,
                cwd: Some("/tmp".into()),
                kind: SurfaceKind::Agent,
                agent_cli: "codex".into(),
            },
        );
        let first_instance = manager
            .list()
            .into_iter()
            .find(|s| s.surface_id == declared_id)
            .expect("declared surface registered");
        tokio::time::timeout(IO_TIMEOUT, async {
            while !first_instance.dead.load(Ordering::Acquire) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("first instance must die");

        let host = Arc::new(PeerHost::new(manager.clone()));
        let (mut reader, mut writer) = handshake(host, capabilities_without_agent()).await;

        let refused = attach(&mut reader, &mut writer, 10, declared_id.clone(), 0).await;
        assert!(!refused.accepted);
        assert!(
            refused.reason.contains("surface.agent.v1"),
            "refusal must name the missing capability: {}",
            refused.reason
        );

        // No respawn as a side effect: the registered instance is still
        // the very Arc that died, not a fresh child spawned from the spec.
        let after = manager
            .list()
            .into_iter()
            .find(|s| s.surface_id == declared_id)
            .expect("surface still registered");
        assert!(
            Arc::ptr_eq(&first_instance, &after),
            "a refused attach must not replace the dead instance"
        );
        assert!(
            after.dead.load(Ordering::Acquire),
            "still dead — the refused attach spawned nothing"
        );

        manager.remove(&declared_id);
    }

    /// In-ring partial resume for the agent kind: a reconnect that asks to
    /// resume from a mid-stream seq must take the `replay_snapshot_from`
    /// path and receive exactly the unseen tail, cut on a chunk (== line)
    /// boundary — never a resend of the event it already has, and never a
    /// mid-line fragment for ordinarily-sized lines.
    #[tokio::test]
    async fn in_ring_resume_replays_only_the_unseen_tail_on_a_chunk_boundary() {
        let manager = Arc::new(PtyManager::new());
        let outcome = manager
            .ensure(
                "agent-resume-in-ring",
                &script_agent_spec(r#"printf '{"a":1}\n{"b":2}\n'; sleep 30"#),
            )
            .expect("ensure agent");
        let agent_id = outcome.surface_id.clone();
        let first_line = b"{\"a\":1}\n".to_vec();
        let second_line = b"{\"b\":2}\n".to_vec();
        // Precondition for the boundary claim: the ring buffered the
        // environment diagnostic and then one chunk per child line, so the
        // resume point below IS a chunk boundary.
        let ring = tokio::time::timeout(IO_TIMEOUT, async {
            loop {
                let ring = outcome.surface.replay_snapshot();
                if ring.len() >= 3 {
                    break ring;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("agent output must reach the ring");
        let diagnostic_len = ring[0].bytes.len() as u64;
        assert!(serde_json::from_slice(&ring[0].bytes)
            .ok()
            .as_ref()
            .is_some_and(tm_agent_bridge::location::is_environment_diagnostic));
        assert_eq!(ring[1].bytes, first_line);
        assert_eq!(ring[2].bytes, second_line);

        let host = Arc::new(PeerHost::new(manager.clone()));
        let (mut reader, mut writer) = handshake(host, capability::supported_vec()).await;

        // The client saw the first event before its connection died;
        // resume from the exact start of the second one.
        let resume_at = diagnostic_len + first_line.len() as u64;
        let granted = attach(&mut reader, &mut writer, 10, agent_id.clone(), resume_at).await;
        assert!(granted.accepted, "{}", granted.reason);
        assert_eq!(
            granted.initial_seq, resume_at,
            "wire seq 0 must map to the resume point, not the ring's start"
        );
        let replayed = collect_pty_data(&mut reader, &agent_id, second_line.len()).await;
        assert_eq!(
            replayed, second_line,
            "resume must replay exactly the unseen tail as a whole-chunk cut"
        );

        manager.remove(&agent_id);
    }

    /// A multi-megabyte Input payload (one giant NDJSON-shaped line)
    /// crosses the socket, the blocking stdin write, the child, the
    /// line-oriented reader, the replay ring and the relay — and comes
    /// back intact. Guards the whole pipe path against size cliffs well
    /// below the 16 MiB frame cap.
    #[tokio::test]
    async fn multi_megabyte_turn_survives_the_round_trip() {
        let manager = Arc::new(PtyManager::new());
        let agent_id = manager
            .ensure("agent-large", &cat_agent_spec())
            .expect("ensure agent")
            .surface_id;
        let host = Arc::new(PeerHost::new(manager.clone()));

        let (mut reader, mut writer) = handshake(host, capability::supported_vec()).await;
        let granted = attach(&mut reader, &mut writer, 10, agent_id.clone(), 0).await;
        assert!(granted.accepted, "{}", granted.reason);
        match recv(&mut reader).await.payload {
            Some(Payload::WorkspaceUpdate(_)) => {}
            other => panic!("expected WorkspaceMeta, got {other:?}"),
        }

        let mut turn = vec![b'x'; 3 * 1024 * 1024];
        turn.push(b'\n');
        send_keys(&mut writer, 11, agent_id.clone(), turn.clone()).await;
        let echoed = collect_pty_data(&mut reader, &agent_id, turn.len()).await;
        assert!(
            echoed == turn,
            "multi-megabyte payload corrupted in transit ({} of {} bytes)",
            echoed.len(),
            turn.len()
        );

        manager.remove(&agent_id);
    }

    /// A resume_from_seq beyond anything the ring ever buffered cannot be
    /// honored exactly; the existing fallback contract (full snapshot,
    /// initial_seq re-based at the ring's first chunk) must hold for the
    /// agent kind unchanged.
    #[tokio::test]
    async fn out_of_ring_resume_falls_back_to_the_full_snapshot() {
        let manager = Arc::new(PtyManager::new());
        let outcome = manager
            .ensure(
                "agent-resume",
                &script_agent_spec(r#"printf '{"a":1}\n{"b":2}\n'; sleep 30"#),
            )
            .expect("ensure agent");
        let agent_id = outcome.surface_id.clone();
        let expected = b"{\"a\":1}\n{\"b\":2}\n".to_vec();

        // The environment diagnostic and both child lines must be in the
        // ring before the attach asks to resume past them.
        tokio::time::timeout(IO_TIMEOUT, async {
            while outcome.surface.replay_snapshot().len() < 3 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("agent output must reach the ring");

        let host = Arc::new(PeerHost::new(manager.clone()));
        let (mut reader, mut writer) = handshake(host, capability::supported_vec()).await;

        let granted = attach(&mut reader, &mut writer, 10, agent_id.clone(), 1_000_000).await;
        assert!(granted.accepted, "{}", granted.reason);
        assert_eq!(
            granted.initial_seq, 0,
            "unsatisfiable resume re-bases at the full snapshot"
        );
        let replayed = collect_pty_data(&mut reader, &agent_id, expected.len()).await;
        assert_eq!(replayed, expected, "fallback must resend the whole ring");

        manager.remove(&agent_id);
    }
}
