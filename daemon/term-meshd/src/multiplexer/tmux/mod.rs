//! tmux control-mode backend — ADR 0002 Phase 1.1.
//!
//! `TmuxControlBackend` implements `RemoteMultiplexerBackend` using
//! `ssh <host> tmux -CC` as the transport.
//!
//! Phase 1.0: parser, octal unescape, encoder, surface map, session skeleton.
//! Phase 1.1: `send_input` wired through `TmuxSession::write_command` +
//!             `encoder::send_keys_hex`; session handle retained after connect.

pub mod encoder;
pub mod octal;
pub mod parser;
pub mod session;
pub mod surface;

use std::collections::HashMap;
use std::sync::Arc;
use anyhow::{anyhow, Result};
use tokio::sync::{broadcast, mpsc, RwLock};

use crate::multiplexer::{
    CellSize, RemoteMultiplexerBackend, RemoteSurfaceStream, RemoteWorkspace,
    SurfaceId, WorkspaceControl,
};
use surface::SurfaceMap;

/// A parsed PTY output frame from a remote tmux pane.  Broadcast to all active
/// `subscribe_output()` receivers.
#[derive(Clone)]
pub struct OutputFrame {
    pub surface_id: SurfaceId,
    /// Raw tmux pane-id (e.g. `%1`).
    pub pane_id: String,
    pub bytes: Vec<u8>,
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
}

impl TmuxControlBackend {
    /// Create a backend referencing a remote SSH host and tmux session name.
    ///
    /// The SSH process is not started until `attach_surface` is called for the
    /// first time.
    pub fn new(host: impl Into<String>, session: impl Into<String>) -> Self {
        let (output_tx, _) = broadcast::channel(256);
        Self {
            host: host.into(),
            session_name: session.into(),
            surface_map: SurfaceMap::new(),
            tmux_session: Arc::new(RwLock::new(None)),
            surface_senders: Arc::new(RwLock::new(HashMap::new())),
            output_tx,
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

    /// Test-only: inject a pre-built session and register a surface mapping.
    #[cfg(test)]
    async fn inject_for_test(&self, sess: session::TmuxSession, pane_id: &str, surface_id: SurfaceId) {
        *self.tmux_session.write().await = Some(Arc::new(sess));
        self.surface_map.register(pane_id, surface_id).await;
    }

    /// Test-only: directly send an OutputFrame on the broadcast channel.
    #[cfg(test)]
    pub fn inject_output_frame_for_test(&self, frame: OutputFrame) {
        let _ = self.output_tx.send(frame);
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
        let (per_surface_tx, per_surface_rx) = mpsc::channel::<Vec<u8>>(256);

        self.surface_senders.write().await.insert(surface_id.clone(), per_surface_tx);

        // Start the session process if this is the first attach.
        let mut sess_guard = self.tmux_session.write().await;
        if sess_guard.is_none() {
            let (raw_sess, session_rx) =
                session::TmuxSession::connect(&self.host, &self.session_name).await?;
            let sess = Arc::new(raw_sess);

            // Send initial terminal size.
            sess.write_command(&encoder::refresh_client_size(size.cols, size.rows)).await?;

            // Retain the session handle for send_input / resize.
            *sess_guard = Some(Arc::clone(&sess));

            // Demux task: fan-out raw PTY output to per-surface channels and
            // to the broadcast channel for subscribe_output() callers.
            //
            // `session_rx` delivers (SurfaceId(real_pane_id), bytes) where
            // real_pane_id is the tmux control-mode id (e.g. "%1").  On the
            // first frame we lazy-register real_pane_id → surface_id so that
            // send_input / lookup_pane works without requiring a separate
            // list-panes round-trip.
            let senders = Arc::clone(&self.surface_senders);
            let output_tx = self.output_tx.clone();
            let surface_map_demux = self.surface_map.clone();
            let surface_id_demux = surface_id.clone();
            let mut demux_rx = session_rx;
            tokio::spawn(async move {
                let mut pane_registered = false;
                while let Some((sid, bytes)) = demux_rx.recv().await {
                    // sid.0 is the real tmux pane_id (e.g. "%1").
                    if !pane_registered {
                        surface_map_demux
                            .register(sid.0.clone(), surface_id_demux.clone())
                            .await;
                        pane_registered = true;
                    }
                    // Per-surface mpsc — keyed by UUID surface_id, not pane_id.
                    if let Some(tx) = senders.read().await.get(&surface_id_demux) {
                        let _ = tx.send(bytes.clone()).await;
                    }
                    // Broadcast with the UUID surface_id so subscribers can
                    // correlate frames back to their attach call.
                    let pane_id = sid.0.clone();
                    let _ = output_tx.send(OutputFrame {
                        surface_id: surface_id_demux.clone(),
                        pane_id,
                        bytes,
                    });
                }
            });
        }

        Ok(per_surface_rx)
    }

    /// Per ADR 0002 §"Input routing" — encode bytes as hex and forward to the
    /// tmux pane via `send-keys -H`.
    async fn send_input(&self, surface_id: SurfaceId, bytes: Vec<u8>) -> Result<()> {
        let sess_guard = self.tmux_session.read().await;
        let sess = sess_guard
            .as_ref()
            .ok_or_else(|| anyhow!("no active session — call attach_surface first"))?;

        let pane_id = self.surface_map
            .lookup_pane(&surface_id)
            .await
            .ok_or_else(|| anyhow!("unknown surface {:?}", surface_id.0))?;

        let cmd = encoder::send_keys_hex(&pane_id, &bytes);
        sess.write_command(&cmd).await
    }

    /// Per ADR 0002 §"Resize Policy": resize applies to the tmux client as a
    /// whole (`refresh-client -C`).  `surface_id` is accepted for API symmetry
    /// but is not used to scope the resize to an individual pane.
    async fn resize(&self, _surface_id: SurfaceId, size: CellSize) -> Result<()> {
        let sess = self.tmux_session.read().await;
        let sess = sess
            .as_ref()
            .ok_or_else(|| anyhow!("no active session — call attach_surface first"))?;
        sess.write_command(&encoder::refresh_client_size(size.cols, size.rows)).await
    }

    /// Per ADR 0002 §"WorkspaceControl encoding" — dispatch pane lifecycle
    /// commands through the control-mode session.
    async fn control(&self, command: WorkspaceControl) -> Result<()> {
        let sess = self.tmux_session.read().await;
        let sess = sess
            .as_ref()
            .ok_or_else(|| anyhow!("no active session — call attach_surface first"))?;
        let cmd = match command {
            WorkspaceControl::SplitPane { pane_id, direction } =>
                encoder::split_window(&pane_id, direction),
            WorkspaceControl::KillPane { pane_id } =>
                encoder::kill_pane(&pane_id),
            WorkspaceControl::SelectPane { pane_id } =>
                encoder::select_pane(&pane_id),
        };
        sess.write_command(&cmd).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::multiplexer::SplitDirection;
    use tokio::process::Command;
    use tokio::sync::mpsc;
    use tokio::io::AsyncBufReadExt;
    use std::time::Duration;

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
        let result = backend.send_input(SurfaceId("pane-1".into()), b"hello".to_vec()).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("no active session"));
    }

    #[tokio::test]
    async fn send_input_unknown_surface_returns_error() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, _stdout) = make_fake_session();
        *backend.tmux_session.write().await = Some(Arc::new(sess));

        let result = backend.send_input(SurfaceId("ghost".into()), b"x".to_vec()).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("ghost"));
    }

    #[tokio::test]
    async fn send_input_writes_send_keys_hex_command() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, stdout) = make_fake_session();
        backend.inject_for_test(sess, "%1", SurfaceId("surf-1".into())).await;

        backend.send_input(SurfaceId("surf-1".into()), vec![0x41, 0x42]).await.unwrap();
        assert_eq!(read_line(stdout).await, "send-keys -t %1 -H 41 42");
    }

    // ── resize ────────────────────────────────────────────────────────────────

    #[tokio::test]
    async fn resize_no_session_returns_error() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let result = backend.resize(SurfaceId("s".into()), CellSize { cols: 80, rows: 24 }).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("no active session"));
    }

    #[tokio::test]
    async fn resize_writes_refresh_client_command() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, stdout) = make_fake_session();
        *backend.tmux_session.write().await = Some(Arc::new(sess));

        backend.resize(SurfaceId("s".into()), CellSize { cols: 120, rows: 40 }).await.unwrap();
        assert_eq!(read_line(stdout).await, "refresh-client -C 120x40");
    }

    // ── control ───────────────────────────────────────────────────────────────

    #[tokio::test]
    async fn control_split_writes_split_window() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, stdout) = make_fake_session();
        *backend.tmux_session.write().await = Some(Arc::new(sess));

        backend.control(WorkspaceControl::SplitPane {
            pane_id: "%1".into(),
            direction: SplitDirection::Horizontal,
        }).await.unwrap();
        assert_eq!(read_line(stdout).await, "split-window -h -t %1");
    }

    #[tokio::test]
    async fn control_kill_writes_kill_pane() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, stdout) = make_fake_session();
        *backend.tmux_session.write().await = Some(Arc::new(sess));

        backend.control(WorkspaceControl::KillPane { pane_id: "%2".into() }).await.unwrap();
        assert_eq!(read_line(stdout).await, "kill-pane -t %2");
    }

    #[tokio::test]
    async fn control_select_writes_select_pane() {
        let backend = TmuxControlBackend::new("localhost", "test-session");
        let (sess, stdout) = make_fake_session();
        *backend.tmux_session.write().await = Some(Arc::new(sess));

        backend.control(WorkspaceControl::SelectPane { pane_id: "%3".into() }).await.unwrap();
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
            .await.unwrap().unwrap();
        let f2 = tokio::time::timeout(Duration::from_millis(200), rx2.recv())
            .await.unwrap().unwrap();

        assert_eq!(f1.pane_id, "%2");
        assert_eq!(f2.pane_id, "%2");
    }
}
