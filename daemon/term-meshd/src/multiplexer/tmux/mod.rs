//! tmux control-mode backend — ADR 0002 Phase 1.0 skeleton.
//!
//! `TmuxControlBackend` implements `RemoteMultiplexerBackend` using
//! `ssh <host> tmux -CC` as the transport.  Phase 1.0 stubs list_workspaces
//! with a placeholder workspace; attach_surface wires the parser to a channel.

pub mod encoder;
pub mod octal;
pub mod parser;
pub mod session;
pub mod surface;

use std::sync::Arc;
use anyhow::Result;
use tokio::sync::{mpsc, RwLock};

use crate::multiplexer::{
    CellSize, RemoteMultiplexerBackend, RemoteSurfaceStream, RemoteWorkspace, SurfaceId,
    WorkspaceControl,
};
use surface::SurfaceMap;

/// Backend handle for a single remote `ssh tmux -CC` session.
pub struct TmuxControlBackend {
    host: String,
    session: String,
    surface_map: SurfaceMap,
    /// Multiplexed raw output from the session process.
    /// `None` until `attach_surface` is first called.
    output_rx: Arc<RwLock<Option<mpsc::Receiver<(SurfaceId, Vec<u8>)>>>>,
    /// Per-surface channel senders, keyed by SurfaceId.
    surface_senders: Arc<RwLock<std::collections::HashMap<SurfaceId, mpsc::Sender<Vec<u8>>>>>,
}

impl TmuxControlBackend {
    /// Create a backend referencing a remote SSH host and tmux session name.
    ///
    /// The underlying SSH process is not started until `attach_surface` is
    /// called for the first time.
    pub fn new(host: impl Into<String>, session: impl Into<String>) -> Self {
        Self {
            host: host.into(),
            session: session.into(),
            surface_map: SurfaceMap::new(),
            output_rx: Arc::new(RwLock::new(None)),
            surface_senders: Arc::new(RwLock::new(std::collections::HashMap::new())),
        }
    }
}

impl RemoteMultiplexerBackend for TmuxControlBackend {
    /// Phase 1.0: return a single placeholder workspace representing the remote
    /// tmux session.  Multi-window enumeration is Phase 1.2+.
    async fn list_workspaces(&self) -> Result<Vec<RemoteWorkspace>> {
        Ok(vec![RemoteWorkspace {
            id: format!("tmux:{}@{}", self.session, self.host),
            name: self.session.clone(),
            surfaces: vec![],
        }])
    }

    /// Attach to a surface and return a byte-stream receiver.
    ///
    /// Phase 1.0: the SSH process is started on first attach.  The receiver
    /// delivers raw PTY bytes for the requested pane.  Demultiplexing from the
    /// shared session output happens in a background tokio task.
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
        {
            let mut rx_guard = self.output_rx.write().await;
            if rx_guard.is_none() {
                let (sess, session_rx) =
                    session::TmuxSession::connect(&self.host, &self.session).await?;
                // Send initial resize.
                let mut sess = sess;
                sess.send_command(&encoder::refresh_client_size(size.cols, size.rows))
                    .await?;
                *rx_guard = Some(session_rx);

                // Demux task: fan-out raw output to per-surface channels.
                let senders = Arc::clone(&self.surface_senders);
                let mut demux_rx = rx_guard.take().unwrap();
                tokio::spawn(async move {
                    while let Some((sid, bytes)) = demux_rx.recv().await {
                        if let Some(tx) = senders.read().await.get(&sid) {
                            let _ = tx.send(bytes).await;
                        }
                    }
                });
            }
        }

        Ok(per_surface_rx)
    }

    async fn send_input(&self, surface_id: SurfaceId, bytes: Vec<u8>) -> Result<()> {
        let _ = (surface_id, bytes);
        // Phase 1.1: route through TmuxSession::send_command(send_keys_hex(...))
        Ok(())
    }

    async fn resize(&self, surface_id: SurfaceId, size: CellSize) -> Result<()> {
        let _ = (surface_id, size);
        // Phase 1.1: send refresh_client_size
        Ok(())
    }

    async fn control(&self, command: WorkspaceControl) -> Result<()> {
        let _ = command;
        // Phase 1.2+
        Ok(())
    }
}
