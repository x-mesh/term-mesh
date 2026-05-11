//! tmux control-mode backend — ADR 0002 Phase 1.1.
//!
//! `TmuxControlBackend` implements `RemoteMultiplexerBackend` using
//! `ssh <host> tmux -CC` as the transport.
//!
//! Phase 1.0: parser, octal unescape, encoder, surface map, session skeleton.
//! Phase 1.1: `send_input` wired through `TmuxSession::write_command` +
//!             `encoder::send_keys_hex`; session handle retained after connect.

pub mod encoder;
pub mod layout;
pub mod octal;
pub mod parser;
pub mod session;
pub mod surface;

use anyhow::{anyhow, Result};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{broadcast, mpsc, RwLock};

use crate::multiplexer::{
    CellSize, RemoteMultiplexerBackend, RemoteSurfaceStream, RemoteWorkspace, SurfaceId,
    WorkspaceControl,
};
use surface::SurfaceMap;

fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// Parse the tab-separated output of `tmux list-panes -F` with the format
/// string used by [`TmuxControlBackend::fetch_panes`]. Rows that don't have
/// the expected six fields are silently dropped — a partial line is far
/// less useful than an explicit error, but it should not poison the rest
/// of the response.
fn parse_list_panes(stdout: &str) -> Vec<RemotePane> {
    stdout
        .lines()
        .filter_map(|line| {
            let mut cols = line.split('\t');
            let pane_id = cols.next()?.trim().to_string();
            let pane_index: u32 = cols.next()?.trim().parse().ok()?;
            let active = cols.next()?.trim() == "1";
            let width: u16 = cols.next()?.trim().parse().ok()?;
            let height: u16 = cols.next()?.trim().parse().ok()?;
            let command = cols.next().unwrap_or("").trim().to_string();
            Some(RemotePane {
                pane_id,
                pane_index,
                active,
                width,
                height,
                command,
            })
        })
        .collect()
}

fn capture_pane_commands(
    target: &str,
    lines: Option<i32>,
    alternate_on: Option<bool>,
) -> Vec<(String, bool)> {
    let target = shell_single_quote(target);
    match lines {
        Some(n) if n > 0 => vec![(
            format!("tmux capture-pane -e -p -N -S -{} -t {}", n, target),
            false,
        )],
        Some(_) => vec![(
            format!("tmux capture-pane -e -p -N -S - -E - -t {}", target),
            false,
        )],
        None => {
            // Do not use -N for visible snapshots. We clear the local screen
            // first, and replaying full-width trailing spaces can trigger
            // auto-wrap before the row separator arrives.
            let primary = (format!("tmux capture-pane -e -p -t {}", target), false);
            match alternate_on {
                Some(true) => vec![
                    // TUIs can run in tmux's alternate screen. Only prefer it
                    // when tmux says the pane is currently using it; on tmux
                    // 3.4, `capture-pane -a` succeeds with empty output even
                    // when alternate screen is off.
                    (format!("tmux capture-pane -a -q -e -p -t {}", target), true),
                    primary,
                ],
                Some(false) => vec![primary],
                None => vec![
                    (format!("tmux capture-pane -a -q -e -p -t {}", target), true),
                    primary,
                ],
            }
        }
    }
}

pub struct TmuxCapture {
    pub bytes: Vec<u8>,
    pub alternate_screen: bool,
}

/// Phase 1.1: metadata for a single tmux pane within the attached window.
///
/// Sourced from `tmux list-panes -F '#{pane_id} #{pane_index} #{pane_active}
///   #{pane_width} #{pane_height} #{pane_current_command}'` so each row is
/// fully self-describing — the caller does not need to issue a follow-up
/// query just to learn the dimensions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemotePane {
    /// tmux control-mode id, e.g. `%1`.
    pub pane_id: String,
    /// 0-based pane index within the window — matches layout-string leaves.
    pub pane_index: u32,
    pub active: bool,
    pub width: u16,
    pub height: u16,
    pub command: String,
}

/// A parsed PTY output frame from a remote tmux pane.  Broadcast to all active
/// `subscribe_output()` receivers.
#[derive(Clone)]
pub struct OutputFrame {
    pub surface_id: SurfaceId,
    /// Raw tmux pane-id (e.g. `%1`).
    pub pane_id: String,
    pub bytes: Vec<u8>,
}

/// Window-scoped notification emitted on every tmux topology change.
/// Phase 1.1: only `%layout-change` is surfaced; future variants
/// (`%window-add`, `%window-renamed`, `%session-window-changed`) plug in
/// here without touching the wire protocol.
#[derive(Clone)]
pub enum NotifyEvent {
    LayoutChange {
        window_id: String,
        raw: String,
        layout: Option<layout::WindowLayout>,
    },
}

/// Backend handle for a single remote `ssh tmux -CC` session.
pub struct TmuxControlBackend {
    host: String,
    /// Remote tmux session name.
    session_name: String,
    surface_map: SurfaceMap,
    /// Live SSH+tmux process, retained for `send_input` / `resize`.
    /// `None` until `attach_surface` is first called.
    tmux_session: Arc<RwLock<Option<Arc<session::TmuxSession>>>>,
    /// Per-surface byte-stream senders, keyed by SurfaceId.
    surface_senders: Arc<RwLock<HashMap<SurfaceId, mpsc::Sender<Vec<u8>>>>>,
    /// Broadcast channel: every parsed %output frame is sent here so multiple
    /// `subscribe_output()` callers can each receive a copy.
    output_tx: broadcast::Sender<OutputFrame>,
    /// Broadcast channel: window-scoped notifications (layout changes etc).
    /// Capacity is small — these arrive at human-edit cadence, not the
    /// per-frame cadence of output bytes.
    notify_tx: broadcast::Sender<NotifyEvent>,
}

impl TmuxControlBackend {
    /// Create a backend referencing a remote SSH host and tmux session name.
    ///
    /// The SSH process is not started until `attach_surface` is called for the
    /// first time.
    pub fn new(host: impl Into<String>, session: impl Into<String>) -> Self {
        let (output_tx, _) = broadcast::channel(4096);
        let (notify_tx, _) = broadcast::channel(128);
        Self {
            host: host.into(),
            session_name: session.into(),
            surface_map: SurfaceMap::new(),
            tmux_session: Arc::new(RwLock::new(None)),
            surface_senders: Arc::new(RwLock::new(HashMap::new())),
            output_tx,
            notify_tx,
        }
    }

    /// Subscribe to all parsed PTY output frames from this backend.
    ///
    /// Returns a broadcast receiver that yields one `OutputFrame` per `%output`
    /// event received from the remote tmux session.  Multiple callers get
    /// independent receivers.
    pub fn subscribe_output(&self) -> broadcast::Receiver<OutputFrame> {
        self.output_tx.subscribe()
    }

    /// Phase 1.1: subscribe to non-output window notifications (layout
    /// changes, future window-add/-renamed). Independent of output_tx so
    /// slow notify consumers cannot lag the high-frequency byte stream.
    pub fn subscribe_notify(&self) -> broadcast::Receiver<NotifyEvent> {
        self.notify_tx.subscribe()
    }

    /// Test-only: inject a pre-built session and register a surface mapping.
    #[cfg(test)]
    async fn inject_for_test(
        &self,
        sess: session::TmuxSession,
        pane_id: &str,
        surface_id: SurfaceId,
    ) {
        *self.tmux_session.write().await = Some(Arc::new(sess));
        self.surface_map.register(pane_id, surface_id).await;
    }

    /// Test-only: directly send an OutputFrame on the broadcast channel.
    #[cfg(test)]
    pub fn inject_output_frame_for_test(&self, frame: OutputFrame) {
        let _ = self.output_tx.send(frame);
    }

    /// Verify that the remote tmux session exists before attempting a full attach.
    ///
    /// Runs `ssh <host> tmux has-session -t <session>` as a one-shot subprocess.
    /// Returns `Ok(())` when the session is present, or an `Err` with a clear
    /// message when it is missing or the SSH connection fails.  Called at the
    /// start of `attach_surface` so callers get an actionable error instead of a
    /// silent SSH failure buried in control-mode startup noise.
    async fn ensure_session_exists(&self, size: CellSize, create_if_missing: bool) -> Result<bool> {
        let quoted_session = shell_single_quote(&self.session_name);
        let check_cmd = format!("tmux has-session -t {}", quoted_session);
        let out = tokio::process::Command::new("ssh")
            .args([
                "-o",
                "BatchMode=yes",
                "-o",
                "StrictHostKeyChecking=accept-new",
                "-o",
                "ConnectTimeout=5",
                &self.host,
                &check_cmd,
            ])
            .output()
            .await
            .map_err(|e| anyhow!("ssh probe failed: {e}"))?;
        if out.status.success() {
            return Ok(false);
        }
        if !create_if_missing {
            let stderr = String::from_utf8_lossy(&out.stderr);
            return Err(anyhow!(
                "remote tmux session '{}' not found on {} — {}",
                self.session_name,
                self.host,
                stderr.trim()
            ));
        }

        let create_cmd = format!(
            "tmux new-session -d -s {} -x {} -y {}",
            quoted_session,
            size.cols.max(1),
            size.rows.max(1)
        );
        let create = tokio::process::Command::new("ssh")
            .args([
                "-o",
                "BatchMode=yes",
                "-o",
                "StrictHostKeyChecking=accept-new",
                "-o",
                "ConnectTimeout=8",
                &self.host,
                &create_cmd,
            ])
            .output()
            .await
            .map_err(|e| anyhow!("ssh create-session failed: {e}"))?;
        if !create.status.success() {
            let stderr = String::from_utf8_lossy(&create.stderr);
            return Err(anyhow!(
                "remote tmux session '{}' not found and could not be created on {} — {}",
                self.session_name,
                self.host,
                stderr.trim()
            ));
        }
        Ok(true)
    }

    /// Capture the current visible screen of the first pane in the session.
    ///
    /// Runs `ssh <host> tmux capture-pane -e -p -t <pane>` as a one-shot
    /// subprocess and returns raw stdout.  The `-e` flag preserves ANSI escape
    /// sequences (colour, SGR) so the client TUI re-renders correctly.
    ///
    /// If `lines` is `Some(n)`, also includes up to `n` lines of scrollback
    /// via `-S -<n>`.  If `None`, only the visible screen (default tmux
    /// behaviour) is captured.
    ///
    /// `surface_id` lets the caller name a specific surface; the function
    /// resolves it to the real tmux pane id that attach_surface registered
    /// in surface_map. Without this resolution the seed would target
    /// `<session>:0` (the default = active pane), which is not necessarily
    /// the same pane that send_input is writing to.  When the active pane
    /// differs from the attached pane the user sees the wrong window's
    /// contents and their keystrokes appear to do nothing.
    ///
    /// Always succeeds: returns empty bytes on any error so callers do not
    /// need to handle failures (ADR 0002 "scrollback seed" — attach must
    /// succeed even when capture is unavailable).
    pub async fn capture_pane(&self, surface_id: &SurfaceId, lines: Option<i32>) -> TmuxCapture {
        // Resolve to the same tmux pane id that send_input uses. If we
        // cannot find a mapping yet (capture racing the first %output),
        // fall back to <session>:0 so the seed is at least *something*.
        let target = match self.surface_map.lookup_pane(surface_id).await {
            Some(pane_id) => pane_id,
            None => format!("{}:0", self.session_name),
        };
        let alternate_on = if lines.is_none() {
            self.pane_alternate_on(&target).await
        } else {
            None
        };
        for (cmd, alternate_screen) in capture_pane_commands(&target, lines, alternate_on) {
            if let Ok(out) = tokio::process::Command::new("ssh")
                .args([
                    "-o",
                    "StrictHostKeyChecking=accept-new",
                    "-o",
                    "LogLevel=QUIET",
                    "-o",
                    "ConnectTimeout=5",
                    &self.host,
                    &cmd,
                ])
                .output()
                .await
            {
                if out.status.success() {
                    if alternate_screen && alternate_on.is_none() && out.stdout.is_empty() {
                        continue;
                    }
                    return TmuxCapture {
                        bytes: out.stdout,
                        alternate_screen,
                    };
                }
            }
        }
        TmuxCapture {
            bytes: Vec::new(),
            alternate_screen: false,
        }
    }

    async fn pane_alternate_on(&self, target: &str) -> Option<bool> {
        let cmd = format!(
            "tmux display-message -p -t {} '#{{alternate_on}}'",
            shell_single_quote(target)
        );
        let out = tokio::process::Command::new("ssh")
            .args([
                "-o",
                "StrictHostKeyChecking=accept-new",
                "-o",
                "LogLevel=QUIET",
                "-o",
                "ConnectTimeout=5",
                &self.host,
                &cmd,
            ])
            .output()
            .await
            .ok()?;
        if !out.status.success() {
            return None;
        }
        match String::from_utf8_lossy(&out.stdout).trim() {
            "1" => Some(true),
            "0" => Some(false),
            _ => None,
        }
    }
}

impl RemoteMultiplexerBackend for TmuxControlBackend {
    /// Phase 1.0: return a single placeholder workspace representing the remote
    /// tmux session.  Multi-window enumeration is Phase 1.2+.
    async fn list_workspaces(&self) -> Result<Vec<RemoteWorkspace>> {
        Ok(vec![RemoteWorkspace {
            id: format!("tmux:{}@{}", self.session_name, self.host),
            name: self.session_name.clone(),
            surfaces: vec![],
        }])
    }

    /// Attach to a surface and return a byte-stream receiver.
    ///
    /// The SSH process is started on the first call.  Subsequent calls reuse
    /// the same process.  Per ADR 0002 §"Session lifecycle".
    async fn attach_surface(
        &self,
        surface_id: SurfaceId,
        size: CellSize,
    ) -> Result<RemoteSurfaceStream> {
        self.attach_surface_with_options(surface_id, size, false)
            .await
    }

    async fn send_input(&self, surface_id: SurfaceId, bytes: Vec<u8>) -> Result<()> {
        self.send_input_impl(surface_id, bytes).await
    }

    /// Per ADR 0002 §"Input routing" — encode bytes as hex and forward to the
    /// tmux pane via `send-keys -H`.
    async fn resize(&self, surface_id: SurfaceId, size: CellSize) -> Result<()> {
        self.resize_impl(surface_id, size).await
    }

    async fn control(&self, command: WorkspaceControl) -> Result<()> {
        self.control_impl(command).await
    }
}

impl TmuxControlBackend {
    pub async fn attach_surface_with_options(
        &self,
        surface_id: SurfaceId,
        size: CellSize,
        create_if_missing: bool,
    ) -> Result<RemoteSurfaceStream> {
        self.ensure_session_exists(size, create_if_missing).await?;

        let (per_surface_tx, per_surface_rx) = mpsc::channel::<Vec<u8>>(4096);

        self.surface_senders
            .write()
            .await
            .insert(surface_id.clone(), per_surface_tx);

        // Start the session process if this is the first attach.
        let mut sess_guard = self.tmux_session.write().await;
        if sess_guard.is_none() {
            let (raw_sess, session_rx) =
                session::TmuxSession::connect(&self.host, &self.session_name).await?;
            let sess = Arc::new(raw_sess);

            // Send initial terminal size.
            sess.write_command(&encoder::refresh_client_size(size.cols, size.rows))
                .await?;

            // Pre-register the *active* tmux pane so send_input works
            // immediately without waiting for the first %output frame. With
            // multi-pane support we cannot blindly pick `list-panes`'s first
            // row — it would bind the caller's surface to whichever pane
            // happened to be created first, which is almost never the user's
            // currently focused pane. We prefer the active pane and fall back
            // to the first listed pane only when the query fails.
            //
            // `#{...}` is single-quoted to prevent the remote shell from
            // treating `#` as a comment character when SSH joins arguments.
            let panes = self.fetch_panes().await.unwrap_or_default();
            let primary_pane_id = panes
                .iter()
                .find(|p| p.active)
                .or_else(|| panes.first())
                .map(|p| p.pane_id.clone());
            if let Some(pane_id) = primary_pane_id {
                self.surface_map.register(pane_id, surface_id.clone()).await;
            }

            // Retain the session handle for send_input / resize.
            *sess_guard = Some(Arc::clone(&sess));

            // Demux task: fan-out raw PTY output to per-surface channels and
            // to the broadcast channel for subscribe_output() callers.
            //
            // `session_rx` delivers (SurfaceId(real_pane_id), bytes) where
            // real_pane_id is the tmux control-mode id (e.g. "%1"). The
            // demux only routes frames whose pane_id has been explicitly
            // registered (via attach_surface or attach_additional_pane);
            // unknown panes are still broadcast so subscribers can see them,
            // but their bytes are not forwarded to any per-surface mpsc.
            //
            // Frames for not-yet-attached panes are dropped intentionally —
            // callers that attach additional panes later issue
            // `multiplexer.tmux.capture` to seed the visible screen, per
            // ADR 0002 §"Scrollback seed".

            let senders = Arc::clone(&self.surface_senders);
            let output_tx = self.output_tx.clone();
            let notify_tx = self.notify_tx.clone();
            let surface_map_demux = self.surface_map.clone();
            let mut demux_rx = session_rx;
            tokio::spawn(async move {
                use session::SessionFrame;
                while let Some(frame) = demux_rx.recv().await {
                    match frame {
                        SessionFrame::Output { surface_id, bytes } => {
                            let pane_id = surface_id.0;
                            let mapped_surface =
                                surface_map_demux.lookup_surface(&pane_id).await;
                            if let Some(ref surf) = mapped_surface {
                                let per_surface_tx = {
                                    senders
                                        .read()
                                        .await
                                        .get(surf)
                                        .filter(|tx| !tx.is_closed())
                                        .cloned()
                                };
                                if let Some(tx) = per_surface_tx {
                                    let _ = tx.try_send(bytes.clone());
                                }
                            }
                            let broadcast_surface = mapped_surface
                                .unwrap_or_else(|| SurfaceId(format!("unmapped:{}", pane_id)));
                            let _ = output_tx.send(OutputFrame {
                                surface_id: broadcast_surface,
                                pane_id,
                                bytes,
                            });
                        }
                        SessionFrame::LayoutChange {
                            window_id,
                            raw,
                            layout,
                        } => {
                            // No subscribers is the steady state for sessions
                            // whose client (CLI relay) does not care about
                            // topology — send errors are intentionally swallowed.
                            let _ = notify_tx.send(NotifyEvent::LayoutChange {
                                window_id,
                                raw,
                                layout,
                            });
                        }
                    }
                }
            });
        }

        Ok(per_surface_rx)
    }

    /// Phase 1.1: snapshot all panes in the attached window via a one-shot
    /// SSH `tmux list-panes`. Does *not* require the control session to be
    /// open — useful as a discovery step before deciding what to attach.
    pub async fn list_panes(&self) -> Result<Vec<RemotePane>> {
        self.fetch_panes().await
    }

    async fn fetch_panes(&self) -> Result<Vec<RemotePane>> {
        // Format string is single-quoted to keep `#{...}` away from remote
        // shell expansion. Tabs separate fields so command names containing
        // spaces (e.g. "/usr/bin/python3 -m foo") stay in one column.
        let fmt = "#{pane_id}\t#{pane_index}\t#{pane_active}\t#{pane_width}\t#{pane_height}\t#{pane_current_command}";
        let cmd = format!(
            "tmux list-panes -t {} -F {}",
            shell_single_quote(&self.session_name),
            shell_single_quote(fmt)
        );
        let out = tokio::process::Command::new("ssh")
            .args([
                "-o",
                "BatchMode=yes",
                "-o",
                "StrictHostKeyChecking=accept-new",
                "-o",
                "LogLevel=QUIET",
                "-o",
                "ConnectTimeout=5",
                &self.host,
                &cmd,
            ])
            .output()
            .await
            .map_err(|e| anyhow!("ssh list-panes failed: {e}"))?;
        if !out.status.success() {
            return Err(anyhow!(
                "tmux list-panes failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        Ok(parse_list_panes(&String::from_utf8_lossy(&out.stdout)))
    }

    /// Phase 1.1: fetch the active window's layout string and parse it.
    /// Returns Err on either an SSH failure or a parse error so the caller
    /// can decide whether to retry or fall back to `list_panes`.
    pub async fn current_layout(&self) -> Result<layout::WindowLayout> {
        let cmd = format!(
            "tmux display-message -p -t {} {}",
            shell_single_quote(&self.session_name),
            shell_single_quote("#{window_layout}")
        );
        let out = tokio::process::Command::new("ssh")
            .args([
                "-o",
                "BatchMode=yes",
                "-o",
                "StrictHostKeyChecking=accept-new",
                "-o",
                "LogLevel=QUIET",
                "-o",
                "ConnectTimeout=5",
                &self.host,
                &cmd,
            ])
            .output()
            .await
            .map_err(|e| anyhow!("ssh display-message failed: {e}"))?;
        if !out.status.success() {
            return Err(anyhow!(
                "tmux display-message failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        let raw = String::from_utf8_lossy(&out.stdout);
        layout::parse_window_layout(raw.trim())
    }

    /// Phase 1.1: attach an additional pane on the existing SSH+tmux session.
    /// Returns a freshly minted SurfaceId paired with its byte-stream
    /// receiver. `attach_surface` (or `attach_surface_with_options`) must
    /// have been called first — this method reuses that session and refuses
    /// to bootstrap a new one.
    ///
    /// The pane is also resized via `refresh-client -C` so the new surface
    /// matches the caller's terminal dimensions.
    pub async fn attach_additional_pane(
        &self,
        pane_id: &str,
        size: CellSize,
    ) -> Result<(SurfaceId, RemoteSurfaceStream)> {
        let sess_guard = self.tmux_session.read().await;
        if sess_guard.is_none() {
            return Err(anyhow!(
                "attach_additional_pane requires an active session — call attach_surface first"
            ));
        }
        drop(sess_guard);

        // Reject re-attach against the same pane: the existing SurfaceId
        // already owns the routing slot and overwriting it would silently
        // strand the previous mpsc receiver.
        if let Some(existing) = self.surface_map.lookup_surface(pane_id).await {
            return Err(anyhow!(
                "pane {pane_id} is already attached as surface {}",
                existing.0
            ));
        }

        let surface_id = SurfaceId(uuid::Uuid::new_v4().to_string());
        let (tx, rx) = mpsc::channel::<Vec<u8>>(4096);
        self.surface_senders
            .write()
            .await
            .insert(surface_id.clone(), tx);
        self.surface_map.register(pane_id, surface_id.clone()).await;

        // Push the caller's size to tmux so the newly attached pane redraws
        // at the right width/height. Errors are swallowed — resize is a
        // best-effort sync, not a hard precondition for attach success.
        let _ = self.resize_impl(surface_id.clone(), size).await;

        Ok((surface_id, rx))
    }

    async fn send_input_impl(&self, surface_id: SurfaceId, bytes: Vec<u8>) -> Result<()> {
        let sess_guard = self.tmux_session.read().await;
        let sess = sess_guard
            .as_ref()
            .ok_or_else(|| anyhow!("no active session — call attach_surface first"))?;

        let pane_id = self
            .surface_map
            .lookup_pane(&surface_id)
            .await
            .ok_or_else(|| anyhow!("unknown surface {:?}", surface_id.0))?;

        let cmd = encoder::send_keys_hex(&pane_id, &bytes);
        sess.write_command(&cmd).await
    }

    /// Phase 1.1 resize policy: each attached surface drives its own pane
    /// via `resize-pane -t %N -x cols -y rows`.
    ///
    /// The previous client-wide `refresh-client -C` was racy under the
    /// multi-pane mirror (Step 5+): N secondary relays each running
    /// SIGWINCH would call resize() with their own slot dimensions, and
    /// whichever update arrived last would shrink the entire client view
    /// to one slot's size — leaving panes mis-sized and content clipped.
    ///
    /// resize-pane targets a specific pane and is idempotent under
    /// concurrent calls against different panes. tmux re-balances the
    /// surrounding layout to satisfy each absolute size.
    ///
    /// If the surface has no registered pane id yet (e.g. attach RPC
    /// raced ahead of the first %output mapping), fall back to the
    /// client-wide refresh so the initial size still propagates.
    async fn resize_impl(&self, surface_id: SurfaceId, size: CellSize) -> Result<()> {
        let sess = self.tmux_session.read().await;
        let sess = sess
            .as_ref()
            .ok_or_else(|| anyhow!("no active session — call attach_surface first"))?;
        let cmd = match self.surface_map.lookup_pane(&surface_id).await {
            Some(pane_id) => encoder::resize_pane(&pane_id, size.cols, size.rows),
            None => encoder::refresh_client_size(size.cols, size.rows),
        };
        sess.write_command(&cmd).await
    }

    /// Per ADR 0002 §"WorkspaceControl encoding" — dispatch pane lifecycle
    /// commands through the control-mode session.
    async fn control_impl(&self, command: WorkspaceControl) -> Result<()> {
        let sess = self.tmux_session.read().await;
        let sess = sess
            .as_ref()
            .ok_or_else(|| anyhow!("no active session — call attach_surface first"))?;
        let cmd = match command {
            WorkspaceControl::SplitPane { pane_id, direction } => {
                encoder::split_window(&pane_id, direction)
            }
            WorkspaceControl::KillPane { pane_id } => encoder::kill_pane(&pane_id),
            WorkspaceControl::SelectPane { pane_id } => encoder::select_pane(&pane_id),
        };
        sess.write_command(&cmd).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::multiplexer::SplitDirection;
    use std::time::Duration;
    use tokio::io::AsyncBufReadExt;
    use tokio::process::Command;
    use tokio::sync::mpsc;

    fn make_fake_session() -> (session::TmuxSession, tokio::process::ChildStdout) {
        let mut child = Command::new("cat")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, _rx) = mpsc::channel(1);
        (session::TmuxSession::from_parts(child, stdin, tx), stdout)
    }

    async fn read_line(stdout: tokio::process::ChildStdout) -> String {
        let mut reader = tokio::io::BufReader::new(stdout).lines();
        tokio::time::timeout(Duration::from_secs(1), reader.next_line())
            .await
            .expect("timeout")
            .expect("io error")
            .expect("eof")
    }

    // ── send_input ────────────────────────────────────────────────────────────

    #[tokio::test]
    async fn send_input_no_session_returns_error() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let result = backend
            .send_input(SurfaceId("pane-1".into()), b"hello".to_vec())
            .await;
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("no active session"));
    }

    #[tokio::test]
    async fn send_input_unknown_surface_returns_error() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, _stdout) = make_fake_session();
        *backend.tmux_session.write().await = Some(Arc::new(sess));

        let result = backend
            .send_input(SurfaceId("ghost".into()), b"x".to_vec())
            .await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("ghost"));
    }

    #[tokio::test]
    async fn send_input_writes_send_keys_hex_command() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, stdout) = make_fake_session();
        backend
            .inject_for_test(sess, "%1", SurfaceId("surf-1".into()))
            .await;

        backend
            .send_input(SurfaceId("surf-1".into()), vec![0x41, 0x42])
            .await
            .unwrap();
        assert_eq!(read_line(stdout).await, "send-keys -t %1 -H 41 42");
    }

    // ── resize ────────────────────────────────────────────────────────────────

    #[tokio::test]
    async fn resize_no_session_returns_error() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let result = backend
            .resize(SurfaceId("s".into()), CellSize { cols: 80, rows: 24 })
            .await;
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("no active session"));
    }

    #[tokio::test]
    async fn resize_falls_back_to_refresh_client_when_pane_unmapped() {
        // Phase 1.1: resize() prefers per-pane `resize-pane` once the
        // surface has a known pane id. With no mapping yet (e.g. before
        // the first %output frame), it falls back to the client-wide
        // refresh so the initial size still reaches tmux.
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, stdout) = make_fake_session();
        *backend.tmux_session.write().await = Some(Arc::new(sess));

        backend
            .resize(
                SurfaceId("s".into()),
                CellSize {
                    cols: 120,
                    rows: 40,
                },
            )
            .await
            .unwrap();
        assert_eq!(read_line(stdout).await, "refresh-client -C 120x40");
    }

    #[tokio::test]
    async fn resize_targets_mapped_pane_with_resize_pane() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, stdout) = make_fake_session();
        backend
            .inject_for_test(sess, "%3", SurfaceId("surf-x".into()))
            .await;

        backend
            .resize(
                SurfaceId("surf-x".into()),
                CellSize {
                    cols: 100,
                    rows: 30,
                },
            )
            .await
            .unwrap();
        assert_eq!(read_line(stdout).await, "resize-pane -t %3 -x 100 -y 30");
    }

    // ── control ───────────────────────────────────────────────────────────────

    #[tokio::test]
    async fn control_split_writes_split_window() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, stdout) = make_fake_session();
        *backend.tmux_session.write().await = Some(Arc::new(sess));

        backend
            .control(WorkspaceControl::SplitPane {
                pane_id: "%1".into(),
                direction: SplitDirection::Horizontal,
            })
            .await
            .unwrap();
        assert_eq!(read_line(stdout).await, "split-window -h -t %1");
    }

    #[tokio::test]
    async fn control_kill_writes_kill_pane() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, stdout) = make_fake_session();
        *backend.tmux_session.write().await = Some(Arc::new(sess));

        backend
            .control(WorkspaceControl::KillPane {
                pane_id: "%2".into(),
            })
            .await
            .unwrap();
        assert_eq!(read_line(stdout).await, "kill-pane -t %2");
    }

    #[tokio::test]
    async fn control_select_writes_select_pane() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, stdout) = make_fake_session();
        *backend.tmux_session.write().await = Some(Arc::new(sess));

        backend
            .control(WorkspaceControl::SelectPane {
                pane_id: "%3".into(),
            })
            .await
            .unwrap();
        assert_eq!(read_line(stdout).await, "select-pane -t %3");
    }

    // ── subscribe_output broadcast ────────────────────────────────────────────

    #[tokio::test]
    async fn subscribe_output_receives_injected_frame() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let mut rx = backend.subscribe_output();

        let frame = OutputFrame {
            surface_id: SurfaceId("surf-42".into()),
            pane_id: "%1".into(),
            bytes: b"hello broadcast".to_vec(),
        };
        backend.inject_output_frame_for_test(frame);

        let received = tokio::time::timeout(Duration::from_millis(200), rx.recv())
            .await
            .expect("timeout waiting for broadcast frame")
            .expect("broadcast channel closed");

        assert_eq!(received.pane_id, "%1");
        assert_eq!(received.surface_id.0, "surf-42");
        assert_eq!(received.bytes, b"hello broadcast");
    }

    #[tokio::test]
    async fn multiple_subscribers_each_receive_frame() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let mut rx1 = backend.subscribe_output();
        let mut rx2 = backend.subscribe_output();

        backend.inject_output_frame_for_test(OutputFrame {
            surface_id: SurfaceId("s".into()),
            pane_id: "%2".into(),
            bytes: vec![0x41],
        });

        let f1 = tokio::time::timeout(Duration::from_millis(200), rx1.recv())
            .await
            .unwrap()
            .unwrap();
        let f2 = tokio::time::timeout(Duration::from_millis(200), rx2.recv())
            .await
            .unwrap()
            .unwrap();

        assert_eq!(f1.pane_id, "%2");
        assert_eq!(f2.pane_id, "%2");
    }

    #[test]
    fn capture_pane_prefers_alternate_screen_for_visible_snapshot() {
        let cmds = capture_pane_commands("%1", None, Some(true));
        assert_eq!(cmds.len(), 2);
        assert!(cmds[0].0.contains("capture-pane -a -q -e -p"));
        assert!(cmds[0].1);
        assert!(cmds[1].0.contains("capture-pane -e -p"));
        assert!(!cmds[1].0.contains(" -a "));
        assert!(!cmds[1].1);
        assert!(!cmds[0].0.contains(" -N "));
    }

    #[test]
    fn capture_pane_uses_primary_when_alternate_screen_is_off() {
        let cmds = capture_pane_commands("%1", None, Some(false));
        assert_eq!(cmds.len(), 1);
        assert!(cmds[0].0.contains("capture-pane -e -p"));
        assert!(!cmds[0].0.contains(" -a "));
        assert!(!cmds[0].1);
    }

    #[test]
    fn capture_pane_preserves_trailing_spaces_for_scrollback() {
        let cmds = capture_pane_commands("%1", Some(200), None);
        assert_eq!(
            cmds,
            vec![("tmux capture-pane -e -p -N -S -200 -t '%1'".into(), false)]
        );
    }

    // ── parse_list_panes ─────────────────────────────────────────────────────

    #[test]
    fn parse_list_panes_extracts_full_pane_metadata() {
        let raw = concat!(
            "%1\t0\t1\t80\t24\tzsh\n",
            "%2\t1\t0\t40\t24\tvim\n",
        );
        let panes = parse_list_panes(raw);
        assert_eq!(
            panes,
            vec![
                RemotePane {
                    pane_id: "%1".into(),
                    pane_index: 0,
                    active: true,
                    width: 80,
                    height: 24,
                    command: "zsh".into(),
                },
                RemotePane {
                    pane_id: "%2".into(),
                    pane_index: 1,
                    active: false,
                    width: 40,
                    height: 24,
                    command: "vim".into(),
                },
            ]
        );
    }

    #[test]
    fn parse_list_panes_drops_rows_with_missing_fields() {
        // Last row only has 3 fields → discarded; first two still parse.
        let raw = "%1\t0\t1\t80\t24\tzsh\n%2\t1\t0\n";
        let panes = parse_list_panes(raw);
        assert_eq!(panes.len(), 1);
        assert_eq!(panes[0].pane_id, "%1");
    }

    // ── attach_additional_pane ───────────────────────────────────────────────

    #[tokio::test]
    async fn attach_additional_pane_without_session_errors() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let err = backend
            .attach_additional_pane("%2", CellSize { cols: 80, rows: 24 })
            .await
            .unwrap_err();
        assert!(err.to_string().contains("requires an active session"));
    }

    #[tokio::test]
    async fn attach_additional_pane_rejects_duplicate_pane() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, _stdout) = make_fake_session();
        backend
            .inject_for_test(sess, "%1", SurfaceId("primary".into()))
            .await;

        let err = backend
            .attach_additional_pane("%1", CellSize { cols: 80, rows: 24 })
            .await
            .unwrap_err();
        assert!(err.to_string().contains("already attached"));
    }

    #[tokio::test]
    async fn attach_additional_pane_registers_new_surface_and_resizes() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, stdout) = make_fake_session();
        backend
            .inject_for_test(sess, "%1", SurfaceId("primary".into()))
            .await;

        let (sid, _rx) = backend
            .attach_additional_pane("%2", CellSize { cols: 120, rows: 40 })
            .await
            .unwrap();
        assert_ne!(sid.0, "primary");
        // Pane → surface mapping is bidirectional.
        let resolved = backend.surface_map.lookup_surface("%2").await;
        assert_eq!(resolved.as_ref().map(|s| s.0.as_str()), Some(sid.0.as_str()));
        // attach_additional_pane registers the pane *before* the
        // best-effort resize, so the resize takes the per-pane path
        // (Phase 1.1 multi-pane fix).
        assert_eq!(read_line(stdout).await, "resize-pane -t %2 -x 120 -y 40");
    }
}
