use notify::{Config, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Scan interval for JSONL files (fallback poll; FSEvents trigger is primary).
const SCAN_INTERVAL: Duration = Duration::from_secs(30);

// ── Model Pricing (USD per million tokens) ──

struct ModelPricing {
    base_input: f64,
    cache_write_1h: f64,
    cache_read: f64,
    output: f64,
}

fn model_pricing(model: &str) -> ModelPricing {
    // Match by prefix to handle versioned model IDs
    if model.starts_with("claude-opus-4-6")
        || model.starts_with("claude-opus-4-5")
        || model.starts_with("claude-opus-4-20")
    {
        ModelPricing {
            base_input: 5.0,
            cache_write_1h: 10.0,
            cache_read: 0.5,
            output: 25.0,
        }
    } else if model.starts_with("claude-sonnet-4")
        || model.starts_with("claude-sonnet-3-5")
        || model.starts_with("claude-sonnet-3.5")
    {
        ModelPricing {
            base_input: 3.0,
            cache_write_1h: 6.0,
            cache_read: 0.3,
            output: 15.0,
        }
    } else if model.starts_with("claude-haiku") {
        ModelPricing {
            base_input: 1.0,
            cache_write_1h: 2.0,
            cache_read: 0.1,
            output: 5.0,
        }
    } else {
        // Default to Sonnet pricing for unknown models
        ModelPricing {
            base_input: 3.0,
            cache_write_1h: 6.0,
            cache_read: 0.3,
            output: 15.0,
        }
    }
}

// ── JSONL Parsing Structures ──

#[derive(Debug, Deserialize)]
struct JsonlLine {
    #[serde(rename = "type")]
    line_type: String,
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
    cwd: Option<String>,
    message: Option<AssistantMessage>,
    /// ISO-8601 UTC timestamp (e.g. "2026-05-13T01:18:43.744Z"). Present on
    /// attachment/user/assistant lines; absent on last-prompt/permission-mode/
    /// file-history-snapshot lines. Used to derive the session start time.
    timestamp: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AssistantMessage {
    model: Option<String>,
    usage: Option<TokenUsage>,
}

#[derive(Debug, Clone, Deserialize)]
struct TokenUsage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    cache_creation: Option<CacheCreationBreakdown>,
}

#[derive(Debug, Clone, Deserialize)]
struct CacheCreationBreakdown {
    #[serde(default)]
    ephemeral_1h_input_tokens: u64,
}

// ── Aggregated Stats ──

/// Per-session usage stats for API/dashboard consumption.
#[derive(Debug, Clone, Serialize, Default)]
pub struct SessionUsageStats {
    pub session_id: String,
    pub project_path: String,
    pub model: String,
    pub input_tokens: u64,
    pub cache_write_tokens: u64,
    pub cache_read_tokens: u64,
    pub output_tokens: u64,
    pub api_calls: u64,
    pub cost_usd: f64,
    pub last_activity_ms: u64,
}

/// Snapshot of all sessions.
#[derive(Debug, Clone, Serialize)]
pub struct UsageSnapshot {
    pub sessions: Vec<SessionUsageStats>,
    pub total_cost_usd: f64,
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
    pub total_cache_read_tokens: u64,
    pub total_cache_write_tokens: u64,
}

// ── Tracker ──

struct TrackerState {
    sessions: HashMap<String, SessionUsageStats>,
    file_positions: HashMap<PathBuf, u64>,
    claude_projects_dir: PathBuf,
    /// cwd → session_id of the most recently active session.
    /// Updated every time a new assistant line is processed for a given cwd.
    /// Used by snapshot_by_project() to return only the current session's tokens.
    latest_session_per_cwd: HashMap<String, String>,
    /// session_id → Unix timestamp (seconds) of the session's earliest line.
    /// Parsed from the `timestamp` field inside the JSONL itself (not file
    /// metadata), so backup/copy/restore of the file does not skew it.
    session_started_at: HashMap<String, i64>,
}

/// Tracks real API token usage by parsing Claude Code JSONL log files.
#[derive(Clone)]
pub struct UsageTracker {
    state: Arc<Mutex<TrackerState>>,
}

impl UsageTracker {
    pub fn new() -> Self {
        let home = dirs::home_dir().expect("no home directory");
        let claude_dir = home.join(".claude").join("projects");

        Self {
            state: Arc::new(Mutex::new(TrackerState {
                sessions: HashMap::new(),
                file_positions: HashMap::new(),
                claude_projects_dir: claude_dir,
                latest_session_per_cwd: HashMap::new(),
                session_started_at: HashMap::new(),
            })),
        }
    }

    /// Start FSEvents watcher + fallback poll loop. Returns self for chaining.
    pub fn start(self) -> Self {
        let claude_dir = self.state.lock().unwrap().claude_projects_dir.clone();

        // Primary: FSEvents-triggered scan via notify crate.
        // Watches ~/.claude/projects/ recursively; fires scan_all() immediately
        // on any *.jsonl create/modify event. Fallback poll (every 30s) catches
        // edge cases where the OS coalesces events under heavy write load.
        if claude_dir.exists() {
            let tracker_fsevent = self.clone();
            let watch_dir = claude_dir.clone();
            tokio::task::spawn_blocking(move || {
                let (tx, rx) = std::sync::mpsc::channel::<Event>();
                let mut watcher: RecommendedWatcher = Watcher::new(
                    move |res: Result<Event, notify::Error>| {
                        if let Ok(ev) = res {
                            let _ = tx.send(ev);
                        }
                    },
                    Config::default(),
                )
                .expect("failed to create jsonl notify watcher");
                if let Err(e) = watcher.watch(&watch_dir, RecursiveMode::Recursive) {
                    tracing::warn!("sidebar.token.watch.start failed: {e}");
                    return;
                }
                tracing::info!("sidebar.token.watch.start path={}", watch_dir.display());
                for event in rx {
                    let is_jsonl_change =
                        matches!(event.kind, EventKind::Create(_) | EventKind::Modify(_))
                            && event
                                .paths
                                .iter()
                                .any(|p| p.extension().and_then(|e| e.to_str()) == Some("jsonl"));
                    if is_jsonl_change {
                        if let Err(e) = tracker_fsevent.scan_all() {
                            tracing::debug!("sidebar.token.parse.skip reason=scan_error: {e}");
                        }
                    }
                }
            });
        } else {
            tracing::info!("sidebar.token.watch.start dormant: ~/.claude/projects not found");
        }

        // Fallback: periodic poll to catch any missed FSEvents.
        let tracker = self.clone();
        tokio::spawn(async move {
            // Initial scan
            if let Err(e) = tracker.scan_all() {
                tracing::warn!("Initial JSONL scan error: {e}");
            }
            let mut interval = tokio::time::interval(SCAN_INTERVAL);
            loop {
                interval.tick().await;
                if let Err(e) = tracker.scan_all() {
                    tracing::warn!("JSONL scan error: {e}");
                }
            }
        });
        self
    }

    /// Scan all JSONL files for new data.
    pub fn scan_all(&self) -> anyhow::Result<()> {
        let claude_dir = { self.state.lock().unwrap().claude_projects_dir.clone() };

        if !claude_dir.exists() {
            return Ok(());
        }

        // Prune file_positions for deleted files
        {
            let mut state = self.state.lock().unwrap();
            state.file_positions.retain(|p, _| p.exists());
        }

        for entry in std::fs::read_dir(&claude_dir)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let project_dir = entry.path();
            self.scan_jsonl_files_in(&project_dir)?;

            // Scan subagent directories: <session-uuid>/subagents/*.jsonl
            for sub_entry in std::fs::read_dir(&project_dir)
                .into_iter()
                .flatten()
                .flatten()
            {
                if sub_entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    let subagent_dir = sub_entry.path().join("subagents");
                    if subagent_dir.exists() {
                        self.scan_jsonl_files_in(&subagent_dir)?;
                    }
                }
            }
        }
        Ok(())
    }

    fn scan_jsonl_files_in(&self, dir: &Path) -> anyhow::Result<()> {
        for entry in std::fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
                if let Err(e) = self.scan_file(&path) {
                    tracing::debug!("Error scanning {}: {e}", path.display());
                }
            }
        }
        Ok(())
    }

    fn scan_file(&self, path: &Path) -> anyhow::Result<()> {
        let metadata = std::fs::metadata(path)?;
        let file_len = metadata.len();

        let mut state = self.state.lock().unwrap();
        let offset = state.file_positions.get(path).copied().unwrap_or(0);

        // File truncated or rotated — reset
        if file_len < offset {
            state.file_positions.insert(path.to_path_buf(), 0);
            return Ok(());
        }

        // No new data
        if file_len == offset {
            return Ok(());
        }

        let file = std::fs::File::open(path)?;
        let mut reader = BufReader::new(file);
        reader.seek(SeekFrom::Start(offset))?;

        let mut line_buf = String::new();

        let mut line_n: u64 = 0;
        while reader.read_line(&mut line_buf)? > 0 {
            line_n += 1;
            let trimmed = line_buf.trim();
            if !trimmed.is_empty() {
                match serde_json::from_str::<JsonlLine>(trimmed) {
                    Ok(entry) => {
                        // Session start time comes from the line's own ISO-8601
                        // `timestamp` field — not file metadata, which drifts on
                        // backup/copy/dotfile-sync/restore. Recorded for every line
                        // type that carries a timestamp (attachment is usually first).
                        record_session_start(&mut state, &entry);
                        let had_usage = entry
                            .message
                            .as_ref()
                            .and_then(|m| m.usage.as_ref())
                            .is_some();
                        if !had_usage && entry.line_type == "assistant" {
                            tracing::debug!(
                                "sidebar.token.parse.skip reason=no-usage line_n={line_n}"
                            );
                        }
                        process_line(&mut state, &entry, path);
                    }
                    Err(_) => {
                        tracing::debug!("sidebar.token.parse.skip reason=json line_n={line_n}");
                    }
                }
            }
            line_buf.clear();
        }

        let new_offset = reader.stream_position()?;
        state.file_positions.insert(path.to_path_buf(), new_offset);
        Ok(())
    }

    /// Current-session token totals keyed by project_path.
    /// Returns only the most recently active session per cwd (not a cumulative sum).
    /// Returns: project_path → (input, output, cache_read, cache_write)
    #[allow(dead_code)]
    pub fn snapshot_by_project(&self) -> HashMap<String, (u64, u64, u64, u64)> {
        let state = self.state.lock().unwrap();
        let mut by_project: HashMap<String, (u64, u64, u64, u64)> = HashMap::new();
        for (cwd, session_id) in &state.latest_session_per_cwd {
            if let Some(s) = state.sessions.get(session_id) {
                by_project.insert(
                    cwd.clone(),
                    (
                        s.input_tokens,
                        s.output_tokens,
                        s.cache_read_tokens,
                        s.cache_write_tokens,
                    ),
                );
            }
        }
        by_project
    }

    /// Per-panel token totals correlated by process start time, with a PID
    /// tiebreaker for same-second spawns.
    ///
    /// `panes`: (panel_id, cwd, proc_start_unix, pid) from PaneTracker.
    ///
    /// Mirrors `CodexUsageTracker::snapshot_by_panel`: within one cwd, panes
    /// sorted by (proc_start, pid) zip 1:1 against sessions sorted by
    /// (session_started_at, session_id). Claude's in-JSONL timestamps usually
    /// disambiguate on their own, but `iso8601_to_unix` is 1-second resolution,
    /// so the PID-ordered zip is the safety net when several agents start in
    /// the same second. The 300s `MAX_DIFF` guard drops stale sessions.
    /// Returns: panel_id → (in, out, cr, cw).
    pub fn snapshot_by_panel(
        &self,
        panes: &[(String, String, i64, u32)],
    ) -> HashMap<String, (u64, u64, u64, u64)> {
        const MAX_DIFF: i64 = 300;
        let state = self.state.lock().unwrap();

        // (started_at, session_id, tokens) per cwd, sorted by (started_at, session_id).
        let mut sessions_by_cwd: HashMap<&str, Vec<(i64, &str, (u64, u64, u64, u64))>> =
            HashMap::new();
        for s in state.sessions.values() {
            let Some(&started) = state.session_started_at.get(&s.session_id) else {
                continue;
            };
            sessions_by_cwd
                .entry(s.project_path.as_str())
                .or_default()
                .push((
                    started,
                    s.session_id.as_str(),
                    (
                        s.input_tokens,
                        s.output_tokens,
                        s.cache_read_tokens,
                        s.cache_write_tokens,
                    ),
                ));
        }
        for v in sessions_by_cwd.values_mut() {
            // session_id is the stable secondary key for same-second sessions.
            v.sort_unstable_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(b.1)));
        }

        // Group panes by cwd.
        let mut panes_by_cwd: HashMap<&str, Vec<(&str, i64, u32)>> = HashMap::new();
        for (panel_id, cwd, proc_start, pid) in panes {
            panes_by_cwd.entry(cwd.as_str()).or_default().push((
                panel_id.as_str(),
                *proc_start,
                *pid,
            ));
        }

        let mut by_panel = HashMap::new();
        for (cwd, mut cwd_panes) in panes_by_cwd {
            let Some(cwd_sessions) = sessions_by_cwd.get(cwd) else {
                continue;
            };
            // Spawn order: earlier proc_start first, PID breaks the same-second tie.
            cwd_panes.sort_unstable_by_key(|&(_, proc_start, pid)| (proc_start, pid));
            // Drop stale sessions not near any pane (keeps the index-zip aligned).
            let relevant: Vec<&(i64, &str, (u64, u64, u64, u64))> = cwd_sessions
                .iter()
                .filter(|(started, _, _)| {
                    cwd_panes
                        .iter()
                        .any(|&(_, proc_start, _)| (started - proc_start).abs() <= MAX_DIFF)
                })
                .collect();
            for (i, &(panel_id, proc_start, _pid)) in cwd_panes.iter().enumerate() {
                let Some(&&(started, _sid, tokens)) = relevant.get(i) else {
                    continue;
                };
                if (started - proc_start).abs() > MAX_DIFF {
                    continue;
                }
                by_panel.insert(panel_id.to_string(), tokens);
            }
        }
        by_panel
    }

    /// Get a snapshot of all session usage data.
    pub fn snapshot(&self) -> UsageSnapshot {
        let state = self.state.lock().unwrap();
        let sessions: Vec<SessionUsageStats> = state.sessions.values().cloned().collect();

        let total_cost_usd = sessions.iter().map(|s| s.cost_usd).sum();
        let total_input_tokens = sessions.iter().map(|s| s.input_tokens).sum();
        let total_output_tokens = sessions.iter().map(|s| s.output_tokens).sum();
        let total_cache_read_tokens = sessions.iter().map(|s| s.cache_read_tokens).sum();
        let total_cache_write_tokens = sessions.iter().map(|s| s.cache_write_tokens).sum();

        UsageSnapshot {
            sessions,
            total_cost_usd,
            total_input_tokens,
            total_output_tokens,
            total_cache_read_tokens,
            total_cache_write_tokens,
        }
    }
}

fn process_line(state: &mut TrackerState, entry: &JsonlLine, file_path: &Path) {
    if entry.line_type != "assistant" {
        return;
    }

    let session_id = match &entry.session_id {
        Some(s) => s.clone(),
        None => return,
    };

    let message = match &entry.message {
        Some(m) => m,
        None => return,
    };

    let usage = match &message.usage {
        Some(u) => u.clone(),
        None => return,
    };

    let model = message.model.clone().unwrap_or_else(|| "unknown".into());

    let project_path = entry
        .cwd
        .clone()
        .unwrap_or_else(|| decode_project_dir(file_path));

    let cost = calculate_line_cost(&usage, &model);

    let stats = state
        .sessions
        .entry(session_id.clone())
        .or_insert_with(|| SessionUsageStats {
            session_id: session_id.clone(),
            project_path: project_path.clone(),
            model: model.clone(),
            ..Default::default()
        });

    stats.input_tokens += usage.input_tokens;
    stats.output_tokens += usage.output_tokens;
    stats.cache_read_tokens += usage.cache_read_input_tokens;

    if let Some(ref cc) = usage.cache_creation {
        stats.cache_write_tokens += cc.ephemeral_1h_input_tokens;
    } else {
        stats.cache_write_tokens += usage.cache_creation_input_tokens;
    }

    stats.api_calls += 1;
    stats.cost_usd += cost;
    stats.last_activity_ms = now_ms();

    // Update model to most recent
    if !model.is_empty() && model != "unknown" {
        stats.model = model;
    }
    // Update project_path if cwd is available
    if entry.cwd.is_some() {
        stats.project_path = project_path.clone();
    }

    // Track most recently active session per cwd for current-session view.
    state
        .latest_session_per_cwd
        .insert(project_path, session_id);

    tracing::debug!(
        "sidebar.token.update agent={} in={} out={}",
        stats.session_id,
        usage.input_tokens,
        usage.output_tokens
    );
}

/// Record the earliest observed timestamp for a session.
/// Called for every JSONL line; the minimum wins (lines are appended
/// chronologically, so the first timestamped line of a session is its start).
fn record_session_start(state: &mut TrackerState, entry: &JsonlLine) {
    let (Some(sid), Some(ts_str)) = (&entry.session_id, &entry.timestamp) else {
        return;
    };
    let Some(ts) = iso8601_to_unix(ts_str) else {
        return;
    };
    state
        .session_started_at
        .entry(sid.clone())
        .and_modify(|e| {
            if ts < *e {
                *e = ts;
            }
        })
        .or_insert(ts);
}

/// Parse an ISO-8601 UTC timestamp ("YYYY-MM-DDTHH:MM:SS(.sss)Z") to Unix
/// seconds. Sub-second precision and the trailing 'Z' are ignored. Returns
/// None if the prefix does not match the expected fixed-width layout.
pub(crate) fn iso8601_to_unix(s: &str) -> Option<i64> {
    if s.len() < 19 {
        return None;
    }
    let year: i64 = s.get(0..4)?.parse().ok()?;
    let month: i64 = s.get(5..7)?.parse().ok()?;
    let day: i64 = s.get(8..10)?.parse().ok()?;
    let hour: i64 = s.get(11..13)?.parse().ok()?;
    let minute: i64 = s.get(14..16)?.parse().ok()?;
    let second: i64 = s.get(17..19)?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    // days-from-civil (Howard Hinnant's algorithm), valid for the Gregorian calendar.
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(days * 86400 + hour * 3600 + minute * 60 + second)
}

fn calculate_line_cost(usage: &TokenUsage, model: &str) -> f64 {
    let pricing = model_pricing(model);
    let mtok = 1_000_000.0;

    let input_cost = (usage.input_tokens as f64 / mtok) * pricing.base_input;

    let cache_write_cost = if let Some(ref cc) = usage.cache_creation {
        (cc.ephemeral_1h_input_tokens as f64 / mtok) * pricing.cache_write_1h
    } else {
        (usage.cache_creation_input_tokens as f64 / mtok) * pricing.cache_write_1h
    };

    let cache_read_cost = (usage.cache_read_input_tokens as f64 / mtok) * pricing.cache_read;
    let output_cost = (usage.output_tokens as f64 / mtok) * pricing.output;

    input_cost + cache_write_cost + cache_read_cost + output_cost
}

/// Decode project directory name back to a path.
/// e.g., "-Users-jinwoo-work-tty-mesh" → "/Users/jinwoo/work/tty-mesh"
fn decode_project_dir(file_path: &Path) -> String {
    // Walk up to find the project directory under ~/.claude/projects/
    let mut path = file_path;
    loop {
        if let Some(parent) = path.parent() {
            if parent
                .file_name()
                .and_then(|n| n.to_str())
                .map(|n| n == "projects")
                .unwrap_or(false)
            {
                // path is the project directory
                let dir_name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
                return dir_name.replacen('-', "/", 1).replace('-', "/");
            }
            path = parent;
        } else {
            break;
        }
    }
    "unknown".to_string()
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── model_pricing tests ──

    #[test]
    fn pricing_opus() {
        let p = model_pricing("claude-opus-4-6-20250101");
        assert_eq!(p.base_input, 5.0);
        assert_eq!(p.output, 25.0);
        assert_eq!(p.cache_read, 0.5);
        assert_eq!(p.cache_write_1h, 10.0);
    }

    #[test]
    fn pricing_opus_45() {
        let p = model_pricing("claude-opus-4-5-20250101");
        assert_eq!(p.base_input, 5.0);
        assert_eq!(p.output, 25.0);
    }

    #[test]
    fn pricing_sonnet() {
        let p = model_pricing("claude-sonnet-4-6-20250101");
        assert_eq!(p.base_input, 3.0);
        assert_eq!(p.output, 15.0);
        assert_eq!(p.cache_read, 0.3);
        assert_eq!(p.cache_write_1h, 6.0);
    }

    #[test]
    fn pricing_sonnet_35() {
        let p = model_pricing("claude-sonnet-3-5-20241022");
        assert_eq!(p.base_input, 3.0);
        assert_eq!(p.output, 15.0);
    }

    #[test]
    fn pricing_haiku() {
        let p = model_pricing("claude-haiku-4-5-20251001");
        assert_eq!(p.base_input, 1.0);
        assert_eq!(p.output, 5.0);
        assert_eq!(p.cache_read, 0.1);
        assert_eq!(p.cache_write_1h, 2.0);
    }

    #[test]
    fn pricing_unknown_defaults_to_sonnet() {
        let p = model_pricing("gpt-4o");
        assert_eq!(p.base_input, 3.0);
        assert_eq!(p.output, 15.0);
    }

    // ── calculate_line_cost tests ──

    #[test]
    fn cost_basic_input_output() {
        let usage = TokenUsage {
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
            cache_creation: None,
        };
        let cost = calculate_line_cost(&usage, "claude-opus-4-6");
        // 1M input * $5/MTok + 1M output * $25/MTok = $30
        assert!((cost - 30.0).abs() < 1e-9);
    }

    #[test]
    fn cost_with_cache_read() {
        let usage = TokenUsage {
            input_tokens: 0,
            output_tokens: 0,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 1_000_000,
            cache_creation: None,
        };
        let cost = calculate_line_cost(&usage, "claude-opus-4-6");
        // 1M cache_read * $0.5/MTok = $0.5
        assert!((cost - 0.5).abs() < 1e-9);
    }

    #[test]
    fn cost_with_cache_write_legacy() {
        let usage = TokenUsage {
            input_tokens: 0,
            output_tokens: 0,
            cache_creation_input_tokens: 1_000_000,
            cache_read_input_tokens: 0,
            cache_creation: None,
        };
        let cost = calculate_line_cost(&usage, "claude-opus-4-6");
        // 1M cache_write * $10/MTok = $10
        assert!((cost - 10.0).abs() < 1e-9);
    }

    #[test]
    fn cost_with_cache_creation_breakdown() {
        let usage = TokenUsage {
            input_tokens: 0,
            output_tokens: 0,
            cache_creation_input_tokens: 500_000, // ignored when breakdown present
            cache_read_input_tokens: 0,
            cache_creation: Some(CacheCreationBreakdown {
                ephemeral_1h_input_tokens: 1_000_000,
            }),
        };
        let cost = calculate_line_cost(&usage, "claude-opus-4-6");
        // Uses breakdown: 1M * $10/MTok = $10
        assert!((cost - 10.0).abs() < 1e-9);
    }

    #[test]
    fn cost_zero_tokens() {
        let usage = TokenUsage {
            input_tokens: 0,
            output_tokens: 0,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
            cache_creation: None,
        };
        assert_eq!(calculate_line_cost(&usage, "claude-opus-4-6"), 0.0);
    }

    // ── decode_project_dir tests ──

    #[test]
    fn decode_standard_path() {
        // Note: decode_project_dir replaces all '-' with '/' — hyphens in
        // directory names (e.g. tty-mesh) are not preserved. This is a known
        // limitation; the cwd field from JSONL is preferred when available.
        let path =
            PathBuf::from("/home/user/.claude/projects/-Users-jinwoo-work-project/abc.jsonl");
        let decoded = decode_project_dir(&path);
        assert_eq!(decoded, "/Users/jinwoo/work/project");
    }

    #[test]
    fn decode_no_projects_parent() {
        let path = PathBuf::from("/tmp/random/file.jsonl");
        let decoded = decode_project_dir(&path);
        assert_eq!(decoded, "unknown");
    }

    // ── process_line tests ──

    fn make_state() -> TrackerState {
        TrackerState {
            sessions: HashMap::new(),
            file_positions: HashMap::new(),
            claude_projects_dir: PathBuf::from("/tmp"),
            latest_session_per_cwd: HashMap::new(),
            session_started_at: HashMap::new(),
        }
    }

    /// Build an assistant JsonlLine. `timestamp` is the line's ISO-8601 field.
    fn assistant_entry(
        session_id: &str,
        cwd: Option<&str>,
        timestamp: Option<&str>,
        usage: TokenUsage,
    ) -> JsonlLine {
        JsonlLine {
            line_type: "assistant".into(),
            session_id: Some(session_id.into()),
            cwd: cwd.map(str::to_string),
            timestamp: timestamp.map(str::to_string),
            message: Some(AssistantMessage {
                model: Some("claude-sonnet-4-6".into()),
                usage: Some(usage),
            }),
        }
    }

    fn usage(input: u64, output: u64, cr: u64, cw: u64) -> TokenUsage {
        TokenUsage {
            input_tokens: input,
            output_tokens: output,
            cache_creation_input_tokens: cw,
            cache_read_input_tokens: cr,
            cache_creation: None,
        }
    }

    #[test]
    fn process_assistant_line() {
        let mut state = make_state();
        let entry = assistant_entry(
            "sess1",
            Some("/home/user/project"),
            None,
            usage(100, 50, 0, 0),
        );
        let path = PathBuf::from("/home/user/.claude/projects/-test/file.jsonl");
        process_line(&mut state, &entry, &path);

        assert_eq!(state.sessions.len(), 1);
        let stats = state.sessions.get("sess1").unwrap();
        assert_eq!(stats.input_tokens, 100);
        assert_eq!(stats.output_tokens, 50);
        assert_eq!(stats.api_calls, 1);
        assert_eq!(stats.project_path, "/home/user/project");
    }

    #[test]
    fn process_non_assistant_skipped() {
        let mut state = make_state();
        let entry = JsonlLine {
            line_type: "user".into(),
            session_id: Some("sess1".into()),
            cwd: None,
            timestamp: None,
            message: None,
        };
        let path = PathBuf::from("/tmp/file.jsonl");
        process_line(&mut state, &entry, &path);
        assert!(state.sessions.is_empty());
    }

    #[test]
    fn process_no_session_id_skipped() {
        let mut state = make_state();
        let entry = JsonlLine {
            line_type: "assistant".into(),
            session_id: None,
            cwd: None,
            timestamp: None,
            message: Some(AssistantMessage {
                model: Some("claude-opus-4-6".into()),
                usage: Some(usage(100, 50, 0, 0)),
            }),
        };
        let path = PathBuf::from("/tmp/file.jsonl");
        process_line(&mut state, &entry, &path);
        assert!(state.sessions.is_empty());
    }

    #[test]
    fn process_no_usage_skipped() {
        let mut state = make_state();
        let entry = JsonlLine {
            line_type: "assistant".into(),
            session_id: Some("sess1".into()),
            cwd: None,
            timestamp: None,
            message: Some(AssistantMessage {
                model: Some("claude-opus-4-6".into()),
                usage: None,
            }),
        };
        let path = PathBuf::from("/tmp/file.jsonl");
        process_line(&mut state, &entry, &path);
        assert!(state.sessions.is_empty());
    }

    #[test]
    fn process_multiple_lines_accumulate() {
        let mut state = make_state();
        let path = PathBuf::from("/home/user/.claude/projects/-test/file.jsonl");

        for _ in 0..3 {
            let entry = assistant_entry("sess1", Some("/project"), None, usage(100, 50, 20, 0));
            process_line(&mut state, &entry, &path);
        }

        let stats = state.sessions.get("sess1").unwrap();
        assert_eq!(stats.input_tokens, 300);
        assert_eq!(stats.output_tokens, 150);
        assert_eq!(stats.cache_read_tokens, 60);
        assert_eq!(stats.api_calls, 3);
    }

    // ── UsageSnapshot aggregation ──

    #[test]
    fn snapshot_aggregates_multiple_sessions() {
        let mut state = make_state();
        let path = PathBuf::from("/home/user/.claude/projects/-test/file.jsonl");

        let entry1 = assistant_entry(
            "sess1",
            Some("/project1"),
            None,
            usage(1_000_000, 500_000, 0, 0),
        );
        process_line(&mut state, &entry1, &path);

        let entry2 = assistant_entry(
            "sess2",
            Some("/project2"),
            None,
            usage(500_000, 200_000, 0, 0),
        );
        process_line(&mut state, &entry2, &path);

        // Build snapshot manually (same logic as UsageTracker::snapshot)
        let sessions: Vec<SessionUsageStats> = state.sessions.values().cloned().collect();
        let total_input: u64 = sessions.iter().map(|s| s.input_tokens).sum();
        let total_output: u64 = sessions.iter().map(|s| s.output_tokens).sum();

        assert_eq!(sessions.len(), 2);
        assert_eq!(total_input, 1_500_000);
        assert_eq!(total_output, 700_000);
    }

    // ── snapshot_by_project ──

    #[test]
    fn snapshot_by_project_returns_only_latest_session() {
        let mut state = make_state();
        let path = PathBuf::from("/home/user/.claude/projects/-test/file.jsonl");

        // sessA processed first (older)
        let entry_a = assistant_entry("sessA", Some("/project/foo"), None, usage(999, 888, 0, 0));
        process_line(&mut state, &entry_a, &path);

        // sessB processed second (newer — becomes "current session")
        let entry_b = assistant_entry("sessB", Some("/project/foo"), None, usage(100, 50, 20, 10));
        process_line(&mut state, &entry_b, &path);

        // sessC in a different project
        let entry_c = assistant_entry("sessC", Some("/project/bar"), None, usage(300, 150, 0, 0));
        process_line(&mut state, &entry_c, &path);

        let tracker = UsageTracker {
            state: Arc::new(Mutex::new(state)),
        };
        let by_project = tracker.snapshot_by_project();

        assert_eq!(by_project.len(), 2);
        // Only sessB (the latest-processed session for foo), NOT sessA+sessB sum
        let foo = by_project["/project/foo"];
        assert_eq!(foo.0, 100);
        assert_eq!(foo.1, 50);
        assert_eq!(foo.2, 20);
        assert_eq!(foo.3, 10);

        let bar = by_project["/project/bar"];
        assert_eq!(bar.0, 300);
        assert_eq!(bar.1, 150);
    }

    // ── iso8601_to_unix ──

    #[test]
    fn iso8601_parses_known_epoch() {
        // 1970-01-01T00:00:00Z is Unix 0.
        assert_eq!(iso8601_to_unix("1970-01-01T00:00:00.000Z"), Some(0));
        // 2000-01-01T00:00:00Z = 946684800.
        assert_eq!(iso8601_to_unix("2000-01-01T00:00:00Z"), Some(946684800));
        // A real Claude jsonl timestamp; sub-second precision is dropped.
        assert_eq!(
            iso8601_to_unix("2026-05-13T01:18:43.744Z"),
            Some(1778635123)
        );
    }

    #[test]
    fn iso8601_rejects_malformed() {
        assert_eq!(iso8601_to_unix(""), None);
        assert_eq!(iso8601_to_unix("not-a-date"), None);
        assert_eq!(iso8601_to_unix("2026-13-01T00:00:00Z"), None); // month 13
        assert_eq!(iso8601_to_unix("2026-05-00T00:00:00Z"), None); // day 0
    }

    // ── record_session_start ──

    #[test]
    fn record_session_start_keeps_earliest_timestamp() {
        let mut state = make_state();
        // attachment line is usually first and carries the timestamp.
        let early = JsonlLine {
            line_type: "attachment".into(),
            session_id: Some("sess1".into()),
            cwd: Some("/cwd".into()),
            timestamp: Some("2026-05-13T01:00:00.000Z".into()),
            message: None,
        };
        let late = assistant_entry(
            "sess1",
            Some("/cwd"),
            Some("2026-05-13T01:05:00.000Z"),
            usage(1, 1, 0, 0),
        );
        // Process in chronological order, then again out of order.
        record_session_start(&mut state, &early);
        record_session_start(&mut state, &late);
        let expected = iso8601_to_unix("2026-05-13T01:00:00.000Z").unwrap();
        assert_eq!(state.session_started_at.get("sess1"), Some(&expected));
        // A later re-scan of an even-earlier line still lowers the value.
        let earlier = JsonlLine {
            timestamp: Some("2026-05-13T00:55:00.000Z".into()),
            ..early
        };
        record_session_start(&mut state, &earlier);
        let expected_earlier = iso8601_to_unix("2026-05-13T00:55:00.000Z").unwrap();
        assert_eq!(
            state.session_started_at.get("sess1"),
            Some(&expected_earlier)
        );
    }

    #[test]
    fn record_session_start_ignores_lines_without_timestamp() {
        let mut state = make_state();
        // last-prompt / permission-mode lines have sessionId but no timestamp.
        let no_ts = JsonlLine {
            line_type: "last-prompt".into(),
            session_id: Some("sess1".into()),
            cwd: None,
            timestamp: None,
            message: None,
        };
        record_session_start(&mut state, &no_ts);
        assert!(state.session_started_at.is_empty());
    }

    // ── snapshot_by_panel ──

    #[test]
    fn snapshot_by_panel_same_cwd_two_panes_distinct_sessions() {
        let mut state = make_state();
        let path = PathBuf::from("/home/user/.claude/projects/-test/file.jsonl");

        // Two sessions in the same cwd, started 60s apart — start time is taken
        // from each line's own ISO-8601 timestamp via record_session_start.
        let entry_a = assistant_entry(
            "sessA",
            Some("/cwd/shared"),
            Some("2026-05-13T01:00:00.000Z"),
            usage(100, 50, 0, 0),
        );
        let entry_b = assistant_entry(
            "sessB",
            Some("/cwd/shared"),
            Some("2026-05-13T01:01:00.000Z"),
            usage(200, 100, 0, 0),
        );
        record_session_start(&mut state, &entry_a);
        process_line(&mut state, &entry_a, &path);
        record_session_start(&mut state, &entry_b);
        process_line(&mut state, &entry_b, &path);

        let base = iso8601_to_unix("2026-05-13T01:00:00.000Z").unwrap();
        let tracker = UsageTracker {
            state: Arc::new(Mutex::new(state)),
        };

        // Sessions sorted by started_at: [sessA@base, sessB@base+60].
        // Panes sorted by (proc_start, pid): [panelA@base+5, panelB@base+62].
        // Index-zip: panelA→sessA, panelB→sessB.
        let panes = vec![
            (
                "panelA".to_string(),
                "/cwd/shared".to_string(),
                base + 5,
                1_u32,
            ),
            (
                "panelB".to_string(),
                "/cwd/shared".to_string(),
                base + 62,
                2_u32,
            ),
        ];
        let by_panel = tracker.snapshot_by_panel(&panes);

        assert_eq!(
            by_panel.len(),
            2,
            "both panes should match distinct sessions"
        );
        assert_eq!(by_panel["panelA"].0, 100); // → sessA
        assert_eq!(by_panel["panelB"].0, 200); // → sessB
    }

    #[test]
    fn snapshot_by_panel_exceeds_max_diff_skipped() {
        let mut state = make_state();
        let path = PathBuf::from("/home/user/.claude/projects/-test/file.jsonl");
        let entry = assistant_entry(
            "sessX",
            Some("/cwd/far"),
            Some("2026-05-13T01:00:00.000Z"),
            usage(50, 25, 0, 0),
        );
        record_session_start(&mut state, &entry);
        process_line(&mut state, &entry, &path);

        let base = iso8601_to_unix("2026-05-13T01:00:00.000Z").unwrap();
        let tracker = UsageTracker {
            state: Arc::new(Mutex::new(state)),
        };
        // proc_start = base+500 → diff 500s > MAX_DIFF(300) → not relevant → skip
        let panes = vec![(
            "panelX".to_string(),
            "/cwd/far".to_string(),
            base + 500,
            1_u32,
        )];
        let by_panel = tracker.snapshot_by_panel(&panes);
        assert!(by_panel.is_empty(), "diff > 300s should be skipped");
    }

    #[test]
    fn snapshot_by_panel_same_second_spawn_pid_tiebreak() {
        // Two sessions with the *same* start timestamp (1-second resolution).
        // The old code refused this as an ambiguous tie; now panes sorted by
        // (proc_start, pid) zip 1:1 against sessions sorted by (started, id).
        let mut state = make_state();
        let path = PathBuf::from("/home/user/.claude/projects/-test/file.jsonl");
        let entry_a = assistant_entry(
            "sessA",
            Some("/cwd/tie"),
            Some("2026-05-13T01:00:00.000Z"),
            usage(100, 0, 0, 0),
        );
        let entry_b = assistant_entry(
            "sessB",
            Some("/cwd/tie"),
            Some("2026-05-13T01:00:00.000Z"),
            usage(200, 0, 0, 0),
        );
        record_session_start(&mut state, &entry_a);
        process_line(&mut state, &entry_a, &path);
        record_session_start(&mut state, &entry_b);
        process_line(&mut state, &entry_b, &path);

        let base = iso8601_to_unix("2026-05-13T01:00:00.000Z").unwrap();
        let tracker = UsageTracker {
            state: Arc::new(Mutex::new(state)),
        };
        // Same proc_start, distinct PIDs given out of order. Sessions sort
        // (base, "sessA") < (base, "sessB"); panes sort by pid 10 < 20.
        let panes = vec![
            (
                "panelHigh".to_string(),
                "/cwd/tie".to_string(),
                base,
                20_u32,
            ),
            ("panelLow".to_string(), "/cwd/tie".to_string(), base, 10_u32),
        ];
        let by_panel = tracker.snapshot_by_panel(&panes);
        assert_eq!(by_panel.len(), 2, "no tie-refusal — both panels matched");
        assert_eq!(by_panel["panelLow"].0, 100); // lower pid → sessA
        assert_eq!(by_panel["panelHigh"].0, 200); // higher pid → sessB
    }

    // ── JSONL parsing from string ──

    #[test]
    fn parse_valid_jsonl_line() {
        let json = r#"{"type":"assistant","sessionId":"abc","message":{"model":"claude-opus-4-6","usage":{"input_tokens":100,"output_tokens":50}}}"#;
        let entry: JsonlLine = serde_json::from_str(json).unwrap();
        assert_eq!(entry.line_type, "assistant");
        assert_eq!(entry.session_id.as_deref(), Some("abc"));
        assert_eq!(entry.message.unwrap().usage.unwrap().input_tokens, 100);
    }

    #[test]
    fn parse_malformed_json_returns_error() {
        let json = r#"{"type": "assistant", broken}"#;
        assert!(serde_json::from_str::<JsonlLine>(json).is_err());
    }

    #[test]
    fn parse_empty_string_returns_error() {
        assert!(serde_json::from_str::<JsonlLine>("").is_err());
    }
}
