use notify::{Config, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;
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
}

enum WatcherCommand {
    Watch(String),
    Unwatch(String),
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
        }
        // Send command to the watcher thread to actually start watching
        let _ = self.command_tx.try_send(WatcherCommand::Watch(path.to_string()));
    }

    pub fn unwatch_path(&self, path: &str) {
        {
            let mut state = self.state.lock().unwrap();
            state.watched_paths.retain(|p| p != path);
        }
        let _ = self.command_tx.try_send(WatcherCommand::Unwatch(path.to_string()));
    }

    pub fn snapshot(&self) -> HeatmapSnapshot {
        let state = self.state.lock().unwrap();
        let now = now_ms();

        // Top 10 files by event count
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
        entries.truncate(10);

        // Last 50 events
        let recent = state
            .recent_events
            .iter()
            .rev()
            .take(50)
            .cloned()
            .collect();

        // Timeline: last 10 minutes, sorted by time
        let timeline_cutoff = now.saturating_sub(10 * 60_000);
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
            }
        }
    });

    // Process events in async context
    let state_for_events = state.clone();
    tokio::spawn(async move {
        while let Some(event) = event_rx.recv().await {
            let kind_str = match event.kind {
                EventKind::Create(_) => "create",
                EventKind::Modify(_) => "modify",
                EventKind::Remove(_) => "remove",
                EventKind::Access(_) => "access",
                _ => continue,
            };

            let now = now_ms();
            let mut state = state_for_events.lock().unwrap();

            // Floor to minute boundary for timeline bucket
            let minute_ms = (now / 60_000) * 60_000;

            for path in &event.paths {
                let path_str = path.to_string_lossy().to_string();

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
        }
    });

    WatcherHandle {
        state,
        command_tx: cmd_tx,
    }
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
            // Insert 15 files with different event counts
            for i in 0..15 {
                s.event_counts.insert(format!("/file_{i}"), (i + 1) as u64);
                s.last_event_times.insert(format!("/file_{i}"), 1000 + i as u64);
            }
        }
        let handle = make_handle(state);
        let snap = handle.snapshot();

        // Should be truncated to 10
        assert_eq!(snap.top_files.len(), 10);
        // Should be sorted descending by event_count
        assert_eq!(snap.top_files[0].event_count, 15);
        assert_eq!(snap.top_files[9].event_count, 6);
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
            // Very old bucket (should be excluded — more than 10 min ago)
            s.timeline_buckets.insert(current_minute - 20 * minute, (1, 1, 1));
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
