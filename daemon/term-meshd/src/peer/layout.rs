//! Authoritative workspace layout for a daemon-only peer host.
//!
//! A daemon host has no bonsplit windows — it owns a flat set of forkpty
//! surfaces. This module keeps the split tree those surfaces are arranged
//! in, so `ListWorkspaces` and the `WorkspaceLayoutChanged` push both
//! serialize the SAME tree (a stateless re-tile would reset the user's
//! arrangement on every reconnect).
//!
//! The tree lives in memory only: the PTYs are children of this process,
//! so a daemon restart kills the shells anyway — persisting the layout
//! past them would restore panes onto dead surfaces.
//!
//! Locking contract (matches the rest of `peer::`): the store is wrapped
//! in a `std::sync::Mutex` by its owner; guards are never held across an
//! `.await`, and mutations return owned snapshots so broadcasting happens
//! outside the lock.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use peer_proto::v1::{
    envelope::Payload, workspace_control, workspace_layout, workspace_update, Envelope, PaneTab,
    WorkspaceControl, WorkspaceLayout, WorkspaceLayoutChanged, WorkspacePane, WorkspaceSplit,
    WorkspaceUpdate,
};
use tokio::sync::mpsc;

use super::surface::{surface_id_from_name, PtyManager, PtySurface, SpawnSpec};

pub type SurfaceId = Vec<u8>;

/// Proto uses the strings "horizontal" / "vertical" on the wire; anything
/// else is a client bug and the request carrying it is dropped (F4).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Orientation {
    Horizontal,
    Vertical,
}

impl Orientation {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "horizontal" => Some(Self::Horizontal),
            "vertical" => Some(Self::Vertical),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Horizontal => "horizontal",
            Self::Vertical => "vertical",
        }
    }
}

/// The client's divider fast-path compares split ids across pushes, so an
/// id must survive every mutation that does not remove its split. Ids are
/// meaningful only within one daemon lifetime (the tree is memory-only),
/// so a counter is enough — no UUID needed.
fn split_id_bytes(id: u64) -> Vec<u8> {
    id.to_be_bytes().to_vec()
}

#[derive(Debug)]
pub enum LayoutNode {
    Split {
        id: u64,
        orientation: Orientation,
        /// Fraction of the first child, clamped to [0.05, 0.95] like the
        /// Swift host's `performSetDivider`.
        divider: f64,
        first: Box<LayoutNode>,
        second: Box<LayoutNode>,
    },
    Pane {
        /// Invariant: `active` is always an element of `tabs`.
        active: SurfaceId,
        tabs: Vec<SurfaceId>,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub enum LayoutError {
    /// Refusing to close the only pane left — an empty workspace has no
    /// meaning on the client, and unlike tmux there is no session to end.
    LastPane,
    /// Target pane / split / tab not in the tree. Callers treat this as a
    /// silent no-op per the fire-and-forget contract.
    NotFound,
}

pub struct LayoutStore {
    root: Option<LayoutNode>,
    next_split_id: u64,
}

/// Every mutation returns `Ok(true)` when the tree changed (the caller
/// must broadcast a fresh snapshot), `Ok(false)` when the request was
/// valid but changed nothing, and `Err` when it must be dropped. A failed
/// mutation never leaves the tree partially modified.
impl LayoutStore {
    /// Seed the tree by tiling the startup surfaces into a balanced grid
    /// (orientation alternates by depth, so 4 surfaces make a 2x2). This
    /// is the old stateless `tile_surfaces` demoted to a constructor.
    pub fn balanced_from_surfaces(surfaces: &[Arc<PtySurface>]) -> Self {
        let mut store = Self { root: None, next_split_id: 1 };
        let ids: Vec<SurfaceId> = surfaces.iter().map(|s| s.surface_id.clone()).collect();
        store.root = store.build_balanced(&ids, 0);
        store
    }

    fn build_balanced(&mut self, ids: &[SurfaceId], depth: usize) -> Option<LayoutNode> {
        match ids.len() {
            0 => None,
            1 => Some(LayoutNode::Pane { active: ids[0].clone(), tabs: vec![ids[0].clone()] }),
            n => {
                let mid = n / 2;
                let first = self.build_balanced(&ids[..mid], depth + 1)?;
                let second = self.build_balanced(&ids[mid..], depth + 1)?;
                Some(LayoutNode::Split {
                    id: self.take_split_id(),
                    orientation: if depth % 2 == 0 {
                        Orientation::Horizontal
                    } else {
                        Orientation::Vertical
                    },
                    divider: 0.5,
                    first: Box::new(first),
                    second: Box::new(second),
                })
            }
        }
    }

    fn take_split_id(&mut self) -> u64 {
        let id = self.next_split_id;
        self.next_split_id += 1;
        id
    }

    /// Split the pane containing `pane_id`, placing `new_surface` in the
    /// second half. The existing pane keeps its node identity (tabs and
    /// active selection), so the client can reuse its view for it.
    pub fn split_pane(
        &mut self,
        pane_id: &[u8],
        orientation: Orientation,
        new_surface: SurfaceId,
    ) -> Result<bool, LayoutError> {
        let id = self.take_split_id();
        let Some(root) = self.root.as_mut() else { return Err(LayoutError::NotFound) };
        if !Self::split_in(root, pane_id, orientation, &new_surface, id) {
            // The reserved id is simply skipped; gaps are harmless.
            return Err(LayoutError::NotFound);
        }
        Ok(true)
    }

    fn split_in(
        node: &mut LayoutNode,
        pane_id: &[u8],
        orientation: Orientation,
        new_surface: &SurfaceId,
        split_id: u64,
    ) -> bool {
        match node {
            LayoutNode::Pane { tabs, .. } => {
                if !tabs.iter().any(|t| t == pane_id) {
                    return false;
                }
                let old = std::mem::replace(
                    node,
                    LayoutNode::Pane { active: new_surface.clone(), tabs: vec![new_surface.clone()] },
                );
                let new_pane = std::mem::replace(
                    node,
                    LayoutNode::Split {
                        id: split_id,
                        orientation,
                        divider: 0.5,
                        first: Box::new(old),
                        second: Box::new(LayoutNode::Pane {
                            active: new_surface.clone(),
                            tabs: vec![new_surface.clone()],
                        }),
                    },
                );
                // `new_pane` was the placeholder we swapped in; drop it.
                drop(new_pane);
                true
            }
            LayoutNode::Split { first, second, .. } => {
                Self::split_in(first, pane_id, orientation, new_surface, split_id)
                    || Self::split_in(second, pane_id, orientation, new_surface, split_id)
            }
        }
    }

    /// Remove the pane containing `pane_id`, promoting its sibling. The
    /// removed pane's surfaces are returned so the caller can kill their
    /// PTYs (outside the layout lock).
    pub fn close_pane(&mut self, pane_id: &[u8]) -> Result<Vec<SurfaceId>, LayoutError> {
        match self.root.take() {
            None => Err(LayoutError::NotFound),
            Some(LayoutNode::Pane { active, tabs }) => {
                // Sole pane in the workspace: refuse, put it back untouched.
                let found = tabs.iter().any(|t| t == pane_id);
                self.root = Some(LayoutNode::Pane { active, tabs });
                Err(if found { LayoutError::LastPane } else { LayoutError::NotFound })
            }
            Some(mut root) => match Self::close_in(&mut root, pane_id) {
                CloseOutcome::NotHere => {
                    self.root = Some(root);
                    Err(LayoutError::NotFound)
                }
                CloseOutcome::Closed(removed) => {
                    self.root = Some(root);
                    Ok(removed)
                }
                CloseOutcome::RemoveMe(removed) => {
                    // Root itself was the split whose child died — its
                    // sibling was already promoted into `root` by close_in.
                    self.root = Some(root);
                    Ok(removed)
                }
            },
        }
    }

    /// Sub-tab close semantics: when the pane has several tabs, closing a
    /// tab keeps the pane; only a pane's last tab removes the pane itself.
    fn close_in(node: &mut LayoutNode, pane_id: &[u8]) -> CloseOutcome {
        match node {
            LayoutNode::Pane { active, tabs } => {
                let Some(idx) = tabs.iter().position(|t| t == pane_id) else {
                    return CloseOutcome::NotHere;
                };
                if tabs.len() > 1 {
                    let removed = tabs.remove(idx);
                    if active == &removed {
                        *active = tabs[idx.min(tabs.len() - 1)].clone();
                    }
                    CloseOutcome::Closed(vec![removed])
                } else {
                    CloseOutcome::RemoveMe(tabs.clone())
                }
            }
            LayoutNode::Split { first, second, .. } => {
                let outcome_first = Self::close_in(first, pane_id);
                let (removed, promote_second) = match outcome_first {
                    CloseOutcome::Closed(removed) => return CloseOutcome::Closed(removed),
                    CloseOutcome::RemoveMe(removed) => (removed, true),
                    CloseOutcome::NotHere => match Self::close_in(second, pane_id) {
                        CloseOutcome::NotHere => return CloseOutcome::NotHere,
                        CloseOutcome::Closed(removed) => return CloseOutcome::Closed(removed),
                        CloseOutcome::RemoveMe(removed) => (removed, false),
                    },
                };
                // Promote the surviving sibling over this split node.
                let placeholder = LayoutNode::Pane { active: Vec::new(), tabs: Vec::new() };
                let sibling = if promote_second {
                    std::mem::replace(second.as_mut(), placeholder)
                } else {
                    std::mem::replace(first.as_mut(), placeholder)
                };
                *node = sibling;
                CloseOutcome::Closed(removed)
            }
        }
    }

    /// Clamped like the Swift host (Provider `performSetDivider`): 0.05–0.95.
    /// Non-finite ratios are adversarial input (F3) and are dropped.
    pub fn set_divider(&mut self, split_id: &[u8], ratio: f64) -> Result<bool, LayoutError> {
        if !ratio.is_finite() {
            return Err(LayoutError::NotFound);
        }
        let clamped = ratio.clamp(0.05, 0.95);
        let Some(root) = self.root.as_mut() else { return Err(LayoutError::NotFound) };
        match Self::set_divider_in(root, split_id, clamped) {
            None => Err(LayoutError::NotFound),
            Some(changed) => Ok(changed),
        }
    }

    fn set_divider_in(node: &mut LayoutNode, split_id: &[u8], ratio: f64) -> Option<bool> {
        match node {
            LayoutNode::Pane { .. } => None,
            LayoutNode::Split { id, divider, first, second, .. } => {
                if split_id_bytes(*id) == split_id {
                    let changed = (*divider - ratio).abs() > f64::EPSILON;
                    *divider = ratio;
                    Some(changed)
                } else {
                    Self::set_divider_in(first, split_id, ratio)
                        .or_else(|| Self::set_divider_in(second, split_id, ratio))
                }
            }
        }
    }

    /// Add `new_surface` as a tab of the pane containing `pane_id` and
    /// make it active (the Swift host's `newTerminalSurface(focus: true)`).
    pub fn add_tab(&mut self, pane_id: &[u8], new_surface: SurfaceId) -> Result<bool, LayoutError> {
        let Some(root) = self.root.as_mut() else { return Err(LayoutError::NotFound) };
        if Self::add_tab_in(root, pane_id, &new_surface) {
            Ok(true)
        } else {
            Err(LayoutError::NotFound)
        }
    }

    fn add_tab_in(node: &mut LayoutNode, pane_id: &[u8], new_surface: &SurfaceId) -> bool {
        match node {
            LayoutNode::Pane { active, tabs } => {
                if !tabs.iter().any(|t| t == pane_id) {
                    return false;
                }
                tabs.push(new_surface.clone());
                *active = new_surface.clone();
                true
            }
            LayoutNode::Split { first, second, .. } => {
                Self::add_tab_in(first, pane_id, new_surface)
                    || Self::add_tab_in(second, pane_id, new_surface)
            }
        }
    }

    /// Select `surface_id` as the active tab of the pane containing
    /// `pane_id`. F5: a surface that is not one of the pane's tabs is
    /// adversarial input and is dropped.
    pub fn activate_tab(&mut self, pane_id: &[u8], surface_id: &[u8]) -> Result<bool, LayoutError> {
        let Some(root) = self.root.as_mut() else { return Err(LayoutError::NotFound) };
        match Self::activate_in(root, pane_id, surface_id) {
            None => Err(LayoutError::NotFound),
            Some(changed) => Ok(changed),
        }
    }

    fn activate_in(node: &mut LayoutNode, pane_id: &[u8], surface_id: &[u8]) -> Option<bool> {
        match node {
            LayoutNode::Pane { active, tabs } => {
                if !tabs.iter().any(|t| t == pane_id) {
                    return None;
                }
                if !tabs.iter().any(|t| t == surface_id) {
                    return None;
                }
                let changed = active != surface_id;
                *active = surface_id.to_vec();
                Some(changed)
            }
            LayoutNode::Split { first, second, .. } => {
                Self::activate_in(first, pane_id, surface_id)
                    .or_else(|| Self::activate_in(second, pane_id, surface_id))
            }
        }
    }

    /// Drop a surface wherever it appears — the dead-watcher path for an
    /// ephemeral (split-spawned) shell that exited on its own. A sole
    /// surviving pane is kept as a dead pane rather than emptying the
    /// tree: a self-exit is not a user request, so there is nothing to
    /// refuse — and nothing left to render if we removed everything.
    pub fn remove_surface(&mut self, surface_id: &[u8]) -> bool {
        match self.close_pane(surface_id) {
            Ok(_) => true,
            Err(LayoutError::LastPane) => false,
            Err(LayoutError::NotFound) => false,
        }
    }

    /// Serialize the tree for the wire, pulling live pane metadata
    /// (title / size / cwd) from the manager at snapshot time. Surfaces
    /// that vanished from the manager still serialize (with empty
    /// metadata) so the tree and the wire never disagree about shape.
    pub fn snapshot_proto(&self, manager: &PtyManager) -> Option<WorkspaceLayout> {
        // One list() = one manager lock acquisition for the whole tree.
        let meta: std::collections::HashMap<SurfaceId, (String, u32, u32, String)> = manager
            .list()
            .into_iter()
            .map(|s| {
                let info = s.info();
                (info.surface_id.clone(), (info.title, info.cols, info.rows, info.cwd))
            })
            .collect();
        self.root.as_ref().map(|n| Self::node_to_proto(n, &meta))
    }

    fn node_to_proto(
        node: &LayoutNode,
        meta_map: &std::collections::HashMap<SurfaceId, (String, u32, u32, String)>,
    ) -> WorkspaceLayout {
        match node {
            LayoutNode::Pane { active, tabs } => {
                let meta = |sid: &SurfaceId| -> (String, u32, u32, String) {
                    meta_map.get(sid).cloned().unwrap_or_default()
                };
                let (title, cols, rows, cwd) = meta(active);
                WorkspaceLayout {
                    node: Some(workspace_layout::Node::Pane(WorkspacePane {
                        surface_id: active.clone(),
                        title,
                        cols,
                        rows,
                        cwd,
                        tabs: tabs
                            .iter()
                            .map(|sid| PaneTab {
                                surface_id: sid.clone(),
                                title: meta(sid).0,
                            })
                            .collect(),
                    })),
                }
            }
            LayoutNode::Split { id, orientation, divider, first, second } => WorkspaceLayout {
                node: Some(workspace_layout::Node::Split(Box::new(WorkspaceSplit {
                    orientation: orientation.as_str().to_string(),
                    divider_position: *divider,
                    first: Some(Box::new(Self::node_to_proto(first, meta_map))),
                    second: Some(Box::new(Self::node_to_proto(second, meta_map))),
                    split_id: split_id_bytes(*id),
                }))),
            },
        }
    }

    /// Surface ids currently present in the tree, in-order. Lets the
    /// caller reconcile the tree against the manager (e.g. seed checks in
    /// tests) without exposing the node structure.
    pub fn surface_ids(&self) -> Vec<SurfaceId> {
        let mut out = Vec::new();
        if let Some(root) = &self.root {
            Self::collect_ids(root, &mut out);
        }
        out
    }

    fn collect_ids(node: &LayoutNode, out: &mut Vec<SurfaceId>) {
        match node {
            LayoutNode::Pane { tabs, .. } => out.extend(tabs.iter().cloned()),
            LayoutNode::Split { first, second, .. } => {
                Self::collect_ids(first, out);
                Self::collect_ids(second, out);
            }
        }
    }

    pub fn is_empty(&self) -> bool {
        self.root.is_none()
    }
}

enum CloseOutcome {
    /// Target pane is not in this subtree.
    NotHere,
    /// Closed a tab (or a descendant pane); subtree structure already fixed.
    Closed(Vec<SurfaceId>),
    /// This whole node must be removed; the parent promotes the sibling.
    RemoveMe(Vec<SurfaceId>),
}

/// Name of the single workspace a daemon-only host synthesises. Hashed
/// through `surface_id_from_name`, so the id is stable across restarts
/// and the client can keep referring to the same workspace.
pub const DAEMON_WORKSPACE: &str = "term-meshd";

/// Outgoing handles of every connection that reached `Ready`, so a layout
/// mutation made over one connection can push the new tree to all of
/// them. Registration hands back an RAII guard; a dropped connection
/// unregisters itself even on panic.
///
/// The lock is only ever held to copy the sender list out — sending
/// happens after the guard is dropped, and with `try_send`, so one slow
/// client (its 128-slot channel full) skips its push instead of stalling
/// everyone else's. A skipped client is stale until the next layout
/// change; that is acceptable for a cosmetic push and avoids unbounded
/// buffering.
pub struct Broadcaster {
    clients: Mutex<HashMap<u64, RegisteredClient>>,
    next_id: AtomicU64,
}

#[derive(Clone)]
struct RegisteredClient {
    tx: mpsc::Sender<Envelope>,
    /// The connection's own outgoing seq counter — pushes must continue
    /// each connection's monotonic sequence, not share a global one.
    seq: Arc<AtomicU64>,
}

impl Broadcaster {
    pub fn new() -> Self {
        Self { clients: Mutex::new(HashMap::new()), next_id: AtomicU64::new(1) }
    }

    pub fn register(
        self: &Arc<Self>,
        tx: mpsc::Sender<Envelope>,
        seq: Arc<AtomicU64>,
    ) -> BroadcastGuard {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.clients.lock().unwrap().insert(id, RegisteredClient { tx, seq });
        BroadcastGuard { broadcaster: Arc::clone(self), id }
    }

    /// Fan a payload out to every registered connection, stamping each
    /// envelope with that connection's next seq. Clone-then-send: the
    /// guard is released before any channel interaction.
    pub fn broadcast(&self, payload: &peer_proto::v1::envelope::Payload) {
        let clients: Vec<RegisteredClient> =
            self.clients.lock().unwrap().values().cloned().collect();
        for client in clients {
            let env = Envelope {
                seq: client.seq.fetch_add(1, Ordering::Relaxed) + 1,
                correlation_id: 0,
                payload: Some(payload.clone()),
            };
            if client.tx.try_send(env).is_err() {
                tracing::debug!("layout push skipped: peer outgoing channel full or closed");
            }
        }
    }
}

pub struct BroadcastGuard {
    broadcaster: Arc<Broadcaster>,
    id: u64,
}

impl Drop for BroadcastGuard {
    fn drop(&mut self) {
        self.broadcaster.clients.lock().unwrap().remove(&self.id);
    }
}

/// Shared state of one daemon peer host: the PTYs, the layout tree they
/// are arranged in, and the connections to push layout changes to. This
/// is what `connection::run` receives instead of a bare `PtyManager`.
///
/// Lock discipline (as everywhere in `peer::`): guards never cross an
/// `.await`, and mutation results are broadcast after unlock. Nesting is
/// one-directional — the layout guard may wrap the manager's short
/// internal locks (snapshot reads pane metadata), but no code path takes
/// the layout lock while holding a manager guard, so the order is
/// consistent and cannot deadlock.
pub struct PeerHost {
    pub pty: Arc<PtyManager>,
    pub layout: Mutex<LayoutStore>,
    pub clients: Arc<Broadcaster>,
    pub workspace_id: Vec<u8>,
    /// Names split/new-tab surfaces (`split-1`, `split-2`, …). Lifetime
    /// of this daemon only, like the tree itself.
    ephemeral_counter: AtomicU64,
    /// True while a debounced layout push is pending — collapses a burst
    /// of mutations (divider drags especially) into one push.
    push_scheduled: AtomicBool,
}

/// Debounce window for layout pushes. Mirrors the Swift host's 120 ms
/// (`PeerServerHost.scheduleLayoutBroadcast`); the client itself debounces
/// divider sends at 150 ms, so anything in this range coalesces a drag
/// into a handful of pushes instead of hundreds.
const PUSH_DEBOUNCE: Duration = Duration::from_millis(120);

impl PeerHost {
    pub fn new(pty: Arc<PtyManager>) -> Self {
        let layout = LayoutStore::balanced_from_surfaces(&pty.list());
        Self {
            pty,
            layout: Mutex::new(layout),
            clients: Arc::new(Broadcaster::new()),
            workspace_id: surface_id_from_name(DAEMON_WORKSPACE),
            ephemeral_counter: AtomicU64::new(1),
            push_scheduled: AtomicBool::new(false),
        }
    }

    /// Apply one WorkspaceControl command. Fire-and-forget end to end:
    /// nothing is ever sent back to the requester specifically — a
    /// mutation that changed the tree schedules a push to everyone, and
    /// anything invalid (unknown ids, bad orientation, last-pane close,
    /// F1–F8 adversarial shapes) drops silently, exactly like the Swift
    /// host's `perform*` guards.
    pub fn apply_control(self: &Arc<Self>, ctl: WorkspaceControl) {
        use workspace_control::Kind;
        let changed = match ctl.kind {
            // F8: a kind this build predates. Ignore, don't disconnect.
            None => false,
            // R10: the daemon has no keyboard focus to move, and the Swift
            // host deliberately no-ops this too.
            Some(Kind::FocusPane(_)) => false,
            Some(Kind::SplitPane(req)) => self.split_pane(&req.pane_id, &req.orientation),
            Some(Kind::ClosePane(req)) => self.close_pane(&req.pane_id),
            Some(Kind::SetDivider(req)) => self
                .layout
                .lock()
                .unwrap()
                .set_divider(&req.split_id, req.ratio)
                .unwrap_or(false),
            Some(Kind::NewTab(req)) => self.new_tab(&req.pane_id),
            Some(Kind::ActivateTab(req)) => self
                .layout
                .lock()
                .unwrap()
                .activate_tab(&req.pane_id, &req.surface_id)
                .unwrap_or(false),
        };
        if changed {
            self.schedule_layout_push();
        }
    }

    fn split_pane(self: &Arc<Self>, pane_id: &[u8], orientation: &str) -> bool {
        let Some(orientation) = Orientation::parse(orientation) else {
            return false; // F4
        };
        // Cheap existence probe before paying for a fork. The tree can
        // still change before the insert below — that race is resolved by
        // rolling the spawn back.
        if !self.layout.lock().unwrap().surface_ids().iter().any(|s| s == pane_id) {
            return false;
        }
        // A dead source pane revives first, same as attach would do — the
        // user is clearly working in it. No-op when it is alive.
        self.pty.get_or_respawn(pane_id);
        let Some(new_id) = self.spawn_ephemeral(pane_id) else { return false };
        match self.layout.lock().unwrap().split_pane(pane_id, orientation, new_id.clone()) {
            Ok(changed) => changed,
            Err(_) => {
                // Source pane vanished between probe and insert; don't
                // leak the shell we spawned for it.
                self.pty.remove(&new_id);
                false
            }
        }
    }

    fn new_tab(self: &Arc<Self>, pane_id: &[u8]) -> bool {
        if !self.layout.lock().unwrap().surface_ids().iter().any(|s| s == pane_id) {
            return false;
        }
        self.pty.get_or_respawn(pane_id);
        let Some(new_id) = self.spawn_ephemeral(pane_id) else { return false };
        match self.layout.lock().unwrap().add_tab(pane_id, new_id.clone()) {
            Ok(changed) => changed,
            Err(_) => {
                self.pty.remove(&new_id);
                false
            }
        }
    }

    fn close_pane(self: &Arc<Self>, pane_id: &[u8]) -> bool {
        let removed = match self.layout.lock().unwrap().close_pane(pane_id) {
            Ok(removed) => removed,
            // LastPane / NotFound: silent no-op — the client observes
            // "nothing happened", same as the Swift host.
            Err(_) => return false,
        };
        // PTYs die outside the layout lock. The spec (when one exists)
        // stays registered: a daemon restart resets the tree anyway, and
        // declared surfaces reappearing after a restart is the agreed
        // semantic.
        for sid in removed {
            self.pty.remove(&sid);
        }
        true
    }

    /// Fork a login shell for a split/new-tab pane, inheriting the source
    /// pane's cwd. Registered with a respawn spec so a dead ephemeral
    /// pane revives on attach just like declared surfaces do, and watched
    /// so a shell that exits on its own removes its pane from the tree.
    fn spawn_ephemeral(self: &Arc<Self>, source_pane: &[u8]) -> Option<SurfaceId> {
        let cwd = self
            .pty
            .list()
            .into_iter()
            .find(|s| s.surface_id == source_pane)
            .map(|s| s.cwd.clone())
            .filter(|c| !c.is_empty());
        let n = self.ephemeral_counter.fetch_add(1, Ordering::Relaxed);
        let surface_id = surface_id_from_name(&format!("split-{n}"));
        let spec = SpawnSpec {
            title: format!("shell {n}"),
            command: "/bin/sh".into(),
            args: vec!["-c".into(), super::surface::login_shell_cmd()],
            cols: 80,
            rows: 24,
            cwd,
        };
        self.pty.register_and_spawn(surface_id.clone(), spec);
        // register_and_spawn logs-and-continues on failure; only report a
        // surface that actually exists.
        let surface = self.pty.list().into_iter().find(|s| s.surface_id == surface_id)?;
        self.watch_ephemeral(surface);
        Some(surface_id)
    }

    /// Remove an ephemeral pane from the tree when its shell exits on its
    /// own (typed `exit`, crashed, got HUP'd from inside). Declared
    /// surfaces deliberately have no watcher — their dead pane stays
    /// visible and revives on the next attach.
    ///
    /// A user-initiated ClosePane races this: close removes the pane and
    /// hangs the shell up, then the watcher fires and finds nothing —
    /// remove_surface returns false and no second push goes out.
    fn watch_ephemeral(self: &Arc<Self>, surface: Arc<PtySurface>) {
        let host = Arc::downgrade(self);
        let sid = surface.surface_id.clone();
        tokio::spawn(async move {
            // Register interest before checking the flag: notify_waiters
            // only wakes CURRENT waiters, so the reverse order would miss
            // a death landing between check and await.
            let notified = surface.dead_notify.notified();
            if !surface.dead.load(Ordering::Acquire) {
                notified.await;
            }
            let Some(host) = host.upgrade() else { return };
            let removed = host.layout.lock().unwrap().remove_surface(&sid);
            if removed {
                // Out of the tree → out of the roster (it is already dead;
                // remove only drops the map entry and re-signals a corpse).
                host.pty.remove(&sid);
                host.schedule_layout_push();
            }
        });
    }

    /// Debounced fan-out of the current tree to every connection. The
    /// snapshot is taken when the timer fires, so a burst of mutations
    /// yields one push carrying the final state.
    pub fn schedule_layout_push(self: &Arc<Self>) {
        if self.push_scheduled.swap(true, Ordering::AcqRel) {
            return;
        }
        let host = Arc::clone(self);
        tokio::spawn(async move {
            tokio::time::sleep(PUSH_DEBOUNCE).await;
            host.push_scheduled.store(false, Ordering::Release);
            let layout = host.layout_snapshot();
            let payload = Payload::WorkspaceUpdate(WorkspaceUpdate {
                kind: Some(workspace_update::Kind::WorkspaceLayout(WorkspaceLayoutChanged {
                    workspace_id: host.workspace_id.clone(),
                    layout,
                })),
            });
            host.clients.broadcast(&payload);
        });
    }

    /// Wire snapshot of the current tree. Reseeds first when the tree is
    /// empty but surfaces exist — covers hosts whose manager was populated
    /// after construction (the test harness does this; production spawns
    /// surfaces before `PeerHost::new`).
    pub fn layout_snapshot(&self) -> Option<WorkspaceLayout> {
        let mut layout = self.layout.lock().unwrap();
        if layout.is_empty() {
            let surfaces = self.pty.list();
            if !surfaces.is_empty() {
                *layout = LayoutStore::balanced_from_surfaces(&surfaces);
            }
        }
        layout.snapshot_proto(&self.pty)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::peer::surface::surface_id_from_name;

    fn sid(name: &str) -> SurfaceId {
        surface_id_from_name(name)
    }

    /// Build a store with N single-tab panes without spawning PTYs.
    fn store_with(names: &[&str]) -> LayoutStore {
        let mut store = LayoutStore { root: None, next_split_id: 1 };
        let ids: Vec<SurfaceId> = names.iter().map(|n| sid(n)).collect();
        store.root = store.build_balanced(&ids, 0);
        store
    }

    fn split_ids(store: &LayoutStore) -> Vec<Vec<u8>> {
        fn walk(node: &LayoutNode, out: &mut Vec<Vec<u8>>) {
            if let LayoutNode::Split { id, first, second, .. } = node {
                out.push(split_id_bytes(*id));
                walk(first, out);
                walk(second, out);
            }
        }
        let mut out = Vec::new();
        if let Some(root) = &store.root {
            walk(root, &mut out);
        }
        out
    }

    #[test]
    fn balanced_seed_shapes() {
        assert!(store_with(&[]).is_empty());
        assert_eq!(store_with(&["a"]).surface_ids().len(), 1);
        let four = store_with(&["a", "b", "c", "d"]);
        assert_eq!(four.surface_ids().len(), 4);
        // 4 panes need 3 splits (2x2).
        assert_eq!(split_ids(&four).len(), 3);
    }

    #[test]
    fn split_adds_pane_and_changes_tree() {
        let mut store = store_with(&["a"]);
        let changed = store.split_pane(&sid("a"), Orientation::Horizontal, sid("b")).unwrap();
        assert!(changed);
        assert_eq!(store.surface_ids(), vec![sid("a"), sid("b")]);
        assert_eq!(split_ids(&store).len(), 1);
    }

    #[test]
    fn split_unknown_pane_is_notfound_and_tree_unchanged() {
        let mut store = store_with(&["a"]);
        let before = store.surface_ids();
        assert_eq!(
            store.split_pane(&sid("ghost"), Orientation::Vertical, sid("b")).unwrap_err(),
            LayoutError::NotFound
        );
        assert_eq!(store.surface_ids(), before);
    }

    #[test]
    fn close_promotes_sibling() {
        let mut store = store_with(&["a", "b"]);
        let removed = store.close_pane(&sid("a")).unwrap();
        assert_eq!(removed, vec![sid("a")]);
        assert_eq!(store.surface_ids(), vec![sid("b")]);
        // Split collapsed away.
        assert!(split_ids(&store).is_empty());
    }

    #[test]
    fn close_last_pane_is_refused() {
        let mut store = store_with(&["a"]);
        assert_eq!(store.close_pane(&sid("a")).unwrap_err(), LayoutError::LastPane);
        assert_eq!(store.surface_ids(), vec![sid("a")]);
    }

    #[test]
    fn double_close_second_is_notfound() {
        let mut store = store_with(&["a", "b", "c"]);
        store.close_pane(&sid("a")).unwrap();
        assert_eq!(store.close_pane(&sid("a")).unwrap_err(), LayoutError::NotFound);
        assert_eq!(store.surface_ids(), vec![sid("b"), sid("c")]);
    }

    #[test]
    fn split_ids_stable_across_unrelated_mutations() {
        let mut store = store_with(&["a", "b"]);
        let before = split_ids(&store);
        store.split_pane(&sid("b"), Orientation::Vertical, sid("c")).unwrap();
        let after = split_ids(&store);
        // The original split's id survives; one new id appended.
        assert!(after.contains(&before[0]));
        assert_eq!(after.len(), 2);
        // New id is distinct.
        assert_ne!(after[0], after[1]);
    }

    #[test]
    fn divider_clamps_and_reports_change() {
        let mut store = store_with(&["a", "b"]);
        let split = split_ids(&store)[0].clone();
        assert!(store.set_divider(&split, 0.3).unwrap());
        // Same value again: valid but unchanged → no push.
        assert!(!store.set_divider(&split, 0.3).unwrap());
        // Out-of-range finite values clamp (F3).
        assert!(store.set_divider(&split, -1.0).unwrap());
        assert!(!store.set_divider(&split, 0.0).unwrap()); // clamps to 0.05 again
        assert!(store.set_divider(&split, 2.0).unwrap()); // clamps to 0.95
    }

    #[test]
    fn divider_rejects_nan_inf_and_unknown_id() {
        let mut store = store_with(&["a", "b"]);
        let split = split_ids(&store)[0].clone();
        assert_eq!(store.set_divider(&split, f64::NAN).unwrap_err(), LayoutError::NotFound);
        assert_eq!(store.set_divider(&split, f64::INFINITY).unwrap_err(), LayoutError::NotFound);
        assert_eq!(store.set_divider(&[1, 2, 3], 0.5).unwrap_err(), LayoutError::NotFound);
        // F1: absurd id lengths.
        assert_eq!(store.set_divider(&[], 0.5).unwrap_err(), LayoutError::NotFound);
        assert_eq!(store.set_divider(&vec![0u8; 1024], 0.5).unwrap_err(), LayoutError::NotFound);
    }

    #[test]
    fn tabs_add_activate_and_close_within_pane() {
        let mut store = store_with(&["a", "b"]);
        assert!(store.add_tab(&sid("a"), sid("t2")).unwrap());
        // New tab became active; pane now has 2 tabs.
        assert_eq!(store.surface_ids(), vec![sid("a"), sid("t2"), sid("b")]);

        // Activate back to "a".
        assert!(store.activate_tab(&sid("t2"), &sid("a")).unwrap());
        // Same activation again: no change → no push.
        assert!(!store.activate_tab(&sid("t2"), &sid("a")).unwrap());

        // F5: activating a surface that is not one of this pane's tabs.
        assert_eq!(
            store.activate_tab(&sid("a"), &sid("b")).unwrap_err(),
            LayoutError::NotFound
        );

        // Closing one tab keeps the pane (and the other tab).
        let removed = store.close_pane(&sid("t2")).unwrap();
        assert_eq!(removed, vec![sid("t2")]);
        assert_eq!(store.surface_ids(), vec![sid("a"), sid("b")]);
    }

    #[test]
    fn close_active_tab_moves_active_to_neighbor() {
        let mut store = store_with(&["a", "b"]);
        store.add_tab(&sid("a"), sid("t2")).unwrap();
        // t2 is active; closing it must hand active back to "a".
        store.close_pane(&sid("t2")).unwrap();
        assert!(store.activate_tab(&sid("a"), &sid("a")).is_ok());
    }

    #[test]
    fn remove_surface_may_not_empty_tree_but_reports() {
        let mut store = store_with(&["a", "b"]);
        assert!(store.remove_surface(&sid("a")));
        // Sole survivor: self-exit of the last pane is kept (dead pane
        // stays visible; respawn revives it on next attach).
        assert!(!store.remove_surface(&sid("b")));
        assert_eq!(store.surface_ids(), vec![sid("b")]);
        // Unknown surface: no-op.
        assert!(!store.remove_surface(&sid("ghost")));
    }

    #[test]
    fn deep_tree_proto_roundtrip_no_overflow() {
        // F7: a pathologically deep tree must serialize without blowing
        // the stack. 512 successive splits of the same pane produce a
        // maximally unbalanced tree.
        let mut store = store_with(&["p0"]);
        for i in 1..=512 {
            store
                .split_pane(&sid("p0"), Orientation::Horizontal, sid(&format!("p{i}")))
                .unwrap();
        }
        let manager = PtyManager::new();
        let proto = store.snapshot_proto(&manager).expect("tree present");
        // Depth check: walk down the first chain counting splits.
        let mut depth = 0usize;
        let mut cursor = &proto;
        while let Some(workspace_layout::Node::Split(split)) = &cursor.node {
            depth += 1;
            cursor = split.first.as_ref().expect("first child");
        }
        assert_eq!(depth, 512);
    }

    /// R8 end to end inside the daemon: split spawns a real login shell,
    /// hanging that shell up (as if the user typed `exit`) must remove
    /// its pane from the tree and schedule a push — without touching the
    /// surviving pane.
    #[tokio::test]
    async fn ephemeral_self_exit_removes_pane() {
        let manager = Arc::new(PtyManager::new());
        let base = PtySurface::spawn(
            sid("base"),
            "cat".into(),
            "/bin/cat",
            &[],
            80,
            24,
            None,
        )
        .expect("spawn /bin/cat");
        manager.insert_surface(base);
        let host = Arc::new(PeerHost::new(manager));
        assert_eq!(host.layout.lock().unwrap().surface_ids().len(), 1);

        host.apply_control(WorkspaceControl {
            kind: Some(workspace_control::Kind::SplitPane(peer_proto::v1::SplitPaneRequest {
                pane_id: sid("base"),
                orientation: "horizontal".into(),
            })),
        });
        assert_eq!(host.layout.lock().unwrap().surface_ids().len(), 2, "split landed");

        // The ephemeral shell "exits": SIGHUP → PTY reader EOF →
        // dead_notify → watcher prunes the pane.
        let ephemeral = host
            .pty
            .list()
            .into_iter()
            .find(|s| s.surface_id != sid("base"))
            .expect("ephemeral surface exists");
        ephemeral.hangup();

        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            if host.layout.lock().unwrap().surface_ids() == vec![sid("base")] {
                break;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "watcher never pruned the dead ephemeral pane; tree = {:?}",
                host.layout.lock().unwrap().surface_ids()
            );
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        // Roster pruned too.
        assert!(host.pty.list().iter().all(|s| s.surface_id == sid("base")));
    }

    #[test]
    fn snapshot_survives_manager_without_surfaces() {
        // Surfaces absent from the manager still serialize with empty
        // metadata — shape must never diverge from the tree.
        let store = store_with(&["a", "b"]);
        let manager = PtyManager::new();
        let proto = store.snapshot_proto(&manager).unwrap();
        match proto.node.unwrap() {
            workspace_layout::Node::Split(split) => {
                assert_eq!(split.orientation, "horizontal");
                assert!(!split.split_id.is_empty());
            }
            other => panic!("expected split root, got {other:?}"),
        }
    }
}
