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
use tokio::sync::{mpsc, RwLock};

use crate::multiplexer::{
    CellSize, RemoteMultiplexerBackend, RemoteSurfaceStream, RemoteWorkspace, SurfaceId,
    WorkspaceControl,
};
use surface::SurfaceMap;

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
}

impl TmuxControlBackend {
    /// Create a backend referencing a remote SSH host and tmux session name.
    ///
    /// The SSH process is not started until `attach_surface` is called for the
    /// first time.
    pub fn new(host: impl Into<String>, session: impl Into<String>) -> Self {
        Self {
            host: host.into(),
            session_name: session.into(),
            surface_map: SurfaceMap::new(),
            tmux_session: Arc::new(RwLock::new(None)),
            surface_senders: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Test-only: inject a pre-built session and register a surface mapping.
    #[cfg(test)]
    async fn inject_for_test(&self, sess: session::TmuxSession, pane_id: &str, surface_id: SurfaceId) {
        *self.tmux_session.write().await = Some(Arc::new(sess));
        self.surface_map.register(pane_id, surface_id).await;
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

        // Register the surface so the demux task can route output to it.
        self.surface_map.register(surface_id.0.clone(), surface_id.clone()).await;
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

            // Demux task: fan-out raw PTY output to per-surface channels.
            let senders = Arc::clone(&self.surface_senders);
            let mut demux_rx = session_rx;
            tokio::spawn(async move {
                while let Some((sid, bytes)) = demux_rx.recv().await {
                    if let Some(tx) = senders.read().await.get(&sid) {
                        let _ = tx.send(bytes).await;
                    }
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

    async fn resize(&self, surface_id: SurfaceId, size: CellSize) -> Result<()> {
        let _ = (surface_id, size);
        // Phase 1.1 next slice: send refresh_client_size via write_command
        Ok(())
    }

    async fn control(&self, command: WorkspaceControl) -> Result<()> {
        let _ = command;
        // Phase 1.2+
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::process::Command;
    use tokio::sync::mpsc;
    use tokio::io::AsyncBufReadExt;
    use std::time::Duration;

    fn make_fake_session() -> (session::TmuxSession, tokio::process::ChildStdout) {
        // Use `cat` as a fake tmux stdin sink + stdout echo.
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
        // Inject session but do NOT register the surface being sent to.
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

        // Send bytes 0x41 0x42 ('A' 'B') — expect "send-keys -t %1 -H 41 42"
        backend.send_input(SurfaceId("surf-1".into()), vec![0x41, 0x42]).await.unwrap();

        let mut reader = tokio::io::BufReader::new(stdout).lines();
        let line = tokio::time::timeout(Duration::from_secs(1), reader.next_line())
            .await
            .expect("timeout waiting for command")
            .expect("io error")
            .expect("eof before command");
        assert_eq!(line, "send-keys -t %1 -H 41 42");
    }
}
