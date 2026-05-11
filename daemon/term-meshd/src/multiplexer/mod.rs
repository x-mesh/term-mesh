//! Remote multiplexer abstraction — ADR 0001 §"tmux Adapter Boundary".
//!
//! Both the existing peer relay and the new tmux backend implement
//! `RemoteMultiplexerBackend` and feed the same UI surface layer.
#![allow(dead_code)]

pub mod tmux;

use anyhow::Result;
use tokio::sync::mpsc;

/// Stable identifier for a remote PTY surface (pane, window, …).
#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub struct SurfaceId(pub String);

/// Terminal dimensions in cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellSize {
    pub cols: u16,
    pub rows: u16,
}

/// Metadata for a single remote workspace (tmux session / peer workspace).
#[derive(Debug, Clone)]
pub struct RemoteWorkspace {
    pub id: String,
    pub name: String,
    pub surfaces: Vec<SurfaceId>,
}

/// Raw PTY byte stream received from a remote surface.
/// Produced by `attach_surface`; consumer drives the terminal emulator.
pub type RemoteSurfaceStream = mpsc::Receiver<Vec<u8>>;

/// Direction for pane splits — per ADR 0002 §"WorkspaceControl encoding".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitDirection {
    /// Side-by-side split (`split-window -h`).
    Horizontal,
    /// Stacked split (`split-window -v`).
    Vertical,
}

/// High-level workspace control requests — Phase 1.1 variants.
#[derive(Debug, Clone)]
pub enum WorkspaceControl {
    /// Split `pane_id` in the given direction.
    SplitPane { pane_id: String, direction: SplitDirection },
    /// Close the pane identified by `pane_id`.
    KillPane { pane_id: String },
    /// Focus the pane identified by `pane_id`.
    SelectPane { pane_id: String },
}

/// Per ADR 0001 §"tmux Adapter Boundary" — backend contract shared by
/// `PeerSurfaceProvider` (existing) and `TmuxControlBackend` (new).
pub trait RemoteMultiplexerBackend: Send + Sync {
    fn list_workspaces(&self) -> impl std::future::Future<Output = Result<Vec<RemoteWorkspace>>> + Send + '_;
    fn attach_surface(
        &self,
        surface_id: SurfaceId,
        size: CellSize,
    ) -> impl std::future::Future<Output = Result<RemoteSurfaceStream>> + Send + '_;
    fn send_input(
        &self,
        surface_id: SurfaceId,
        bytes: Vec<u8>,
    ) -> impl std::future::Future<Output = Result<()>> + Send + '_;
    fn resize(
        &self,
        surface_id: SurfaceId,
        size: CellSize,
    ) -> impl std::future::Future<Output = Result<()>> + Send + '_;
    fn control(
        &self,
        command: WorkspaceControl,
    ) -> impl std::future::Future<Output = Result<()>> + Send + '_;
}
