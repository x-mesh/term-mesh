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

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use peer_proto::v1::{
    envelope::Payload, workspace_control, workspace_layout, workspace_update, Envelope, PaneTab,
    TeamLeaderCommandRequest, TeamLeaderCommandResponse, Workspace, WorkspaceControl,
    WorkspaceLayout, WorkspaceLayoutChanged, WorkspaceListChanged, WorkspacePane, WorkspaceRemoved,
    WorkspaceSplit, WorkspaceUpdate,
};
use tokio::sync::{mpsc, oneshot, watch};

use super::persist::PersistedWorkspace;
use super::surface::{
    surface_id_from_name, EnsureError, EnsureOutcome, PtyManager, PtySurface, SpawnSpec,
    SurfaceKind, SurfaceSpec,
};
use crate::monitor::SystemSnapshot;

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

/// Short hex of a workspace id for log lines — enough to correlate
/// create/remove without dumping the full 16 bytes.
fn hex_prefix(id: &[u8]) -> String {
    id.iter().take(4).map(|b| format!("{b:02x}")).collect()
}

/// Nearest ancestor of `cwd` holding a `.git` entry, or empty when the pane
/// is not inside a repository. Only the host can answer this — a client
/// staring at `/srv/app/backend` cannot tell a project root from one of its
/// subdirectories — so it rides the layout snapshot the wire already builds.
///
/// Memoized per cwd: a pane's directory changes rarely while layout
/// snapshots fire on every split, resize and tab switch, and the walk costs
/// one `exists()` per ancestor. The map is bounded and cleared wholesale
/// when it fills, since a stale entry only outlives an actual `git init`
/// (or a repo being deleted) under that exact path.
pub(super) fn project_root_for(cwd: &str) -> String {
    const MAX_CACHED: usize = 512;
    static CACHE: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

    if cwd.is_empty() {
        return String::new();
    }
    if let Ok(mut guard) = CACHE.lock() {
        let cache = guard.get_or_insert_with(HashMap::new);
        if let Some(hit) = cache.get(cwd) {
            return hit.clone();
        }
        let resolved = walk_to_git_root(cwd);
        if cache.len() >= MAX_CACHED {
            cache.clear();
        }
        cache.insert(cwd.to_string(), resolved.clone());
        return resolved;
    }
    // Poisoned lock: answering without the cache beats poisoning the wire.
    walk_to_git_root(cwd)
}

fn walk_to_git_root(cwd: &str) -> String {
    let mut dir = PathBuf::from(cwd);
    if !dir.is_absolute() {
        return String::new();
    }
    loop {
        // `.git` is a directory in a normal clone and a FILE in a worktree
        // or submodule, so test for existence rather than for a directory —
        // term-mesh's own worktrees would otherwise report no project.
        let dotgit = dir.join(".git");
        if dotgit.exists() {
            // A linked worktree is a temporary station of its primary
            // project, not a project of its own: an agent working in
            // `demo-executor-260728-a3f2` is working on `demo`, and
            // reporting the worktree path fragmented the sidebar's project
            // grouping into one ghost project per agent. Resolve it to the
            // primary. A submodule's `.git` is also a file but points into
            // `.git/modules/…` — that one IS its own project (ghostty inside
            // term-mesh), so it keeps its own root.
            if let Some(primary) = linked_worktree_primary(&dotgit) {
                return primary;
            }
            return dir.to_string_lossy().into_owned();
        }
        if !dir.pop() {
            return String::new();
        }
    }
}

/// The primary checkout's root when `.git` is a linked-worktree pointer
/// file (`gitdir: <primary>/.git/worktrees/<name>`), else None. Reads the
/// file rather than running git: this sits on the layout-snapshot path.
fn linked_worktree_primary(dotgit: &Path) -> Option<String> {
    if !dotgit.is_file() {
        return None;
    }
    let text = std::fs::read_to_string(dotgit).ok()?;
    let target = text.strip_prefix("gitdir:")?.trim();
    // `<primary>/.git/worktrees/<name>` — anything else (a submodule's
    // `.git/modules/…`, an unrecognised layout) is not a linked worktree.
    let target_path = Path::new(target);
    let worktrees_dir = target_path.parent()?; // …/.git/worktrees
    let git_dir = worktrees_dir.parent()?; // …/.git
    if worktrees_dir.file_name()? != "worktrees" || git_dir.file_name()? != ".git" {
        return None;
    }
    let primary = git_dir.parent()?;
    if !primary.is_absolute() {
        return None;
    }
    Some(primary.to_string_lossy().into_owned())
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
        let mut store = Self {
            root: None,
            next_split_id: 1,
        };
        let ids: Vec<SurfaceId> = surfaces.iter().map(|s| s.surface_id.clone()).collect();
        store.root = store.build_balanced(&ids, 0);
        store
    }

    fn build_balanced(&mut self, ids: &[SurfaceId], depth: usize) -> Option<LayoutNode> {
        match ids.len() {
            0 => None,
            1 => Some(LayoutNode::Pane {
                active: ids[0].clone(),
                tabs: vec![ids[0].clone()],
            }),
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
        let Some(root) = self.root.as_mut() else {
            return Err(LayoutError::NotFound);
        };
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
                    LayoutNode::Pane {
                        active: new_surface.clone(),
                        tabs: vec![new_surface.clone()],
                    },
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
    ///
    /// Delegates uniformly to `close_in` regardless of whether `root` is
    /// itself a `Pane` or a `Split` — a bare-`Pane` root with more than
    /// one tab (grown via `add_tab` without ever splitting) must remove
    /// just that tab like any other multi-tab pane, not be refused as the
    /// "last pane". `close_in`'s `Split` branch always resolves a child's
    /// `RemoveMe` into `Closed` by promoting the sibling in its place, so
    /// `RemoveMe` reaching *this* level means `root` itself has no parent
    /// to promote into: it was a `Pane` that just lost its last tab. That
    /// is the only real "last pane" case, and `close_in` leaves the node
    /// unmutated on that path, so putting `root` back is always safe.
    pub fn close_pane(&mut self, pane_id: &[u8]) -> Result<Vec<SurfaceId>, LayoutError> {
        let Some(mut root) = self.root.take() else {
            return Err(LayoutError::NotFound);
        };
        match Self::close_in(&mut root, pane_id) {
            CloseOutcome::NotHere => {
                self.root = Some(root);
                Err(LayoutError::NotFound)
            }
            CloseOutcome::Closed(removed) => {
                self.root = Some(root);
                Ok(removed)
            }
            CloseOutcome::RemoveMe(_) => {
                self.root = Some(root);
                Err(LayoutError::LastPane)
            }
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
                let placeholder = LayoutNode::Pane {
                    active: Vec::new(),
                    tabs: Vec::new(),
                };
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
        let Some(root) = self.root.as_mut() else {
            return Err(LayoutError::NotFound);
        };
        match Self::set_divider_in(root, split_id, clamped) {
            None => Err(LayoutError::NotFound),
            Some(changed) => Ok(changed),
        }
    }

    fn set_divider_in(node: &mut LayoutNode, split_id: &[u8], ratio: f64) -> Option<bool> {
        match node {
            LayoutNode::Pane { .. } => None,
            LayoutNode::Split {
                id,
                divider,
                first,
                second,
                ..
            } => {
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
        let Some(root) = self.root.as_mut() else {
            return Err(LayoutError::NotFound);
        };
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
        let Some(root) = self.root.as_mut() else {
            return Err(LayoutError::NotFound);
        };
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
        // Tuple carries (title, cols, rows, cwd, busy). `busy` is the
        // active surface's foreground-process state; computed here (one
        // tcgetpgrp per live surface) so it rides the SAME snapshot the
        // wire already builds — no separate polling path.
        let meta: std::collections::HashMap<SurfaceId, (String, u32, u32, String, bool)> = manager
            .list()
            .into_iter()
            .map(|s| {
                let info = s.info();
                (
                    info.surface_id.clone(),
                    (info.title, info.cols, info.rows, info.cwd, s.is_busy()),
                )
            })
            .collect();
        self.root.as_ref().map(|n| Self::node_to_proto(n, &meta))
    }

    fn node_to_proto(
        node: &LayoutNode,
        meta_map: &std::collections::HashMap<SurfaceId, (String, u32, u32, String, bool)>,
    ) -> WorkspaceLayout {
        match node {
            LayoutNode::Pane { active, tabs } => {
                let meta = |sid: &SurfaceId| -> (String, u32, u32, String, bool) {
                    meta_map.get(sid).cloned().unwrap_or_default()
                };
                let (title, cols, rows, cwd, busy) = meta(active);
                let project_root = project_root_for(&cwd);
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
                        busy,
                        project_root,
                    })),
                }
            }
            LayoutNode::Split {
                id,
                orientation,
                divider,
                first,
                second,
            } => WorkspaceLayout {
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

    /// Seed a brand-new workspace's tree with its very first pane. Used by
    /// `PeerHost::new_tab` when a `NewTabRequest` carries `workspace_id`
    /// instead of a resolvable `pane_id` — the client's "create the first
    /// pane in this (till now empty) workspace" case, right after
    /// `CreateWorkspaceRequest`. Refuses (returns `false`, tree
    /// untouched) once the tree already has content — that path goes
    /// through `add_tab`/`split_pane` instead, which know how to target
    /// an existing pane.
    pub fn seed_first_pane(&mut self, surface_id: SurfaceId) -> bool {
        if self.root.is_some() {
            return false;
        }
        self.root = Some(LayoutNode::Pane {
            active: surface_id.clone(),
            tabs: vec![surface_id],
        });
        true
    }

    /// Register a daemon-owned surface in the first pane of this workspace.
    /// Ensured runners use this deterministic placement rather than requiring
    /// a client-side picker or an inferred pane target.
    pub fn register_surface(&mut self, surface_id: SurfaceId) -> bool {
        if self.surface_ids().iter().any(|id| id == &surface_id) {
            return false;
        }
        let Some(root) = self.root.as_mut() else {
            return self.seed_first_pane(surface_id);
        };
        Self::register_in_first_pane(root, &surface_id);
        true
    }

    fn register_in_first_pane(node: &mut LayoutNode, surface_id: &SurfaceId) {
        match node {
            LayoutNode::Pane { active, tabs } => {
                tabs.push(surface_id.clone());
                *active = surface_id.clone();
            }
            LayoutNode::Split { first, .. } => Self::register_in_first_pane(first, surface_id),
        }
    }

    /// Explicit runner termination may leave a named workspace empty. This
    /// differs from interactive ClosePane, which still refuses its last pane.
    pub fn remove_surface_allow_empty(&mut self, surface_id: &[u8]) -> bool {
        if matches!(&self.root, Some(LayoutNode::Pane { tabs, .. }) if tabs.len() == 1 && tabs[0] == surface_id)
        {
            self.root = None;
            return true;
        }
        self.close_pane(surface_id).is_ok()
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

/// Fallback name for the default workspace a daemon-only host always has.
/// Used only as the last-resort name (constructors that skip persistence
/// entirely, e.g. `PeerHost::new`) or as a defensive title in
/// `default_workspace_title` — production boot (`persist::boot`) instead
/// names the default workspace from a persisted rename, the hostname, or
/// `TERMMESH_PEER_WORKSPACE_TITLE`. M1 dropped the prior
/// `surface_id_from_name(DAEMON_WORKSPACE)` id derivation: a workspace's
/// id is now a random 16 bytes assigned once at creation (see
/// `persist::PersistedWorkspace`), so it survives a rename unchanged
/// instead of being re-derivable from (and therefore coupled to) the name.
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
    next_leader_generation: AtomicU64,
    leader_pending: Mutex<HashMap<Vec<u8>, PendingLeaderResponse>>,
}

#[derive(Clone)]
struct RegisteredClient {
    tx: mpsc::Sender<Envelope>,
    peer_id: Vec<u8>,
    /// The connection's own outgoing seq counter — pushes must continue
    /// each connection's monotonic sequence, not share a global one.
    seq: Arc<AtomicU64>,
    /// Set once this connection sends `SubscribeWorkspaceList`.
    ///
    /// Shared with the connection task, which is the only writer: the
    /// subscription arrives on its receive loop, long after registration.
    /// Without it the roster went to every client on every layout push —
    /// including a viewer watching one pane, which had already been sent
    /// the scoped delta it actually needed.
    wants_roster: Arc<AtomicBool>,
}

struct PendingLeaderResponse {
    generation: u64,
    routes: Vec<PendingLeaderRoute>,
    target_peer_id: Vec<u8>,
    request: TeamLeaderCommandRequest,
    senders: Vec<oneshot::Sender<Result<TeamLeaderCommandResponse, String>>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct PendingLeaderRoute {
    connection_id: u64,
    correlation_id: u64,
}

impl Broadcaster {
    fn fail_pending_leader_generation_if_matches(
        &self,
        request_id: &[u8],
        generation: u64,
        message: &str,
    ) -> bool {
        let entry = {
            let mut pending = self.leader_pending.lock().unwrap();
            let matches = pending
                .get(request_id)
                .is_some_and(|entry| entry.generation == generation);
            matches.then(|| pending.remove(request_id)).flatten()
        };
        let Some(entry) = entry else { return false };
        for sender in entry.senders {
            let _ = sender.send(Err(message.to_string()));
        }
        true
    }

    /// Retire one unusable connection route. The command remains pending as
    /// long as another connection for the same peer can still answer it.
    fn remove_pending_leader_route(
        &self,
        request_id: &[u8],
        generation: u64,
        route: PendingLeaderRoute,
        message: &str,
    ) -> bool {
        let entry = {
            let mut pending = self.leader_pending.lock().unwrap();
            let Some(entry) = pending.get_mut(request_id) else {
                return false;
            };
            if entry.generation != generation {
                return false;
            }
            let Some(index) = entry
                .routes
                .iter()
                .position(|candidate| *candidate == route)
            else {
                return false;
            };
            entry.routes.swap_remove(index);
            entry
                .routes
                .is_empty()
                .then(|| pending.remove(request_id))
                .flatten()
        };
        let Some(entry) = entry else { return false };
        for sender in entry.senders {
            let _ = sender.send(Err(message.to_string()));
        }
        true
    }

    pub fn new() -> Self {
        Self {
            clients: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            next_leader_generation: AtomicU64::new(1),
            leader_pending: Mutex::new(HashMap::new()),
        }
    }

    pub fn register(
        self: &Arc<Self>,
        tx: mpsc::Sender<Envelope>,
        seq: Arc<AtomicU64>,
        peer_id: Vec<u8>,
    ) -> BroadcastGuard {
        self.register_with_roster_flag(tx, seq, peer_id, Arc::new(AtomicBool::new(false)))
    }

    /// `register`, plus the handle the connection flips when it subscribes to
    /// the workspace roster.
    pub fn register_with_roster_flag(
        self: &Arc<Self>,
        tx: mpsc::Sender<Envelope>,
        seq: Arc<AtomicU64>,
        peer_id: Vec<u8>,
        wants_roster: Arc<AtomicBool>,
    ) -> BroadcastGuard {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.clients.lock().unwrap().insert(
            id,
            RegisteredClient {
                tx,
                peer_id,
                seq,
                wants_roster,
            },
        );
        BroadcastGuard {
            broadcaster: Arc::clone(self),
            id,
        }
    }

    /// Fan a payload out to every registered connection, stamping each
    /// envelope with that connection's next seq. Clone-then-send: the
    /// guard is released before any channel interaction.
    /// Whether anyone has asked for the workspace roster.
    ///
    /// Checked before the roster is built, not after: assembling it walks
    /// every workspace's pane tree, so with no subscriber the cheapest
    /// correct thing is to never start.
    pub fn has_roster_subscriber(&self) -> bool {
        self.clients
            .lock()
            .unwrap()
            .values()
            .any(|client| client.wants_roster.load(Ordering::Relaxed))
    }

    /// Send only to connections that subscribed to the roster.
    pub fn broadcast_to_roster_subscribers(&self, payload: &peer_proto::v1::envelope::Payload) {
        let clients: Vec<RegisteredClient> = self
            .clients
            .lock()
            .unwrap()
            .values()
            .filter(|client| client.wants_roster.load(Ordering::Relaxed))
            .cloned()
            .collect();
        self.send_to(clients, payload);
    }

    pub fn broadcast(&self, payload: &peer_proto::v1::envelope::Payload) {
        let clients: Vec<RegisteredClient> =
            self.clients.lock().unwrap().values().cloned().collect();
        self.send_to(clients, payload);
    }

    fn send_to(&self, clients: Vec<RegisteredClient>, payload: &peer_proto::v1::envelope::Payload) {
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

    /// Send a scoped remote-leader command to an authenticated viewer and
    /// wait for its authoritative control-plane response. The request itself
    /// carries the expiring grant; this router never accepts a lifecycle
    /// method or a filesystem/process field.
    pub async fn call_team_leader(
        &self,
        request: TeamLeaderCommandRequest,
        target_peer_id: &[u8],
    ) -> Result<TeamLeaderCommandResponse, String> {
        if request.request_id.len() != peer_proto::team_leader::REQUEST_ID_BYTES {
            return Err("invalid request_id".into());
        }
        let targets = self
            .clients
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, client)| client.peer_id == target_peer_id)
            .map(|(id, client)| (*id, client.clone()))
            .collect::<Vec<_>>();
        if targets.is_empty() {
            return Err("authorized peer viewer is not connected".to_string());
        }
        let (tx, rx) = oneshot::channel();
        let mut joined = false;
        let generation;
        let routes;
        {
            let mut pending = self.leader_pending.lock().unwrap();
            if let Some(existing) = pending.get_mut(&request.request_id) {
                if existing.target_peer_id != target_peer_id || existing.request != request {
                    return Err("request_id conflicts with an in-flight request".into());
                }
                existing.senders.push(tx);
                generation = existing.generation;
                routes = Vec::new();
                joined = true;
            } else {
                generation = self.next_leader_generation.fetch_add(1, Ordering::Relaxed);
                routes = targets
                    .iter()
                    .map(|(connection_id, client)| PendingLeaderRoute {
                        connection_id: *connection_id,
                        correlation_id: client.seq.fetch_add(1, Ordering::Relaxed) + 1,
                    })
                    .collect::<Vec<_>>();
                pending.insert(
                    request.request_id.clone(),
                    PendingLeaderResponse {
                        generation,
                        routes: routes.clone(),
                        target_peer_id: target_peer_id.to_vec(),
                        request: request.clone(),
                        senders: vec![tx],
                    },
                );
            }
        }
        if joined {
            return match tokio::time::timeout(
                Duration::from_secs(peer_proto::team_leader::COMMAND_PENDING_TIMEOUT_SECS),
                rx,
            )
            .await
            {
                Ok(Ok(result)) => result,
                Ok(Err(_)) => Err("peer viewer dropped the command response".into()),
                Err(_) => Err("peer leader command timed out".into()),
            };
        }
        // Re-check every selected connection after installing the pending
        // entry. Disconnects and channel backpressure retire only that route;
        // another connection for the same peer may still answer.
        {
            let registered = self.clients.lock().unwrap();
            for ((_, client), route) in targets.into_iter().zip(routes.iter().copied()) {
                let still_registered = registered
                    .get(&route.connection_id)
                    .is_some_and(|candidate| candidate.peer_id == target_peer_id);
                let sent = still_registered
                    && client
                        .tx
                        .try_send(Envelope {
                            seq: route.correlation_id,
                            correlation_id: 0,
                            payload: Some(Payload::TeamLeaderCommandRequest(request.clone())),
                        })
                        .is_ok();
                if !sent {
                    self.remove_pending_leader_route(
                        &request.request_id,
                        generation,
                        route,
                        "authorized peer viewer is unavailable",
                    );
                }
            }
        }
        match tokio::time::timeout(
            Duration::from_secs(peer_proto::team_leader::COMMAND_PENDING_TIMEOUT_SECS),
            rx,
        )
        .await
        {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err("peer viewer dropped the command response".into()),
            Err(_) => {
                self.fail_pending_leader_generation_if_matches(
                    &request.request_id,
                    generation,
                    "peer leader command timed out",
                );
                Err("peer leader command timed out".into())
            }
        }
    }

    /// Complete a pending reverse request. Duplicate responses are expected
    /// when several attached panes share the same viewer; only the first one
    /// wins, while the local control-plane's request cache prevents duplicate
    /// mutation on the viewer side.
    pub fn resolve_team_leader(
        &self,
        connection_id: u64,
        correlation_id: u64,
        response: TeamLeaderCommandResponse,
    ) -> bool {
        let mut pending = self.leader_pending.lock().unwrap();
        let Some(expected) = pending.get(&response.request_id) else {
            return false;
        };
        if !expected.routes.iter().any(|route| {
            route.connection_id == connection_id && route.correlation_id == correlation_id
        }) {
            return false;
        }
        let Some(expected) = pending.remove(&response.request_id) else {
            return false;
        };
        for sender in expected.senders {
            let _ = sender.send(Ok(response.clone()));
        }
        true
    }
}

pub struct BroadcastGuard {
    broadcaster: Arc<Broadcaster>,
    id: u64,
}

impl BroadcastGuard {
    pub fn connection_id(&self) -> u64 {
        self.id
    }
}

impl Drop for BroadcastGuard {
    fn drop(&mut self) {
        self.broadcaster.clients.lock().unwrap().remove(&self.id);
        // A reverse leader request may be in flight on several connections
        // for the same peer. Retire only this connection's route and fail the
        // callers immediately only when no route remains.
        let removed = {
            let mut pending = self.broadcaster.leader_pending.lock().unwrap();
            let request_ids = pending
                .iter_mut()
                .filter_map(|(request_id, entry)| {
                    entry.routes.retain(|route| route.connection_id != self.id);
                    entry.routes.is_empty().then(|| request_id.clone())
                })
                .collect::<Vec<_>>();
            request_ids
                .into_iter()
                .filter_map(|request_id| pending.remove(&request_id))
                .collect::<Vec<_>>()
        };
        for entry in removed {
            for sender in entry.senders {
                let _ = sender.send(Err("authorized peer viewer is unavailable".into()));
            }
        }
    }
}

/// One named workspace on a daemon host: its stable id, display name, and
/// the split tree its surfaces are arranged in. A daemon boots with
/// exactly one (`DAEMON_WORKSPACE`); the collection exists so a later task
/// (Create/Rename/Delete workspace RPCs) can grow it without another pass
/// over this module's locking/broadcast plumbing.
pub struct WorkspaceEntry {
    pub id: Vec<u8>,
    pub name: String,
    /// True for exactly one entry in a host's collection at all times.
    /// Invariant enforced by `PeerHost::with_workspaces` (promotes the
    /// first entry if none is marked) and `PeerHost::remove_workspace`
    /// (refuses to remove the entry carrying this flag).
    pub is_default: bool,
    pub store: LayoutStore,
}

/// One roster entry as returned by `PeerHost::list_workspaces` — the
/// generic (N-workspace) counterpart to the single hardcoded `Workspace`
/// connection.rs's `ListWorkspaces` handler used to build before M2.
pub struct WorkspaceRosterEntry {
    pub id: Vec<u8>,
    pub title: String,
    pub layout: Option<WorkspaceLayout>,
    pub is_default: bool,
}

static ACTIVE_HOST: std::sync::OnceLock<Mutex<Weak<PeerHost>>> = std::sync::OnceLock::new();

/// One durable manifest as an operator sees it (`peer.project_presentations.list`).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct ProjectPresentationStatus {
    pub project_id: String,
    pub team_name: String,
    pub working_directory: String,
    pub owner_peer_id: String,
    pub revision: u64,
    pub referenced_surfaces: usize,
    pub live_surfaces: usize,
    pub directory_present: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct ProjectPresentationPruneSkip {
    pub project_id: String,
    pub reason: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct ProjectPresentationPruneReport {
    pub applied: bool,
    pub backup_path: Option<String>,
    pub removed: Vec<ProjectPresentationStatus>,
    pub skipped: Vec<ProjectPresentationPruneSkip>,
}

/// Shared state of one daemon peer host: the PTYs, the workspaces they are
/// arranged into, and the connections to push layout changes to. This is
/// what `connection::run` receives instead of a bare `PtyManager`.
///
/// Lock discipline (as everywhere in `peer::`): guards never cross an
/// `.await`, and mutation results are broadcast after unlock. Nesting is
/// one-directional — a method may hold `workspaces` and, separately (never
/// nested), `surface_workspace` — but no code path takes either lock while
/// holding a manager guard, so the order is consistent and cannot
/// deadlock.
pub struct PeerHost {
    pub pty: Arc<PtyManager>,
    /// Every workspace this host currently serves, keyed by workspace id.
    /// Invariant: never empty after `new()` returns — `DAEMON_WORKSPACE`
    /// always exists.
    pub workspaces: Mutex<HashMap<Vec<u8>, WorkspaceEntry>>,
    pub clients: Arc<Broadcaster>,
    /// Id of the current default entry. Before M3 this was stable for the
    /// daemon's lifetime; M3 lets the default workspace itself be deleted
    /// (`remove_workspace`), promoting a survivor and updating this field,
    /// so it is now a `Mutex` rather than a plain field. Not `pub` — every
    /// reader goes through `default_id()` so the lock discipline lives in
    /// one place; `connection.rs`/`server.rs` never touched the field
    /// directly even when it was public (verified before this change).
    workspace_id: Mutex<Vec<u8>>,
    /// Reverse index from surface id to the workspace whose tree currently
    /// contains it. `surface_id` is globally unique across all workspaces,
    /// so this is a simple flat map. Used to route `apply_control`
    /// mutations and `watch_ephemeral` removals to the right tree without
    /// scanning every workspace.
    surface_workspace: Mutex<HashMap<SurfaceId, Vec<u8>>>,
    /// Names split/new-tab surfaces (`split-1`, `split-2`, …). Lifetime
    /// of this daemon only, like the tree itself. Host-wide (not
    /// per-workspace) so ephemeral ids never collide across workspaces.
    ephemeral_counter: AtomicU64,
    /// Workspace ids with a debounced layout push currently pending —
    /// collapses a burst of mutations (divider drags especially) against
    /// the SAME workspace into one push, while still letting a different
    /// workspace's mutation schedule (and fire) its own push
    /// independently. Keyed by workspace id rather than a single flag
    /// because M2 made pushes per-workspace (see `schedule_layout_push`).
    pending_pushes: Mutex<HashSet<Vec<u8>>>,
    /// On-disk path the workspace collection is persisted to after every
    /// create/rename/delete. `None` for hosts built without a
    /// persistence path (every test constructor: `new`/`with_workspaces`
    /// default to this) — those mutate in memory only, exactly like
    /// before M1/M2. Production boot (`server::serve`) sets this via
    /// `set_persist_path` right after construction.
    persist_path: Mutex<Option<PathBuf>>,
    /// Serializes each workspace mutation through the snapshot+save boundary,
    /// preventing an older concurrent snapshot from winning the final rename.
    workspace_persistence: Mutex<()>,
    /// Host-level lifecycle boundary covering PTY, layout, and reverse index.
    /// The manager's per-id lock remains authoritative for PTY internals.
    surface_lifecycle: Mutex<HashMap<SurfaceId, Weak<Mutex<()>>>>,
    /// Live system stats for the machine this host runs on, if the daemon
    /// wired its monitor in. `None` for every host built without one (the
    /// test constructors, and any embedder that has no monitor) — those
    /// simply never push `HostStats`, which is the same thing a client
    /// sees when talking to a daemon too old to have it. Set by
    /// `server::serve` right after construction, mirroring `persist_path`.
    monitor: Mutex<Option<watch::Receiver<Option<SystemSnapshot>>>>,
    /// The daemon's agent-team manager, when one was wired in. `None` for
    /// every host built without it (tests, embedders), which is exactly what
    /// a client sees from a daemon too old to answer `ListTeams` — so the
    /// capability is advertised only when this is set.
    teams: Mutex<Option<Arc<tokio::sync::Mutex<crate::headless::HeadlessManager>>>>,
    /// The daemon's task board, when one was wired in.
    ///
    /// Separate from `teams` because they answer different questions: the team
    /// manager knows about running agents, the task board knows where a task
    /// did its work. `team.task.diff` needs the second and nothing else, and a
    /// host without a board answers that method honestly rather than guessing
    /// at a directory.
    agents: Mutex<Option<Arc<crate::agent::AgentSessionManager>>>,
    /// Durable project → surface ownership map. Unlike a workspace layout,
    /// this includes agent surfaces (which intentionally never enter the
    /// tree) and survives every viewer disconnect.
    project_presentations: Mutex<HashMap<String, super::persist::PersistedProjectPresentation>>,
    project_presentations_path: Mutex<Option<PathBuf>>,
    project_presentations_persistence: Mutex<()>,
    project_presentation_watchers: Mutex<HashSet<Vec<u8>>>,
}

/// Debounce window for layout pushes. Mirrors the Swift host's 120 ms
/// (`PeerServerHost.scheduleLayoutBroadcast`); the client itself debounces
/// divider sends at 150 ms, so anything in this range coalesces a drag
/// into a handful of pushes instead of hundreds.
const PUSH_DEBOUNCE: Duration = Duration::from_millis(120);

/// Failure modes for `PeerHost::remove_workspace`, wired up to
/// `DeleteWorkspaceRequest` in `connection.rs`. Through M2 the collection-
/// level invariant here was "the default workspace can never be removed";
/// M3 relaxes that to "the LAST workspace can never be removed" — the
/// default is deletable like any other entry as long as a survivor can be
/// promoted to take its place (see `remove_workspace`).
#[derive(Debug, PartialEq, Eq)]
pub enum RemoveWorkspaceError {
    NotFound,
    /// Refusing to remove the only workspace left — un-namespaced control
    /// (and `default_id()`) always needs a home to resolve to.
    LastWorkspace,
}

impl PeerHost {
    /// Convenience constructor for callers that don't care about
    /// persistence (every existing test, and any future in-process
    /// caller that just wants a working host): a single default
    /// workspace, freshly random id, `DAEMON_WORKSPACE` as its name.
    /// Production boot goes through `with_workspaces` instead, seeded by
    /// `persist::boot` (see `server::serve`) — so in a non-test build this
    /// constructor's only caller is `server::serve_with_manager`, itself
    /// test-only for the same reason. Kept `pub` (not `#[cfg(test)]`)
    /// because it is the documented entry point for any future in-process
    /// embedder that wants a working host without touching persistence.
    #[allow(dead_code)]
    pub fn new(pty: Arc<PtyManager>) -> Self {
        Self::with_workspaces(
            pty,
            vec![PersistedWorkspace {
                id: super::connection::random_peer_bytes(16),
                name: DAEMON_WORKSPACE.to_string(),
                is_default: true,
            }],
        )
    }

    /// Build a host from an already-resolved workspace collection — the
    /// result of `persist::boot`, or a hand-built single entry (`new`).
    /// The manager's current surfaces are tiled into the default entry's
    /// tree exactly like the pre-M1 constructor did; every other entry
    /// starts as an empty workspace (M1 boots named workspaces empty —
    /// only the default one ever inherits startup surfaces).
    ///
    /// Exactly one entry must be `is_default`; if none is (defensive —
    /// `persist::boot` already guards this, but a hand-built `Vec`
    /// passed by some future caller might not), the first entry is
    /// promoted so the collection is never left without a home for
    /// un-namespaced control commands.
    pub fn with_workspaces(pty: Arc<PtyManager>, mut entries: Vec<PersistedWorkspace>) -> Self {
        debug_assert!(
            !entries.is_empty(),
            "workspace collection must never be empty"
        );
        if !entries.iter().any(|e| e.is_default) {
            if let Some(first) = entries.first_mut() {
                first.is_default = true;
            }
        }

        // PTY surfaces only: an agent surface never tiles into a workspace
        // tree. `WorkspacePane` carries no surface_type, so a viewer reading
        // the layout could only render such a pane as a terminal — until the
        // wire can name the kind, staying out of the tree IS the contract
        // (the surface remains reachable through SurfaceList/attach).
        let surfaces: Vec<Arc<PtySurface>> = pty
            .list()
            .into_iter()
            .filter(|s| s.kind() == SurfaceKind::Pty)
            .collect();
        let mut surface_workspace = HashMap::new();
        let mut workspaces = HashMap::new();
        let mut default_id = None;
        for entry in entries {
            let store = if entry.is_default {
                default_id = Some(entry.id.clone());
                for surface in &surfaces {
                    surface_workspace.insert(surface.surface_id.clone(), entry.id.clone());
                }
                LayoutStore::balanced_from_surfaces(&surfaces)
            } else {
                LayoutStore {
                    root: None,
                    next_split_id: 1,
                }
            };
            workspaces.insert(
                entry.id.clone(),
                WorkspaceEntry {
                    id: entry.id,
                    name: entry.name,
                    is_default: entry.is_default,
                    store,
                },
            );
        }
        // Guaranteed by the promotion above: some entry is always default.
        let workspace_id = default_id.expect("workspace collection must contain a default entry");

        Self {
            pty,
            workspaces: Mutex::new(workspaces),
            clients: Arc::new(Broadcaster::new()),
            workspace_id: Mutex::new(workspace_id),
            surface_workspace: Mutex::new(surface_workspace),
            ephemeral_counter: AtomicU64::new(1),
            pending_pushes: Mutex::new(HashSet::new()),
            persist_path: Mutex::new(None),
            workspace_persistence: Mutex::new(()),
            surface_lifecycle: Mutex::new(HashMap::new()),
            monitor: Mutex::new(None),
            teams: Mutex::new(None),
            agents: Mutex::new(None),
            project_presentations: Mutex::new(HashMap::new()),
            project_presentations_path: Mutex::new(None),
            project_presentations_persistence: Mutex::new(()),
            project_presentation_watchers: Mutex::new(HashSet::new()),
        }
    }

    fn surface_lifecycle_lock(&self, surface_id: &[u8]) -> Arc<Mutex<()>> {
        let mut locks = self.surface_lifecycle.lock().unwrap();
        locks.retain(|_, lock| lock.strong_count() > 0);
        if let Some(lock) = locks.get(surface_id).and_then(Weak::upgrade) {
            return lock;
        }
        let lock = Arc::new(Mutex::new(()));
        locks.insert(surface_id.to_vec(), Arc::downgrade(&lock));
        lock
    }

    /// Wire the on-disk persistence path after construction. Kept out of
    /// `with_workspaces` itself so that constructor stays I/O-free (every
    /// existing test calls it directly and must not race real disk
    /// access) — production boot (`server::serve`) calls this once right
    /// after building the host, and every workspace-lifecycle mutation
    /// below (`create_workspace`/`rename_workspace`/`remove_workspace`)
    /// persists through it via `persist_workspaces`.
    pub fn set_persist_path(self: &Arc<Self>, path: PathBuf) {
        self.pty
            .set_ensured_persist_path(super::persist::ensured_surfaces_path(&path));
        let project_path = super::persist::project_presentations_path(&path);
        let records = super::persist::load_project_presentations(&project_path)
            .into_iter()
            .map(|record| (record.project_id.clone(), record))
            .collect();
        *self.project_presentations.lock().unwrap() = records;
        *self.project_presentations_path.lock().unwrap() = Some(project_path);
        *self.persist_path.lock().unwrap() = Some(path);
        for surface in self.pty.list() {
            if self.presentation_references_surface(&surface.surface_id) {
                self.watch_presentation_surface(surface);
            }
        }
    }

    pub fn project_presentations(&self) -> Vec<super::persist::PersistedProjectPresentation> {
        self.project_presentations
            .lock()
            .unwrap()
            .values()
            .cloned()
            .collect()
    }

    /// Publish this host as the process-wide active host so control-socket
    /// RPCs (`peer.project_presentations.*`) can reach it without threading
    /// the handle through `socket::Context`. Mirrors the replay-capacity
    /// static: the daemon has exactly one host, tests construct their own
    /// and never register.
    pub fn register_active_host(self: &Arc<Self>) {
        let slot = ACTIVE_HOST.get_or_init(|| Mutex::new(Weak::new()));
        let mut current = slot.lock().unwrap();
        if let Some(previous) = current.upgrade() {
            if !Arc::ptr_eq(&previous, self) {
                tracing::warn!("replacing a live active peer host; control RPCs now target the new one");
            }
        }
        *current = Arc::downgrade(self);
    }

    pub fn active_host() -> Option<Arc<PeerHost>> {
        ACTIVE_HOST
            .get()
            .and_then(|slot| slot.lock().unwrap().upgrade())
    }

    /// Surface ids the registry currently reports attachable — the same
    /// liveness the roster advertises, so an administrative view never
    /// disagrees with what a client can see.
    fn live_surface_ids(&self) -> HashSet<Vec<u8>> {
        self.pty
            .list()
            .into_iter()
            .filter(|surface| surface.info().attachable)
            .map(|surface| surface.surface_id.clone())
            .collect()
    }

    fn presentation_status(
        record: &super::persist::PersistedProjectPresentation,
        live: &HashSet<Vec<u8>>,
    ) -> ProjectPresentationStatus {
        let ids = Self::presentation_surface_ids(record);
        ProjectPresentationStatus {
            project_id: record.project_id.clone(),
            team_name: record.team_name.clone(),
            working_directory: record.working_directory.clone(),
            owner_peer_id: record.owner_peer_id.clone(),
            revision: record.revision,
            referenced_surfaces: ids.len(),
            live_surfaces: ids.iter().filter(|id| live.contains(*id)).count(),
            directory_present: !record.working_directory.is_empty()
                && Path::new(&record.working_directory).is_dir(),
        }
    }

    /// Every durable manifest with the facts an operator needs to judge it:
    /// how many of its surfaces are live and whether its directory exists.
    pub fn project_presentation_statuses(&self) -> Vec<ProjectPresentationStatus> {
        let live = self.live_surface_ids();
        let mut statuses: Vec<_> = self
            .project_presentations
            .lock()
            .unwrap()
            .values()
            .map(|record| Self::presentation_status(record, &live))
            .collect();
        statuses.sort_by(|a, b| a.project_id.cmp(&b.project_id));
        statuses
    }

    /// Host-side removal of manifests nothing can resume. This is the
    /// operator path for records another installation owns (protocol
    /// deletion answers `not_owner`); it bypasses ownership on purpose and
    /// therefore never runs from a peer connection.
    ///
    /// Selection: with `project_ids` the named records are candidates; without
    /// them only records whose working directory is gone. A record with any
    /// live surface is never removed, whichever way it was selected — a
    /// project that is merely idle must stay resumable. Nothing here touches
    /// workspaces or surfaces. `apply = false` reports without writing; an
    /// applied prune first copies the current file to a timestamped `.bak`.
    pub fn prune_stale_project_presentations(
        &self,
        project_ids: &[String],
        apply: bool,
    ) -> Result<ProjectPresentationPruneReport, &'static str> {
        let _persist_guard = self.project_presentations_persistence.lock().unwrap();
        let live = self.live_surface_ids();
        let mut records = self.project_presentations.lock().unwrap();
        let explicit = !project_ids.is_empty();
        let mut targets: Vec<String> = if explicit {
            project_ids.to_vec()
        } else {
            records.keys().cloned().collect()
        };
        targets.sort();
        targets.dedup();

        let mut removed = Vec::new();
        let mut skipped = Vec::new();
        for project_id in targets {
            let Some(record) = records.get(&project_id) else {
                skipped.push(ProjectPresentationPruneSkip { project_id, reason: "not_found" });
                continue;
            };
            let status = Self::presentation_status(record, &live);
            if status.live_surfaces > 0 {
                skipped.push(ProjectPresentationPruneSkip { project_id, reason: "live" });
                continue;
            }
            if !explicit && status.directory_present {
                skipped.push(ProjectPresentationPruneSkip {
                    project_id,
                    reason: "directory_present",
                });
                continue;
            }
            removed.push(status);
        }

        if !apply || removed.is_empty() {
            return Ok(ProjectPresentationPruneReport {
                applied: false,
                backup_path: None,
                removed,
                skipped,
            });
        }

        // The liveness set above is a snapshot: an attach can respawn a dead
        // surface (`get_or_respawn`) between it and the removal below. Look
        // again right before committing so a record that just came back to
        // life is reported as live instead of removed.
        let live_now = self.live_surface_ids();
        let (removed, revived): (Vec<_>, Vec<_>) = removed.into_iter().partition(|status| {
            records
                .get(&status.project_id)
                .map(|record| Self::presentation_status(record, &live_now).live_surfaces == 0)
                .unwrap_or(false)
        });
        for status in revived {
            skipped.push(ProjectPresentationPruneSkip {
                project_id: status.project_id,
                reason: "live",
            });
        }
        if removed.is_empty() {
            return Ok(ProjectPresentationPruneReport {
                applied: false,
                backup_path: None,
                removed,
                skipped,
            });
        }
        let path = self.project_presentations_path.lock().unwrap().clone();
        let backup_path = match &path {
            Some(path) => Self::backup_project_presentations_file(path)?,
            None => None,
        };
        let previous: Vec<_> = removed
            .iter()
            .filter_map(|status| records.remove(&status.project_id))
            .collect();
        if let Some(path) = &path {
            let snapshot: Vec<_> = records.values().cloned().collect();
            if super::persist::save_project_presentations(path, &snapshot).is_err() {
                for record in previous {
                    records.insert(record.project_id.clone(), record);
                }
                return Err("persistence_failed");
            }
        }
        Ok(ProjectPresentationPruneReport {
            applied: true,
            backup_path,
            removed,
            skipped,
        })
    }

    /// Copy the persisted manifest file next to itself as
    /// `peer-project-presentations.<unix-secs>[-<n>].bak.json`. The loader
    /// reads only the exact primary path, so backups are never mistaken for
    /// state. `Ok(None)` when nothing was persisted yet.
    fn backup_project_presentations_file(path: &Path) -> Result<Option<String>, &'static str> {
        if !path.exists() {
            return Ok(None);
        }
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_secs())
            .unwrap_or(0);
        let mut candidate = path.with_file_name(format!("peer-project-presentations.{stamp}.bak.json"));
        let mut suffix = 1;
        while candidate.exists() {
            if suffix > 1000 {
                return Err("backup_failed");
            }
            candidate = path.with_file_name(format!(
                "peer-project-presentations.{stamp}-{suffix}.bak.json"
            ));
            suffix += 1;
        }
        std::fs::copy(path, &candidate).map_err(|_| "backup_failed")?;
        Ok(Some(candidate.display().to_string()))
    }

    /// Every surface id a stored manifest names, leader first.
    ///
    /// Malformed entries are skipped rather than failing the caller: a record
    /// that reached the map already passed validation, and a reap list is not
    /// the place to discover otherwise.
    fn presentation_surface_ids(
        record: &super::persist::PersistedProjectPresentation,
    ) -> Vec<Vec<u8>> {
        std::iter::once(&record.leader_surface_id)
            .chain(record.members.iter().map(|member| &member.surface_id))
            .filter_map(|encoded| hex::decode(encoded).ok())
            .collect()
    }

    pub fn delete_project_presentation(
        self: &Arc<Self>,
        owner_peer_ids: &[Vec<u8>],
        project_id: &str,
    ) -> Result<bool, &'static str> {
        self.delete_project_presentation_with_released(owner_peer_ids, project_id)
            .map(|released| released.is_some())
    }

    /// Remove one manifest and retire surfaces that lost their final Project reference.
    ///
    /// The ids are taken from the record this call actually removed, while
    /// the persistence and records locks are still held. A caller that reads
    /// the manifest first and deletes second would be reaping a snapshot: a
    /// replace landing in between makes it release surfaces the live manifest
    /// still names while stranding the ones that really lost their last
    /// reference. `Ok(None)` means there was no such project — nothing was
    /// removed and nothing is released. Losing THIS manifest's reference is
    /// not the same as being unreferenced, so another project naming the same
    /// surface still protects it. The persistence guard stays held through the
    /// final-reference decision; surface lifecycle locks serialize retirement
    /// against a concurrent upsert's under-lock liveness recheck.
    pub(crate) fn delete_project_presentation_with_released(
        self: &Arc<Self>,
        owner_peer_ids: &[Vec<u8>],
        project_id: &str,
    ) -> Result<Option<Vec<Vec<u8>>>, &'static str> {
        if owner_peer_ids.is_empty()
            || owner_peer_ids.iter().any(|id| id.len() != 16)
            || project_id.is_empty()
            || project_id.len() > 128
        {
            return Err("invalid_manifest");
        }
        let _persist_guard = self.project_presentations_persistence.lock().unwrap();
        let mut records = self.project_presentations.lock().unwrap();
        let Some(existing) = records.get(project_id) else {
            return Ok(None);
        };
        if !owner_peer_ids
            .iter()
            .any(|peer_id| existing.owner_peer_id == hex::encode(peer_id))
        {
            return Err("not_owner");
        }
        let previous = records.remove(project_id).expect("checked above");
        let released = Self::presentation_surface_ids(&previous);
        if let Some(path) = self.project_presentations_path.lock().unwrap().clone() {
            let snapshot: Vec<_> = records.values().cloned().collect();
            if super::persist::save_project_presentations(&path, &snapshot).is_err() {
                // The record is back, so its surfaces never lost their
                // reference: a rolled-back delete releases nothing.
                records.insert(project_id.to_string(), previous);
                return Err("persistence_failed");
            }
        }
        let unreferenced = released.iter().filter(|surface_id| {
            let encoded = hex::encode(surface_id);
            !records.values().any(|record| {
                record.leader_surface_id == encoded
                    || record.members.iter().any(|member| member.surface_id == encoded)
            })
        }).cloned().collect::<Vec<_>>();
        drop(records);
        drop(_persist_guard);
        for surface_id in unreferenced {
            let lifecycle = self.surface_lifecycle_lock(&surface_id);
            let _lifecycle_guard = lifecycle.lock().map_err(|_| "surface_lifecycle_poisoned")?;
            if !self.presentation_references_surface(&surface_id) {
                let _ = self.terminate_surface_locked(&surface_id);
            }
        }
        Ok(Some(released))
    }

    /// Whether any durable project manifest still names this surface.
    ///
    /// Read by the roster watcher below and by `reap_if_abandoned`: a
    /// published manifest is itself a live reference, so a surface it names
    /// is never abandoned merely because the viewer that published it left.
    pub(crate) fn presentation_references_surface(&self, surface_id: &[u8]) -> bool {
        let encoded = hex::encode(surface_id);
        self.project_presentations
            .lock()
            .unwrap()
            .values()
            .any(|record| {
                record.leader_surface_id == encoded
                    || record
                        .members
                        .iter()
                        .any(|member| member.surface_id == encoded)
            })
    }

    fn watch_presentation_surface(self: &Arc<Self>, surface: Arc<PtySurface>) -> bool {
        if !self
            .project_presentation_watchers
            .lock()
            .unwrap()
            .insert(surface.surface_id.clone())
        {
            return false;
        }
        let host = Arc::downgrade(self);
        tokio::spawn(async move {
            while !surface.dead.load(Ordering::Acquire) {
                tokio::select! {
                    _ = surface.dead_notify.notified() => {},
                    _ = tokio::time::sleep(Duration::from_millis(100)) => {},
                }
            }
            let Some(host) = host.upgrade() else { return };
            host.project_presentation_watchers
                .lock()
                .unwrap()
                .remove(&surface.surface_id);
            if host.presentation_references_surface(&surface.surface_id) {
                host.broadcast_workspace_roster();
            }
        });
        true
    }

    /// Replace one complete manifest. First writer owns the project; later
    /// updates must come from that same authenticated installation. Every
    /// named surface is checked against the live registry before persistence,
    /// so discovery can never advertise an unrelated or already-dead pane.
    pub fn upsert_project_presentation(
        self: &Arc<Self>,
        owner_peer_ids: &[Vec<u8>],
        project: &peer_proto::v1::Team,
    ) -> Result<(u64, bool), &'static str> {
        self.upsert_project_presentation_with_released(owner_peer_ids, project)
            .map(|(revision, changed, _)| (revision, changed))
    }

    pub(crate) fn upsert_project_presentation_with_released(
        self: &Arc<Self>,
        owner_peer_ids: &[Vec<u8>],
        project: &peer_proto::v1::Team,
    ) -> Result<(u64, bool, Vec<Vec<u8>>), &'static str> {
        if owner_peer_ids.is_empty()
            || owner_peer_ids.iter().any(|id| id.len() != 16)
            || project.project_id.is_empty()
            || project.project_id.len() > 128
            || project.name.is_empty()
            || project.name.len() > 128
            || project.team_uuid.is_empty()
            || project.team_uuid.len() > 128
            || project.working_directory.len() > 4096
            || project.project_root.len() > 4096
            || project.leader_surface_id.len() != 16
            || project.members.len() > 64
        {
            return Err("invalid_manifest");
        }
        let mut seen_instances = HashSet::new();
        let mut seen_surfaces = HashSet::from([project.leader_surface_id.clone()]);
        for member in &project.members {
            if member.name.is_empty()
                || member.agent_instance_id.is_empty()
                || member.name.len() > 128
                || member.agent_instance_id.len() > 128
                || member.cli.len() > 128
                || member.model.len() > 256
                || member.agent_type.len() > 128
                || member.color.len() > 64
                || member.working_directory.len() > 4096
                || member.surface_type.len() > 32
                || !seen_instances.insert(member.agent_instance_id.clone())
                || member.surface_id.len() != 16
                || !seen_surfaces.insert(member.surface_id.clone())
            {
                return Err("invalid_member");
            }
        }

        let _persist_guard = self.project_presentations_persistence.lock().unwrap();
        let mut ordered_surface_ids = seen_surfaces.iter().cloned().collect::<Vec<_>>();
        ordered_surface_ids.sort();
        let lifecycle_locks = ordered_surface_ids.iter()
            .map(|surface_id| self.surface_lifecycle_lock(surface_id))
            .collect::<Vec<_>>();
        let _lifecycle_guards = lifecycle_locks.iter()
            .map(|lock| lock.lock().map_err(|_| "surface_lifecycle_poisoned"))
            .collect::<Result<Vec<_>, _>>()?;
        let surfaces: HashMap<Vec<u8>, _> = self.pty.list().into_iter()
            .map(|surface| (surface.surface_id.clone(), surface)).collect();
        let Some(leader) = surfaces.get(&project.leader_surface_id) else {
            return Err("leader_surface_missing");
        };
        if !leader.info().attachable { return Err("leader_surface_missing"); }
        let mut members = Vec::with_capacity(project.members.len());
        for member in &project.members {
            let Some(surface) = surfaces.get(&member.surface_id) else {
                return Err("member_surface_missing");
            };
            let info = surface.info();
            if !info.attachable || info.surface_type != member.surface_type {
                return Err("member_surface_mismatch");
            }
            members.push(super::persist::PersistedProjectMember {
                name: member.name.clone(),
                agent_instance_id: member.agent_instance_id.clone(),
                cli: member.cli.clone(),
                model: member.model.clone(),
                agent_type: member.agent_type.clone(),
                color: member.color.clone(),
                working_directory: member.working_directory.clone(),
                surface_id: hex::encode(&member.surface_id),
                surface_type: member.surface_type.clone(),
            });
        }
        let owner = hex::encode(&owner_peer_ids[0]);
        let mut records = self.project_presentations.lock().unwrap();
        let previous_surface_ids: Vec<Vec<u8>> = records
            .get(&project.project_id)
            .map(Self::presentation_surface_ids)
            .unwrap_or_default();
        if let Some(existing) = records.get(&project.project_id) {
            // Surface liveness is not an ownership-transfer protocol. A dead
            // leader may be replaced by its owner, but it must not turn a
            // durable project ID into a first-writer race for other peers.
            if !owner_peer_ids
                .iter()
                .any(|peer_id| existing.owner_peer_id == hex::encode(peer_id))
            {
                return Err("not_owner");
            }
        }
        let revision = records
            .get(&project.project_id)
            .map_or(1, |record| record.revision.saturating_add(1));
        let mut record = super::persist::PersistedProjectPresentation {
            // Preserve the original owner while an alias authorizes this
            // write. Rotation recovery must not silently rewrite ownership;
            // that keeps every retained alias usable across offline hosts.
            owner_peer_id: records
                .get(&project.project_id)
                .map_or(owner, |record| record.owner_peer_id.clone()),
            project_id: project.project_id.clone(),
            team_name: project.name.clone(),
            team_uuid: project.team_uuid.clone(),
            working_directory: project.working_directory.clone(),
            project_root: project.project_root.clone(),
            delegation_configured: project.delegation_configured.clone(),
            delegation_effective: project.delegation_effective.clone(),
            delegation_pending: project.delegation_pending.clone(),
            created_at_unix_secs: project.created_at_unix_secs,
            leader_surface_id: hex::encode(&project.leader_surface_id),
            members,
            revision,
        };
        if let Some(existing) = records.get(&project.project_id) {
            record.revision = existing.revision;
            if existing == &record {
                let existing_revision = existing.revision;
                let watched = std::iter::once(project.leader_surface_id.as_slice())
                    .chain(
                        project
                            .members
                            .iter()
                            .map(|member| member.surface_id.as_slice()),
                    )
                    .filter_map(|surface_id| surfaces.get(surface_id).cloned())
                    .collect::<Vec<_>>();
                drop(records);
                let mut watchers_changed = false;
                for surface in watched {
                    watchers_changed |= self.watch_presentation_surface(surface);
                }
                return Ok((existing_revision, watchers_changed, Vec::new()));
            }
            record.revision = revision;
        }
        let previous = records.insert(project.project_id.clone(), record);
        if let Some(path) = self.project_presentations_path.lock().unwrap().clone() {
            let snapshot: Vec<_> = records.values().cloned().collect();
            if super::persist::save_project_presentations(&path, &snapshot).is_err() {
                if let Some(previous) = previous {
                    records.insert(project.project_id.clone(), previous);
                } else {
                    records.remove(&project.project_id);
                }
                return Err("persistence_failed");
            }
        }
        let watched = std::iter::once(project.leader_surface_id.as_slice())
            .chain(
                project
                    .members
                    .iter()
                    .map(|member| member.surface_id.as_slice()),
            )
            .filter_map(|surface_id| surfaces.get(surface_id).cloned())
            .collect::<Vec<_>>();
        drop(records);
        for surface in watched {
            self.watch_presentation_surface(surface);
        }
        let released = previous_surface_ids
            .into_iter()
            .filter(|surface_id| !seen_surfaces.contains(surface_id))
            .collect();
        Ok((revision, true, released))
    }

    /// Wire the daemon's system monitor so connections can push `HostStats`.
    ///
    /// Injected after construction for the same reason as the persistence
    /// path: the constructors stay free of daemon-wide dependencies, so
    /// every test and embedder keeps building a host without one. A host
    /// left unwired never pushes stats, which is indistinguishable from a
    /// daemon predating the feature — exactly the fallback the capability
    /// gate already gives an older client.
    pub fn set_monitor(&self, monitor: watch::Receiver<Option<SystemSnapshot>>) {
        *self.monitor.lock().unwrap() = Some(monitor);
    }

    pub fn set_teams(&self, teams: Arc<tokio::sync::Mutex<crate::headless::HeadlessManager>>) {
        *self.teams.lock().unwrap() = Some(teams);
    }

    /// The team manager, if one was wired in. Cloned out of the lock so the
    /// caller can await on the manager's own mutex without holding this one.
    pub fn team_manager(
        &self,
    ) -> Option<Arc<tokio::sync::Mutex<crate::headless::HeadlessManager>>> {
        self.teams.lock().unwrap().clone()
    }

    pub fn set_agents(&self, agents: Arc<crate::agent::AgentSessionManager>) {
        *self.agents.lock().unwrap() = Some(agents);
    }

    /// The task board, if one was wired in.
    pub fn agent_store(&self) -> Option<Arc<crate::agent::AgentSessionManager>> {
        self.agents.lock().unwrap().clone()
    }

    /// A receiver for the live system stats, if a monitor was wired in.
    ///
    /// Each caller gets its own receiver so one connection's polling does
    /// not consume another's — `watch` marks per-receiver seen state.
    pub fn monitor_receiver(&self) -> Option<watch::Receiver<Option<SystemSnapshot>>> {
        self.monitor.lock().unwrap().clone()
    }

    /// Deterministically ensure a runner and expose it in the default
    /// workspace. The manager owns process/persistence; the host owns only
    /// workspace placement and client visibility.
    pub fn ensure_surface(
        self: &Arc<Self>,
        key: &str,
        spec: &SurfaceSpec,
    ) -> Result<EnsureOutcome, EnsureError> {
        let surface_id = surface_id_from_name(key);
        let lifecycle = self.surface_lifecycle_lock(&surface_id);
        let _lifecycle_guard = lifecycle
            .lock()
            .map_err(|_| EnsureError::Internal("host surface lifecycle lock poisoned"))?;
        let outcome = self.pty.ensure(key, spec)?;
        // An agent surface is ensured, attachable, and listed in
        // SurfaceList — but NEVER placed in a workspace tree. See
        // `with_workspaces` for why non-exposure is the contract. Skipping
        // the reverse index too keeps its invariant ("workspace whose tree
        // holds this surface"): `terminate_surface` then simply finds no
        // layout entry, which is the truth.
        if spec.kind != SurfaceKind::Pty {
            return Ok(outcome);
        }
        let workspace_id = self.default_id();
        let changed = {
            let mut workspaces = self.workspaces.lock().unwrap();
            workspaces
                .get_mut(&workspace_id)
                .is_some_and(|entry| entry.store.register_surface(outcome.surface_id.clone()))
        };
        self.surface_workspace
            .lock()
            .unwrap()
            .insert(outcome.surface_id.clone(), workspace_id.clone());
        if changed {
            self.schedule_layout_push(workspace_id);
        }
        Ok(outcome)
    }

    /// Remove an ensured runner from runtime, logical persistence, and the
    /// workspace roster. Repeating termination is a harmless no-op.
    pub fn terminate_surface(self: &Arc<Self>, surface_id: &[u8]) -> Result<bool, EnsureError> {
        let lifecycle = self.surface_lifecycle_lock(surface_id);
        let _lifecycle_guard = lifecycle
            .lock()
            .map_err(|_| EnsureError::Internal("host surface lifecycle lock poisoned"))?;
        self.terminate_surface_locked(surface_id)
    }

    fn terminate_surface_locked(self: &Arc<Self>, surface_id: &[u8]) -> Result<bool, EnsureError> {
        let workspace_id = self.workspace_id_for_surface(surface_id);
        // Durable PTY/logical-state deletion commits first. On failure the
        // manager restores the live process, so layout/index remain untouched.
        // TerminateSurface is the explicit destructive verb, not the
        // interactive ClosePane verb. It therefore applies to ordinary PTY
        // surfaces as well as ensured runners and may leave a named workspace
        // empty (the layout helper below deliberately allows that).
        let runtime_removed = self.pty.terminate(surface_id)?;
        let layout_removed = workspace_id.as_ref().is_some_and(|workspace_id| {
            self.with_store(workspace_id, |store| {
                store.remove_surface_allow_empty(surface_id)
            })
            .unwrap_or(false)
        });
        self.surface_workspace.lock().unwrap().remove(surface_id);
        if layout_removed {
            self.schedule_layout_push(workspace_id.expect("checked above"));
        }
        Ok(runtime_removed || layout_removed)
    }

    /// Best-effort save of the full workspace collection to
    /// `persist_path`, if one was set. Matches `persist::boot`'s policy
    /// of logging on failure rather than propagating it — an RPC that
    /// already mutated in-memory state must not roll back just because
    /// the disk write failed; the next successful mutation retries the
    /// same save.
    fn persist_workspaces(&self) {
        let path = self.persist_path.lock().unwrap().clone();
        let Some(path) = path else { return };
        let entries: Vec<PersistedWorkspace> = self
            .workspaces
            .lock()
            .unwrap()
            .values()
            .map(|e| PersistedWorkspace {
                id: e.id.clone(),
                name: e.name.clone(),
                is_default: e.is_default,
            })
            .collect();
        if let Err(e) = super::persist::save(&path, &entries) {
            tracing::warn!("peer-workspaces.json save failed ({}): {e}", path.display());
        }
    }

    /// Current default workspace id. Reads through the `Mutex` so callers
    /// never touch the field's lock discipline directly — see the field's
    /// doc comment for why it became a `Mutex` in M3.
    pub fn default_id(&self) -> Vec<u8> {
        self.workspace_id.lock().unwrap().clone()
    }

    /// Display title for the default workspace: its persisted (or
    /// renamed, or `TERMMESH_PEER_WORKSPACE_TITLE`-overridden) `name`.
    /// Falls back to `DAEMON_WORKSPACE` only in the should-never-happen
    /// case where the default entry is missing from the collection.
    pub fn default_workspace_title(&self) -> String {
        self.workspaces
            .lock()
            .unwrap()
            .get(&self.default_id())
            .map(|entry| entry.name.clone())
            .unwrap_or_else(|| DAEMON_WORKSPACE.to_string())
    }

    /// Delete a workspace, default or not: every surface currently in its
    /// tree is torn down exactly like `close_pane` tears down a single
    /// pane (dropped from `pty` — ephemeral specs are lost so a closed
    /// id can't respawn, declared specs keep theirs — and out of the
    /// reverse index), the now-empty collection entry is removed, and the
    /// remaining collection is persisted. Refuses (no removal, no side
    /// effects at all) only when `workspace_id` is empty, unknown, or
    /// names the LAST workspace left — un-namespaced control always needs
    /// a home to resolve to (`RemoveWorkspaceError::LastWorkspace`).
    ///
    /// If the removed entry WAS the default, the survivor with the
    /// lexicographically lowest id is deterministically promoted in its
    /// place (`is_default = true`, `default_id()` updated) — deterministic
    /// because `workspaces` is a `HashMap` with no stable iteration order.
    /// The promoted entry keeps its own tree untouched: the old default's
    /// surfaces (including any static `TERMMESH_PEER_SURFACES` shells) are
    /// simply gone, not re-parented — a restart brings declared surfaces
    /// back via env, matching how a self-exited ephemeral pane is handled
    /// elsewhere in this file.
    ///
    /// Every connected client is told about the deletion via a
    /// `WorkspaceRemoved` broadcast regardless of whether a promotion also
    /// happened; the wire has no separate "default changed" push (see
    /// `WorkspaceLayoutChanged`'s fields), so a client that cares about
    /// `is_default` re-derives it from its next `ListWorkspaces` roster.
    pub fn remove_workspace(&self, workspace_id: &[u8]) -> Result<(), RemoveWorkspaceError> {
        let _persistence_guard = self.workspace_persistence.lock().unwrap();
        if workspace_id.is_empty() {
            return Err(RemoveWorkspaceError::NotFound);
        }
        let (removed_surfaces, promoted) = {
            let mut workspaces = self.workspaces.lock().unwrap();
            if !workspaces.contains_key(workspace_id) {
                return Err(RemoveWorkspaceError::NotFound);
            }
            if workspaces.len() == 1 {
                return Err(RemoveWorkspaceError::LastWorkspace);
            }
            let entry = workspaces
                .remove(workspace_id)
                .expect("checked present above");
            let removed_surfaces = entry.store.surface_ids();
            let promoted = if entry.is_default {
                // Deterministic pick among survivors: lowest workspace id.
                let new_default_id = workspaces
                    .keys()
                    .min()
                    .cloned()
                    .expect("collection has >1 entry before removal, so a survivor remains");
                if let Some(new_default) = workspaces.get_mut(&new_default_id) {
                    new_default.is_default = true;
                }
                *self.workspace_id.lock().unwrap() = new_default_id.clone();
                Some(new_default_id)
            } else {
                None
            };
            (removed_surfaces, promoted)
        };
        {
            let mut index = self.surface_workspace.lock().unwrap();
            for sid in &removed_surfaces {
                self.pty.remove(sid);
                index.remove(sid);
            }
        }
        self.persist_workspaces();
        // Audit line: a workspace delete kills real host processes, so
        // make the surface count (and any default promotion) visible in
        // the journal for monitoring
        // (journalctl --user -u term-meshd | grep 'peer workspace').
        match &promoted {
            Some(new_default_id) => tracing::info!(
                "peer workspace removed: id={} surfaces_killed={} promoted_default={}",
                hex_prefix(workspace_id),
                removed_surfaces.len(),
                hex_prefix(new_default_id)
            ),
            None => tracing::info!(
                "peer workspace removed: id={} surfaces_killed={}",
                hex_prefix(workspace_id),
                removed_surfaces.len()
            ),
        }
        self.clients
            .broadcast(&Payload::WorkspaceUpdate(WorkspaceUpdate {
                kind: Some(workspace_update::Kind::WorkspaceRemoved(WorkspaceRemoved {
                    workspace_id: workspace_id.to_vec(),
                })),
            }));
        self.broadcast_workspace_roster();
        Ok(())
    }

    /// Create a new, initially pane-less workspace with a random 16-byte
    /// id and persist it immediately. `title` is used verbatim (an empty
    /// title is accepted as-is, matching `RenameWorkspaceRequest`'s
    /// contract of never second-guessing the caller). Schedules a
    /// (debounced, empty-layout) `WorkspaceLayoutChanged` push under the
    /// new id so already-connected bystanders learn a new workspace_id
    /// exists — the "roster 반영 push" this RPC's contract calls for.
    /// Seed a first pane into every workspace that boots empty. A
    /// non-default workspace restored from `peer-workspaces.json` has
    /// only {id, name} persisted (shells are daemon children, never
    /// serialized), so it comes back with an empty tree — un-attachable,
    /// which surfaced as "no panes" when a client opened it. Called once
    /// after boot so every workspace is usable, exactly like a freshly
    /// created one. The default keeps its static TERMMESH_PEER_SURFACES
    /// shells and is skipped when already populated.
    pub fn seed_empty_workspaces(self: &Arc<Self>) {
        let empty_ids: Vec<Vec<u8>> = {
            let workspaces = self.workspaces.lock().unwrap();
            workspaces
                .values()
                .filter(|e| e.store.is_empty())
                .map(|e| e.id.clone())
                .collect()
        };
        for id in empty_ids {
            if let Some(sid) = self.spawn_ephemeral(&[], &id) {
                self.with_store(&id, |store| store.seed_first_pane(sid));
            }
        }
    }

    pub fn create_workspace(self: &Arc<Self>, title: String) -> Vec<u8> {
        let _persistence_guard = self.workspace_persistence.lock().unwrap();
        let id = super::connection::random_peer_bytes(16);
        {
            let mut workspaces = self.workspaces.lock().unwrap();
            workspaces.insert(
                id.clone(),
                WorkspaceEntry {
                    id: id.clone(),
                    name: title,
                    is_default: false,
                    store: LayoutStore {
                        root: None,
                        next_split_id: 1,
                    },
                },
            );
        }
        self.persist_workspaces();
        // Seed the first pane so a freshly created workspace is usable
        // immediately — an empty tree is un-attachable, which raced the
        // client's open ("no panes"). Best-effort: on spawn failure the
        // workspace stays empty and the client's open-time seed retries.
        // Gated by the same MAX_PEER_SURFACES cap as split/new_tab: without
        // this check, CreateWorkspaceRequest was an uncapped PTY spawn —
        // looping it bypassed the cap entirely. At-cap, the workspace is
        // still created (empty); `new_tab`'s open-time seed fallback also
        // checks the cap, so it won't silently backfill one either.
        if self.pty.list().len() >= Self::MAX_PEER_SURFACES {
            tracing::info!(
                "peer workspace created empty: id={} reason=max_peer_surfaces cap={}",
                hex_prefix(&id),
                Self::MAX_PEER_SURFACES
            );
        } else if let Some(sid) = self.spawn_ephemeral(&[], &id) {
            self.with_store(&id, |store| store.seed_first_pane(sid));
        }
        tracing::info!(
            "peer workspace created: id={} total={}",
            hex_prefix(&id),
            self.workspaces.lock().unwrap().len()
        );
        self.schedule_layout_push(id.clone());
        id
    }

    /// Rename an existing workspace's display name in place; its id
    /// never changes. Returns `false` (no-op, nothing persisted) for an
    /// empty or unknown `workspace_id` — connection.rs logs the warning,
    /// this method itself stays silent so it composes cleanly with any
    /// future non-RPC caller.
    pub fn rename_workspace(&self, workspace_id: &[u8], title: String) -> bool {
        let _persistence_guard = self.workspace_persistence.lock().unwrap();
        if workspace_id.is_empty() {
            return false;
        }
        let renamed = {
            let mut workspaces = self.workspaces.lock().unwrap();
            match workspaces.get_mut(workspace_id) {
                Some(entry) => {
                    entry.name = title;
                    true
                }
                None => false,
            }
        };
        if renamed {
            self.persist_workspaces();
            self.broadcast_workspace_roster();
        }
        renamed
    }

    /// Every workspace this host currently serves, as roster entries
    /// ready for `WorkspaceList` — the N-workspace successor to the
    /// single hardcoded entry `ListWorkspaces` used to build before M2.
    /// Sorted by title for a stable, deterministic wire order (`HashMap`
    /// iteration itself is not).
    pub fn list_workspaces(&self) -> Vec<WorkspaceRosterEntry> {
        let default_id = self.default_id();
        let ids: Vec<Vec<u8>> = self.workspaces.lock().unwrap().keys().cloned().collect();
        let mut out: Vec<WorkspaceRosterEntry> = ids
            .into_iter()
            .map(|id| {
                // The default entry goes through `default_workspace_title`
                // for its should-never-happen fallback; every other entry
                // is a plain read of its own persisted name.
                let title = if id == default_id {
                    self.default_workspace_title()
                } else {
                    self.workspaces
                        .lock()
                        .unwrap()
                        .get(&id)
                        .map(|entry| entry.name.clone())
                        .unwrap_or_default()
                };
                let layout = self.layout_snapshot_for(&id);
                let is_default = id == default_id;
                WorkspaceRosterEntry {
                    id,
                    title,
                    layout,
                    is_default,
                }
            })
            .collect();
        out.sort_by(|a, b| a.title.cmp(&b.title));
        out
    }

    /// Workspace id currently hosting `surface_id`, if any.
    fn workspace_id_for_surface(&self, surface_id: &[u8]) -> Option<Vec<u8>> {
        self.surface_workspace
            .lock()
            .unwrap()
            .get(surface_id)
            .cloned()
    }

    /// Run `f` against the named workspace's store, if that workspace
    /// still exists. `None` means the workspace vanished between lookup
    /// and this call (never happens today — workspaces are never removed
    /// — but callers treat it the same as "target not found").
    fn with_store<T>(
        &self,
        workspace_id: &[u8],
        f: impl FnOnce(&mut LayoutStore) -> T,
    ) -> Option<T> {
        let mut workspaces = self.workspaces.lock().unwrap();
        workspaces
            .get_mut(workspace_id)
            .map(|entry| f(&mut entry.store))
    }

    /// Apply one WorkspaceControl command. Fire-and-forget end to end:
    /// nothing is ever sent back to the requester specifically — a
    /// mutation that changed the tree schedules a push to everyone, and
    /// anything invalid (unknown ids, bad orientation, last-pane close,
    /// F1–F8 adversarial shapes) drops silently, exactly like the Swift
    /// host's `perform*` guards.
    pub fn apply_control(self: &Arc<Self>, ctl: WorkspaceControl) {
        use workspace_control::Kind;
        // `Some(ws_id)` means the tree of workspace `ws_id` changed and
        // must be pushed; `None` covers both "nothing changed" and
        // "invalid/unresolvable request" — both are silent no-ops.
        let changed_workspace = match ctl.kind {
            // F8: a kind this build predates. Ignore, don't disconnect.
            None => None,
            // R10: the daemon has no keyboard focus to move, and the Swift
            // host deliberately no-ops this too.
            Some(Kind::FocusPane(_)) => None,
            Some(Kind::SplitPane(req)) => self.split_pane(&req.pane_id, &req.orientation),
            Some(Kind::ClosePane(req)) => self.close_pane(&req.pane_id),
            Some(Kind::SetDivider(req)) => {
                self.set_divider(&req.workspace_id, &req.split_id, req.ratio)
            }
            Some(Kind::NewTab(req)) => self.new_tab(&req.pane_id, &req.workspace_id),
            Some(Kind::ActivateTab(req)) => self.activate_tab(&req.pane_id, &req.surface_id),
        };
        if let Some(ws_id) = changed_workspace {
            self.schedule_layout_push(ws_id);
        }
    }

    /// Ceiling on total registered `PtyManager` surfaces (declared +
    /// ephemeral) a `SplitPane`/`NewTab` may push past. `HandshakeState::Ready`
    /// requires only the ssh-passthrough handshake — the entire trust model
    /// documented for a daemon host — so without this, any peer that can
    /// open the socket could loop split requests to exhaust the daemon
    /// uid's PIDs/fds/PTYs. Counting `self.pty.list()` rather than the
    /// layout tree matters: it is only a faithful, un-inflatable count
    /// because closing an ephemeral surface now also drops its spec (see
    /// `PtyManager::remove`) — before that fix, a closed-then-directly-
    /// reattached surface would respawn outside the tree and bypass a
    /// tree-based cap entirely.
    const MAX_PEER_SURFACES: usize = 64;

    /// Returns the workspace id whose tree changed, or `None` for any
    /// invalid/unresolvable/no-op request (F4 garbage orientation, unknown
    /// pane, or the source pane's workspace vanishing between probe and
    /// insert).
    fn split_pane(self: &Arc<Self>, pane_id: &[u8], orientation: &str) -> Option<Vec<u8>> {
        let orientation = Orientation::parse(orientation)?; // F4
        if self.pty.list().len() >= Self::MAX_PEER_SURFACES {
            return None;
        }
        // Cheap existence probe before paying for a fork. The tree can
        // still change before the insert below — that race is resolved by
        // rolling the spawn back.
        let ws_id = self.workspace_id_for_surface(pane_id)?;
        if !self
            .with_store(&ws_id, |store| {
                store.surface_ids().iter().any(|s| s == pane_id)
            })
            .unwrap_or(false)
        {
            return None;
        }
        // A dead source pane revives first, same as attach would do — the
        // user is clearly working in it. No-op when it is alive.
        self.pty.get_or_respawn(pane_id);
        let new_id = self.spawn_ephemeral(pane_id, &ws_id)?;
        match self.with_store(&ws_id, |store| {
            store.split_pane(pane_id, orientation, new_id.clone())
        }) {
            Some(Ok(true)) => Some(ws_id),
            Some(Ok(false)) => None,
            _ => {
                // Source pane (or its workspace) vanished between probe and
                // insert; don't leak the shell we spawned for it.
                self.pty.remove(&new_id);
                self.surface_workspace.lock().unwrap().remove(&new_id);
                None
            }
        }
    }

    /// `pane_id` resolving to an existing pane always wins (matches every
    /// other `WorkspaceControl` kind); `workspace_id` is only consulted as
    /// the "first pane of an empty workspace" fallback the proto
    /// documents for right after `CreateWorkspaceRequest`, when there is
    /// no pane_id to reference yet. Returns the workspace id whose tree
    /// changed, or `None` for a no-op/invalid request.
    fn new_tab(self: &Arc<Self>, pane_id: &[u8], workspace_id: &[u8]) -> Option<Vec<u8>> {
        if self.pty.list().len() >= Self::MAX_PEER_SURFACES {
            return None;
        }
        if let Some(ws_id) = self.workspace_id_for_surface(pane_id) {
            if self
                .with_store(&ws_id, |store| {
                    store.surface_ids().iter().any(|s| s == pane_id)
                })
                .unwrap_or(false)
            {
                self.pty.get_or_respawn(pane_id);
                let new_id = self.spawn_ephemeral(pane_id, &ws_id)?;
                return match self.with_store(&ws_id, |store| store.add_tab(pane_id, new_id.clone()))
                {
                    Some(Ok(true)) => Some(ws_id),
                    _ => {
                        self.pty.remove(&new_id);
                        self.surface_workspace.lock().unwrap().remove(&new_id);
                        None
                    }
                };
            }
        }

        if workspace_id.is_empty() {
            return None;
        }
        let is_empty_target = self
            .workspaces
            .lock()
            .unwrap()
            .get(workspace_id)
            .map(|entry| entry.store.is_empty())
            .unwrap_or(false);
        if !is_empty_target {
            return None;
        }
        let new_id = self.spawn_ephemeral(&[], workspace_id)?;
        match self.with_store(workspace_id, |store| store.seed_first_pane(new_id.clone())) {
            Some(true) => Some(workspace_id.to_vec()),
            _ => {
                self.pty.remove(&new_id);
                self.surface_workspace.lock().unwrap().remove(&new_id);
                None
            }
        }
    }

    fn close_pane(self: &Arc<Self>, pane_id: &[u8]) -> Option<Vec<u8>> {
        let ws_id = self.workspace_id_for_surface(pane_id)?;
        let removed = match self.with_store(&ws_id, |store| store.close_pane(pane_id)) {
            Some(Ok(removed)) => removed,
            // LastPane / NotFound / workspace already gone: silent no-op —
            // the client observes "nothing happened", same as the Swift host.
            _ => return None,
        };
        // PTYs die outside the layout lock. `PtyManager::remove` decides
        // spec fate: declared surfaces keep theirs (a restart brings them
        // back via TERMMESH_PEER_SURFACES anyway), ephemeral ones lose
        // theirs so a closed split/new-tab pane cannot respawn via a raw
        // AttachSurface for the same id.
        let mut index = self.surface_workspace.lock().unwrap();
        for sid in removed {
            self.pty.remove(&sid);
            index.remove(&sid);
        }
        drop(index);
        Some(ws_id)
    }

    /// `split_id` is unique only WITHIN one workspace's tree (each
    /// `LayoutStore` keeps its own counter) — two workspaces routinely
    /// share a split_id. `SetDividerPositionRequest.workspace_id` (proto
    /// field 3) disambiguates: when non-empty and it names a workspace
    /// this host currently serves, the resize is scoped to THAT
    /// workspace's store only — a hit or miss there never spills into any
    /// other tree. Empty `workspace_id` means a legacy client (pre field-3)
    /// or a caller that genuinely doesn't know it; degrade to the old
    /// behavior of matching whichever tree's split id hits first, which
    /// stays correct as long as there is exactly one workspace (the
    /// pre-M2 case this fallback exists for).
    fn set_divider(&self, workspace_id: &[u8], split_id: &[u8], ratio: f64) -> Option<Vec<u8>> {
        let mut workspaces = self.workspaces.lock().unwrap();
        if !workspace_id.is_empty() {
            return match workspaces.get_mut(workspace_id) {
                Some(entry) => match entry.store.set_divider(split_id, ratio) {
                    Ok(true) => Some(entry.id.clone()),
                    Ok(false) | Err(_) => None,
                },
                None => None,
            };
        }
        for entry in workspaces.values_mut() {
            match entry.store.set_divider(split_id, ratio) {
                Ok(true) => return Some(entry.id.clone()),
                Ok(false) => return None,
                Err(_) => continue,
            }
        }
        None
    }

    fn activate_tab(&self, pane_id: &[u8], surface_id: &[u8]) -> Option<Vec<u8>> {
        let ws_id = self.workspace_id_for_surface(pane_id)?;
        let changed = self
            .with_store(&ws_id, |store| store.activate_tab(pane_id, surface_id))
            .and_then(|r| r.ok())
            .unwrap_or(false);
        changed.then_some(ws_id)
    }

    /// Fork a login shell for a split/new-tab pane, inheriting the source
    /// pane's cwd. Registered *ephemeral* — the pane revives on attach
    /// while it's still dead-but-present in the tree (same as declared
    /// surfaces), but the respawn spec is dropped the moment it's
    /// actually removed (explicit close, or the dead-watcher below), so
    /// closing it is permanent for this daemon lifetime and a raw
    /// `AttachSurface` for the same id can't resurrect it.
    fn spawn_ephemeral(
        self: &Arc<Self>,
        source_pane: &[u8],
        workspace_id: &[u8],
    ) -> Option<SurfaceId> {
        let cwd = self
            .pty
            .list()
            .into_iter()
            .find(|s| s.surface_id == source_pane)
            .map(|s| s.cwd.clone())
            .filter(|c| !c.is_empty());
        let n = self.ephemeral_counter.fetch_add(1, Ordering::Relaxed);
        // `\0`-prefixed: surface_id_from_name is a deterministic hash, and
        // a plain "split-{n}" could collide with an operator's own
        // TERMMESH_PEER_SURFACES entry of the same name (register_and_spawn
        // would then overwrite that declared surface's live PTY). An
        // environment variable's value cannot contain an embedded NUL on
        // any POSIX system, so parse_surfaces_env can never hand back a
        // name that produces this prefix -- the collision is structurally
        // impossible, not just unlikely.
        let surface_id = surface_id_from_name(&format!("\0split-{n}"));
        let spec = SpawnSpec {
            title: format!("shell {n}"),
            command: "/bin/sh".into(),
            args: vec!["-c".into(), super::surface::login_shell_cmd()],
            cols: 80,
            rows: 24,
            cwd,
            kind: super::surface::SurfaceKind::Pty,
            agent_cli: String::new(),
        };
        self.pty
            .register_and_spawn_ephemeral(surface_id.clone(), spec);
        // register_and_spawn_ephemeral logs-and-continues on failure; only
        // report a surface that actually exists.
        let surface = self
            .pty
            .list()
            .into_iter()
            .find(|s| s.surface_id == surface_id)?;
        self.surface_workspace
            .lock()
            .unwrap()
            .insert(surface_id.clone(), workspace_id.to_vec());
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
            // Route the removal to whichever workspace's tree currently
            // holds this surface (the reverse index), not always the
            // default — a dead ephemeral pane can belong to any workspace.
            let Some(ws_id) = host.workspace_id_for_surface(&sid) else {
                return;
            };
            let removed = host
                .with_store(&ws_id, |store| store.remove_surface(&sid))
                .unwrap_or(false);
            if removed {
                // Out of the tree → out of the roster (it is already dead;
                // remove only drops the map entry and re-signals a corpse)
                // and out of the reverse index.
                host.pty.remove(&sid);
                host.surface_workspace.lock().unwrap().remove(&sid);
                host.schedule_layout_push(ws_id);
            }
        });
    }

    /// Debounced fan-out of `workspace_id`'s current tree to every
    /// connection. The snapshot is taken when the timer fires, so a burst
    /// of mutations against the SAME workspace yields one push carrying
    /// the final state. Per-workspace debounce (`pending_pushes`) means a
    /// concurrent burst against a DIFFERENT workspace schedules and fires
    /// its own push independently instead of being swallowed by this one.
    pub fn schedule_layout_push(self: &Arc<Self>, workspace_id: Vec<u8>) {
        {
            let mut pending = self.pending_pushes.lock().unwrap();
            if !pending.insert(workspace_id.clone()) {
                return;
            }
        }
        let host = Arc::clone(self);
        tokio::spawn(async move {
            tokio::time::sleep(PUSH_DEBOUNCE).await;
            host.pending_pushes.lock().unwrap().remove(&workspace_id);
            let layout = host.layout_snapshot_for(&workspace_id);
            let payload = Payload::WorkspaceUpdate(WorkspaceUpdate {
                kind: Some(workspace_update::Kind::WorkspaceLayout(
                    WorkspaceLayoutChanged {
                        workspace_id: workspace_id.clone(),
                        layout,
                    },
                )),
            });
            host.clients.broadcast(&payload);
            // A roster subscriber needs layout-derived pane metadata too;
            // publish the complete post-debounce roster alongside the focused
            // layout delta so it converges after reconnect or missed frames.
            host.broadcast_workspace_roster();
        });
    }

    /// Complete workspace roster for `SubscribeWorkspaceList` snapshots and
    /// change pushes. Reusing `list_workspaces` guarantees the same IDs,
    /// titles, default flag and layouts as the synchronous discovery RPC.
    pub fn workspace_roster(&self) -> Vec<Workspace> {
        self.list_workspaces()
            .into_iter()
            .map(|entry| Workspace {
                workspace_id: entry.id,
                title: entry.title,
                layout: entry.layout,
                window_id: Vec::new(),
                window_title: String::new(),
                is_default: entry.is_default,
            })
            .collect()
    }

    pub fn broadcast_workspace_roster(&self) {
        // `workspace_roster` rebuilds a layout snapshot for EVERY workspace,
        // each a recursive walk of its pane tree. With nobody subscribed that
        // is pure waste, and this runs on every debounced layout push — which
        // fires throughout a divider drag.
        if !self.clients.has_roster_subscriber() {
            return;
        }
        self.clients
            .broadcast_to_roster_subscribers(&Payload::WorkspaceListChanged(
                WorkspaceListChanged {
                    workspaces: self.workspace_roster(),
                },
            ));
    }

    /// Wire snapshot of any single workspace's tree by id — the generic
    /// counterpart to `layout_snapshot` (default-workspace-only, and the
    /// only one that carries the reseed special case below). Scoped
    /// `WorkspaceLayoutChanged` pushes (`schedule_layout_push`) and
    /// `list_workspaces` both go through this so a mutation to — or a
    /// listing of — a non-default workspace is reported under ITS id
    /// instead of being misattributed to the default workspace.
    pub fn layout_snapshot_for(&self, workspace_id: &[u8]) -> Option<WorkspaceLayout> {
        if workspace_id == self.default_id() {
            return self.layout_snapshot();
        }
        self.workspaces
            .lock()
            .unwrap()
            .get(workspace_id)
            .and_then(|entry| entry.store.snapshot_proto(&self.pty))
    }

    /// Wire snapshot of the default workspace's tree. Reseeds first when
    /// that tree is empty but surfaces exist — covers hosts whose manager
    /// was populated after construction (the test harness does this;
    /// production spawns surfaces before `PeerHost::new`).
    pub fn layout_snapshot(&self) -> Option<WorkspaceLayout> {
        // Captured once: a concurrent `remove_workspace` promotion could
        // otherwise change the default mid-function, splitting the reseed
        // check from the final read across two different workspaces.
        let default_id = self.default_id();
        let needs_reseed = self
            .workspaces
            .lock()
            .unwrap()
            .get(&default_id)
            .map(|entry| entry.store.is_empty())
            .unwrap_or(false);
        if needs_reseed {
            // Reseed from PTY surfaces only — an empty default tree must
            // not sweep an agent surface in through the back door (same
            // contract as `ensure_surface`/`with_workspaces`).
            let surfaces: Vec<Arc<PtySurface>> = self
                .pty
                .list()
                .into_iter()
                .filter(|s| s.kind() == SurfaceKind::Pty)
                .collect();
            if !surfaces.is_empty() {
                {
                    let mut workspaces = self.workspaces.lock().unwrap();
                    if let Some(entry) = workspaces.get_mut(&default_id) {
                        if entry.store.is_empty() {
                            entry.store = LayoutStore::balanced_from_surfaces(&surfaces);
                        }
                    }
                }
                let mut index = self.surface_workspace.lock().unwrap();
                for surface in &surfaces {
                    index
                        .entry(surface.surface_id.clone())
                        .or_insert_with(|| default_id.clone());
                }
            }
        }
        self.workspaces
            .lock()
            .unwrap()
            .get(&default_id)
            .and_then(|entry| entry.store.snapshot_proto(&self.pty))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::peer::surface::surface_id_from_name;

    fn sid(name: &str) -> SurfaceId {
        surface_id_from_name(name)
    }

    #[tokio::test]
    async fn leader_reverse_route_fans_out_and_first_exact_response_wins() {
        let router = Arc::new(Broadcaster::new());
        let (older_tx, mut older_rx) = mpsc::channel(4);
        let (newest_tx, mut newest_rx) = mpsc::channel(4);
        let (attacker_tx, mut attacker_rx) = mpsc::channel(4);
        let older = router.register(older_tx, Arc::new(AtomicU64::new(10)), vec![0xA1; 16]);
        let newest = router.register(newest_tx, Arc::new(AtomicU64::new(20)), vec![0xA1; 16]);
        let attacker = router.register(attacker_tx, Arc::new(AtomicU64::new(20)), vec![0xB1; 16]);
        let request = TeamLeaderCommandRequest {
            request_id: vec![0x41; peer_proto::team_leader::REQUEST_ID_BYTES],
            method: "team.delegate".into(),
            params_json: r#"{"submit_return":true}"#.into(),
            ..Default::default()
        };

        let pending_router = Arc::clone(&router);
        let pending_request = request.clone();
        let call = tokio::spawn(async move {
            pending_router
                .call_team_leader(pending_request, &[0xA1; 16])
                .await
        });

        let older_envelope = older_rx.recv().await.expect("older connection request");
        let newest_envelope = newest_rx.recv().await.expect("newest connection request");
        assert!(
            attacker_rx.try_recv().is_err(),
            "non-target peer must not receive the scoped grant"
        );
        let response = TeamLeaderCommandResponse {
            request_id: request.request_id,
            ok: true,
            result_json: r#"{"return_submitted":true}"#.into(),
            ..Default::default()
        };

        assert!(
            !router.resolve_team_leader(
                attacker.connection_id(),
                older_envelope.seq,
                response.clone()
            ),
            "another connection cannot win the response race"
        );
        assert!(
            !router.resolve_team_leader(
                older.connection_id(),
                older_envelope.seq + 1,
                response.clone()
            ),
            "the target must echo the exact request correlation"
        );
        assert!(router.resolve_team_leader(
            older.connection_id(),
            older_envelope.seq,
            response.clone()
        ));
        assert!(
            !router.resolve_team_leader(
                newest.connection_id(),
                newest_envelope.seq,
                response.clone()
            ),
            "a later response from another fanned-out route is stale"
        );
        assert!(
            !router.resolve_team_leader(older.connection_id(), older_envelope.seq, response),
            "a duplicate response cannot complete the request again"
        );
        assert!(call.await.unwrap().unwrap().ok);
    }

    #[tokio::test]
    async fn leader_reverse_route_survives_one_connection_drop() {
        let router = Arc::new(Broadcaster::new());
        let peer_id = vec![0xA1; 16];
        let (first_tx, mut first_rx) = mpsc::channel(4);
        let (second_tx, mut second_rx) = mpsc::channel(4);
        let first = router.register(first_tx, Arc::new(AtomicU64::new(10)), peer_id.clone());
        let second = router.register(second_tx, Arc::new(AtomicU64::new(20)), peer_id.clone());
        let request = TeamLeaderCommandRequest {
            request_id: vec![0x46; peer_proto::team_leader::REQUEST_ID_BYTES],
            method: "team.status".into(),
            params_json: "{}".into(),
            ..Default::default()
        };

        let pending_router = Arc::clone(&router);
        let pending_request = request.clone();
        let call = tokio::spawn(async move {
            pending_router
                .call_team_leader(pending_request, &[0xA1; 16])
                .await
        });
        let first_envelope = first_rx.recv().await.expect("first route");
        let second_envelope = second_rx.recv().await.expect("second route");
        let second_connection_id = second.connection_id();
        drop(second);

        let response = TeamLeaderCommandResponse {
            request_id: request.request_id,
            ok: true,
            result_json: "{}".into(),
            ..Default::default()
        };
        assert!(
            !router.resolve_team_leader(
                second_connection_id,
                second_envelope.seq,
                response.clone()
            ),
            "a disconnected route cannot answer while another route remains"
        );
        assert!(router.resolve_team_leader(first.connection_id(), first_envelope.seq, response));
        assert!(call.await.unwrap().unwrap().ok);
    }

    #[tokio::test]
    async fn leader_reverse_route_fails_immediately_when_all_connections_drop() {
        let router = Arc::new(Broadcaster::new());
        let peer_id = vec![0xA1; 16];
        let (first_tx, mut first_rx) = mpsc::channel(4);
        let (second_tx, mut second_rx) = mpsc::channel(4);
        let first = router.register(first_tx, Arc::new(AtomicU64::new(10)), peer_id.clone());
        let second = router.register(second_tx, Arc::new(AtomicU64::new(20)), peer_id.clone());
        let request = TeamLeaderCommandRequest {
            request_id: vec![0x47; peer_proto::team_leader::REQUEST_ID_BYTES],
            method: "team.status".into(),
            params_json: "{}".into(),
            ..Default::default()
        };

        let pending_router = Arc::clone(&router);
        let call =
            tokio::spawn(
                async move { pending_router.call_team_leader(request, &[0xA1; 16]).await },
            );
        first_rx.recv().await.expect("first route");
        second_rx.recv().await.expect("second route");
        drop(first);
        assert!(
            !call.is_finished(),
            "one live route must keep the call pending"
        );
        drop(second);

        let result = tokio::time::timeout(Duration::from_secs(1), call)
            .await
            .expect("all-route disconnect should not wait for command timeout")
            .unwrap();
        assert_eq!(result.unwrap_err(), "authorized peer viewer is unavailable");
    }

    #[tokio::test]
    async fn leader_reverse_route_ignores_backpressured_connection() {
        let router = Arc::new(Broadcaster::new());
        let peer_id = vec![0xA1; 16];
        let (blocked_tx, _blocked_rx) = mpsc::channel(1);
        blocked_tx
            .try_send(Envelope::default())
            .expect("fill blocked connection channel");
        let _blocked = router.register(blocked_tx, Arc::new(AtomicU64::new(10)), peer_id.clone());
        let (healthy_tx, mut healthy_rx) = mpsc::channel(4);
        let healthy = router.register(healthy_tx, Arc::new(AtomicU64::new(20)), peer_id.clone());
        let request = TeamLeaderCommandRequest {
            request_id: vec![0x48; peer_proto::team_leader::REQUEST_ID_BYTES],
            method: "team.status".into(),
            params_json: "{}".into(),
            ..Default::default()
        };

        let pending_router = Arc::clone(&router);
        let pending_request = request.clone();
        let call = tokio::spawn(async move {
            pending_router
                .call_team_leader(pending_request, &[0xA1; 16])
                .await
        });
        let envelope = healthy_rx.recv().await.expect("healthy route request");
        let response = TeamLeaderCommandResponse {
            request_id: request.request_id,
            ok: true,
            result_json: "{}".into(),
            ..Default::default()
        };
        assert!(router.resolve_team_leader(healthy.connection_id(), envelope.seq, response));
        assert!(call.await.unwrap().unwrap().ok);
    }

    #[tokio::test]
    async fn duplicate_leader_request_joins_the_inflight_result() {
        let router = Arc::new(Broadcaster::new());
        let (viewer_tx, mut viewer_rx) = mpsc::channel(4);
        let viewer = router.register(viewer_tx, Arc::new(AtomicU64::new(10)), vec![0xA1; 16]);
        let request = TeamLeaderCommandRequest {
            request_id: vec![0x44; peer_proto::team_leader::REQUEST_ID_BYTES],
            method: "team.delegate".into(),
            params_json: r#"{"submit_return":true}"#.into(),
            ..Default::default()
        };

        let first_router = Arc::clone(&router);
        let first_request = request.clone();
        let first = tokio::spawn(async move {
            first_router
                .call_team_leader(first_request, &[0xA1; 16])
                .await
        });
        let envelope = viewer_rx.recv().await.expect("one viewer request");

        let retry_router = Arc::clone(&router);
        let retry_request = request.clone();
        let retry = tokio::spawn(async move {
            retry_router
                .call_team_leader(retry_request, &[0xA1; 16])
                .await
        });
        tokio::task::yield_now().await;
        assert!(
            viewer_rx.try_recv().is_err(),
            "retry must not execute twice"
        );

        let response = TeamLeaderCommandResponse {
            request_id: request.request_id,
            ok: true,
            result_json: r#"{"return_submitted":true}"#.into(),
            ..Default::default()
        };
        assert!(router.resolve_team_leader(viewer.connection_id(), envelope.seq, response,));
        assert!(first.await.unwrap().unwrap().ok);
        assert!(retry.await.unwrap().unwrap().ok);
    }

    #[tokio::test]
    async fn duplicate_request_id_rejects_a_different_command() {
        let router = Arc::new(Broadcaster::new());
        let (viewer_tx, mut viewer_rx) = mpsc::channel(4);
        let _viewer = router.register(
            viewer_tx,
            Arc::new(AtomicU64::new(10)),
            vec![0xA1; 16],
        );
        let request = TeamLeaderCommandRequest {
            request_id: vec![0x45; peer_proto::team_leader::REQUEST_ID_BYTES],
            method: "team.status".into(),
            params_json: "{}".into(),
            ..Default::default()
        };
        let first_router = Arc::clone(&router);
        let first_request = request.clone();
        let first = tokio::spawn(async move {
            first_router.call_team_leader(first_request, &[0xA1; 16]).await
        });
        viewer_rx.recv().await.expect("first request");

        let mut conflicting = request;
        conflicting.method = "team.delegate".into();
        let error = router
            .call_team_leader(conflicting, &[0xA1; 16])
            .await
            .expect_err("different command must not join");
        assert_eq!(error, "request_id conflicts with an in-flight request");
        first.abort();
    }

    #[tokio::test]
    async fn dropping_leader_connection_releases_request_id_for_retry() {
        let router = Arc::new(Broadcaster::new());
        let peer_id = vec![0xA1; 16];
        let request = TeamLeaderCommandRequest {
            request_id: vec![0x42; peer_proto::team_leader::REQUEST_ID_BYTES],
            method: "team.read".into(),
            params_json: "{}".into(),
            ..Default::default()
        };

        let (first_tx, mut first_rx) = mpsc::channel(4);
        let first_guard = router.register(first_tx, Arc::new(AtomicU64::new(10)), peer_id.clone());
        let first_router = Arc::clone(&router);
        let first_request = request.clone();
        let first_call =
            tokio::spawn(
                async move { first_router.call_team_leader(first_request, &peer_id).await },
            );
        first_rx.recv().await.expect("first targeted request");
        let joined_router = Arc::clone(&router);
        let joined_request = request.clone();
        let joined_call = tokio::spawn(async move {
            joined_router
                .call_team_leader(joined_request, &[0xA1; 16])
                .await
        });
        tokio::task::yield_now().await;
        assert!(first_rx.try_recv().is_err(), "joined call must not resend");
        drop(first_guard);
        assert_eq!(
            first_call.await.unwrap().unwrap_err(),
            "authorized peer viewer is unavailable"
        );
        assert_eq!(
            joined_call.await.unwrap().unwrap_err(),
            "authorized peer viewer is unavailable"
        );

        let retry_peer_id = vec![0xA1; 16];
        let (retry_tx, mut retry_rx) = mpsc::channel(4);
        let retry_guard = router.register(
            retry_tx,
            Arc::new(AtomicU64::new(20)),
            retry_peer_id.clone(),
        );
        let retry_router = Arc::clone(&router);
        let retry_request = request.clone();
        let retry = tokio::spawn(async move {
            retry_router
                .call_team_leader(retry_request, &retry_peer_id)
                .await
        });
        let envelope = retry_rx.recv().await.expect("retried request");
        let response = TeamLeaderCommandResponse {
            request_id: request.request_id,
            ok: true,
            result_json: "{}".into(),
            ..Default::default()
        };
        assert!(router.resolve_team_leader(retry_guard.connection_id(), envelope.seq, response,));
        assert!(retry.await.unwrap().unwrap().ok);
    }

    #[test]
    fn stale_cleanup_cannot_remove_new_retry_with_same_request_id() {
        use std::sync::Barrier;
        use std::thread;

        let router = Arc::new(Broadcaster::new());
        let request_id = vec![0x43; peer_proto::team_leader::REQUEST_ID_BYTES];
        let (old_tx, _old_rx) = oneshot::channel();
        router.leader_pending.lock().unwrap().insert(
            request_id.clone(),
            PendingLeaderResponse {
                generation: 1,
                routes: vec![PendingLeaderRoute {
                    connection_id: 10,
                    correlation_id: 11,
                }],
                target_peer_id: vec![0xA1; 16],
                request: TeamLeaderCommandRequest {
                    request_id: request_id.clone(),
                    ..Default::default()
                },
                senders: vec![old_tx],
            },
        );
        router.leader_pending.lock().unwrap().remove(&request_id);

        // Model the exact failing order: the disconnected call has already
        // lost its route, but its later error/timeout cleanup is paused while
        // a retry registers the same request_id on a replacement connection.
        let retry_registered = Arc::new(Barrier::new(2));
        let allow_stale_cleanup = Arc::new(Barrier::new(2));
        let cleanup_router = Arc::clone(&router);
        let cleanup_request_id = request_id.clone();
        let cleanup_retry_registered = Arc::clone(&retry_registered);
        let cleanup_allowed = Arc::clone(&allow_stale_cleanup);
        let stale_cleanup = thread::spawn(move || {
            cleanup_retry_registered.wait();
            cleanup_allowed.wait();
            cleanup_router.fail_pending_leader_generation_if_matches(
                &cleanup_request_id,
                1,
                "stale cleanup",
            )
        });

        let (retry_tx, _retry_rx) = oneshot::channel();
        router.leader_pending.lock().unwrap().insert(
            request_id.clone(),
            PendingLeaderResponse {
                generation: 2,
                routes: vec![PendingLeaderRoute {
                    connection_id: 20,
                    correlation_id: 21,
                }],
                target_peer_id: vec![0xA1; 16],
                request: TeamLeaderCommandRequest {
                    request_id: request_id.clone(),
                    ..Default::default()
                },
                senders: vec![retry_tx],
            },
        );

        retry_registered.wait();
        allow_stale_cleanup.wait();
        assert!(!stale_cleanup.join().unwrap());
        let pending = router.leader_pending.lock().unwrap();
        let retry = pending
            .get(&request_id)
            .expect("retry must survive stale cleanup");
        assert_eq!(retry.generation, 2);
        assert_eq!(
            retry.routes,
            vec![PendingLeaderRoute {
                connection_id: 20,
                correlation_id: 21,
            }]
        );
    }

    #[test]
    fn project_root_walks_up_to_the_repo() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let repo = tmp.path().join("myproject");
        let nested = repo.join("daemon").join("src");
        std::fs::create_dir_all(&nested).expect("mkdir");
        std::fs::create_dir(repo.join(".git")).expect("mkdir .git");

        assert_eq!(
            walk_to_git_root(nested.to_str().unwrap()),
            repo.to_string_lossy()
        );
        assert_eq!(
            walk_to_git_root(repo.to_str().unwrap()),
            repo.to_string_lossy()
        );
    }

    #[test]
    fn project_root_accepts_a_git_file_for_worktrees() {
        // A `.git` FILE whose pointer is not a recognisable linked-worktree
        // gitdir still marks a repo root of its own.
        let tmp = tempfile::tempdir().expect("tempdir");
        let worktree = tmp.path().join("feature-branch");
        std::fs::create_dir_all(worktree.join("Sources")).expect("mkdir");
        std::fs::write(worktree.join(".git"), "gitdir: /elsewhere\n").expect("write");

        assert_eq!(
            walk_to_git_root(worktree.join("Sources").to_str().unwrap()),
            worktree.to_string_lossy()
        );
    }

    #[test]
    fn project_root_resolves_a_linked_worktree_to_its_primary() {
        // An agent's instance-tagged worktree is a temporary station of the
        // primary project — it must group under `demo`, not appear as a
        // ghost project called `demo-executor-260728-a3f2`.
        let tmp = tempfile::tempdir().expect("tempdir");
        let primary = tmp.path().join("demo");
        let worktree = tmp.path().join("demo-executor-260728-a3f2");
        std::fs::create_dir_all(worktree.join("src")).expect("mkdir");
        std::fs::write(
            worktree.join(".git"),
            format!(
                "gitdir: {}\n",
                primary.join(".git/worktrees/demo-executor").display()
            ),
        )
        .expect("write");

        assert_eq!(
            walk_to_git_root(worktree.join("src").to_str().unwrap()),
            primary.to_string_lossy()
        );
    }

    #[test]
    fn project_root_keeps_a_submodule_as_its_own_project() {
        // A submodule's `.git` file points into `.git/modules/…` — it is a
        // repository in its own right (ghostty inside term-mesh), so panes
        // working in it stay grouped under the submodule, never absorbed
        // into the superproject.
        let tmp = tempfile::tempdir().expect("tempdir");
        let superproject = tmp.path().join("term-mesh");
        let submodule = superproject.join("ghostty");
        std::fs::create_dir_all(submodule.join("src")).expect("mkdir");
        std::fs::write(
            submodule.join(".git"),
            format!(
                "gitdir: {}\n",
                superproject.join(".git/modules/ghostty").display()
            ),
        )
        .expect("write");

        assert_eq!(
            walk_to_git_root(submodule.join("src").to_str().unwrap()),
            submodule.to_string_lossy()
        );
    }

    #[test]
    fn project_root_is_empty_outside_a_repo_and_for_bad_input() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let plain = tmp.path().join("no-repo-here");
        std::fs::create_dir_all(&plain).expect("mkdir");

        // tempdir lives under /tmp (or /var/folders); neither is a repo.
        assert_eq!(walk_to_git_root(plain.to_str().unwrap()), "");
        assert_eq!(walk_to_git_root("relative/path"), "");
        assert_eq!(project_root_for(""), "");
    }

    /// Build a store with N single-tab panes without spawning PTYs.
    fn store_with(names: &[&str]) -> LayoutStore {
        let mut store = LayoutStore {
            root: None,
            next_split_id: 1,
        };
        let ids: Vec<SurfaceId> = names.iter().map(|n| sid(n)).collect();
        store.root = store.build_balanced(&ids, 0);
        store
    }

    /// Surface ids currently in `host`'s default workspace tree.
    fn default_surface_ids(host: &PeerHost) -> Vec<SurfaceId> {
        host.workspaces
            .lock()
            .unwrap()
            .get(&host.default_id())
            .unwrap()
            .store
            .surface_ids()
    }

    fn split_ids(store: &LayoutStore) -> Vec<Vec<u8>> {
        fn walk(node: &LayoutNode, out: &mut Vec<Vec<u8>>) {
            if let LayoutNode::Split {
                id, first, second, ..
            } = node
            {
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

    /// Current divider ratio for `split_id` in `store`, or `None` if no
    /// split with that id exists in the tree.
    fn divider_ratio(store: &LayoutStore, split_id: &[u8]) -> Option<f64> {
        fn walk(node: &LayoutNode, target: &[u8]) -> Option<f64> {
            if let LayoutNode::Split {
                id,
                divider,
                first,
                second,
                ..
            } = node
            {
                if split_id_bytes(*id) == target {
                    return Some(*divider);
                }
                return walk(first, target).or_else(|| walk(second, target));
            }
            None
        }
        store.root.as_ref().and_then(|root| walk(root, split_id))
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
        let changed = store
            .split_pane(&sid("a"), Orientation::Horizontal, sid("b"))
            .unwrap();
        assert!(changed);
        assert_eq!(store.surface_ids(), vec![sid("a"), sid("b")]);
        assert_eq!(split_ids(&store).len(), 1);
    }

    #[test]
    fn split_unknown_pane_is_notfound_and_tree_unchanged() {
        let mut store = store_with(&["a"]);
        let before = store.surface_ids();
        assert_eq!(
            store
                .split_pane(&sid("ghost"), Orientation::Vertical, sid("b"))
                .unwrap_err(),
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
        assert_eq!(
            store.close_pane(&sid("a")).unwrap_err(),
            LayoutError::LastPane
        );
        assert_eq!(store.surface_ids(), vec![sid("a")]);
    }

    /// F1 regression: a single-pane workspace (root is a bare Pane, the
    /// common default — one declared surface, never split) grown to
    /// multiple tabs via add_tab must let non-last tabs close normally.
    /// The pre-fix code refused every close as LastPane the moment root
    /// was a Pane, regardless of tabs.len().
    #[test]
    fn close_tab_in_single_pane_workspace_when_not_last() {
        let mut store = store_with(&["a"]);
        store.add_tab(&sid("a"), sid("b")).unwrap();
        // root is still a bare Pane (no split ever happened), now with 2 tabs.
        let removed = store.close_pane(&sid("a")).unwrap();
        assert_eq!(removed, vec![sid("a")]);
        assert_eq!(store.surface_ids(), vec![sid("b")]);
        // Only the true last tab is refused.
        assert_eq!(
            store.close_pane(&sid("b")).unwrap_err(),
            LayoutError::LastPane
        );
        assert_eq!(store.surface_ids(), vec![sid("b")]);
    }

    #[test]
    fn double_close_second_is_notfound() {
        let mut store = store_with(&["a", "b", "c"]);
        store.close_pane(&sid("a")).unwrap();
        assert_eq!(
            store.close_pane(&sid("a")).unwrap_err(),
            LayoutError::NotFound
        );
        assert_eq!(store.surface_ids(), vec![sid("b"), sid("c")]);
    }

    #[test]
    fn split_ids_stable_across_unrelated_mutations() {
        let mut store = store_with(&["a", "b"]);
        let before = split_ids(&store);
        store
            .split_pane(&sid("b"), Orientation::Vertical, sid("c"))
            .unwrap();
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
        assert_eq!(
            store.set_divider(&split, f64::NAN).unwrap_err(),
            LayoutError::NotFound
        );
        assert_eq!(
            store.set_divider(&split, f64::INFINITY).unwrap_err(),
            LayoutError::NotFound
        );
        assert_eq!(
            store.set_divider(&[1, 2, 3], 0.5).unwrap_err(),
            LayoutError::NotFound
        );
        // F1: absurd id lengths.
        assert_eq!(
            store.set_divider(&[], 0.5).unwrap_err(),
            LayoutError::NotFound
        );
        assert_eq!(
            store.set_divider(&vec![0u8; 1024], 0.5).unwrap_err(),
            LayoutError::NotFound
        );
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

    /// F5 regression: an ephemeral split's id must never collide with a
    /// declared `TERMMESH_PEER_SURFACES` name, even one deliberately
    /// chosen to match the ephemeral naming scheme. Structural, not
    /// probabilistic: a `\0` can never appear in an env var's value, so
    /// hashing it into the ephemeral name makes the collision impossible
    /// regardless of what an operator names their declared surfaces.
    #[test]
    fn ephemeral_ids_cannot_collide_with_declared_names() {
        for guess in ["split-1", "split-2", "split-0", "split-100"] {
            assert_ne!(
                surface_id_from_name(guess),
                surface_id_from_name(&format!("\0{guess}")),
                "a declared surface literally named {guess:?} would collide with an ephemeral id"
            );
        }
    }

    /// F4 regression: SplitPane must stop forking shells once the
    /// registered-surface ceiling is hit, rather than letting any peer
    /// that can reach Ready (ssh-passthrough is the entire trust model)
    /// exhaust the daemon uid's PIDs/PTYs. Splits the same base pane far
    /// past the cap and confirms the surface count halts exactly there.
    #[tokio::test]
    async fn split_pane_stops_at_surface_cap() {
        let manager = Arc::new(PtyManager::new());
        let base = PtySurface::spawn(sid("base"), "cat".into(), "/bin/cat", &[], 80, 24, None)
            .expect("spawn /bin/cat");
        manager.insert_surface(base);
        let host = Arc::new(PeerHost::new(manager));

        for _ in 0..(PeerHost::MAX_PEER_SURFACES + 20) {
            host.apply_control(WorkspaceControl {
                kind: Some(workspace_control::Kind::SplitPane(
                    peer_proto::v1::SplitPaneRequest {
                        pane_id: sid("base"),
                        orientation: "horizontal".into(),
                    },
                )),
            });
        }

        assert_eq!(host.pty.list().len(), PeerHost::MAX_PEER_SURFACES);
    }

    /// R8 end to end inside the daemon: split spawns a real login shell,
    /// hanging that shell up (as if the user typed `exit`) must remove
    /// its pane from the tree and schedule a push — without touching the
    /// surviving pane.
    #[tokio::test]
    async fn ephemeral_self_exit_removes_pane() {
        let manager = Arc::new(PtyManager::new());
        let base = PtySurface::spawn(sid("base"), "cat".into(), "/bin/cat", &[], 80, 24, None)
            .expect("spawn /bin/cat");
        manager.insert_surface(base);
        let host = Arc::new(PeerHost::new(manager));
        assert_eq!(default_surface_ids(&host).len(), 1);

        host.apply_control(WorkspaceControl {
            kind: Some(workspace_control::Kind::SplitPane(
                peer_proto::v1::SplitPaneRequest {
                    pane_id: sid("base"),
                    orientation: "horizontal".into(),
                },
            )),
        });
        assert_eq!(default_surface_ids(&host).len(), 2, "split landed");

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
            if default_surface_ids(&host) == vec![sid("base")] {
                break;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "watcher never pruned the dead ephemeral pane; tree = {:?}",
                default_surface_ids(&host)
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

    // ---- M1: workspace collection ----------------------------------

    /// A freshly booted host always has exactly one workspace — the
    /// default (`DAEMON_WORKSPACE`) — matching the pre-M1 single-workspace
    /// behavior, just expressed through the collection now. M1 dropped the
    /// deterministic `surface_id_from_name(DAEMON_WORKSPACE)` id
    /// derivation in favor of a random 16-byte id assigned at creation
    /// (see the `layout::DAEMON_WORKSPACE` doc comment), so this only
    /// checks the id's shape and the entry/host agreement, not a fixed
    /// value.
    #[test]
    fn default_workspace_exists_after_boot() {
        let manager = Arc::new(PtyManager::new());
        let host = PeerHost::new(manager);

        let default_id = host.default_id();
        let workspaces = host.workspaces.lock().unwrap();
        assert_eq!(workspaces.len(), 1);
        let entry = workspaces
            .get(&default_id)
            .expect("default workspace present");
        assert_eq!(entry.id, default_id);
        assert_eq!(entry.name, DAEMON_WORKSPACE);
        assert!(entry.is_default);
        assert_eq!(default_id.len(), 16, "id must be a random 16-byte value");
        assert_ne!(
            default_id,
            surface_id_from_name(DAEMON_WORKSPACE),
            "id must no longer be derivable from the workspace name"
        );
    }

    /// Two hosts constructed via `new` must not collide on workspace id —
    /// the whole point of moving off a deterministic name-derived id.
    #[test]
    fn default_workspace_id_is_random_across_hosts() {
        let host_a = PeerHost::new(Arc::new(PtyManager::new()));
        let host_b = PeerHost::new(Arc::new(PtyManager::new()));
        assert_ne!(host_a.default_id(), host_b.default_id());
    }

    /// Booting with surfaces already registered seeds the default
    /// workspace's tree AND the surface→workspace reverse index for every
    /// one of them — the index is not an afterthought populated lazily.
    #[tokio::test]
    async fn boot_seeds_reverse_index_for_declared_surfaces() {
        let manager = Arc::new(PtyManager::new());
        let base = PtySurface::spawn(sid("base"), "cat".into(), "/bin/cat", &[], 80, 24, None)
            .expect("spawn /bin/cat");
        manager.insert_surface(base);
        let host = PeerHost::new(Arc::clone(&manager));

        assert_eq!(
            host.workspace_id_for_surface(&sid("base")),
            Some(host.default_id())
        );
        assert_eq!(host.workspace_id_for_surface(&sid("ghost")), None);
    }

    /// With multiple workspace entries present, the reverse index must
    /// resolve each surface to the workspace that actually owns it, not
    /// always the default — this is the routing primitive `apply_control`
    /// and `watch_ephemeral` depend on.
    #[test]
    fn reverse_index_resolves_correct_workspace_across_entries() {
        let manager = Arc::new(PtyManager::new());
        let host = PeerHost::new(manager);

        // Manually add a second workspace and wire the reverse index for a
        // surface homed there. Production only ever creates the default
        // workspace at boot (Create-workspace RPCs are a later task); this
        // simulates the resulting shape directly.
        let ws2_id = surface_id_from_name("second");
        {
            let mut workspaces = host.workspaces.lock().unwrap();
            let store2 = store_with(&["x"]);
            workspaces.insert(
                ws2_id.clone(),
                WorkspaceEntry {
                    id: ws2_id.clone(),
                    name: "second".into(),
                    is_default: false,
                    store: store2,
                },
            );
        }
        host.surface_workspace
            .lock()
            .unwrap()
            .insert(sid("x"), ws2_id.clone());

        assert_eq!(host.workspaces.lock().unwrap().len(), 2);
        assert_eq!(
            host.workspace_id_for_surface(&sid("x")),
            Some(ws2_id.clone())
        );
        assert_eq!(host.workspace_id_for_surface(&sid("nowhere")), None);
        assert_ne!(ws2_id, host.default_id());
    }

    /// P1-1 regression: `split_id` is only unique WITHIN one workspace's
    /// tree, so two independently-built workspaces routinely mint the same
    /// id (each `LayoutStore`'s counter starts at 1). Passing a non-empty
    /// `workspace_id` to `PeerHost::set_divider` must scope the resize to
    /// that workspace's store only — the other workspace's divider, which
    /// shares the same split_id, must stay exactly as it was.
    #[test]
    fn set_divider_scoped_to_workspace_id_leaves_other_workspace_untouched() {
        let manager = Arc::new(PtyManager::new());
        let host = PeerHost::new(manager);
        let default_id = host.default_id();

        {
            let mut workspaces = host.workspaces.lock().unwrap();
            workspaces.get_mut(&default_id).unwrap().store = store_with(&["a", "b"]);
        }
        let ws2_id = surface_id_from_name("second");
        {
            let mut workspaces = host.workspaces.lock().unwrap();
            workspaces.insert(
                ws2_id.clone(),
                WorkspaceEntry {
                    id: ws2_id.clone(),
                    name: "second".into(),
                    is_default: false,
                    store: store_with(&["x", "y"]),
                },
            );
        }

        let (default_split, ws2_split) = {
            let workspaces = host.workspaces.lock().unwrap();
            (
                split_ids(&workspaces.get(&default_id).unwrap().store)[0].clone(),
                split_ids(&workspaces.get(&ws2_id).unwrap().store)[0].clone(),
            )
        };
        assert_eq!(
            default_split, ws2_split,
            "test setup requires colliding split ids across workspaces — each \
             LayoutStore's counter independently starts at 1"
        );
        let split_id = default_split;

        // Scoped to ws2: only ws2's divider moves.
        let changed = host.set_divider(&ws2_id, &split_id, 0.3);
        assert_eq!(changed, Some(ws2_id.clone()));

        let workspaces = host.workspaces.lock().unwrap();
        assert_eq!(
            divider_ratio(&workspaces.get(&ws2_id).unwrap().store, &split_id),
            Some(0.3)
        );
        assert_ne!(
            divider_ratio(&workspaces.get(&default_id).unwrap().store, &split_id),
            Some(0.3),
            "default workspace's divider (same split_id, different workspace) must be untouched"
        );
        // An unknown workspace_id (that still names no store) resolves to
        // nothing rather than silently falling back to first-match.
        drop(workspaces);
        assert_eq!(
            host.set_divider(&sid("ghost-workspace"), &split_id, 0.7),
            None
        );
    }

    /// Legacy-client fallback: an empty `workspace_id` (pre field-3 clients)
    /// still degrades to matching whichever tree's split_id hits first —
    /// the single-workspace-compatible behavior this path exists for.
    #[test]
    fn set_divider_empty_workspace_id_falls_back_to_first_match() {
        let manager = Arc::new(PtyManager::new());
        let host = PeerHost::new(manager);
        let default_id = host.default_id();
        {
            let mut workspaces = host.workspaces.lock().unwrap();
            workspaces.get_mut(&default_id).unwrap().store = store_with(&["a", "b"]);
        }
        let split_id = {
            let workspaces = host.workspaces.lock().unwrap();
            split_ids(&workspaces.get(&default_id).unwrap().store)[0].clone()
        };

        let changed = host.set_divider(&[], &split_id, 0.3);
        assert_eq!(changed, Some(default_id.clone()));
        let workspaces = host.workspaces.lock().unwrap();
        assert_eq!(
            divider_ratio(&workspaces.get(&default_id).unwrap().store, &split_id),
            Some(0.3)
        );
    }

    /// Multi-workspace regression: `watch_ephemeral` must prune the dead
    /// pane from the workspace that actually owns it (via the reverse
    /// index), not always the default — and must leave every other
    /// workspace's tree, and the reverse index entries for its own
    /// surfaces, untouched.
    #[tokio::test]
    async fn watch_ephemeral_prunes_only_the_owning_workspace() {
        let manager = Arc::new(PtyManager::new());
        let base_a = PtySurface::spawn(sid("base-a"), "cat".into(), "/bin/cat", &[], 80, 24, None)
            .expect("spawn base-a");
        manager.insert_surface(base_a);
        let host = Arc::new(PeerHost::new(Arc::clone(&manager)));
        // Default workspace was seeded from the manager's contents at
        // construction time — base-a only.

        let base_b = PtySurface::spawn(sid("base-b"), "cat".into(), "/bin/cat", &[], 80, 24, None)
            .expect("spawn base-b");
        manager.insert_surface(base_b);

        // Second workspace, manually populated with base-b — stands in for
        // a future Create/attach-workspace RPC not built in this task.
        let ws2_id = surface_id_from_name("second");
        {
            let mut workspaces = host.workspaces.lock().unwrap();
            let surfaces_b: Vec<_> = manager
                .list()
                .into_iter()
                .filter(|s| s.surface_id == sid("base-b"))
                .collect();
            let store2 = LayoutStore::balanced_from_surfaces(&surfaces_b);
            workspaces.insert(
                ws2_id.clone(),
                WorkspaceEntry {
                    id: ws2_id.clone(),
                    name: "second".into(),
                    is_default: false,
                    store: store2,
                },
            );
        }
        host.surface_workspace
            .lock()
            .unwrap()
            .insert(sid("base-b"), ws2_id.clone());

        let ephemeral_id = host
            .spawn_ephemeral(&sid("base-b"), &ws2_id)
            .expect("spawn ephemeral in ws2");
        {
            let mut workspaces = host.workspaces.lock().unwrap();
            workspaces
                .get_mut(&ws2_id)
                .unwrap()
                .store
                .split_pane(
                    &sid("base-b"),
                    Orientation::Horizontal,
                    ephemeral_id.clone(),
                )
                .unwrap();
        }

        let ephemeral_surface = manager
            .list()
            .into_iter()
            .find(|s| s.surface_id == ephemeral_id)
            .expect("ephemeral surface exists");
        ephemeral_surface.hangup();

        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            let ws2_ids = host
                .workspaces
                .lock()
                .unwrap()
                .get(&ws2_id)
                .unwrap()
                .store
                .surface_ids();
            if ws2_ids == vec![sid("base-b")] {
                break;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "watcher never pruned ws2's ephemeral pane; ws2 tree = {ws2_ids:?}"
            );
            tokio::time::sleep(Duration::from_millis(50)).await;
        }

        // Default workspace's tree (base-a only) is untouched.
        assert_eq!(default_surface_ids(&host), vec![sid("base-a")]);
        // Reverse index entry for the pruned surface is gone; base-a's and
        // base-b's own entries are untouched.
        let index = host.surface_workspace.lock().unwrap();
        assert!(!index.contains_key(&ephemeral_id));
        assert_eq!(index.get(&sid("base-a")), Some(&host.default_id()));
        assert_eq!(index.get(&sid("base-b")), Some(&ws2_id));
    }

    // ---- M1: with_workspaces / persistence-driven boot --------------

    fn persisted(name: &str, is_default: bool) -> PersistedWorkspace {
        PersistedWorkspace {
            id: sid(name),
            name: name.to_string(),
            is_default,
        }
    }

    /// `with_workspaces` seeds the default entry's tree from the
    /// manager's current surfaces (matching `new`'s behavior) but leaves
    /// every non-default entry an empty workspace — M1's boot-from-env
    /// contract creates named workspaces empty, not pre-tiled.
    #[tokio::test]
    async fn with_workspaces_seeds_default_only() {
        let manager = Arc::new(PtyManager::new());
        let base = PtySurface::spawn(sid("base"), "cat".into(), "/bin/cat", &[], 80, 24, None)
            .expect("spawn /bin/cat");
        manager.insert_surface(base);

        let host = PeerHost::with_workspaces(
            Arc::clone(&manager),
            vec![persisted("term-meshd", true), persisted("dev", false)],
        );

        let workspaces = host.workspaces.lock().unwrap();
        assert_eq!(workspaces.len(), 2);
        assert_eq!(host.default_id(), sid("term-meshd"));

        let default_entry = workspaces.get(&sid("term-meshd")).unwrap();
        assert!(default_entry.is_default);
        assert_eq!(default_entry.store.surface_ids(), vec![sid("base")]);

        let dev_entry = workspaces.get(&sid("dev")).unwrap();
        assert!(!dev_entry.is_default);
        assert!(dev_entry.store.is_empty(), "non-default entries boot empty");

        // Reverse index only covers the default workspace's surfaces.
        assert_eq!(
            host.workspace_id_for_surface(&sid("base")),
            Some(sid("term-meshd"))
        );
    }

    /// A collection with no entry marked `is_default` (a hand-built `Vec`
    /// bypassing `persist::boot`'s own guard) must still produce a usable
    /// host: the first entry is promoted rather than leaving
    /// `workspace_id` unset.
    #[test]
    fn with_workspaces_promotes_first_entry_when_none_marked_default() {
        let manager = Arc::new(PtyManager::new());
        let host = PeerHost::with_workspaces(manager, vec![persisted("orphan", false)]);

        assert_eq!(host.default_id(), sid("orphan"));
        let workspaces = host.workspaces.lock().unwrap();
        assert!(workspaces.get(&sid("orphan")).unwrap().is_default);
    }

    /// `default_workspace_title` surfaces whatever name the default entry
    /// currently carries — the mechanism `TERMMESH_PEER_WORKSPACE_TITLE`
    /// and a future rename RPC both flow through, and what
    /// `connection.rs`'s `ListWorkspaces` handler now reads directly
    /// instead of always calling `hostname_or`.
    #[test]
    fn default_workspace_title_reflects_persisted_name() {
        let manager = Arc::new(PtyManager::new());
        let host = PeerHost::with_workspaces(manager, vec![persisted("my-custom-title", true)]);
        assert_eq!(host.default_workspace_title(), "my-custom-title");
    }

    /// M3: an unknown id is still refused as `NotFound`, and removing a
    /// non-default workspace still works exactly as before. Once only one
    /// workspace is left, removing THAT one (even though it happens to be
    /// the default) is refused as `LastWorkspace` — the collection-level
    /// invariant is now "never zero workspaces", not "never touch default".
    #[test]
    fn remove_workspace_refuses_unknown_and_last_but_removes_non_default() {
        let manager = Arc::new(PtyManager::new());
        let host = PeerHost::with_workspaces(
            manager,
            vec![persisted("term-meshd", true), persisted("dev", false)],
        );

        assert_eq!(
            host.remove_workspace(&sid("ghost")),
            Err(RemoveWorkspaceError::NotFound)
        );
        assert_eq!(host.remove_workspace(&sid("dev")), Ok(()));
        assert_eq!(
            host.workspaces.lock().unwrap().len(),
            1,
            "default survives, dev is gone"
        );
        // Removing it again is now NotFound, not a second success.
        assert_eq!(
            host.remove_workspace(&sid("dev")),
            Err(RemoveWorkspaceError::NotFound)
        );
        // Only the default is left now — refused as the LAST workspace,
        // not because it is the default.
        assert_eq!(
            host.remove_workspace(&sid("term-meshd")),
            Err(RemoveWorkspaceError::LastWorkspace)
        );
    }

    /// M3(b): the very last remaining workspace can never be removed,
    /// regardless of `is_default` — un-namespaced control and
    /// `default_id()` always need a home to resolve to.
    #[test]
    fn remove_last_workspace_is_refused() {
        let manager = Arc::new(PtyManager::new());
        let host = PeerHost::new(manager);
        let default_id = host.default_id();

        assert_eq!(
            host.remove_workspace(&default_id),
            Err(RemoveWorkspaceError::LastWorkspace)
        );
        assert_eq!(
            host.workspaces.lock().unwrap().len(),
            1,
            "the last workspace survives"
        );
    }

    /// M3(a): deleting the DEFAULT workspace is now allowed once another
    /// workspace exists to take over. The old default's own surfaces
    /// (standing in for static `TERMMESH_PEER_SURFACES` shells) are torn
    /// down exactly like any other workspace delete rather than re-homed,
    /// and the sole survivor is promoted (`is_default = true`,
    /// `default_id()` updated) with its own tree left untouched.
    #[tokio::test]
    async fn remove_default_workspace_promotes_survivor_and_tears_down_old_default_surfaces() {
        let manager = Arc::new(PtyManager::new());
        let base = PtySurface::spawn(sid("base"), "cat".into(), "/bin/cat", &[], 80, 24, None)
            .expect("spawn /bin/cat");
        manager.insert_surface(base);
        // `PeerHost::new` seeds the sole (default) workspace's tree from
        // the manager's current surfaces — "base" stands in for a
        // declared TERMMESH_PEER_SURFACES shell owned by the default.
        let host = Arc::new(PeerHost::new(Arc::clone(&manager)));
        let old_default_id = host.default_id();
        assert_eq!(default_surface_ids(&host), vec![sid("base")]);

        let dev_id = host.create_workspace("dev".into());

        assert_eq!(host.remove_workspace(&old_default_id), Ok(()));

        // Old default's surface was torn down, not re-homed into "dev".
        assert!(!manager.list().iter().any(|s| s.surface_id == sid("base")));
        assert!(!host
            .surface_workspace
            .lock()
            .unwrap()
            .contains_key(&sid("base")));

        // "dev" is the only survivor, so it is unambiguously promoted.
        assert_eq!(host.default_id(), dev_id);
        let workspaces = host.workspaces.lock().unwrap();
        assert_eq!(workspaces.len(), 1);
        let dev_entry = workspaces.get(&dev_id).unwrap();
        assert!(dev_entry.is_default);
        assert!(
            !dev_entry.store.is_empty(),
            "promoted default keeps its own tree (its create-seeded pane), no re-parenting of the old default's panes"
        );
    }

    /// M3: when more than one survivor remains after the default is
    /// removed, promotion is deterministic — the lowest workspace id wins,
    /// matching `HashMap`'s unstable iteration order being unusable here.
    #[test]
    fn remove_default_workspace_promotes_lowest_id_survivor_deterministically() {
        let manager = Arc::new(PtyManager::new());
        let host = PeerHost::with_workspaces(
            manager,
            vec![
                persisted("term-meshd", true),
                persisted("alpha", false),
                persisted("bravo", false),
            ],
        );
        let default_id = host.default_id();
        let expected_new_default = [sid("alpha"), sid("bravo")].into_iter().min().unwrap();

        assert_eq!(host.remove_workspace(&default_id), Ok(()));

        assert_eq!(host.default_id(), expected_new_default);
        let workspaces = host.workspaces.lock().unwrap();
        assert_eq!(workspaces.len(), 2);
        assert!(workspaces.get(&expected_new_default).unwrap().is_default);
    }

    // ---- M2: create/rename/delete workspace lifecycle -----------------

    /// `create_workspace` assigns a random 16-byte id, adds an empty
    /// entry `list_workspaces` immediately reflects (title verbatim,
    /// `layout: None`), and never touches the default workspace.
    // `create_workspace` schedules a debounced layout push (`tokio::spawn`
    // under the hood), so this needs a live Tokio runtime even though
    // nothing in the test body itself awaits.
    #[tokio::test]
    async fn create_workspace_adds_empty_entry_without_disturbing_default() {
        let host = Arc::new(PeerHost::new(Arc::new(PtyManager::new())));
        let default_id = host.default_id();

        let new_id = host.create_workspace("scratch".into());
        assert_eq!(new_id.len(), 16, "id must be a random 16-byte value");
        assert_ne!(new_id, default_id);

        let roster = host.list_workspaces();
        assert_eq!(roster.len(), 2);
        let created = roster
            .iter()
            .find(|e| e.id == new_id)
            .expect("new entry present");
        assert_eq!(created.title, "scratch");
        assert!(
            created.layout.is_some(),
            "a created workspace is seeded with its first pane so it is usable immediately"
        );
        let default_entry = roster
            .iter()
            .find(|e| e.id == default_id)
            .expect("default untouched");
        assert_eq!(default_entry.title, DAEMON_WORKSPACE);
    }

    /// P1-2 regression: `create_workspace`'s "seed a first pane" step was
    /// an unconditional `spawn_ephemeral` — unlike `split_pane`/`new_tab`,
    /// it never checked `MAX_PEER_SURFACES`, so looping `CreateWorkspace`
    /// bypassed the registered-surface cap entirely (uncapped PTY spawn).
    /// At the cap, the workspace must still be created — just left empty,
    /// exactly like a non-default workspace restored from
    /// `peer-workspaces.json` — and no additional PTY may be spawned.
    #[tokio::test]
    async fn create_workspace_at_max_peer_surfaces_skips_seed_and_stays_empty() {
        let manager = Arc::new(PtyManager::new());
        let base = PtySurface::spawn(sid("base"), "cat".into(), "/bin/cat", &[], 80, 24, None)
            .expect("spawn /bin/cat");
        manager.insert_surface(base);
        let host = Arc::new(PeerHost::new(Arc::clone(&manager)));

        // Drive the surface count up to the cap via the same mechanism
        // `split_pane_stops_at_surface_cap` uses — real spawns halt exactly
        // at MAX_PEER_SURFACES because split_pane's own cap check runs
        // before spawn_ephemeral.
        for _ in 0..(PeerHost::MAX_PEER_SURFACES + 20) {
            host.apply_control(WorkspaceControl {
                kind: Some(workspace_control::Kind::SplitPane(
                    peer_proto::v1::SplitPaneRequest {
                        pane_id: sid("base"),
                        orientation: "horizontal".into(),
                    },
                )),
            });
        }
        assert_eq!(
            host.pty.list().len(),
            PeerHost::MAX_PEER_SURFACES,
            "test setup requires the cap already hit"
        );

        let new_id = host.create_workspace("overflow".into());

        assert_eq!(
            host.pty.list().len(),
            PeerHost::MAX_PEER_SURFACES,
            "create_workspace must not spawn past the cap"
        );
        let roster = host.list_workspaces();
        let created = roster
            .iter()
            .find(|e| e.id == new_id)
            .expect("workspace still created");
        assert!(
            created.layout.is_none(),
            "seed must be skipped (not merely failed) once the cap is already hit"
        );
    }

    /// `rename_workspace` changes only the name, leaving the id (and
    /// every other entry) untouched; an unknown or empty id is a no-op.
    #[test]
    fn rename_workspace_changes_title_not_id() {
        let host = Arc::new(PeerHost::new(Arc::new(PtyManager::new())));
        let default_id = host.default_id();

        assert!(host.rename_workspace(&default_id, "renamed".into()));
        assert_eq!(host.default_workspace_title(), "renamed");
        assert_eq!(
            host.default_id(),
            default_id,
            "id must survive a rename unchanged"
        );

        assert!(
            !host.rename_workspace(&sid("ghost"), "hijack".into()),
            "unknown id is a no-op"
        );
        assert!(
            !host.rename_workspace(&[], "hijack".into()),
            "empty id is a no-op"
        );
        assert_eq!(
            host.default_workspace_title(),
            "renamed",
            "no-op must not have applied"
        );
    }

    /// A client that never subscribed to the roster is not sent one, and
    /// with no subscriber at all the roster is never even assembled.
    ///
    /// Building it walks every workspace's pane tree, and this runs on every
    /// debounced layout push — which fires repeatedly throughout a divider
    /// drag. A viewer watching a single pane was receiving the whole roster
    /// each time, right after the scoped delta it actually asked for.
    #[tokio::test]
    async fn workspace_roster_reaches_only_subscribers() {
        let manager = Arc::new(PtyManager::new());
        let host = Arc::new(PeerHost::new(Arc::clone(&manager)));

        let (plain_tx, mut plain_rx) = mpsc::channel(8);
        let _plain = host
            .clients
            .register(plain_tx, Arc::new(AtomicU64::new(0)), vec![0xC1; 16]);
        assert!(
            !host.clients.has_roster_subscriber(),
            "registering alone must not imply a subscription"
        );

        host.broadcast_workspace_roster();
        assert!(
            plain_rx.try_recv().is_err(),
            "a non-subscriber must receive nothing"
        );

        let (sub_tx, mut sub_rx) = mpsc::channel(8);
        let wants = Arc::new(AtomicBool::new(false));
        let _sub = host.clients.register_with_roster_flag(
            sub_tx,
            Arc::new(AtomicU64::new(0)),
            vec![0xD1; 16],
            Arc::clone(&wants),
        );
        wants.store(true, Ordering::Relaxed);
        assert!(host.clients.has_roster_subscriber());

        host.broadcast_workspace_roster();
        assert!(
            matches!(
                sub_rx.try_recv().ok().and_then(|env| env.payload),
                Some(Payload::WorkspaceListChanged(_))
            ),
            "the subscriber must get the roster"
        );
        assert!(
            plain_rx.try_recv().is_err(),
            "the non-subscriber must still receive nothing"
        );
    }

    /// `remove_workspace` on a non-default workspace with live surfaces
    /// must drop every one of them from `pty`, drop their reverse-index
    /// entries, and broadcast a `WorkspaceRemoved` push to every
    /// registered connection.
    #[tokio::test]
    async fn remove_workspace_tears_down_surfaces_and_broadcasts_removal() {
        let manager = Arc::new(PtyManager::new());
        let host = Arc::new(PeerHost::new(Arc::clone(&manager)));

        // Second workspace built directly (not via `create_workspace`, which
        // would itself schedule a debounced push and race the assertions
        // below) — the same manual-construction pattern used by
        // `reverse_index_resolves_correct_workspace_across_entries`.
        let ws2_id = sid("second");
        let extra = PtySurface::spawn(sid("extra"), "cat".into(), "/bin/cat", &[], 80, 24, None)
            .expect("spawn /bin/cat");
        manager.insert_surface(extra);
        {
            let mut workspaces = host.workspaces.lock().unwrap();
            let mut store2 = LayoutStore {
                root: None,
                next_split_id: 1,
            };
            store2.seed_first_pane(sid("extra"));
            workspaces.insert(
                ws2_id.clone(),
                WorkspaceEntry {
                    id: ws2_id.clone(),
                    name: "second".into(),
                    is_default: false,
                    store: store2,
                },
            );
        }
        host.surface_workspace
            .lock()
            .unwrap()
            .insert(sid("extra"), ws2_id.clone());

        let (tx, mut rx) = mpsc::channel(8);
        let guard = host
            .clients
            .register(tx, Arc::new(AtomicU64::new(0)), vec![0x11; 16]);

        assert_eq!(host.remove_workspace(&ws2_id), Ok(()));

        assert!(
            !manager.list().iter().any(|s| s.surface_id == sid("extra")),
            "the deleted workspace's surface must be torn down from pty"
        );
        assert!(!host
            .surface_workspace
            .lock()
            .unwrap()
            .contains_key(&sid("extra")));
        assert!(!host.workspaces.lock().unwrap().contains_key(&ws2_id));

        let env = rx.recv().await.expect("WorkspaceRemoved broadcast");
        match env.payload {
            Some(Payload::WorkspaceUpdate(WorkspaceUpdate {
                kind:
                    Some(workspace_update::Kind::WorkspaceRemoved(WorkspaceRemoved { workspace_id })),
            })) => assert_eq!(workspace_id, ws2_id),
            other => panic!("expected WorkspaceUpdate.workspace_removed, got {other:?}"),
        }
        drop(guard);
    }

    #[tokio::test]
    async fn ensured_surface_is_visible_in_workspace_and_termination_cleans_it() {
        let dir = tempfile::tempdir().unwrap();
        let workspace_path = dir.path().join("peer-workspaces.json");
        let manager = Arc::new(PtyManager::new());
        let host = Arc::new(PeerHost::new(Arc::clone(&manager)));
        host.set_persist_path(workspace_path.clone());
        let spec = SurfaceSpec {
            cwd: "/tmp".into(),
            executable: "/bin/cat".into(),
            args: Vec::new(),
            restart_policy: super::super::surface::EnsureRestartPolicy::OnDaemonRestart,
            kind: super::super::surface::SurfaceKind::Pty,
            agent_cli: String::new(),
        };

        let created = host
            .ensure_surface("workspace-runner", &spec)
            .expect("ensure");
        let workspace_id = host.default_id();
        assert_eq!(
            host.with_store(&workspace_id, |store| store.surface_ids())
                .unwrap(),
            vec![created.surface_id.clone()]
        );
        assert_eq!(
            host.workspace_id_for_surface(&created.surface_id),
            Some(workspace_id.clone())
        );
        assert!(host.layout_snapshot_for(&workspace_id).is_some());

        assert!(host.terminate_surface(&created.surface_id).unwrap());
        assert!(!host.terminate_surface(&created.surface_id).unwrap());
        assert!(host
            .with_store(&workspace_id, |store| store.surface_ids())
            .unwrap()
            .is_empty());
        assert!(crate::peer::persist::load_ensured_surfaces(
            &crate::peer::persist::ensured_surfaces_path(&workspace_path)
        )
        .is_empty());
    }

    #[tokio::test]
    async fn explicit_termination_removes_an_unensured_last_pane() {
        let manager = Arc::new(PtyManager::new());
        let surface = PtySurface::spawn(sid("plain"), "cat".into(), "/bin/cat", &[], 80, 24, None)
            .expect("spawn /bin/cat");
        manager.insert_surface(surface);
        let host = Arc::new(PeerHost::new(Arc::clone(&manager)));
        let workspace_id = host.default_id();

        assert!(host.terminate_surface(&sid("plain")).unwrap());
        assert!(manager.list().is_empty());
        assert!(host
            .with_store(&workspace_id, |store| store.surface_ids())
            .unwrap()
            .is_empty());
        assert!(!host.terminate_surface(&sid("plain")).unwrap());
    }

    /// An ensured agent spec: `/bin/cat` stands in for the bridge — pipes
    /// only, no PTY, stays alive until stdin closes.
    fn agent_spec(cli: &str) -> SurfaceSpec {
        SurfaceSpec {
            cwd: "/tmp".into(),
            executable: "/bin/cat".into(),
            args: Vec::new(),
            restart_policy: super::super::surface::EnsureRestartPolicy::OnDaemonRestart,
            kind: SurfaceKind::Agent,
            agent_cli: cli.into(),
        }
    }

    /// Every surface id `ListWorkspaces` would put on the wire for this
    /// layout: pane actives, their tabs, both split halves — recursively.
    fn collect_wire_surface_ids(layout: Option<&WorkspaceLayout>, out: &mut Vec<SurfaceId>) {
        let Some(node) = layout.and_then(|l| l.node.as_ref()) else {
            return;
        };
        match node {
            workspace_layout::Node::Pane(pane) => {
                out.push(pane.surface_id.clone());
                out.extend(pane.tabs.iter().map(|t| t.surface_id.clone()));
            }
            workspace_layout::Node::Split(split) => {
                collect_wire_surface_ids(split.first.as_deref(), out);
                collect_wire_surface_ids(split.second.as_deref(), out);
            }
        }
    }

    /// Phase 1 non-exposure contract: an ensured agent surface exists in
    /// the runtime (SurfaceList/attach reach it) but never appears in any
    /// workspace tree — `WorkspacePane` has no surface_type, so a viewer
    /// reading the layout could only open it as a terminal pane.
    #[tokio::test]
    async fn agent_surface_is_ensured_but_never_exposed_in_workspaces() {
        let manager = Arc::new(PtyManager::new());
        let host = Arc::new(PeerHost::new(Arc::clone(&manager)));

        let agent = host
            .ensure_surface("agent-hidden", &agent_spec("codex"))
            .expect("ensure agent");
        let terminal_spec = SurfaceSpec {
            cwd: "/tmp".into(),
            executable: "/bin/cat".into(),
            args: Vec::new(),
            restart_policy: super::super::surface::EnsureRestartPolicy::OnDaemonRestart,
            kind: SurfaceKind::Pty,
            agent_cli: String::new(),
        };
        let terminal = host
            .ensure_surface("terminal-visible", &terminal_spec)
            .expect("ensure terminal");

        // The runtime knows both…
        assert!(manager
            .list()
            .iter()
            .any(|s| s.surface_id == agent.surface_id));
        // …the workspace tree and reverse index know only the terminal.
        let workspace_id = host.default_id();
        assert_eq!(
            host.with_store(&workspace_id, |store| store.surface_ids())
                .unwrap(),
            vec![terminal.surface_id.clone()]
        );
        assert_eq!(host.workspace_id_for_surface(&agent.surface_id), None);
        assert_eq!(
            host.workspace_id_for_surface(&terminal.surface_id),
            Some(workspace_id)
        );

        // What ListWorkspaces serializes, across every workspace.
        let mut wire_ids = Vec::new();
        for entry in host.list_workspaces() {
            collect_wire_surface_ids(entry.layout.as_ref(), &mut wire_ids);
        }
        assert!(wire_ids.contains(&terminal.surface_id));
        assert!(
            !wire_ids.contains(&agent.surface_id),
            "agent surface leaked into the ListWorkspaces wire"
        );

        assert!(host.terminate_surface(&agent.surface_id).unwrap());
        assert!(host.terminate_surface(&terminal.surface_id).unwrap());
    }

    /// `terminate_surface` on an agent surface: no layout entry exists (by
    /// contract), so the runtime teardown alone must carry the result —
    /// true once, false on repeat, roster and logical persistence cleaned.
    #[tokio::test]
    async fn agent_surface_terminates_cleanly_without_a_layout_entry() {
        let dir = tempfile::tempdir().unwrap();
        let workspace_path = dir.path().join("peer-workspaces.json");
        let manager = Arc::new(PtyManager::new());
        let host = Arc::new(PeerHost::new(Arc::clone(&manager)));
        host.set_persist_path(workspace_path.clone());

        let created = host
            .ensure_surface("agent-terminate", &agent_spec("codex"))
            .expect("ensure agent");
        assert!(host.terminate_surface(&created.surface_id).unwrap());
        assert!(!host.terminate_surface(&created.surface_id).unwrap());
        assert!(!manager
            .list()
            .iter()
            .any(|s| s.surface_id == created.surface_id));
        assert!(crate::peer::persist::load_ensured_surfaces(
            &crate::peer::persist::ensured_surfaces_path(&workspace_path)
        )
        .is_empty());
    }

    /// The reseed back door: an empty default tree repopulates from
    /// `pty.list()` at snapshot time, which must not sweep an agent
    /// surface in either.
    #[tokio::test]
    async fn empty_default_reseed_skips_agent_surfaces() {
        let manager = Arc::new(PtyManager::new());
        let host = Arc::new(PeerHost::new(Arc::clone(&manager)));
        let agent = host
            .ensure_surface("agent-reseed", &agent_spec("codex"))
            .expect("ensure agent");

        // Agent-only roster: the reseed finds nothing tileable.
        assert!(host.layout_snapshot().is_none());
        assert_eq!(host.workspace_id_for_surface(&agent.surface_id), None);

        // A PTY appearing later reseeds exactly as before — without the agent.
        let base = PtySurface::spawn(sid("base"), "cat".into(), "/bin/cat", &[], 80, 24, None)
            .expect("spawn /bin/cat");
        manager.insert_surface(base);
        let snapshot = host.layout_snapshot().expect("tree reseeds from the pty");
        let mut ids = Vec::new();
        collect_wire_surface_ids(Some(&snapshot), &mut ids);
        assert_eq!(ids, vec![sid("base"), sid("base")], "one pane, one tab");
        assert_eq!(host.workspace_id_for_surface(&agent.surface_id), None);

        assert!(host.terminate_surface(&agent.surface_id).unwrap());
        manager.remove(&sid("base"));
    }

    /// Boot tiling (`with_workspaces`) obeys the same contract: a manager
    /// that already holds an agent surface tiles only its PTY surfaces
    /// into the default workspace.
    #[tokio::test]
    async fn boot_tiling_skips_agent_surfaces() {
        let manager = Arc::new(PtyManager::new());
        let agent = manager
            .ensure("agent-boot", &agent_spec("codex"))
            .expect("ensure agent");
        let base = PtySurface::spawn(sid("base"), "cat".into(), "/bin/cat", &[], 80, 24, None)
            .expect("spawn /bin/cat");
        manager.insert_surface(base);

        let host = Arc::new(PeerHost::new(Arc::clone(&manager)));
        let workspace_id = host.default_id();
        assert_eq!(
            host.with_store(&workspace_id, |store| store.surface_ids())
                .unwrap(),
            vec![sid("base")]
        );
        assert_eq!(host.workspace_id_for_surface(&agent.surface_id), None);

        manager.remove(&agent.surface_id);
        manager.remove(&sid("base"));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn ensure_and_terminate_race_never_leaves_cross_registry_stale_state() {
        let dir = tempfile::tempdir().unwrap();
        let host = Arc::new(PeerHost::new(Arc::new(PtyManager::new())));
        host.set_persist_path(dir.path().join("peer-workspaces.json"));
        let spec = SurfaceSpec {
            cwd: "/tmp".into(),
            executable: "/bin/cat".into(),
            args: Vec::new(),
            restart_policy: super::super::surface::EnsureRestartPolicy::OnDaemonRestart,
            kind: super::super::surface::SurfaceKind::Pty,
            agent_cli: String::new(),
        };

        // Keep the process count low: this module already has PTY-cap stress
        // tests running in parallel, and macOS returns ENXIO when the test
        // process exhausts its configured PTYs.
        for index in 0..2 {
            let key = format!("host-race-{index}");
            let initial = host.ensure_surface(&key, &spec).expect("initial ensure");
            let surface_id = initial.surface_id.clone();
            let barrier = Arc::new(std::sync::Barrier::new(2));
            let ensuring = {
                let host = Arc::clone(&host);
                let barrier = Arc::clone(&barrier);
                let key = key.clone();
                let spec = spec.clone();
                tokio::task::spawn_blocking(move || {
                    barrier.wait();
                    host.ensure_surface(&key, &spec)
                })
            };
            let terminating = {
                let host = Arc::clone(&host);
                let barrier = Arc::clone(&barrier);
                let surface_id = surface_id.clone();
                tokio::task::spawn_blocking(move || {
                    barrier.wait();
                    host.terminate_surface(&surface_id)
                })
            };
            ensuring.await.expect("ensure join").expect("ensure result");
            terminating
                .await
                .expect("terminate join")
                .expect("terminate result");

            let in_runtime = host.pty.list().iter().any(|surface| {
                surface.surface_id == surface_id && !surface.dead.load(Ordering::Acquire)
            });
            let in_layout = host
                .with_store(&host.default_id(), |store| {
                    store.surface_ids().contains(&surface_id)
                })
                .unwrap();
            let in_index = host
                .surface_workspace
                .lock()
                .unwrap()
                .contains_key(&surface_id);
            assert_eq!(in_runtime, in_layout, "runtime/layout diverged at {index}");
            assert_eq!(in_runtime, in_index, "runtime/index diverged at {index}");
            if in_runtime {
                host.terminate_surface(&surface_id).unwrap();
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }

    #[tokio::test]
    async fn terminate_save_failure_is_reported_and_leaves_live_layout_intact() {
        let dir = tempfile::tempdir().unwrap();
        let workspace_path = dir.path().join("peer-workspaces.json");
        let ensured_path = crate::peer::persist::ensured_surfaces_path(&workspace_path);
        let host = Arc::new(PeerHost::new(Arc::new(PtyManager::new())));
        host.set_persist_path(workspace_path);
        let spec = SurfaceSpec {
            cwd: "/tmp".into(),
            executable: "/bin/cat".into(),
            args: Vec::new(),
            restart_policy: super::super::surface::EnsureRestartPolicy::OnDaemonRestart,
            kind: super::super::surface::SurfaceKind::Pty,
            agent_cli: String::new(),
        };
        let created = host
            .ensure_surface("save-failure-runner", &spec)
            .expect("ensure");
        std::fs::remove_file(&ensured_path).unwrap();
        std::fs::create_dir(&ensured_path).unwrap();

        assert!(matches!(
            host.terminate_surface(&created.surface_id),
            Err(EnsureError::Persistence(_))
        ));
        assert!(host
            .pty
            .list()
            .iter()
            .any(|surface| surface.surface_id == created.surface_id
                && !surface.dead.load(Ordering::Acquire)));
        assert!(host
            .with_store(&host.default_id(), |store| {
                store.surface_ids().contains(&created.surface_id)
            })
            .unwrap());

        std::fs::remove_dir(&ensured_path).unwrap();
        assert!(host.terminate_surface(&created.surface_id).unwrap());
        assert!(crate::peer::persist::load_ensured_surfaces(&ensured_path).is_empty());
    }

    #[tokio::test]
    async fn project_presentation_binds_owner_and_exact_live_surfaces() {
        let dir = tempfile::tempdir().unwrap();
        let workspace_path = dir.path().join("peer-workspaces.json");
        let host = Arc::new(PeerHost::new(Arc::new(PtyManager::new())));
        host.set_persist_path(workspace_path.clone());
        let spec = SurfaceSpec {
            cwd: "/tmp".into(),
            executable: "/bin/cat".into(),
            args: Vec::new(),
            restart_policy: super::super::surface::EnsureRestartPolicy::Never,
            kind: super::super::surface::SurfaceKind::Pty,
            agent_cli: String::new(),
        };
        let leader = host.ensure_surface("manifest-leader", &spec).unwrap();
        let member = host.ensure_surface("manifest-member", &spec).unwrap();
        let project = peer_proto::v1::Team {
            name: "demo".into(),
            team_uuid: "team-uuid".into(),
            working_directory: "/tmp".into(),
            leader_surface_id: leader.surface_id.clone(),
            project_id: "team:team-uuid".into(),
            members: vec![peer_proto::v1::TeamMember {
                name: "executor".into(),
                agent_instance_id: "instance-1".into(),
                working_directory: "/tmp".into(),
                surface_id: member.surface_id.clone(),
                surface_type: "terminal".into(),
                ..Default::default()
            }],
            ..Default::default()
        };

        assert_eq!(
            host.upsert_project_presentation(&[vec![1; 16]], &project),
            Ok((1, true))
        );
        assert_eq!(
            host.upsert_project_presentation(&[vec![1; 16]], &project),
            Ok((1, false))
        );
        assert_eq!(
            host.upsert_project_presentation(&[vec![2; 16]], &project),
            Err("not_owner")
        );
        let persisted = crate::peer::persist::load_project_presentations(
            &crate::peer::persist::project_presentations_path(&workspace_path),
        );
        assert_eq!(persisted.len(), 1);
        assert_eq!(persisted[0].revision, 1);

        let mut changed = project.clone();
        changed.name = "renamed".into();
        assert_eq!(
            host.upsert_project_presentation(&[vec![1; 16]], &changed),
            Ok((2, true))
        );

        let mut missing = project;
        missing.members[0].surface_id = vec![9; 16];
        assert_eq!(
            host.upsert_project_presentation(&[vec![1; 16]], &missing),
            Err("member_surface_missing")
        );
        let leader_surface = host
            .pty
            .list()
            .into_iter()
            .find(|surface| surface.surface_id == leader.surface_id)
            .unwrap();
        let member_surface = host
            .pty
            .list()
            .into_iter()
            .find(|surface| surface.surface_id == member.surface_id)
            .unwrap();
        let restarted_manager = Arc::new(PtyManager::new());
        let restarted = Arc::new(PeerHost::new(Arc::clone(&restarted_manager)));
        restarted.set_persist_path(workspace_path.clone());
        restarted_manager.insert_surface(leader_surface);
        restarted_manager.insert_surface(member_surface);
        assert_eq!(
            restarted.upsert_project_presentation(&[vec![1; 16]], &changed),
            Ok((2, true))
        );
        let (tx, mut rx) = mpsc::channel(8);
        let _guard = restarted.clients.register_with_roster_flag(
            tx,
            Arc::new(AtomicU64::new(0)),
            vec![3; 16],
            Arc::new(AtomicBool::new(true)),
        );
        restarted.terminate_surface(&leader.surface_id).unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                let envelope = rx.recv().await.expect("restored watcher broadcast");
                if matches!(envelope.payload, Some(Payload::WorkspaceListChanged(_))) {
                    break;
                }
            }
        })
        .await
        .expect("restored watcher broadcast timeout");
        let replacement_leader = host.ensure_surface("manifest-leader-v2", &spec).unwrap();
        let mut takeover = changed.clone();
        takeover.leader_surface_id = replacement_leader.surface_id.clone();
        assert_eq!(
            host.upsert_project_presentation(&[vec![2; 16]], &takeover),
            Err("not_owner")
        );
        assert_eq!(
            host.delete_project_presentation(&[vec![2; 16]], "team:team-uuid"),
            Err("not_owner")
        );
        assert_eq!(
            host.upsert_project_presentation(&[vec![2; 16], vec![1; 16]], &takeover),
            Ok((3, true))
        );
        assert_eq!(
            host.delete_project_presentation(&[vec![2; 16], vec![1; 16]], "team:team-uuid"),
            Ok(true)
        );
        assert_eq!(
            host.delete_project_presentation(&[vec![1; 16]], "team:team-uuid"),
            Ok(false)
        );
        assert!(crate::peer::persist::load_project_presentations(
            &crate::peer::persist::project_presentations_path(&workspace_path),
        )
        .is_empty());
        host.terminate_surface(&replacement_leader.surface_id)
            .unwrap();
        host.terminate_surface(&member.surface_id).unwrap();
    }

    /// Operator prune for issue #389: records another installation owns
    /// cannot be deleted over the protocol, so the host must be able to drop
    /// them itself — but only when nothing is live, never touching
    /// workspaces, and always leaving a recoverable backup behind.
    #[tokio::test]
    async fn prune_removes_only_dead_records_with_backup_and_keeps_live_ones() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let workspaces_path = tmp.path().join("peer-workspaces.json");
        let presentations_path =
            crate::peer::persist::project_presentations_path(&workspaces_path);
        let host = Arc::new(PeerHost::new(Arc::new(PtyManager::new())));
        host.set_persist_path(workspaces_path.clone());
        let workspace_count = host.list_workspaces().len();
        let spec = SurfaceSpec {
            cwd: "/tmp".into(),
            executable: "/bin/cat".into(),
            args: Vec::new(),
            restart_policy: super::super::surface::EnsureRestartPolicy::Never,
            kind: super::super::surface::SurfaceKind::Pty,
            agent_cli: String::new(),
        };
        // Owned by a peer id this host never sees again: the protocol path
        // would answer not_owner for every one of these.
        let foreign_owner = vec![vec![9; 16]];
        let publish = |key: &str, project_id: &str, dir: &str| {
            let leader = host.ensure_surface(key, &spec).unwrap();
            let team = peer_proto::v1::Team {
                name: project_id.to_string(),
                team_uuid: format!("uuid-{project_id}"),
                working_directory: dir.to_string(),
                leader_surface_id: leader.surface_id.clone(),
                project_id: project_id.to_string(),
                ..Default::default()
            };
            assert_eq!(
                host.upsert_project_presentation(&foreign_owner, &team),
                Ok((1, true))
            );
            leader
        };
        let gone_dir = tmp.path().join("gone").display().to_string();
        let live = publish("live-leader", "live", "/tmp");
        let dead_missing = publish("dead-missing-leader", "dead-missing", &gone_dir);
        let dead_present = publish("dead-present-leader", "dead-present", "/tmp");
        for surface in [&dead_missing, &dead_present] {
            host.terminate_surface(&surface.surface_id).unwrap();
        }
        // Termination marks the surface dead asynchronously; wait for the
        // registry to stop advertising both before judging staleness.
        for _ in 0..50 {
            let live_ids = host.live_surface_ids();
            if !live_ids.contains(&dead_missing.surface_id)
                && !live_ids.contains(&dead_present.surface_id)
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(40)).await;
        }
        let statuses = host.project_presentation_statuses();
        let status = |id: &str| statuses.iter().find(|s| s.project_id == id).cloned().unwrap();
        assert_eq!((status("live").live_surfaces, status("live").directory_present), (1, true));
        assert_eq!(
            (status("dead-missing").live_surfaces, status("dead-missing").directory_present),
            (0, false)
        );
        assert_eq!(
            (status("dead-present").live_surfaces, status("dead-present").directory_present),
            (0, true)
        );

        // Dry run: reports the one implicit candidate, writes nothing.
        let before = std::fs::read(&presentations_path).expect("persisted file");
        let report = host.prune_stale_project_presentations(&[], false).unwrap();
        assert!(!report.applied);
        assert_eq!(
            report.removed.iter().map(|s| s.project_id.as_str()).collect::<Vec<_>>(),
            vec!["dead-missing"]
        );
        assert!(report.skipped.iter().any(|s| s.project_id == "live" && s.reason == "live"));
        assert!(report
            .skipped
            .iter()
            .any(|s| s.project_id == "dead-present" && s.reason == "directory_present"));
        assert_eq!(std::fs::read(&presentations_path).unwrap(), before);
        assert_eq!(host.project_presentations().len(), 3);

        // Explicit ids never remove a live record, and unknown ids are reported.
        let report = host
            .prune_stale_project_presentations(&["live".into(), "nope".into()], true)
            .unwrap();
        assert!(!report.applied);
        assert!(report.removed.is_empty());
        assert!(report.skipped.iter().any(|s| s.project_id == "live" && s.reason == "live"));
        assert!(report.skipped.iter().any(|s| s.project_id == "nope" && s.reason == "not_found"));
        assert_eq!(host.project_presentations().len(), 3);

        // Applied implicit prune: backup first, then only dead-missing goes.
        let report = host.prune_stale_project_presentations(&[], true).unwrap();
        assert!(report.applied);
        let backup = report.backup_path.clone().expect("backup written");
        assert_eq!(std::fs::read(&backup).unwrap(), before);
        assert_eq!(
            report.removed.iter().map(|s| s.project_id.as_str()).collect::<Vec<_>>(),
            vec!["dead-missing"]
        );
        let remaining: Vec<String> = crate::peer::persist::load_project_presentations(
            &presentations_path,
        )
        .into_iter()
        .map(|r| r.project_id)
        .collect();
        assert_eq!(remaining.len(), 2);
        assert!(remaining.contains(&"live".to_string()));
        assert!(remaining.contains(&"dead-present".to_string()));

        // Explicit prune of a dead record whose directory still exists.
        let report = host
            .prune_stale_project_presentations(&["dead-present".into()], true)
            .unwrap();
        assert!(report.applied);
        assert_eq!(host.project_presentations().len(), 1);
        assert_eq!(host.project_presentations()[0].project_id, "live");

        // Workspaces and the live leader are untouched throughout.
        assert_eq!(host.list_workspaces().len(), workspace_count);
        assert!(host.live_surface_ids().contains(&live.surface_id));
        host.terminate_surface(&live.surface_id).unwrap();
    }

    /// The F2 shape, deterministically: a caller that read the manifest
    /// before deleting it reaps the wrong surfaces once a replace lands in
    /// between. Here the read is taken first, the replace commits, and the
    /// delete must still report only what it removed — so a caller has no
    /// reason to keep a snapshot of its own, and `connection.rs` keeps none.
    #[tokio::test]
    async fn delete_releases_the_removed_record_not_an_earlier_read() {
        let host = Arc::new(PeerHost::new(Arc::new(PtyManager::new())));
        let spec = SurfaceSpec {
            cwd: "/tmp".into(),
            executable: "/bin/cat".into(),
            args: Vec::new(),
            restart_policy: super::super::surface::EnsureRestartPolicy::Never,
            kind: super::super::surface::SurfaceKind::Pty,
            agent_cli: String::new(),
        };
        let leader = host.ensure_surface("stale-leader", &spec).unwrap();
        let first_member = host.ensure_surface("stale-member-first", &spec).unwrap();
        let next_member = host.ensure_surface("stale-member-next", &spec).unwrap();
        let owner = vec![vec![6; 16]];
        let project = |member_surface_id: &[u8]| peer_proto::v1::Team {
            name: "stale".into(),
            team_uuid: "uuid-stale".into(),
            working_directory: "/tmp".into(),
            leader_surface_id: leader.surface_id.clone(),
            project_id: "team:uuid-stale".into(),
            members: vec![peer_proto::v1::TeamMember {
                name: "worker".into(),
                agent_instance_id: "worker-instance".into(),
                working_directory: "/tmp".into(),
                surface_id: member_surface_id.to_vec(),
                surface_type: "terminal".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert_eq!(
            host.upsert_project_presentation(&owner, &project(&first_member.surface_id)),
            Ok((1, true))
        );
        // What the old caller would have carried into the delete.
        let stale_read: Vec<Vec<u8>> = host
            .project_presentations()
            .iter()
            .find(|record| record.project_id == "team:uuid-stale")
            .map(PeerHost::presentation_surface_ids)
            .expect("published manifest");
        assert_eq!(
            host.upsert_project_presentation(&owner, &project(&next_member.surface_id)),
            Ok((2, true))
        );

        let released = host
            .delete_project_presentation_with_released(&owner, "team:uuid-stale")
            .expect("delete accepted");
        assert_eq!(
            released,
            Some(vec![
                leader.surface_id.clone(),
                next_member.surface_id.clone()
            ]),
            "the delete must release the record it removed"
        );
        assert_ne!(
            released,
            Some(stale_read),
            "a pre-delete read is exactly what must not decide the reap"
        );
        assert_eq!(
            host.delete_project_presentation_with_released(&owner, "team:uuid-stale"),
            Ok(None),
            "a second delete removes nothing and so releases nothing"
        );

        host.terminate_surface(&leader.surface_id).unwrap();
        host.terminate_surface(&first_member.surface_id).unwrap();
        host.terminate_surface(&next_member.surface_id).unwrap();
    }

    /// A delete releases the surfaces of the record it removed — never the
    /// ones an earlier read happened to see.
    ///
    /// Reading the manifest and then deleting it is two steps, and a replace
    /// fits between them: the delete takes the NEW record while the caller
    /// reaps the OLD one's surfaces, which both strands the pane that truly
    /// lost its last reference and aims the reap at a pane the owner just
    /// published. Both operations serialize on the persistence lock, so only
    /// two end states exist and each one pins its own release set exactly.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_replace_and_delete_release_only_the_removed_record() {
        let host = Arc::new(PeerHost::new(Arc::new(PtyManager::new())));
        let spec = SurfaceSpec {
            cwd: "/tmp".into(),
            executable: "/bin/cat".into(),
            args: Vec::new(),
            restart_policy: super::super::surface::EnsureRestartPolicy::Never,
            kind: super::super::surface::SurfaceKind::Pty,
            agent_cli: String::new(),
        };
        let leader = host.ensure_surface("race-leader", &spec).unwrap();
        let first_member = host.ensure_surface("race-member-first", &spec).unwrap();
        let next_member = host.ensure_surface("race-member-next", &spec).unwrap();
        let owner = vec![vec![5; 16]];
        let project = |member_surface_id: &[u8]| peer_proto::v1::Team {
            name: "race".into(),
            team_uuid: "uuid-race".into(),
            working_directory: "/tmp".into(),
            leader_surface_id: leader.surface_id.clone(),
            project_id: "team:uuid-race".into(),
            members: vec![peer_proto::v1::TeamMember {
                name: "worker".into(),
                agent_instance_id: "worker-instance".into(),
                working_directory: "/tmp".into(),
                surface_id: member_surface_id.to_vec(),
                surface_type: "terminal".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let before = project(&first_member.surface_id);
        let after = project(&next_member.surface_id);
        assert_eq!(
            host.upsert_project_presentation(&owner, &before),
            Ok((1, true))
        );

        let barrier = Arc::new(std::sync::Barrier::new(2));
        let deleting = {
            let host = Arc::clone(&host);
            let owner = owner.clone();
            let barrier = Arc::clone(&barrier);
            tokio::task::spawn_blocking(move || {
                barrier.wait();
                host.delete_project_presentation_with_released(&owner, "team:uuid-race")
            })
        };
        let replacing = {
            let host = Arc::clone(&host);
            let owner = owner.clone();
            let barrier = Arc::clone(&barrier);
            tokio::task::spawn_blocking(move || {
                barrier.wait();
                host.upsert_project_presentation(&owner, &after)
            })
        };
        let released = deleting.await.unwrap().expect("delete accepted");
        let replace_result = replacing.await.unwrap();

        let released_before = Some(vec![
            leader.surface_id.clone(),
            first_member.surface_id.clone(),
        ]);
        let released_after = Some(vec![
            leader.surface_id.clone(),
            next_member.surface_id.clone(),
        ]);
        let remaining = host.project_presentations();
        assert!(remaining.is_empty());
        if replace_result.is_ok() {
            // The replace landed first and the delete removed that exact
            // replacement. Its surfaces were retired atomically.
            assert_eq!(
                released, released_after,
                "the delete must release the record it actually removed"
            );
        } else {
            // The delete landed first and retired the shared leader. The
            // waiting replace must refuse to publish a dead surface.
            assert_eq!(replace_result, Err("leader_surface_missing"));
            assert_eq!(
                released, released_before,
                "the delete must release only the record it removed"
            );
        }

        host.terminate_surface(&leader.surface_id).unwrap();
        host.terminate_surface(&first_member.surface_id).unwrap();
        host.terminate_surface(&next_member.surface_id).unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_delete_and_new_presentation_never_publish_a_dead_surface() {
        let manager = Arc::new(PtyManager::new());
        let host = Arc::new(PeerHost::new(Arc::clone(&manager)));
        let leader = host.ensure_surface("delete-upsert-shared-leader", &SurfaceSpec {
            cwd: "/tmp".into(), executable: "/bin/cat".into(), args: Vec::new(),
            restart_policy: super::super::surface::EnsureRestartPolicy::Never,
            kind: super::super::surface::SurfaceKind::Pty, agent_cli: String::new(),
        }).unwrap();
        let owner = vec![vec![0x5A; 16]];
        let project = |project_id: &str| peer_proto::v1::Team {
            name: project_id.into(), team_uuid: format!("uuid-{project_id}"),
            working_directory: "/tmp".into(), leader_surface_id: leader.surface_id.clone(),
            project_id: format!("team:{project_id}"), ..Default::default()
        };
        assert_eq!(host.upsert_project_presentation(&owner, &project("before")), Ok((1, true)));
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let deleting = {
            let host = Arc::clone(&host); let owner = owner.clone(); let barrier = Arc::clone(&barrier);
            tokio::task::spawn_blocking(move || { barrier.wait(); host.delete_project_presentation_with_released(&owner, "team:before") })
        };
        let publishing = {
            let host = Arc::clone(&host); let owner = owner.clone(); let after = project("after"); let barrier = Arc::clone(&barrier);
            tokio::task::spawn_blocking(move || { barrier.wait(); host.upsert_project_presentation(&owner, &after) })
        };
        deleting.await.unwrap().unwrap();
        let publish_result = publishing.await.unwrap();
        let after_exists = host.project_presentations().iter().any(|record| record.project_id == "team:after");
        let leader_live = manager.list().iter().any(|surface| surface.surface_id == leader.surface_id);
        assert_eq!(after_exists, leader_live, "a published Project must never retain a deleted surface");
        if after_exists {
            assert!(publish_result.is_ok());
            host.delete_project_presentation_with_released(&owner, "team:after").unwrap();
        } else {
            assert_eq!(publish_result, Err("leader_surface_missing"));
        }
    }

    #[test]
    fn concurrent_workspace_mutations_persist_latest_complete_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-workspaces.json");
        let entries: Vec<_> = (0..16)
            .map(|index| PersistedWorkspace {
                id: sid(&format!("workspace-{index}")),
                name: format!("before-{index}"),
                is_default: index == 0,
            })
            .collect();
        let host = Arc::new(PeerHost::with_workspaces(
            Arc::new(PtyManager::new()),
            entries.clone(),
        ));
        host.set_persist_path(path.clone());
        let barrier = Arc::new(std::sync::Barrier::new(entries.len()));
        let workers: Vec<_> = entries
            .iter()
            .enumerate()
            .map(|(index, entry)| {
                let host = Arc::clone(&host);
                let barrier = Arc::clone(&barrier);
                let id = entry.id.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    assert!(host.rename_workspace(&id, format!("after-{index}")));
                })
            })
            .collect();
        for worker in workers {
            worker.join().unwrap();
        }

        let persisted = crate::peer::persist::load(&path);
        assert_eq!(persisted.len(), entries.len());
        for index in 0..entries.len() {
            let id = &entries[index].id;
            assert_eq!(
                persisted.iter().find(|entry| &entry.id == id).unwrap().name,
                format!("after-{index}")
            );
        }
    }
}
