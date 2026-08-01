//! Disk reclamation for the artifacts term-mesh leaves behind.
//!
//! Three subsystems create worktrees and none of them knows about the others:
//! the daemon's own `worktree::create` (`term-mesh_wt_<8hex>` under
//! `~/.term-mesh/worktrees`), `tm-agent delegate --worktree` by way of git-kit
//! (`~/.gk/worktree/...`), and `PeerProjectBootstrap` agent checkouts
//! (`<root>/<project>-<role>-<date>-<hex4>` on an `agent/*` branch). Add the
//! per-team result files, task boards and logs on top and a long-lived machine
//! ends up carrying tens of gigabytes nobody can account for.
//!
//! This module is the accounting layer. It never decides on its own that
//! something should disappear: a scan produces candidates carrying both the
//! `reasons` they look reclaimable and the `blockers` that forbid it, and a
//! sweep removes only candidates with zero blockers. Uncommitted work, commits
//! that exist nowhere else, and anything an active session or task still points
//! at are blockers, so the destructive path stays narrow by construction.
//!
//! The periodic sweep in `main.rs` is narrower still — see
//! [`periodic_safe_sweep`], which touches only categories that cannot contain
//! source changes.

use git2::Repository;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------------
// Categories
// ---------------------------------------------------------------------------

pub const CATEGORY_DAEMON_WORKTREES: &str = "daemon_worktrees";
pub const CATEGORY_GITKIT_WORKTREES: &str = "gitkit_worktrees";
pub const CATEGORY_PROJECT_CHECKOUTS: &str = "project_checkouts";
pub const CATEGORY_TEAM_RESULTS: &str = "team_results";
pub const CATEGORY_TEAM_BOARDS: &str = "team_boards";
pub const CATEGORY_HEADLESS_ARCHIVES: &str = "headless_archives";
pub const CATEGORY_WORKTREE_META: &str = "worktree_meta";
pub const CATEGORY_LOGS: &str = "logs";
pub const CATEGORY_BUILD_CACHES: &str = "build_caches";

/// Categories the unattended sweep is allowed to act on. Everything here is
/// derived state whose liveness the daemon can prove without app state. Team
/// boards are intentionally excluded: startup runs before Swift has synced the
/// live-team set, so age alone is not enough to delete one.
pub const AUTO_CATEGORIES: &[&str] =
    &[CATEGORY_TEAM_RESULTS, CATEGORY_WORKTREE_META, CATEGORY_LOGS];

pub const ALL_CATEGORIES: &[&str] = &[
    CATEGORY_DAEMON_WORKTREES,
    CATEGORY_GITKIT_WORKTREES,
    CATEGORY_PROJECT_CHECKOUTS,
    CATEGORY_TEAM_RESULTS,
    CATEGORY_TEAM_BOARDS,
    CATEGORY_HEADLESS_ARCHIVES,
    CATEGORY_WORKTREE_META,
    CATEGORY_LOGS,
    CATEGORY_BUILD_CACHES,
];

/// Results older than this are reclaimed. Matches the 24h contract the CLI
/// already advertises in its own `cleanup_old_results`.
pub const RESULTS_TTL: Duration = Duration::from_secs(24 * 60 * 60);
/// Task boards outlive the team by a wide margin so a resumed team still finds
/// its history; a month is far past any resume window.
pub const BOARD_TTL: Duration = Duration::from_secs(30 * 24 * 60 * 60);
/// Daemon logs in /tmp are only interesting while the daemon that wrote them
/// is alive. A week of silence means the writer is long gone.
pub const TMP_LOG_TTL: Duration = Duration::from_secs(7 * 24 * 60 * 60);
/// Append-only logs are rotated rather than deleted, so history survives one
/// more generation.
pub const LOG_ROTATE_BYTES: u64 = 10 * 1024 * 1024;

/// Ceiling on entries visited while sizing one candidate. Sizes are shown to
/// humans deciding what to reclaim, so a bounded estimate beats walking a
/// multi-million-file tree.
const SIZE_WALK_BUDGET: usize = 500_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileIdentity {
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
    #[cfg(not(unix))]
    modified_ms: u64,
    #[cfg(not(unix))]
    len: u64,
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct GcCandidate {
    pub path: String,
    pub bytes: u64,
    pub modified_ms: u64,
    /// `worktree` | `checkout` | `directory` | `file` | `worktree_meta`
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    /// Why this looks reclaimable.
    pub reasons: Vec<String>,
    /// Why it must not be touched. Non-empty means the sweep skips it.
    pub blockers: Vec<String>,
    /// Internal scan identity used to reject path-replacement races.
    #[serde(skip)]
    identity: Option<FileIdentity>,
}

impl GcCandidate {
    pub fn reclaimable(&self) -> bool {
        self.blockers.is_empty()
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct GcCategoryReport {
    pub category: String,
    pub roots: Vec<String>,
    pub entry_count: usize,
    pub total_bytes: u64,
    pub candidates: Vec<GcCandidate>,
    pub reclaimable_bytes: u64,
    /// True when the unattended periodic sweep covers this category.
    pub auto: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

impl GcCategoryReport {
    fn new(category: &str, roots: Vec<String>) -> Self {
        Self {
            category: category.to_string(),
            roots,
            entry_count: 0,
            total_bytes: 0,
            candidates: Vec::new(),
            reclaimable_bytes: 0,
            auto: AUTO_CATEGORIES.contains(&category),
            note: None,
        }
    }

    fn push(&mut self, candidate: GcCandidate) {
        self.entry_count += 1;
        self.total_bytes += candidate.bytes;
        if candidate.reclaimable() {
            self.reclaimable_bytes += candidate.bytes;
        }
        self.candidates.push(candidate);
    }

    pub fn reclaimable_count(&self) -> usize {
        self.candidates.iter().filter(|c| c.reclaimable()).count()
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct GcPlan {
    pub generated_at_ms: u64,
    pub categories: Vec<GcCategoryReport>,
    pub total_bytes: u64,
    pub reclaimable_bytes: u64,
}

/// Everything the daemon knows to be in use. Collected by the RPC handler from
/// the session database and the team state, then injected so the scan itself
/// stays a pure function of (filesystem, refs, clock).
#[derive(Debug, Clone, Default)]
pub struct GcRefs {
    /// Worktrees belonging to a live agent session.
    pub active_session_worktrees: HashSet<PathBuf>,
    /// Worktrees held by a task that has not finished.
    pub active_task_worktrees: HashSet<PathBuf>,
    /// Repos to inspect for stale worktree bookkeeping.
    pub repo_paths: Vec<PathBuf>,
    /// Team ids whose board must be kept regardless of age.
    pub active_team_uuids: HashSet<String>,
}

impl GcRefs {
    fn is_pinned(&self, path: &Path) -> Option<&'static str> {
        if self
            .active_session_worktrees
            .iter()
            .any(|active| same_path(active, path))
        {
            return Some("active_session");
        }
        if self
            .active_task_worktrees
            .iter()
            .any(|active| same_path(active, path))
        {
            return Some("active_task");
        }
        None
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct GcOptions {
    /// Restrict the scan to these category ids. Empty/absent means all.
    #[serde(default)]
    pub categories: Option<Vec<String>>,
    /// Extra directories to search for agent project checkouts.
    #[serde(default)]
    pub roots: Option<Vec<PathBuf>>,
    /// Size the build caches too. Off by default because it walks Xcode
    /// derived data, which is large and rarely what the caller asked about.
    #[serde(default)]
    pub deep: bool,
}

impl GcOptions {
    fn wants(&self, category: &str) -> bool {
        match &self.categories {
            Some(list) if !list.is_empty() => list.iter().any(|c| c == category),
            _ => true,
        }
    }
}

/// Where each category lives. Separated from the scanners so tests can point
/// the whole module at a throwaway tree.
#[derive(Debug, Clone)]
pub struct GcPaths {
    pub daemon_worktrees: PathBuf,
    pub gitkit_worktrees: PathBuf,
    pub results: PathBuf,
    pub teams: PathBuf,
    pub headless: PathBuf,
    pub logs: PathBuf,
    pub tmp: PathBuf,
    pub ghosttykit_cache: PathBuf,
    pub checkout_roots: Vec<PathBuf>,
}

impl GcPaths {
    pub fn from_home(home: &Path) -> Self {
        let term_mesh = home.join(".term-mesh");
        Self {
            daemon_worktrees: term_mesh.join("worktrees"),
            gitkit_worktrees: home.join(".gk").join("worktree"),
            results: term_mesh.join("results"),
            teams: term_mesh.join("teams"),
            headless: term_mesh.join("headless"),
            logs: term_mesh.join("logs"),
            tmp: PathBuf::from("/tmp"),
            ghosttykit_cache: home.join(".cache").join("term-mesh").join("ghosttykit"),
            checkout_roots: Vec::new(),
        }
    }
}

pub fn default_paths() -> Option<GcPaths> {
    dirs::home_dir().map(|home| GcPaths::from_home(&home))
}

#[derive(Debug, Clone, Serialize)]
pub struct SweepOutcome {
    pub path: String,
    pub category: String,
    /// `removed` | `rotated` | `would_remove` | `skipped`
    pub action: String,
    pub reason: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct SweepSummary {
    pub applied: bool,
    pub removed: usize,
    pub skipped: usize,
    pub reclaimed_bytes: u64,
    pub outcomes: Vec<SweepOutcome>,
}

// ---------------------------------------------------------------------------
// Sweep state (shared with gc.status)
// ---------------------------------------------------------------------------

/// Serializes sweeps. Two concurrent removals of the same tree race into
/// spurious "not found" errors, and a sweep is never urgent enough to queue.
static SWEEP_LOCK: Mutex<()> = Mutex::new(());

static LAST_SWEEP: Mutex<Option<LastSweep>> = Mutex::new(None);

#[derive(Debug, Clone, Serialize)]
pub struct LastSweep {
    pub at_ms: u64,
    pub mode: String,
    pub removed: usize,
    pub reclaimed_bytes: u64,
}

pub fn last_sweep() -> Option<LastSweep> {
    LAST_SWEEP.lock().ok().and_then(|guard| guard.clone())
}

fn record_sweep(mode: &str, summary: &SweepSummary) {
    if let Ok(mut guard) = LAST_SWEEP.lock() {
        *guard = Some(LastSweep {
            at_ms: now_ms(),
            mode: mode.to_string(),
            removed: summary.removed,
            reclaimed_bytes: summary.reclaimed_bytes,
        });
    }
}

// ---------------------------------------------------------------------------
// Plan
// ---------------------------------------------------------------------------

pub fn build_plan(paths: &GcPaths, opts: &GcOptions, refs: &GcRefs) -> GcPlan {
    build_plan_at(paths, opts, refs, SystemTime::now())
}

pub fn build_plan_at(paths: &GcPaths, opts: &GcOptions, refs: &GcRefs, now: SystemTime) -> GcPlan {
    let mut categories = Vec::new();

    if opts.wants(CATEGORY_DAEMON_WORKTREES) {
        categories.push(scan_daemon_worktrees(paths, refs));
    }
    if opts.wants(CATEGORY_GITKIT_WORKTREES) {
        categories.push(scan_gitkit_worktrees(paths, refs));
    }
    if opts.wants(CATEGORY_PROJECT_CHECKOUTS) {
        categories.push(scan_project_checkouts(paths, opts, refs));
    }
    if opts.wants(CATEGORY_TEAM_RESULTS) {
        categories.push(scan_team_results(paths, now));
    }
    if opts.wants(CATEGORY_TEAM_BOARDS) {
        categories.push(scan_team_boards(paths, refs, now));
    }
    if opts.wants(CATEGORY_HEADLESS_ARCHIVES) {
        categories.push(scan_headless_archives(paths));
    }
    if opts.wants(CATEGORY_WORKTREE_META) {
        categories.push(scan_worktree_meta(refs));
    }
    if opts.wants(CATEGORY_LOGS) {
        categories.push(scan_logs(paths, now));
    }
    if opts.wants(CATEGORY_BUILD_CACHES) {
        categories.push(scan_build_caches(paths, opts));
    }

    let total_bytes = categories.iter().map(|c| c.total_bytes).sum();
    let reclaimable_bytes = categories.iter().map(|c| c.reclaimable_bytes).sum();

    GcPlan {
        generated_at_ms: system_time_ms(now),
        categories,
        total_bytes,
        reclaimable_bytes,
    }
}

// ---------------------------------------------------------------------------
// Scanners
// ---------------------------------------------------------------------------

fn scan_daemon_worktrees(paths: &GcPaths, refs: &GcRefs) -> GcCategoryReport {
    let root = &paths.daemon_worktrees;
    let mut report = GcCategoryReport::new(CATEGORY_DAEMON_WORKTREES, vec![display(root)]);

    // Layout is <root>/<repo name>/term-mesh_wt_<8hex>.
    for repo_dir in real_subdirectories(root) {
        for entry in real_subdirectories(&repo_dir) {
            let name = file_name(&entry);
            if !is_daemon_worktree_name(&name) {
                continue;
            }
            report.push(worktree_candidate(&entry, "worktree", refs));
        }
    }
    report
}

fn scan_gitkit_worktrees(paths: &GcPaths, refs: &GcRefs) -> GcCategoryReport {
    let root = &paths.gitkit_worktrees;
    let mut report = GcCategoryReport::new(CATEGORY_GITKIT_WORKTREES, vec![display(root)]);

    // git-kit nests <project>/<branch...>, and branch names contain slashes, so
    // the depth is not fixed. Recurse until a linked worktree turns up and stop
    // descending there.
    for path in find_linked_worktrees(root, 4) {
        report.push(worktree_candidate(&path, "worktree", refs));
    }
    report
}

fn scan_project_checkouts(paths: &GcPaths, opts: &GcOptions, refs: &GcRefs) -> GcCategoryReport {
    let mut roots: Vec<PathBuf> = paths.checkout_roots.clone();
    if let Some(extra) = &opts.roots {
        roots.extend(extra.iter().cloned());
    }
    // The checkout sits next to the primary it was cut from.
    for repo in &refs.repo_paths {
        if let Some(parent) = repo.parent() {
            roots.push(parent.to_path_buf());
        }
    }
    roots.sort();
    roots.dedup();

    let mut report = GcCategoryReport::new(
        CATEGORY_PROJECT_CHECKOUTS,
        roots.iter().map(|r| display(r)).collect(),
    );

    let mut seen = HashSet::new();
    for root in &roots {
        for entry in real_subdirectories(root) {
            if !seen.insert(entry.clone()) {
                continue;
            }
            // Identify by structure, not by name: a linked worktree checked out
            // on an `agent/*` branch is one of ours no matter how it was named.
            if !is_linked_worktree(&entry) {
                continue;
            }
            let candidate = worktree_candidate(&entry, "checkout", refs);
            let is_agent_branch = candidate
                .branch
                .as_deref()
                .map(|b| b.starts_with("agent/"))
                .unwrap_or(false);
            if !is_agent_branch && !looks_like_agent_checkout(&file_name(&entry)) {
                continue;
            }
            report.push(candidate);
        }
    }
    report
}

fn scan_team_results(paths: &GcPaths, now: SystemTime) -> GcCategoryReport {
    let root = &paths.results;
    let mut report = GcCategoryReport::new(CATEGORY_TEAM_RESULTS, vec![display(root)]);
    report.note = Some("expired agent reply files (24h)".into());

    for team_dir in real_subdirectories(root) {
        let Ok(entries) = fs::read_dir(&team_dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(metadata) = fs::symlink_metadata(&path) else {
                continue;
            };
            if !metadata.file_type().is_file() {
                continue;
            }
            let Some(age) = age_of(&metadata, now) else {
                continue;
            };
            if age < RESULTS_TTL {
                continue;
            }
            report.push(GcCandidate {
                path: display(&path),
                bytes: metadata.len(),
                modified_ms: modified_ms(&metadata),
                kind: "file".into(),
                branch: None,
                reasons: vec!["expired".into()],
                blockers: Vec::new(),
                identity: Some(file_identity(&metadata)),
            });
        }
    }
    report
}

fn scan_team_boards(paths: &GcPaths, refs: &GcRefs, now: SystemTime) -> GcCategoryReport {
    let root = &paths.teams;
    let mut report = GcCategoryReport::new(CATEGORY_TEAM_BOARDS, vec![display(root)]);
    report.note = Some("task boards of teams that no longer exist (30d)".into());

    for dir in real_subdirectories(root) {
        let name = file_name(&dir);
        let mut blockers = Vec::new();
        if refs.active_team_uuids.contains(&name) {
            blockers.push("team_is_live".to_string());
        }
        // A live headless snapshot means the team can still be resumed.
        if paths.headless.join(&name).is_dir() {
            blockers.push("headless_snapshot_present".to_string());
        }
        let Ok(metadata) = fs::symlink_metadata(&dir) else {
            continue;
        };
        let Some(age) = age_of(&metadata, now) else {
            continue;
        };
        if age < BOARD_TTL {
            continue;
        }
        report.push(GcCandidate {
            path: display(&dir),
            bytes: dir_size(&dir),
            modified_ms: modified_ms(&metadata),
            kind: "directory".into(),
            branch: None,
            reasons: vec!["expired".into()],
            blockers,
            identity: Some(file_identity(&metadata)),
        });
    }
    report
}

fn scan_headless_archives(paths: &GcPaths) -> GcCategoryReport {
    let root = &paths.headless;
    let mut report = GcCategoryReport::new(CATEGORY_HEADLESS_ARCHIVES, vec![display(root)]);
    report.note = Some("owned by the headless GC (12h, 7d retention) — reported only".into());

    for dir in real_subdirectories(root) {
        if !file_name(&dir).contains(".archived.") {
            continue;
        }
        let Ok(metadata) = fs::symlink_metadata(&dir) else {
            continue;
        };
        report.push(GcCandidate {
            path: display(&dir),
            bytes: dir_size(&dir),
            modified_ms: modified_ms(&metadata),
            kind: "directory".into(),
            branch: None,
            reasons: Vec::new(),
            blockers: vec!["owned_by_headless_gc".into()],
            identity: Some(file_identity(&metadata)),
        });
    }
    report
}

fn scan_worktree_meta(refs: &GcRefs) -> GcCategoryReport {
    let mut report = GcCategoryReport::new(
        CATEGORY_WORKTREE_META,
        refs.repo_paths.iter().map(|p| display(p)).collect(),
    );
    report.note = Some("git worktree registrations whose working tree is gone".into());

    for repo_path in &refs.repo_paths {
        let Ok(repo) = Repository::open(repo_path) else {
            continue;
        };
        let Ok(names) = repo.worktrees() else {
            continue;
        };
        for name in names.iter().flatten() {
            let Ok(worktree) = repo.find_worktree(name) else {
                continue;
            };
            let wt_path = worktree.path().to_path_buf();
            if wt_path.exists() {
                continue;
            }
            report.push(GcCandidate {
                path: display(&wt_path),
                bytes: 0,
                modified_ms: 0,
                kind: "worktree_meta".into(),
                branch: None,
                reasons: vec![
                    "working_tree_missing".into(),
                    format!("repo={}", display(repo_path)),
                ],
                blockers: Vec::new(),
                identity: None,
            });
        }
    }
    report
}

fn scan_logs(paths: &GcPaths, now: SystemTime) -> GcCategoryReport {
    let mut report = GcCategoryReport::new(
        CATEGORY_LOGS,
        vec![display(&paths.logs), display(&paths.tmp)],
    );
    report.note = Some("oversized append-only logs are rotated, dead daemon logs removed".into());

    // Append-only logs under ~/.term-mesh/logs grow without bound.
    if let Ok(entries) = fs::read_dir(&paths.logs) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("log") {
                continue;
            }
            let Ok(metadata) = fs::symlink_metadata(&path) else {
                continue;
            };
            if !metadata.file_type().is_file() || metadata.len() < LOG_ROTATE_BYTES {
                continue;
            }
            report.push(GcCandidate {
                path: display(&path),
                bytes: metadata.len(),
                modified_ms: modified_ms(&metadata),
                kind: "file".into(),
                branch: None,
                reasons: vec!["oversized".into(), "rotate".into()],
                blockers: Vec::new(),
                identity: Some(file_identity(&metadata)),
            });
        }
    }

    // Daemon logs in /tmp belong to daemons that are no longer running. A live
    // daemon writes constantly, so a week of silence identifies a dead one.
    if let Ok(entries) = fs::read_dir(&paths.tmp) {
        for entry in entries.flatten() {
            let path = entry.path();
            let name = file_name(&path);
            let is_daemon_log = name.starts_with("term-meshd") && name.ends_with(".log");
            let is_debug_log = name.starts_with("term-mesh-debug") && name.ends_with(".log");
            if !is_daemon_log && !is_debug_log {
                continue;
            }
            let Ok(metadata) = fs::symlink_metadata(&path) else {
                continue;
            };
            if !metadata.file_type().is_file() {
                continue;
            }
            let Some(age) = age_of(&metadata, now) else {
                continue;
            };
            if age < TMP_LOG_TTL {
                continue;
            }
            report.push(GcCandidate {
                path: display(&path),
                bytes: metadata.len(),
                modified_ms: modified_ms(&metadata),
                kind: "file".into(),
                branch: None,
                reasons: vec!["writer_is_gone".into()],
                blockers: Vec::new(),
                identity: Some(file_identity(&metadata)),
            });
        }
    }

    report
}

fn scan_build_caches(paths: &GcPaths, opts: &GcOptions) -> GcCategoryReport {
    let mut report = GcCategoryReport::new(
        CATEGORY_BUILD_CACHES,
        vec![display(&paths.tmp), display(&paths.ghosttykit_cache)],
    );
    report.note =
        Some("reported only — reclaimed by scripts/reload.sh and scripts/setup.sh".into());
    if !opts.deep {
        report.note = Some("pass deep=true to size build caches".into());
        return report;
    }

    // Tagged debug builds: /tmp/term-mesh-<tag> carrying Xcode derived data.
    if let Ok(entries) = fs::read_dir(&paths.tmp) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !file_name(&path).starts_with("term-mesh-") {
                continue;
            }
            if !path.join("Build").is_dir() || is_symlink(&path) {
                continue;
            }
            let Ok(metadata) = fs::symlink_metadata(&path) else {
                continue;
            };
            report.push(GcCandidate {
                path: display(&path),
                bytes: dir_size(&path),
                modified_ms: modified_ms(&metadata),
                kind: "directory".into(),
                branch: None,
                reasons: vec!["tagged_debug_build".into()],
                blockers: vec!["owned_by_reload_script".into()],
                identity: Some(file_identity(&metadata)),
            });
        }
    }

    for dir in real_subdirectories(&paths.ghosttykit_cache) {
        let Ok(metadata) = fs::symlink_metadata(&dir) else {
            continue;
        };
        report.push(GcCandidate {
            path: display(&dir),
            bytes: dir_size(&dir),
            modified_ms: modified_ms(&metadata),
            kind: "directory".into(),
            branch: None,
            reasons: vec!["ghosttykit_cache".into()],
            blockers: vec!["owned_by_setup_script".into()],
            identity: Some(file_identity(&metadata)),
        });
    }

    report
}

// ---------------------------------------------------------------------------
// Worktree verdicts
// ---------------------------------------------------------------------------

/// Decide whether a worktree directory can go, and say why either way.
///
/// The blocker list is what keeps this safe. Anything that could represent
/// work-in-progress — uncommitted files, commits absent from the parent repo,
/// a session or task still pointing here — lands there, and the sweep honours
/// it even under `--apply`.
fn worktree_candidate(path: &Path, kind: &str, refs: &GcRefs) -> GcCandidate {
    let mut reasons = Vec::new();
    let mut blockers = Vec::new();
    let mut branch = None;
    let metadata = fs::symlink_metadata(path).ok();

    if let Some(pin) = refs.is_pinned(path) {
        blockers.push(pin.to_string());
    } else {
        reasons.push("no_active_session".into());
    }

    // The scanners reject symlinks, but an entry can be replaced after the
    // scan and before an apply pass reaches it. Check before Repository::open:
    // libgit2 follows directory symlinks and could otherwise inspect (or later
    // prune) an unrelated live worktree outside the managed tree.
    if metadata
        .as_ref()
        .map(|value| value.file_type().is_symlink())
        .unwrap_or(false)
    {
        blockers.push("path_is_symlink".into());
        return GcCandidate {
            path: display(path),
            bytes: 0,
            modified_ms: metadata.as_ref().map(modified_ms).unwrap_or(0),
            kind: kind.to_string(),
            branch,
            reasons,
            blockers,
            identity: metadata.as_ref().map(file_identity),
        };
    }

    match Repository::open(path) {
        Ok(repo) => {
            branch = repo
                .head()
                .ok()
                .and_then(|head| head.shorthand().map(|s| s.to_string()));

            match repo.statuses(Some(
                git2::StatusOptions::new()
                    .include_untracked(true)
                    .recurse_untracked_dirs(true),
            )) {
                Ok(statuses) if statuses.is_empty() => reasons.push("clean".into()),
                Ok(_) => blockers.push("uncommitted_changes".into()),
                Err(_) => blockers.push("status_unavailable".into()),
            }

            match unmerged_commits(&repo) {
                Some(0) => reasons.push("no_unmerged_commits".into()),
                Some(ahead) => blockers.push(format!("unmerged_commits={ahead}")),
                None => blockers.push("merge_state_unknown".into()),
            }
        }
        Err(_) if parent_gitdir_missing(path) => {
            // The repository this worktree belonged to is gone, so git cannot
            // prove that the checkout has no uncommitted files. Preserve it by
            // default; an operator can explicitly accept that uncertainty with
            // `--force`, which relaxes this single `unopenable` blocker.
            reasons.push("parent_repo_gone".into());
            blockers.push("unopenable".into());
        }
        Err(_) => blockers.push("unopenable".into()),
    }

    GcCandidate {
        path: display(path),
        bytes: dir_size(path),
        modified_ms: metadata.as_ref().map(modified_ms).unwrap_or(0),
        kind: kind.to_string(),
        branch,
        reasons,
        blockers,
        identity: metadata.as_ref().map(file_identity),
    }
}

/// Commits on this worktree's HEAD that exist nowhere else we can see.
///
/// Prefers the branch's upstream; falls back to the primary repository's HEAD
/// so a never-pushed agent branch is still compared against something real.
/// `None` means we could not establish a baseline — treated as a blocker.
fn unmerged_commits(repo: &Repository) -> Option<usize> {
    let head = repo.head().ok()?;
    let local_oid = head.target()?;

    if let Some(name) = head.shorthand() {
        if let Ok(branch) = repo.find_branch(name, git2::BranchType::Local) {
            if let Ok(upstream) = branch.upstream() {
                if let Some(upstream_oid) = upstream.get().target() {
                    return repo
                        .graph_ahead_behind(local_oid, upstream_oid)
                        .ok()
                        .map(|(ahead, _)| ahead);
                }
            }
        }
    }

    // No upstream: compare against the repository this worktree was cut from.
    // For a linked worktree `repo.path()` is `<main>/.git/worktrees/<name>/`,
    // so three levels up is the primary working directory.
    let primary = repo
        .path()
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)?;
    let primary_repo = Repository::open(primary).ok()?;
    let primary_oid = primary_repo.head().ok()?.target()?;
    repo.graph_ahead_behind(local_oid, primary_oid)
        .ok()
        .map(|(ahead, _)| ahead)
}

/// True when `.git` is a file pointing at a gitdir that no longer exists.
fn parent_gitdir_missing(path: &Path) -> bool {
    let git_file = path.join(".git");
    let Ok(metadata) = fs::symlink_metadata(&git_file) else {
        return false;
    };
    if !metadata.file_type().is_file() {
        return false;
    }
    let Ok(contents) = fs::read_to_string(&git_file) else {
        return false;
    };
    let Some(target) = contents.trim().strip_prefix("gitdir:") else {
        return false;
    };
    !Path::new(target.trim()).exists()
}

fn is_linked_worktree(path: &Path) -> bool {
    let git_file = path.join(".git");
    fs::symlink_metadata(&git_file)
        .map(|m| m.file_type().is_file())
        .unwrap_or(false)
}

/// `<project>-<role>-<yyMMdd>-<hex4>`, the shape `PeerProjectBootstrap` mints.
fn looks_like_agent_checkout(name: &str) -> bool {
    let parts: Vec<&str> = name.rsplitn(3, '-').collect();
    if parts.len() < 3 {
        return false;
    }
    let suffix = parts[0];
    let date = parts[1];
    suffix.len() == 4
        && suffix.bytes().all(|b| b.is_ascii_hexdigit())
        && date.len() == 6
        && date.bytes().all(|b| b.is_ascii_digit())
}

fn is_daemon_worktree_name(name: &str) -> bool {
    let Some(suffix) = name.strip_prefix("term-mesh_wt_") else {
        return false;
    };
    suffix.len() == 8 && suffix.bytes().all(|b| b.is_ascii_hexdigit())
}

fn find_linked_worktrees(root: &Path, depth: usize) -> Vec<PathBuf> {
    let mut found = Vec::new();
    if depth == 0 {
        return found;
    }
    for dir in real_subdirectories(root) {
        if is_linked_worktree(&dir) {
            found.push(dir);
        } else {
            found.extend(find_linked_worktrees(&dir, depth - 1));
        }
    }
    found
}

// ---------------------------------------------------------------------------
// Sweep
// ---------------------------------------------------------------------------

/// Act on a plan. With `apply == false` nothing is touched and every
/// reclaimable candidate comes back as `would_remove`.
///
/// `force` relaxes exactly one blocker — `unopenable`, where git cannot answer
/// and the operator has decided anyway. Every other blocker holds.
pub fn execute_sweep(
    paths: &GcPaths,
    plan: &GcPlan,
    apply: bool,
    force: bool,
    current_refs: &GcRefs,
) -> Result<SweepSummary, String> {
    // Rust runs independent `#[test]` functions concurrently in one process.
    // They all exercise this process-global lock, so a non-blocking acquire
    // would make otherwise unrelated GC tests fail depending on scheduling.
    // Production keeps the non-blocking contract: a second caller gets a
    // deterministic `GC_BUSY` instead of waiting behind a long filesystem walk.
    #[cfg(test)]
    let _guard = SWEEP_LOCK
        .lock()
        .map_err(|_| "GC_BUSY: sweep lock is poisoned".to_string())?;
    #[cfg(not(test))]
    let _guard = SWEEP_LOCK
        .try_lock()
        .map_err(|_| "GC_BUSY: another sweep is already running".to_string())?;

    let mut summary = SweepSummary {
        applied: apply,
        ..Default::default()
    };

    for category in &plan.categories {
        // Results, boards and logs can change while a large worktree scan is
        // running. Re-scan each managed non-worktree category once immediately
        // before acting on it. A candidate that disappeared, became fresh,
        // gained a liveness blocker, or moved behind a symlink is no longer in
        // scope for this sweep.
        let refreshed_category = if apply {
            match category.category.as_str() {
                CATEGORY_TEAM_RESULTS => Some(scan_team_results(paths, SystemTime::now())),
                CATEGORY_TEAM_BOARDS => {
                    Some(scan_team_boards(paths, current_refs, SystemTime::now()))
                }
                CATEGORY_LOGS => Some(scan_logs(paths, SystemTime::now())),
                _ => None,
            }
        } else {
            None
        };

        for candidate in &category.candidates {
            if !candidate_allowed(candidate, force) {
                summary.skipped += 1;
                summary.outcomes.push(SweepOutcome {
                    path: candidate.path.clone(),
                    category: category.category.clone(),
                    action: "skipped".into(),
                    reason: candidate.blockers.join(","),
                    bytes: candidate.bytes,
                });
                continue;
            }

            if !apply {
                summary.outcomes.push(SweepOutcome {
                    path: candidate.path.clone(),
                    category: category.category.clone(),
                    action: "would_remove".into(),
                    reason: candidate.reasons.join(","),
                    bytes: candidate.bytes,
                });
                summary.reclaimed_bytes += candidate.bytes;
                summary.removed += 1;
                continue;
            }

            // A full scan can take long enough for a clean idle worktree to
            // become dirty or active before its turn in the sweep. Never let a
            // stale plan expand what is removable: only candidates accepted by
            // the original plan reach here, and worktrees are then checked
            // again against the current filesystem and current daemon refs.
            let refreshed_worktree;
            let candidate = if candidate.kind == "worktree" || candidate.kind == "checkout" {
                refreshed_worktree =
                    worktree_candidate(Path::new(&candidate.path), &candidate.kind, current_refs);
                if candidate.identity != refreshed_worktree.identity {
                    summary.skipped += 1;
                    summary.outcomes.push(SweepOutcome {
                        path: candidate.path.clone(),
                        category: category.category.clone(),
                        action: "skipped".into(),
                        reason: "candidate_replaced_since_plan".into(),
                        bytes: candidate.bytes,
                    });
                    continue;
                }
                if !candidate_allowed(&refreshed_worktree, force) {
                    summary.skipped += 1;
                    summary.outcomes.push(SweepOutcome {
                        path: refreshed_worktree.path.clone(),
                        category: category.category.clone(),
                        action: "skipped".into(),
                        reason: refreshed_worktree.blockers.join(","),
                        bytes: refreshed_worktree.bytes,
                    });
                    continue;
                }
                &refreshed_worktree
            } else if let Some(refreshed) = &refreshed_category {
                let Some(current) = refreshed
                    .candidates
                    .iter()
                    .find(|current| current.path == candidate.path)
                else {
                    summary.skipped += 1;
                    summary.outcomes.push(SweepOutcome {
                        path: candidate.path.clone(),
                        category: category.category.clone(),
                        action: "skipped".into(),
                        reason: "candidate_changed_or_no_longer_eligible".into(),
                        bytes: candidate.bytes,
                    });
                    continue;
                };
                if candidate.identity != current.identity {
                    summary.skipped += 1;
                    summary.outcomes.push(SweepOutcome {
                        path: candidate.path.clone(),
                        category: category.category.clone(),
                        action: "skipped".into(),
                        reason: "candidate_replaced_since_plan".into(),
                        bytes: candidate.bytes,
                    });
                    continue;
                }
                if !candidate_allowed(current, force) {
                    summary.skipped += 1;
                    summary.outcomes.push(SweepOutcome {
                        path: current.path.clone(),
                        category: category.category.clone(),
                        action: "skipped".into(),
                        reason: current.blockers.join(","),
                        bytes: current.bytes,
                    });
                    continue;
                }
                current
            } else {
                candidate
            };

            match reclaim(candidate, &category.category) {
                Ok(action) => {
                    summary.removed += 1;
                    summary.reclaimed_bytes += candidate.bytes;
                    summary.outcomes.push(SweepOutcome {
                        path: candidate.path.clone(),
                        category: category.category.clone(),
                        action,
                        reason: candidate.reasons.join(","),
                        bytes: candidate.bytes,
                    });
                }
                Err(error) => {
                    summary.skipped += 1;
                    summary.outcomes.push(SweepOutcome {
                        path: candidate.path.clone(),
                        category: category.category.clone(),
                        action: "skipped".into(),
                        reason: error,
                        bytes: candidate.bytes,
                    });
                }
            }
        }
    }

    if apply {
        record_sweep("apply", &summary);
        log_sweep(&paths.logs, "apply", &summary);
    }
    Ok(summary)
}

fn candidate_allowed(candidate: &GcCandidate, force: bool) -> bool {
    candidate.reclaimable()
        || (force && candidate.blockers.len() == 1 && candidate.blockers[0] == "unopenable")
}

fn reclaim(candidate: &GcCandidate, category: &str) -> Result<String, String> {
    let path = PathBuf::from(&candidate.path);

    if category == CATEGORY_WORKTREE_META {
        return prune_worktree_meta(candidate).map(|_| "removed".to_string());
    }

    if candidate.reasons.iter().any(|r| r == "rotate") {
        return rotate_log(&path).map(|_| "rotated".to_string());
    }

    let is_worktree = candidate.kind == "worktree" || candidate.kind == "checkout";

    // Never ask git/libgit2 to remove the working tree itself. The path may
    // have been replaced after the candidate refresh, and libgit2 follows a
    // directory symlink while resolving the linked checkout. Inspect the
    // path first, read only the registration owner, then use std's
    // symlink-safe removal and prune the now-dangling registration below.
    let metadata = fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
    if metadata.file_type().is_symlink() {
        return Err("refusing to remove a symlink".into());
    }
    if candidate.identity != Some(file_identity(&metadata)) {
        return Err("candidate_replaced_after_refresh".into());
    }

    // The registration has to be read before the directory goes: `.git` is
    // what names the owning repository. If that pointer now names a different
    // live worktree, the candidate was replaced after its refresh and must not
    // be removed. Missing parent repositories remain removable only through
    // the existing explicit `--force` path.
    let owner = if is_worktree {
        let owner = verified_worktree_owner(&path)?;
        if owner.is_none() && !candidate.reasons.iter().any(|r| r == "parent_repo_gone") {
            return Err("refusing to remove a worktree whose registration vanished".into());
        }
        owner
    } else {
        None
    };

    if metadata.file_type().is_dir() {
        fs::remove_dir_all(&path).map_err(|e| e.to_string())?;
    } else {
        fs::remove_file(&path).map_err(|e| e.to_string())?;
    }

    // Drop the now-dangling registration, or `git worktree list` keeps
    // reporting it as `prunable` and the branch cannot be checked out again.
    if let Some((repo_root, name)) = owner {
        prune_registration(&repo_root, &name, false);
    }
    Ok("removed".to_string())
}

/// `(owning repository, worktree name)` read out of a linked worktree's
/// `.git` pointer file, which reads `gitdir: <main>/.git/worktrees/<name>`.
fn worktree_owner(path: &Path) -> Option<(PathBuf, String)> {
    let contents = fs::read_to_string(path.join(".git")).ok()?;
    let target = contents.trim().strip_prefix("gitdir:")?.trim();
    let gitdir = Path::new(target);
    let name = gitdir.file_name()?.to_str()?.to_string();
    let main_root = gitdir.parent()?.parent()?.parent()?.to_path_buf();
    Some((main_root, name))
}

fn verified_worktree_owner(path: &Path) -> Result<Option<(PathBuf, String)>, String> {
    let Some((repo_root, name)) = worktree_owner(path) else {
        return Ok(None);
    };
    let Ok(repo) = Repository::open(&repo_root) else {
        return Ok(None);
    };
    let Ok(worktree) = repo.find_worktree(&name) else {
        return Ok(None);
    };

    let registered = worktree.path();
    let same_path = match (fs::canonicalize(path), fs::canonicalize(registered)) {
        (Ok(candidate), Ok(registered)) => candidate == registered,
        _ => path == registered,
    };
    if !same_path {
        return Err(format!(
            "refusing to remove a worktree whose registration points at {}",
            registered.display()
        ));
    }

    Ok(Some((repo_root, name)))
}

fn prune_registration(repo_root: &Path, name: &str, with_working_tree: bool) -> Option<()> {
    let repo = Repository::open(repo_root).ok()?;
    let worktree = repo.find_worktree(name).ok()?;
    worktree
        .prune(Some(
            git2::WorktreePruneOptions::new()
                .valid(true)
                .working_tree(with_working_tree),
        ))
        .ok()?;
    Some(())
}

fn prune_worktree_meta(candidate: &GcCandidate) -> Result<(), String> {
    // The scan recorded the owning repo alongside the reason so the prune does
    // not have to rediscover it.
    let repo_path = candidate
        .reasons
        .iter()
        .find_map(|r| r.strip_prefix("repo="))
        .ok_or_else(|| "missing repo reference".to_string())?;
    let repo = Repository::open(repo_path).map_err(|e| e.to_string())?;
    let target = PathBuf::from(&candidate.path);

    // A checkout can be recreated after the scan. Never prune its registration
    // from a stale plan. `symlink_metadata` also treats a broken symlink as an
    // occupant, which is the conservative answer at a deletion boundary.
    if fs::symlink_metadata(&target).is_ok() {
        return Err("worktree path exists again".into());
    }

    let names = repo.worktrees().map_err(|e| e.to_string())?;
    for name in names.iter().flatten() {
        let Ok(worktree) = repo.find_worktree(name) else {
            continue;
        };
        if worktree.path() != target {
            continue;
        }
        return worktree
            .prune(Some(git2::WorktreePruneOptions::new().valid(true)))
            .map_err(|e| e.to_string());
    }
    Err("worktree registration no longer present".into())
}

fn rotate_log(path: &Path) -> Result<(), String> {
    let rotated = path.with_extension("log.1");
    let _ = fs::remove_file(&rotated);
    fs::rename(path, &rotated).map_err(|e| e.to_string())
}

/// The unattended sweep. Restricted to [`AUTO_CATEGORIES`], so it can never
/// remove a worktree or a checkout no matter what the scan turned up.
pub fn periodic_safe_sweep(paths: &GcPaths, refs: &GcRefs) -> Result<SweepSummary, String> {
    let opts = GcOptions {
        categories: Some(AUTO_CATEGORIES.iter().map(|c| c.to_string()).collect()),
        roots: None,
        deep: false,
    };
    let plan = build_plan(paths, &opts, refs);
    let summary = execute_sweep(paths, &plan, true, false, refs)?;
    record_sweep("periodic", &summary);
    Ok(summary)
}

/// Append one line per sweep to `<logs>/gc.log`. Best effort.
///
/// Takes the directory rather than resolving the home directory itself so a
/// test sweep writes into its own tree instead of the developer's home.
fn log_sweep(dir: &Path, mode: &str, summary: &SweepSummary) {
    if fs::create_dir_all(dir).is_err() {
        return;
    }
    let entry = serde_json::json!({
        "at_ms": now_ms(),
        "mode": mode,
        "removed": summary.removed,
        "skipped": summary.skipped,
        "reclaimed_bytes": summary.reclaimed_bytes,
    });
    use std::io::Write;
    if let Ok(mut file) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("gc.log"))
    {
        let _ = writeln!(file, "{entry}");
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn display(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[cfg(unix)]
fn file_identity(metadata: &fs::Metadata) -> FileIdentity {
    use std::os::unix::fs::MetadataExt;

    FileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    }
}

#[cfg(not(unix))]
fn file_identity(metadata: &fs::Metadata) -> FileIdentity {
    FileIdentity {
        modified_ms: modified_ms(metadata),
        len: metadata.len(),
    }
}

fn same_path(left: &Path, right: &Path) -> bool {
    if left == right {
        return true;
    }
    match (fs::canonicalize(left), fs::canonicalize(right)) {
        (Ok(left), Ok(right)) => left == right,
        _ => false,
    }
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn is_symlink(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
}

/// Direct subdirectories, symlinks excluded. Every scanner goes through this so
/// a symlinked entry can never redirect a sweep outside the managed tree.
fn real_subdirectories(root: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(root) else {
        return Vec::new();
    };
    let mut dirs = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if metadata.file_type().is_dir() {
            dirs.push(path);
        }
    }
    dirs.sort();
    dirs
}

fn dir_size(path: &Path) -> u64 {
    let mut total = 0u64;
    let mut visited = 0usize;
    let mut stack = vec![path.to_path_buf()];

    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            if visited >= SIZE_WALK_BUDGET {
                return total;
            }
            visited += 1;
            // DirEntry::metadata does not traverse symlinks, so a link counts
            // as its own small size rather than its target's.
            let Ok(metadata) = entry.metadata() else {
                continue;
            };
            if metadata.file_type().is_dir() {
                stack.push(entry.path());
            } else {
                total += metadata.len();
            }
        }
    }
    total
}

fn age_of(metadata: &fs::Metadata, now: SystemTime) -> Option<Duration> {
    let modified = metadata.modified().ok()?;
    now.duration_since(modified).ok()
}

fn modified_ms(metadata: &fs::Metadata) -> u64 {
    metadata
        .modified()
        .ok()
        .map(system_time_ms)
        .unwrap_or_default()
}

fn system_time_ms(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or_default()
}

fn now_ms() -> u64 {
    system_time_ms(SystemTime::now())
}

/// Convenience for callers that only need the headline numbers.
pub fn summarize(plan: &GcPlan) -> serde_json::Value {
    serde_json::json!({
        "categories": plan.categories.iter().map(|c| serde_json::json!({
            "category": c.category,
            "entry_count": c.entry_count,
            "candidate_count": c.reclaimable_count(),
            "total_bytes": c.total_bytes,
            "reclaimable_bytes": c.reclaimable_bytes,
            "auto": c.auto,
            "note": c.note,
        })).collect::<Vec<_>>(),
        "total_bytes": plan.total_bytes,
        "reclaimable_bytes": plan.reclaimable_bytes,
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn git(args: &[&str], cwd: &Path) {
        let out = Command::new("git")
            .args(args)
            .current_dir(cwd)
            .output()
            .expect("git runs");
        assert!(
            out.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    /// A primary repo with one commit, plus the empty worktree base directory.
    fn init_repo(root: &Path) -> PathBuf {
        let repo = root.join("repo");
        fs::create_dir_all(&repo).unwrap();
        git(&["init", "-b", "main"], &repo);
        git(&["config", "user.email", "t@t.test"], &repo);
        git(&["config", "user.name", "T"], &repo);
        fs::write(repo.join("README.md"), "# test\n").unwrap();
        git(&["add", "."], &repo);
        git(&["commit", "-m", "init"], &repo);
        repo
    }

    fn add_worktree(repo: &Path, path: &Path, branch: &str) {
        git(
            &[
                "worktree",
                "add",
                "-b",
                branch,
                path.to_str().unwrap(),
                "HEAD",
            ],
            repo,
        );
    }

    fn paths_for(root: &Path) -> GcPaths {
        let mut paths = GcPaths::from_home(root);
        paths.tmp = root.join("tmp");
        fs::create_dir_all(&paths.tmp).unwrap();
        paths
    }

    fn only(category: &str) -> GcOptions {
        GcOptions {
            categories: Some(vec![category.to_string()]),
            roots: None,
            deep: false,
        }
    }

    fn category<'a>(plan: &'a GcPlan, name: &str) -> &'a GcCategoryReport {
        plan.categories
            .iter()
            .find(|c| c.category == name)
            .expect("category present")
    }

    #[test]
    fn a_clean_idle_worktree_is_reclaimable() {
        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let paths = paths_for(temp.path());
        let wt = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_0011aabb");
        fs::create_dir_all(wt.parent().unwrap()).unwrap();
        add_worktree(&repo, &wt, "term-mesh/0011aabb");

        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());
        let report = category(&plan, CATEGORY_DAEMON_WORKTREES);
        assert_eq!(report.entry_count, 1);
        let candidate = &report.candidates[0];
        assert!(
            candidate.reclaimable(),
            "blockers: {:?}",
            candidate.blockers
        );
        assert!(candidate.reasons.iter().any(|r| r == "clean"));
    }

    #[test]
    fn removing_a_worktree_also_drops_its_registration() {
        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let paths = paths_for(temp.path());
        let wt = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_0011aabb");
        fs::create_dir_all(wt.parent().unwrap()).unwrap();
        add_worktree(&repo, &wt, "term-mesh/0011aabb");

        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());
        assert_eq!(
            execute_sweep(&paths, &plan, true, false, &GcRefs::default())
                .unwrap()
                .removed,
            1
        );

        assert!(!wt.exists());
        // A directory-only delete would leave git holding a prunable entry.
        let handle = Repository::open(&repo).unwrap();
        assert_eq!(
            handle.worktrees().unwrap().len(),
            0,
            "the worktree registration must be gone too"
        );
    }

    /// git refuses to remove a working tree containing submodules, and this
    /// repository has one (`ghostty`) — so every real term-mesh worktree hits
    /// that path. Deleting the directory without pruning afterwards is what
    /// leaves `git worktree list` full of `prunable` entries.
    #[test]
    fn a_worktree_with_a_submodule_is_still_fully_reclaimed() {
        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let sub = init_repo(&temp.path().join("sub-src"));
        git(
            &[
                "-c",
                "protocol.file.allow=always",
                "submodule",
                "add",
                sub.to_str().unwrap(),
                "vendored",
            ],
            &repo,
        );
        git(&["commit", "-m", "add submodule"], &repo);

        let paths = paths_for(temp.path());
        let wt = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_5ab00001");
        fs::create_dir_all(wt.parent().unwrap()).unwrap();
        add_worktree(&repo, &wt, "term-mesh/5ab00001");
        // An initialized submodule is what triggers git's refusal — and it
        // leaves the worktree clean, so nothing else blocks the sweep.
        git(
            &[
                "-c",
                "protocol.file.allow=always",
                "submodule",
                "update",
                "--init",
            ],
            &wt,
        );

        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());
        let candidate = &category(&plan, CATEGORY_DAEMON_WORKTREES).candidates[0];
        assert!(
            candidate.reclaimable(),
            "a clean worktree must not be blocked by its submodule: {:?}",
            candidate.blockers
        );
        assert_eq!(
            execute_sweep(&paths, &plan, true, false, &GcRefs::default())
                .unwrap()
                .removed,
            1
        );

        assert!(!wt.exists(), "the directory must go even when git will not");
        let handle = Repository::open(&repo).unwrap();
        assert_eq!(
            handle.worktrees().unwrap().len(),
            0,
            "and the registration must not be left behind as prunable"
        );
    }

    #[test]
    fn uncommitted_changes_block_removal() {
        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let paths = paths_for(temp.path());
        let wt = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_0011aabb");
        fs::create_dir_all(wt.parent().unwrap()).unwrap();
        add_worktree(&repo, &wt, "term-mesh/0011aabb");
        fs::write(wt.join("scratch.txt"), "unsaved work").unwrap();

        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());
        let candidate = &category(&plan, CATEGORY_DAEMON_WORKTREES).candidates[0];
        assert!(candidate
            .blockers
            .iter()
            .any(|b| b == "uncommitted_changes"));

        // Even an apply pass must leave it alone.
        let summary = execute_sweep(&paths, &plan, true, false, &GcRefs::default()).unwrap();
        assert_eq!(summary.removed, 0);
        assert!(wt.exists());
    }

    #[test]
    fn worktree_that_becomes_dirty_after_planning_is_preserved() {
        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let paths = paths_for(temp.path());
        let wt = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_0011aabb");
        fs::create_dir_all(wt.parent().unwrap()).unwrap();
        add_worktree(&repo, &wt, "term-mesh/0011aabb");

        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());
        assert!(category(&plan, CATEGORY_DAEMON_WORKTREES).candidates[0].reclaimable());

        fs::write(wt.join("scratch.txt"), "created after the scan\n").unwrap();
        // `--force` relaxes the refreshed `unopenable` blocker, so this
        // reaches the final registration-identity guard in `reclaim`.
        let summary = execute_sweep(&paths, &plan, true, true, &GcRefs::default()).unwrap();

        assert_eq!(summary.removed, 0);
        assert_eq!(summary.skipped, 1);
        assert!(summary.outcomes[0].reason.contains("uncommitted_changes"));
        assert!(wt.join("scratch.txt").exists());
    }

    #[test]
    fn commits_missing_from_the_parent_repo_block_removal() {
        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let paths = paths_for(temp.path());
        let wt = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_00c0ffee");
        fs::create_dir_all(wt.parent().unwrap()).unwrap();
        add_worktree(&repo, &wt, "term-mesh/00c0ffee");
        fs::write(wt.join("feature.txt"), "done\n").unwrap();
        git(&["add", "."], &wt);
        git(&["commit", "-m", "agent work"], &wt);

        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());
        let candidate = &category(&plan, CATEGORY_DAEMON_WORKTREES).candidates[0];
        assert!(
            candidate
                .blockers
                .iter()
                .any(|b| b.starts_with("unmerged_commits")),
            "blockers: {:?}",
            candidate.blockers
        );
    }

    #[test]
    fn an_active_session_pins_its_worktree() {
        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let paths = paths_for(temp.path());
        let wt = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_0011aabb");
        fs::create_dir_all(wt.parent().unwrap()).unwrap();
        add_worktree(&repo, &wt, "term-mesh/0011aabb");

        let refs = GcRefs {
            active_session_worktrees: [wt.clone()].into_iter().collect(),
            ..Default::default()
        };
        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &refs);
        let candidate = &category(&plan, CATEGORY_DAEMON_WORKTREES).candidates[0];
        assert!(candidate.blockers.iter().any(|b| b == "active_session"));
    }

    #[test]
    fn an_active_session_pins_the_same_canonical_worktree_path() {
        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let paths = paths_for(temp.path());
        let wt = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_0011aabb");
        fs::create_dir_all(wt.parent().unwrap()).unwrap();
        add_worktree(&repo, &wt, "term-mesh/0011aabb");
        let aliased = wt
            .parent()
            .unwrap()
            .join("..")
            .join("repo")
            .join("term-mesh_wt_0011aabb");
        let refs = GcRefs {
            active_session_worktrees: [aliased].into_iter().collect(),
            ..Default::default()
        };

        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &refs);
        let candidate = &category(&plan, CATEGORY_DAEMON_WORKTREES).candidates[0];
        assert!(candidate.blockers.iter().any(|b| b == "active_session"));
    }

    #[test]
    fn a_worktree_whose_repo_vanished_requires_force() {
        // The shape the leaked unit-test worktrees take: .git points at a
        // gitdir under a deleted temp directory.
        let temp = tempfile::tempdir().unwrap();
        let paths = paths_for(temp.path());
        let wt = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_deadbeef");
        fs::create_dir_all(&wt).unwrap();
        fs::write(wt.join("scratch.txt"), "possibly valuable\n").unwrap();
        fs::write(
            wt.join(".git"),
            "gitdir: /nonexistent/repo/.git/worktrees/term-mesh_wt_deadbeef\n",
        )
        .unwrap();

        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());
        let candidate = &category(&plan, CATEGORY_DAEMON_WORKTREES).candidates[0];
        assert!(!candidate.reclaimable());
        assert!(candidate.reasons.iter().any(|r| r == "parent_repo_gone"));
        assert_eq!(candidate.blockers, ["unopenable"]);

        let summary = execute_sweep(&paths, &plan, true, false, &GcRefs::default()).unwrap();
        assert_eq!(summary.removed, 0);
        assert!(
            wt.exists(),
            "default apply must preserve unverifiable files"
        );

        let summary = execute_sweep(&paths, &plan, true, true, &GcRefs::default()).unwrap();
        assert_eq!(summary.removed, 1);
        assert!(!wt.exists(), "force explicitly accepts the unopenable risk");
    }

    #[test]
    fn names_outside_the_managed_shape_are_ignored() {
        let temp = tempfile::tempdir().unwrap();
        let paths = paths_for(temp.path());
        let repo_dir = paths.daemon_worktrees.join("repo");
        fs::create_dir_all(repo_dir.join("term-mesh_wt_short")).unwrap();
        fs::create_dir_all(repo_dir.join("term-mesh_wt_zzzzzzzz")).unwrap();
        fs::create_dir_all(repo_dir.join("my-own-checkout")).unwrap();

        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());
        assert_eq!(category(&plan, CATEGORY_DAEMON_WORKTREES).entry_count, 0);
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_entries_are_never_candidates() {
        use std::os::unix::fs::symlink;

        let temp = tempfile::tempdir().unwrap();
        let paths = paths_for(temp.path());
        let repo_dir = paths.daemon_worktrees.join("repo");
        fs::create_dir_all(&repo_dir).unwrap();
        let precious = temp.path().join("precious");
        fs::create_dir_all(&precious).unwrap();
        symlink(&precious, repo_dir.join("term-mesh_wt_00001111")).unwrap();

        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());
        assert_eq!(category(&plan, CATEGORY_DAEMON_WORKTREES).entry_count, 0);
        assert!(precious.exists());
    }

    #[cfg(unix)]
    #[test]
    fn worktree_replaced_by_a_symlink_after_planning_is_preserved() {
        use std::os::unix::fs::symlink;

        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let paths = paths_for(temp.path());
        let wt = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_0011aabb");
        fs::create_dir_all(wt.parent().unwrap()).unwrap();
        add_worktree(&repo, &wt, "term-mesh/0011aabb");
        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());

        fs::remove_dir_all(&wt).unwrap();
        let precious = temp.path().join("precious");
        fs::create_dir_all(&precious).unwrap();
        fs::write(precious.join("keep.txt"), "keep\n").unwrap();
        symlink(&precious, &wt).unwrap();

        let summary = execute_sweep(&paths, &plan, true, false, &GcRefs::default()).unwrap();
        assert_eq!(summary.removed, 0);
        assert_eq!(summary.outcomes[0].reason, "candidate_replaced_since_plan");
        assert!(precious.join("keep.txt").exists());
    }

    #[test]
    fn worktree_replaced_by_another_registration_after_planning_is_preserved() {
        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let paths = paths_for(temp.path());
        let candidate = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_0011aabb");
        fs::create_dir_all(candidate.parent().unwrap()).unwrap();
        add_worktree(&repo, &candidate, "term-mesh/0011aabb");
        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());

        let other = temp.path().join("other-worktree");
        add_worktree(&repo, &other, "term-mesh/other");
        let other_git_pointer = fs::read_to_string(other.join(".git")).unwrap();
        fs::remove_dir_all(&candidate).unwrap();
        fs::create_dir_all(&candidate).unwrap();
        fs::write(candidate.join(".git"), other_git_pointer).unwrap();

        let summary = execute_sweep(&paths, &plan, true, true, &GcRefs::default()).unwrap();
        assert_eq!(summary.removed, 0);
        assert_eq!(summary.skipped, 1);
        assert_eq!(summary.outcomes[0].reason, "candidate_replaced_since_plan");
        assert!(candidate.exists());
        assert!(other.exists());
        assert!(Repository::open(&repo)
            .unwrap()
            .find_worktree("other-worktree")
            .is_ok());
    }

    #[test]
    fn worktree_replaced_by_an_unregistered_directory_after_planning_is_preserved() {
        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let paths = paths_for(temp.path());
        let candidate = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_0011aabb");
        fs::create_dir_all(candidate.parent().unwrap()).unwrap();
        add_worktree(&repo, &candidate, "term-mesh/0011aabb");
        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());

        fs::remove_dir_all(&candidate).unwrap();
        fs::create_dir_all(&candidate).unwrap();
        fs::write(candidate.join("keep.txt"), "new occupant\n").unwrap();

        let summary = execute_sweep(&paths, &plan, true, true, &GcRefs::default()).unwrap();
        assert_eq!(summary.removed, 0);
        assert_eq!(summary.skipped, 1);
        assert_eq!(summary.outcomes[0].reason, "candidate_replaced_since_plan");
        assert!(candidate.join("keep.txt").exists());
    }

    #[test]
    fn worktree_recreated_clean_at_the_same_path_after_planning_is_preserved() {
        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let paths = paths_for(temp.path());
        let candidate = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_0011aabb");
        fs::create_dir_all(candidate.parent().unwrap()).unwrap();
        add_worktree(&repo, &candidate, "term-mesh/original");
        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());

        git(
            &["worktree", "remove", "--force", candidate.to_str().unwrap()],
            &repo,
        );
        add_worktree(&repo, &candidate, "term-mesh/recreated");

        let summary = execute_sweep(&paths, &plan, true, false, &GcRefs::default()).unwrap();

        assert_eq!(summary.removed, 0);
        assert_eq!(summary.skipped, 1);
        assert_eq!(summary.outcomes[0].reason, "candidate_replaced_since_plan");
        assert!(candidate.exists());
        assert!(Repository::open(&repo)
            .unwrap()
            .find_worktree("term-mesh_wt_0011aabb")
            .is_ok());
    }

    #[test]
    fn dry_run_removes_nothing() {
        let temp = tempfile::tempdir().unwrap();
        let paths = paths_for(temp.path());
        let wt = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_deadbeef");
        fs::create_dir_all(&wt).unwrap();
        fs::write(wt.join(".git"), "gitdir: /nonexistent/x\n").unwrap();

        let plan = build_plan(&paths, &only(CATEGORY_DAEMON_WORKTREES), &GcRefs::default());
        let summary = execute_sweep(&paths, &plan, false, true, &GcRefs::default()).unwrap();
        assert!(!summary.applied);
        assert_eq!(summary.removed, 1);
        assert_eq!(summary.outcomes[0].action, "would_remove");
        assert!(wt.exists(), "dry run must not touch the filesystem");
    }

    #[test]
    fn results_expire_on_the_ttl_boundary() {
        let temp = tempfile::tempdir().unwrap();
        let paths = paths_for(temp.path());
        let team = paths.results.join("my-team");
        fs::create_dir_all(&team).unwrap();
        let file = team.join("task-1.md");
        fs::write(&file, "report").unwrap();
        let modified = fs::metadata(&file).unwrap().modified().unwrap();

        let fresh = build_plan_at(
            &paths,
            &only(CATEGORY_TEAM_RESULTS),
            &GcRefs::default(),
            modified + RESULTS_TTL - Duration::from_secs(1),
        );
        assert_eq!(category(&fresh, CATEGORY_TEAM_RESULTS).entry_count, 0);

        let expired = build_plan_at(
            &paths,
            &only(CATEGORY_TEAM_RESULTS),
            &GcRefs::default(),
            modified + RESULTS_TTL,
        );
        assert_eq!(category(&expired, CATEGORY_TEAM_RESULTS).entry_count, 1);
    }

    #[test]
    fn a_live_team_keeps_its_board() {
        let temp = tempfile::tempdir().unwrap();
        let paths = paths_for(temp.path());
        let board = paths.teams.join("team-uuid-1");
        fs::create_dir_all(&board).unwrap();
        fs::write(board.join("board.json"), "{}").unwrap();
        let modified = fs::metadata(&board).unwrap().modified().unwrap();

        let refs = GcRefs {
            active_team_uuids: ["team-uuid-1".to_string()].into_iter().collect(),
            ..Default::default()
        };
        let plan = build_plan_at(
            &paths,
            &only(CATEGORY_TEAM_BOARDS),
            &refs,
            modified + BOARD_TTL,
        );
        let candidate = &category(&plan, CATEGORY_TEAM_BOARDS).candidates[0];
        assert!(candidate.blockers.iter().any(|b| b == "team_is_live"));
    }

    #[test]
    fn a_team_that_becomes_live_after_planning_keeps_its_board() {
        let temp = tempfile::tempdir().unwrap();
        let paths = paths_for(temp.path());
        let board = paths.teams.join("team-uuid-1");
        fs::create_dir_all(&board).unwrap();
        fs::write(board.join("board.json"), "{}").unwrap();
        let old = SystemTime::now() - BOARD_TTL - Duration::from_secs(60);
        filetime_set(&board, old);
        let plan = build_plan(&paths, &only(CATEGORY_TEAM_BOARDS), &GcRefs::default());
        assert!(category(&plan, CATEGORY_TEAM_BOARDS).candidates[0].reclaimable());
        let refs = GcRefs {
            active_team_uuids: ["team-uuid-1".to_string()].into_iter().collect(),
            ..Default::default()
        };

        let summary = execute_sweep(&paths, &plan, true, false, &refs).unwrap();

        assert_eq!(summary.removed, 0);
        assert_eq!(summary.skipped, 1);
        assert_eq!(summary.outcomes[0].reason, "team_is_live");
        assert!(board.exists());
    }

    #[test]
    fn an_expired_result_replaced_after_planning_is_preserved() {
        let temp = tempfile::tempdir().unwrap();
        let paths = paths_for(temp.path());
        let team = paths.results.join("team");
        fs::create_dir_all(&team).unwrap();
        let result = team.join("task.md");
        fs::write(&result, "old").unwrap();
        let old = SystemTime::now() - RESULTS_TTL - Duration::from_secs(60);
        filetime_set(&result, old);
        let plan = build_plan(&paths, &only(CATEGORY_TEAM_RESULTS), &GcRefs::default());
        fs::write(&result, "new result").unwrap();

        let summary = execute_sweep(&paths, &plan, true, false, &GcRefs::default()).unwrap();

        assert_eq!(summary.removed, 0);
        assert_eq!(summary.skipped, 1);
        assert_eq!(
            summary.outcomes[0].reason,
            "candidate_changed_or_no_longer_eligible"
        );
        assert_eq!(fs::read_to_string(result).unwrap(), "new result");
    }

    #[test]
    fn oversized_logs_rotate_instead_of_vanishing() {
        let temp = tempfile::tempdir().unwrap();
        let paths = paths_for(temp.path());
        fs::create_dir_all(&paths.logs).unwrap();
        let log = paths.logs.join("worktree.log");
        fs::write(&log, vec![b'x'; (LOG_ROTATE_BYTES + 1) as usize]).unwrap();

        let plan = build_plan(&paths, &only(CATEGORY_LOGS), &GcRefs::default());
        let summary = execute_sweep(&paths, &plan, true, false, &GcRefs::default()).unwrap();
        assert_eq!(summary.outcomes[0].action, "rotated");
        assert!(!log.exists());
        assert!(paths.logs.join("worktree.log.1").exists());
    }

    #[test]
    fn the_periodic_sweep_never_touches_worktrees() {
        let temp = tempfile::tempdir().unwrap();
        let paths = paths_for(temp.path());
        // A worktree that a full sweep would happily reclaim.
        let wt = paths
            .daemon_worktrees
            .join("repo")
            .join("term-mesh_wt_deadbeef");
        fs::create_dir_all(&wt).unwrap();
        fs::write(wt.join(".git"), "gitdir: /nonexistent/x\n").unwrap();
        // And an expired result, which it should reclaim.
        let team = paths.results.join("t");
        fs::create_dir_all(&team).unwrap();
        let stale = team.join("old.md");
        fs::write(&stale, "x").unwrap();
        let old = SystemTime::now() - RESULTS_TTL - Duration::from_secs(60);
        filetime_set(&stale, old);

        periodic_safe_sweep(&paths, &GcRefs::default()).unwrap();
        assert!(wt.exists(), "worktrees are out of scope for the auto sweep");
        assert!(!stale.exists(), "expired results are in scope");
    }

    #[test]
    fn the_periodic_sweep_never_deletes_team_boards_without_live_state() {
        let temp = tempfile::tempdir().unwrap();
        let paths = paths_for(temp.path());
        let board = paths.teams.join("team-uuid-1");
        fs::create_dir_all(&board).unwrap();
        fs::write(board.join("board.json"), "{}").unwrap();
        let old = SystemTime::now() - BOARD_TTL - Duration::from_secs(60);
        filetime_set(&board, old);

        periodic_safe_sweep(&paths, &GcRefs::default()).unwrap();

        assert!(
            board.exists(),
            "the background daemon has no authoritative live-team snapshot"
        );
    }

    #[test]
    fn stale_worktree_registrations_are_pruned() {
        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let wt = temp.path().join("gone");
        add_worktree(&repo, &wt, "term-mesh/gone");
        fs::remove_dir_all(&wt).unwrap();

        let refs = GcRefs {
            repo_paths: vec![repo.clone()],
            ..Default::default()
        };
        let paths = paths_for(temp.path());
        let plan = build_plan(&paths, &only(CATEGORY_WORKTREE_META), &refs);
        assert_eq!(category(&plan, CATEGORY_WORKTREE_META).entry_count, 1);

        execute_sweep(&paths, &plan, true, false, &GcRefs::default()).unwrap();
        let repo_handle = Repository::open(&repo).unwrap();
        assert_eq!(repo_handle.worktrees().unwrap().len(), 0);
    }

    #[test]
    fn worktree_registration_that_becomes_live_after_planning_is_preserved() {
        let temp = tempfile::tempdir().unwrap();
        let repo = init_repo(temp.path());
        let wt = temp.path().join("gone");
        add_worktree(&repo, &wt, "term-mesh/gone");
        fs::remove_dir_all(&wt).unwrap();

        let refs = GcRefs {
            repo_paths: vec![repo.clone()],
            ..Default::default()
        };
        let paths = paths_for(temp.path());
        let plan = build_plan(&paths, &only(CATEGORY_WORKTREE_META), &refs);
        assert_eq!(category(&plan, CATEGORY_WORKTREE_META).entry_count, 1);

        fs::create_dir_all(&wt).unwrap();
        fs::write(wt.join("keep.txt"), "new occupant\n").unwrap();
        let summary = execute_sweep(&paths, &plan, true, false, &refs).unwrap();

        assert_eq!(summary.removed, 0);
        assert_eq!(summary.skipped, 1);
        assert_eq!(summary.outcomes[0].reason, "worktree path exists again");
        assert!(wt.join("keep.txt").exists());
        assert!(Repository::open(&repo)
            .unwrap()
            .find_worktree("gone")
            .is_ok());
    }

    #[test]
    fn agent_checkout_names_are_recognized() {
        assert!(looks_like_agent_checkout("term-mesh-executor-260731-5ce8"));
        assert!(looks_like_agent_checkout("app-reviewer-2-260731-ab12"));
        assert!(!looks_like_agent_checkout("term-mesh"));
        assert!(!looks_like_agent_checkout("term-mesh-executor-26073-5ce8"));
        assert!(!looks_like_agent_checkout("term-mesh-executor-260731-5ce"));
    }

    /// Set a file's mtime without pulling in another dependency.
    fn filetime_set(path: &Path, time: SystemTime) {
        let seconds = time
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let stamp = format!("@{seconds}");
        let out = Command::new("touch")
            .args(["-d", &stamp, path.to_str().unwrap()])
            .output()
            .expect("touch runs");
        if !out.status.success() {
            // BSD touch wants -t with a formatted stamp; fall back to -r on a
            // helper file created with the right time is overkill, so use -A.
            let ts = Command::new("date")
                .args(["-r", &seconds.to_string(), "+%Y%m%d%H%M.%S"])
                .output()
                .expect("date runs");
            let formatted = String::from_utf8_lossy(&ts.stdout).trim().to_string();
            let out = Command::new("touch")
                .args(["-t", &formatted, path.to_str().unwrap()])
                .output()
                .expect("touch runs");
            assert!(out.status.success(), "could not set mtime");
        }
    }
}
