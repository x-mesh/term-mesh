//! Pane-ID ↔ SurfaceId mapping table for the tmux backend.
//!
//! tmux identifies panes by their control-mode id (`%N`).
//! The UI layer uses opaque `SurfaceId` values.  This table provides
//! bidirectional lookup under an async-safe read-write lock.

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::multiplexer::SurfaceId;

/// Thread-safe bidirectional map between tmux pane ids (`%N`) and `SurfaceId`.
#[derive(Clone)]
pub struct SurfaceMap {
    inner: Arc<RwLock<Inner>>,
}

#[derive(Default)]
struct Inner {
    pane_to_surface: HashMap<String, SurfaceId>,
    surface_to_pane: HashMap<SurfaceId, String>,
}

impl SurfaceMap {
    pub fn new() -> Self {
        Self { inner: Arc::new(RwLock::new(Inner::default())) }
    }

    /// Register a (pane_id, surface_id) pair.  Overwrites any previous mapping.
    pub async fn register(&self, pane_id: impl Into<String>, surface_id: SurfaceId) {
        let pane_id = pane_id.into();
        let mut g = self.inner.write().await;
        g.surface_to_pane.insert(surface_id.clone(), pane_id.clone());
        g.pane_to_surface.insert(pane_id, surface_id);
    }

    /// Look up the tmux pane id for a given `SurfaceId`.
    pub async fn lookup_pane(&self, surface_id: &SurfaceId) -> Option<String> {
        self.inner.read().await.surface_to_pane.get(surface_id).cloned()
    }

    /// Look up the `SurfaceId` for a given tmux pane id.
    pub async fn lookup_surface(&self, pane_id: &str) -> Option<SurfaceId> {
        self.inner.read().await.pane_to_surface.get(pane_id).cloned()
    }
}
