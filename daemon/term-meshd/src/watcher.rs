use notify::{Config, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc;

/// A single file event record.
#[derive(Debug, Clone, Serialize)]
pub struct FileEvent {
    pub path: String,
    pub kind: String, // "create" | "modify" | "remove" | "access"
    pub timestamp_ms: u64,
}

/// Aggregated heatmap entry for a file/directory.
#[derive(Debug, Clone, Serialize)]
pub struct HeatmapEntry {
    pub path: String,
    pub event_count: u64,
    pub last_event_ms: u64,
}

/// Per-minute event count for the timeline chart.
#[derive(Debug, Clone, Serialize)]
pub struct TimelineBucket {
    pub minute_ms: u64,   // start of the minute (floored)
    pub create: u64,
    pub modify: u64,
    pub remove: u64,
}

/// Snapshot of the file heatmap state.
#[derive(Debug, Clone, Serialize)]
pub struct HeatmapSnapshot {
    pub timestamp_ms: u64,
    pub watched_paths: Vec<String>,
    pub top_files: Vec<HeatmapEntry>,
    pub recent_events: Vec<FileEvent>,
    pub timeline: Vec<TimelineBucket>,
}

/// Shared state for the file watcher.
#[derive(Clone)]
pub struct WatcherHandle {
    state: Arc<Mutex<WatcherState>>,
    command_tx: mpsc::Sender<WatcherCommand>,
}

struct WatcherState {
    event_counts: HashMap<String, u64>,
    last_event_times: HashMap<String, u64>,
    recent_events: Vec<FileEvent>,
    watched_paths: Vec<String>,
    /// Per-minute event counts: key = minute_ms (floored), value = (create, modify, remove)
    timeline_buckets: HashMap<u64, (u64, u64, u64)>,
    /// Gitignore-based dynamic ignore patterns (loaded per watched directory).
    /// Each entry: (base_dir, pattern) where pattern is a glob-like string.
    gitignore_patterns: Vec<GitignoreRule>,
    /// Whether to use .gitignore-based filtering.
    use_gitignore: bool,
}

/// A parsed .gitignore rule with its base directory.
#[derive(Debug, Clone)]
struct GitignoreRule {
    base_dir: String,
    pattern: String,
    negated: bool,
    #[allow(dead_code)] // Parsed for future dir-only matching support
    dir_only: bool,
}

enum WatcherCommand {
    Watch(String),
    Unwatch(String),
    #[allow(dead_code)] // Wired internally but not exposed via RPC yet
    SetUseGitignore(bool),
}

impl WatcherHandle {
    pub fn watch_path(&self, path: &str) {
        // Update state immediately so snapshot reflects it right away
        {
            let mut state = self.state.lock().unwrap();
            if state.watched_paths.iter().any(|p| p == path) {
                return; // Already watching
            }
            state.watched_paths.push(path.to_string());
            // Load .gitignore rules if enabled
            if state.use_gitignore {
                let rules = load_gitignore_rules(path);
                state.gitignore_patterns.extend(rules);
            }
        }
        // Send command to the watcher thread to actually start watching
        let _ = self.command_tx.try_send(WatcherCommand::Watch(path.to_string()));
    }

    pub fn unwatch_path(&self, path: &str) {
        {
            let mut state = self.state.lock().unwrap();
            state.watched_paths.retain(|p| p != path);
            // Remove gitignore rules for this base dir
            state.gitignore_patterns.retain(|r| r.base_dir != path);
        }
        let _ = self.command_tx.try_send(WatcherCommand::Unwatch(path.to_string()));
    }

    /// Enable/disable .gitignore-based filtering for file events.
    #[allow(dead_code)] // Not exposed via RPC yet
    pub fn set_use_gitignore(&self, enabled: bool) {
        {
            let mut state = self.state.lock().unwrap();
            state.use_gitignore = enabled;
            if enabled {
                // Reload gitignore for all watched paths
                let paths: Vec<String> = state.watched_paths.clone();
                state.gitignore_patterns.clear();
                for path in &paths {
                    let rules = load_gitignore_rules(path);
                    state.gitignore_patterns.extend(rules);
                }
            }
        }
        let _ = self.command_tx.try_send(WatcherCommand::SetUseGitignore(enabled));
    }

    /// Check if .gitignore filtering is enabled.
    #[allow(dead_code)] // Not exposed via RPC yet
    pub fn use_gitignore(&self) -> bool {
        self.state.lock().unwrap().use_gitignore
    }

    pub fn snapshot(&self) -> HeatmapSnapshot {
        let state = self.state.lock().unwrap();
        let now = now_ms();

        // Top 20 files by event count
        let mut entries: Vec<HeatmapEntry> = state
            .event_counts
            .iter()
            .map(|(path, &count)| HeatmapEntry {
                path: path.clone(),
                event_count: count,
                last_event_ms: state.last_event_times.get(path).copied().unwrap_or(0),
            })
            .collect();
        entries.sort_by(|a, b| b.event_count.cmp(&a.event_count));
        entries.truncate(20);

        // Last 50 events
        let recent = state
            .recent_events
            .iter()
            .rev()
            .take(50)
            .cloned()
            .collect();

        // Timeline: last 30 minutes, sorted by time
        let timeline_cutoff = now.saturating_sub(30 * 60_000);
        let timeline_cutoff_minute = (timeline_cutoff / 60_000) * 60_000;
        let mut timeline: Vec<TimelineBucket> = state
            .timeline_buckets
            .iter()
            .filter(|(&k, _)| k >= timeline_cutoff_minute)
            .map(|(&minute_ms, &(create, modify, remove))| TimelineBucket {
                minute_ms,
                create,
                modify,
                remove,
            })
            .collect();
        timeline.sort_by_key(|b| b.minute_ms);

        HeatmapSnapshot {
            timestamp_ms: now,
            watched_paths: state.watched_paths.clone(),
            top_files: entries,
            recent_events: recent,
            timeline,
        }
    }
}

/// Start the file watcher background task.
pub fn start_watcher() -> WatcherHandle {
    let state = Arc::new(Mutex::new(WatcherState {
        event_counts: HashMap::new(),
        last_event_times: HashMap::new(),
        recent_events: Vec::new(),
        watched_paths: Vec::new(),
        timeline_buckets: HashMap::new(),
        gitignore_patterns: Vec::new(),
        use_gitignore: true, // enabled by default
    }));

    let (cmd_tx, mut cmd_rx) = mpsc::channel::<WatcherCommand>(256);
    let (event_tx, mut event_rx) = mpsc::channel::<Event>(512);

    // Spawn the notify watcher in a blocking thread
    std::thread::spawn(move || {
        let tx = event_tx;
        let mut watcher: RecommendedWatcher = Watcher::new(
            move |res: Result<Event, notify::Error>| {
                if let Ok(event) = res {
                    let _ = tx.blocking_send(event);
                }
            },
            Config::default(),
        )
        .expect("failed to create watcher");

        // Process commands
        while let Some(cmd) = cmd_rx.blocking_recv() {
            match cmd {
                WatcherCommand::Watch(path) => {
                    tracing::info!("watching: {path}");
                    if let Err(e) =
                        watcher.watch(PathBuf::from(&path).as_path(), RecursiveMode::Recursive)
                    {
                        tracing::error!("failed to watch {path}: {e}");
                    }
                }
                WatcherCommand::Unwatch(path) => {
                    tracing::info!("unwatching: {path}");
                    let _ = watcher.unwatch(PathBuf::from(&path).as_path());
                }
                WatcherCommand::SetUseGitignore(enabled) => {
                    tracing::info!("gitignore filtering: {enabled}");
                }
            }
        }
    });

    // Process events in async context
    let state_for_events = state.clone();
    tokio::spawn(async move {
        while let Some(event) = event_rx.recv().await {
            // Only track write operations (create/modify/remove).
            // Access (read) events are skipped — macOS FSEvents rarely emits
            // them, and they add noise without actionable information.
            let kind_str = match event.kind {
                EventKind::Create(_) => "create",
                EventKind::Modify(_) => "modify",
                EventKind::Remove(_) => "remove",
                _ => continue,
            };

            let now = now_ms();
            let mut state = state_for_events.lock().unwrap();

            // Floor to minute boundary for timeline bucket
            let minute_ms = (now / 60_000) * 60_000;

            for path in &event.paths {
                let path_str = path.to_string_lossy().to_string();

                // Skip noisy paths (hardcoded list + optional gitignore)
                if should_ignore_path(&path_str) {
                    continue;
                }
                if state.use_gitignore && matches_gitignore(&state.gitignore_patterns, &path_str) {
                    continue;
                }

                *state.event_counts.entry(path_str.clone()).or_insert(0) += 1;
                state.last_event_times.insert(path_str.clone(), now);

                state.recent_events.push(FileEvent {
                    path: path_str,
                    kind: kind_str.to_string(),
                    timestamp_ms: now,
                });

                // Keep recent events bounded
                if state.recent_events.len() > 500 {
                    state.recent_events.drain(0..250);
                }

                // Timeline bucket
                let bucket = state.timeline_buckets.entry(minute_ms).or_insert((0, 0, 0));
                match kind_str {
                    "create" => bucket.0 += 1,
                    "modify" => bucket.1 += 1,
                    "remove" => bucket.2 += 1,
                    _ => {}
                }
            }

            // Prune old timeline buckets (keep last 30 minutes)
            let cutoff = now.saturating_sub(30 * 60_000);
            let cutoff_minute = (cutoff / 60_000) * 60_000;
            state.timeline_buckets.retain(|&k, _| k >= cutoff_minute);

            // Prune stale heatmap entries (keep only paths seen in last 30 minutes)
            state.last_event_times.retain(|_, &mut ts| ts >= cutoff);
            let live_keys: std::collections::HashSet<String> =
                state.last_event_times.keys().cloned().collect();
            state.event_counts.retain(|k, _| live_keys.contains(k));
        }
    });

    WatcherHandle {
        state,
        command_tx: cmd_tx,
    }
}

/// Load .gitignore rules from a directory (walks up to find all .gitignore files).
fn load_gitignore_rules(dir: &str) -> Vec<GitignoreRule> {
    let mut rules = Vec::new();
    let dir_path = Path::new(dir);

    // Load .gitignore from the watched directory
    load_gitignore_file(dir_path, dir, &mut rules);

    // Also check subdirectories one level deep for nested .gitignore files
    // (deeper ones are loaded lazily on demand — not worth the upfront cost)
    if let Ok(entries) = fs::read_dir(dir_path) {
        for entry in entries.flatten() {
            if entry.path().is_dir() {
                let subdir = entry.path();
                let gi = subdir.join(".gitignore");
                if gi.exists() {
                    load_gitignore_file(&subdir, &subdir.to_string_lossy(), &mut rules);
                }
            }
        }
    }

    rules
}

fn load_gitignore_file(dir: &Path, base_dir: &str, rules: &mut Vec<GitignoreRule>) {
    let gi_path = dir.join(".gitignore");
    let content = match fs::read_to_string(&gi_path) {
        Ok(c) => c,
        Err(_) => return,
    };
    for line in content.lines() {
        let trimmed = line.trim();
        // Skip comments and empty lines
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let (negated, pattern) = if let Some(rest) = trimmed.strip_prefix('!') {
            (true, rest.to_string())
        } else {
            (false, trimmed.to_string())
        };
        let dir_only = pattern.ends_with('/');
        let pattern = pattern.trim_end_matches('/').to_string();
        if pattern.is_empty() {
            continue;
        }
        rules.push(GitignoreRule {
            base_dir: base_dir.to_string(),
            pattern,
            negated,
            dir_only,
        });
    }
}

/// Check if a path matches any gitignore rule.
fn matches_gitignore(rules: &[GitignoreRule], path: &str) -> bool {
    let mut ignored = false;
    for rule in rules {
        // Only apply rules whose base_dir is a prefix of the path
        if !path.starts_with(&rule.base_dir) {
            continue;
        }
        // Get relative path from the rule's base dir
        let rel = &path[rule.base_dir.len()..].trim_start_matches('/');
        if rel.is_empty() {
            continue;
        }
        if gitignore_pattern_matches(&rule.pattern, rel) {
            if rule.negated {
                ignored = false; // Negation un-ignores
            } else {
                ignored = true;
            }
        }
    }
    ignored
}

/// Simple gitignore glob matching.
/// Supports: `*` (single segment), `**` (any depth), `*.ext`, `dir/`, prefix match.
fn gitignore_pattern_matches(pattern: &str, rel_path: &str) -> bool {
    // If pattern has no slash, match against any path component
    if !pattern.contains('/') {
        for component in rel_path.split('/') {
            if simple_glob_match(pattern, component) {
                return true;
            }
        }
        return false;
    }
    // Pattern with slash: match from the start of relative path
    simple_glob_match(pattern, rel_path)
}

/// Basic glob match: `*` matches any chars within a segment, `**` matches across segments.
fn simple_glob_match(pattern: &str, text: &str) -> bool {
    if pattern == "**" {
        return true;
    }
    if let Some(ext) = pattern.strip_prefix("*.") {
        // *.ext — match file extension
        return text.ends_with(&format!(".{ext}"));
    }
    if let Some(prefix) = pattern.strip_suffix("/**") {
        // dir/** — match anything under dir
        return text.starts_with(prefix) || text == prefix;
    }
    if pattern.contains("**") {
        // a/**/b — split and check prefix+suffix
        let parts: Vec<&str> = pattern.splitn(2, "**").collect();
        if parts.len() == 2 {
            let prefix = parts[0].trim_end_matches('/');
            let suffix = parts[1].trim_start_matches('/');
            if !prefix.is_empty() && !text.starts_with(prefix) {
                return false;
            }
            if !suffix.is_empty() && !text.ends_with(suffix) {
                return false;
            }
            return true;
        }
    }
    // Simple wildcard: * matches any non-slash chars
    if pattern.contains('*') {
        let parts: Vec<&str> = pattern.split('*').collect();
        if parts.len() == 2 {
            return text.starts_with(parts[0]) && text.ends_with(parts[1]);
        }
    }
    // Exact match or prefix match (for directories)
    text == pattern || text.starts_with(&format!("{pattern}/"))
}

/// Directories and file patterns to ignore in the file watcher.
/// Matches any path component (e.g. "/.git/" anywhere in the path).
const IGNORE_DIRS: &[&str] = &[
    "/.git/",
    "/node_modules/",
    "/.next/",
    "/target/",          // Rust/Cargo
    "/build/",
    "/dist/",
    "/.xm/",             // x-kit state
    "/.omc/",            // OMC state
    "/__pycache__/",
    "/.cache/",
    "/DerivedData/",
    "/.swiftpm/",
    "/zig-cache/",
    "/zig-out/",
];

const IGNORE_SUFFIXES: &[&str] = &[
    ".DS_Store",
    ".swp",
    ".swo",
    "~",
    ".pyc",
    ".pyo",
    ".o",
    ".d",
    ".lock",
];

fn should_ignore_path(path: &str) -> bool {
    for dir in IGNORE_DIRS {
        if path.contains(dir) {
            return true;
        }
    }
    for suffix in IGNORE_SUFFIXES {
        if path.ends_with(suffix) {
            return true;
        }
    }
    false
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_watcher_state() -> Arc<Mutex<WatcherState>> {
        Arc::new(Mutex::new(WatcherState {
            event_counts: HashMap::new(),
            last_event_times: HashMap::new(),
            recent_events: Vec::new(),
            watched_paths: Vec::new(),
            timeline_buckets: HashMap::new(),
            gitignore_patterns: Vec::new(),
            use_gitignore: false,
        }))
    }

    fn make_handle(state: Arc<Mutex<WatcherState>>) -> WatcherHandle {
        let (tx, _rx) = mpsc::channel(16);
        WatcherHandle {
            state,
            command_tx: tx,
        }
    }

    #[test]
    fn snapshot_empty_state() {
        let state = make_watcher_state();
        let handle = make_handle(state);
        let snap = handle.snapshot();

        assert!(snap.watched_paths.is_empty());
        assert!(snap.top_files.is_empty());
        assert!(snap.recent_events.is_empty());
        assert!(snap.timeline.is_empty());
    }

    #[test]
    fn snapshot_top_files_sorted_and_truncated() {
        let state = make_watcher_state();
        {
            let mut s = state.lock().unwrap();
            // Insert 25 files with different event counts
            for i in 0..25 {
                s.event_counts.insert(format!("/file_{i}"), (i + 1) as u64);
                s.last_event_times.insert(format!("/file_{i}"), 1000 + i as u64);
            }
        }
        let handle = make_handle(state);
        let snap = handle.snapshot();

        // Should be truncated to 20
        assert_eq!(snap.top_files.len(), 20);
        // Should be sorted descending by event_count
        assert_eq!(snap.top_files[0].event_count, 25);
        assert_eq!(snap.top_files[19].event_count, 6);
    }

    #[test]
    fn snapshot_recent_events_reversed_and_limited() {
        let state = make_watcher_state();
        {
            let mut s = state.lock().unwrap();
            for i in 0..100 {
                s.recent_events.push(FileEvent {
                    path: format!("/file_{i}"),
                    kind: "modify".into(),
                    timestamp_ms: 1000 + i,
                });
            }
        }
        let handle = make_handle(state);
        let snap = handle.snapshot();

        // Should take last 50 (reversed)
        assert_eq!(snap.recent_events.len(), 50);
        // First in the result should be the most recent
        assert_eq!(snap.recent_events[0].path, "/file_99");
    }

    #[test]
    fn snapshot_timeline_filters_old_buckets() {
        let state = make_watcher_state();
        let now = now_ms();
        let minute = 60_000u64;
        let current_minute = (now / minute) * minute;

        {
            let mut s = state.lock().unwrap();
            // Recent bucket (should be included)
            s.timeline_buckets.insert(current_minute, (5, 10, 2));
            // Very old bucket (should be excluded — more than 30 min ago)
            s.timeline_buckets.insert(current_minute - 40 * minute, (1, 1, 1));
        }
        let handle = make_handle(state);
        let snap = handle.snapshot();

        // Only the recent bucket should be in the snapshot
        assert_eq!(snap.timeline.len(), 1);
        assert_eq!(snap.timeline[0].create, 5);
        assert_eq!(snap.timeline[0].modify, 10);
        assert_eq!(snap.timeline[0].remove, 2);
    }

    #[test]
    fn watch_path_adds_to_watched() {
        let state = make_watcher_state();
        let handle = make_handle(state);

        handle.watch_path("/tmp/test");
        let snap = handle.snapshot();
        assert_eq!(snap.watched_paths, vec!["/tmp/test"]);

        // Duplicate watch should not add twice
        handle.watch_path("/tmp/test");
        let snap = handle.snapshot();
        assert_eq!(snap.watched_paths.len(), 1);
    }

    #[test]
    fn gitignore_pattern_matching() {
        // *.log matches any .log file in any directory
        assert!(gitignore_pattern_matches("*.log", "debug.log"));
        assert!(gitignore_pattern_matches("*.log", "src/debug.log"));
        assert!(!gitignore_pattern_matches("*.log", "debug.txt"));

        // dir pattern matches as prefix
        assert!(gitignore_pattern_matches("build", "build/output.js"));
        assert!(gitignore_pattern_matches("build", "build"));
        assert!(!gitignore_pattern_matches("build", "rebuild/x"));

        // dir/** matches everything under dir
        assert!(gitignore_pattern_matches("logs/**", "logs/a.log"));
        assert!(gitignore_pattern_matches("logs/**", "logs/deep/nested/file"));
    }

    #[test]
    fn matches_gitignore_with_rules() {
        let rules = vec![
            GitignoreRule { base_dir: "/project".into(), pattern: "*.log".into(), negated: false, dir_only: false },
            GitignoreRule { base_dir: "/project".into(), pattern: "dist".into(), negated: false, dir_only: false },
            GitignoreRule { base_dir: "/project".into(), pattern: "important.log".into(), negated: true, dir_only: false },
        ];
        // *.log matches
        assert!(matches_gitignore(&rules, "/project/debug.log"));
        // Negation: important.log is un-ignored
        assert!(!matches_gitignore(&rules, "/project/important.log"));
        // dist/ matches
        assert!(matches_gitignore(&rules, "/project/dist/bundle.js"));
        // Regular file not matched
        assert!(!matches_gitignore(&rules, "/project/src/main.rs"));
        // Different base dir — rules don't apply
        assert!(!matches_gitignore(&rules, "/other/debug.log"));
    }

    #[test]
    fn should_ignore_git_and_node_modules() {
        assert!(should_ignore_path("/Users/me/project/.git/objects/pack/abc"));
        assert!(should_ignore_path("/Users/me/project/node_modules/react/index.js"));
        assert!(should_ignore_path("/Users/me/project/.DS_Store"));
        assert!(should_ignore_path("/Users/me/project/src/main.rs.swp"));
        assert!(should_ignore_path("/Users/me/project/target/release/binary"));
        assert!(!should_ignore_path("/Users/me/project/src/main.rs"));
        assert!(!should_ignore_path("/Users/me/project/README.md"));
        assert!(!should_ignore_path("/Users/me/project/.gitignore"));
    }

    #[test]
    fn unwatch_path_removes_from_watched() {
        let state = make_watcher_state();
        let handle = make_handle(state);

        handle.watch_path("/tmp/test");
        handle.watch_path("/tmp/other");
        handle.unwatch_path("/tmp/test");

        let snap = handle.snapshot();
        assert_eq!(snap.watched_paths, vec!["/tmp/other"]);
    }
}
