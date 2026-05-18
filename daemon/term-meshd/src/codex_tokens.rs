use serde::Deserialize;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use crate::tokens::iso8601_to_unix;

/// One Codex rollout session's current cumulative usage.
#[derive(Debug, Clone)]
struct CodexSession {
    cwd: String,
    /// Session start time (Unix seconds), from the `session_meta` payload's
    /// own `timestamp` field. Used for proc-start correlation (R4 v3).
    started_at: i64,
    /// `total_token_usage.input_tokens` from the latest `token_count` event.
    input: u64,
    /// `output_tokens + reasoning_output_tokens` — reasoning is billed output.
    output: u64,
    /// `cached_input_tokens` — surfaced as cache_read to mirror Claude's 4-tuple.
    cache_read: u64,
}

#[derive(Default)]
struct CodexState {
    /// rollout file path → parsed session usage.
    sessions: HashMap<PathBuf, CodexSession>,
    /// rollout file path → byte offset already consumed (incremental parsing).
    file_positions: HashMap<PathBuf, u64>,
}

/// Tracks Codex token usage by parsing rollout JSONL logs under
/// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
///
/// Each rollout file's first line is a `session_meta` (cwd + start timestamp);
/// every `token_count` `event_msg` carries the session's cumulative
/// `total_token_usage`, so the most recent one wins. This replaces the old
/// `state_5.sqlite` reader, which only exposed `total_tokens` (input + output
/// + reasoning lumped together) and forced a misleading "0 in" sidebar value.
///
/// Same incremental-parse model as the Claude `UsageTracker`; the 2s codex
/// broadcaster tick is the poll that drives `scan()`.
pub struct CodexUsageTracker {
    sessions_dir: PathBuf,
    state: Arc<Mutex<CodexState>>,
}

// ── rollout JSONL structures ──

#[derive(Debug, Deserialize)]
struct RolloutLine {
    #[serde(rename = "type")]
    line_type: String,
    payload: Option<RolloutPayload>,
}

#[derive(Debug, Deserialize)]
struct RolloutPayload {
    // session_meta fields
    cwd: Option<String>,
    timestamp: Option<String>,
    // event_msg fields
    #[serde(rename = "type")]
    event_type: Option<String>,
    info: Option<TokenCountInfo>,
}

#[derive(Debug, Deserialize)]
struct TokenCountInfo {
    total_token_usage: Option<CodexTokenUsage>,
}

#[derive(Debug, Deserialize)]
struct CodexTokenUsage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    cached_input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    reasoning_output_tokens: u64,
}

impl CodexUsageTracker {
    /// Returns Some if `~/.codex/sessions/` exists, None otherwise.
    pub fn new() -> Option<Self> {
        let sessions_dir = dirs::home_dir()?.join(".codex").join("sessions");
        if sessions_dir.is_dir() {
            Some(Self {
                sessions_dir,
                state: Arc::new(Mutex::new(CodexState::default())),
            })
        } else {
            None
        }
    }

    /// Incrementally parse every rollout JSONL file under `sessions_dir`.
    fn scan(&self) -> anyhow::Result<()> {
        let mut files = Vec::new();
        collect_rollout_files(&self.sessions_dir, &mut files, 0);

        let mut state = self.state.lock().unwrap();
        // Drop state for files that no longer exist.
        state.file_positions.retain(|p, _| p.exists());
        state.sessions.retain(|p, _| p.exists());

        for path in files {
            if let Err(e) = scan_rollout_file(&mut state, &path) {
                tracing::debug!("codex.token.parse.skip path={} err={e}", path.display());
            }
        }
        Ok(())
    }

    /// Per-panel token totals correlated by process start time, with a PID
    /// tiebreaker for same-second spawns (R4 v3).
    ///
    /// `panes`: (panel_id, cwd, proc_start_unix, pid) from PaneTracker.
    ///
    /// Within one cwd, panes sorted by (proc_start, pid) zip 1:1 against
    /// rollout sessions sorted by (started_at, rollout_path). The rollout file
    /// name embeds the start timestamp, so the path is a stable chronological
    /// tiebreak. The 300s `MAX_DIFF` guard drops stale sessions.
    ///
    /// Returns: panel_id → (input, output, cache_read, cache_write). Codex has
    /// no cache-write concept, so cache_write is always 0.
    pub fn snapshot_by_panel(
        &self,
        panes: &[(String, String, i64, u32)],
    ) -> anyhow::Result<HashMap<String, (u64, u64, u64, u64)>> {
        self.scan()?;
        const MAX_DIFF: i64 = 300;
        let state = self.state.lock().unwrap();

        // (started_at, rollout_path, tokens) grouped by cwd.
        let mut sessions_by_cwd: HashMap<&str, Vec<(i64, &Path, (u64, u64, u64, u64))>> =
            HashMap::new();
        for (path, s) in &state.sessions {
            sessions_by_cwd.entry(s.cwd.as_str()).or_default().push((
                s.started_at,
                path.as_path(),
                (s.input, s.output, s.cache_read, 0),
            ));
        }
        for v in sessions_by_cwd.values_mut() {
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
            let relevant: Vec<&(i64, &Path, (u64, u64, u64, u64))> = cwd_sessions
                .iter()
                .filter(|(started, _, _)| {
                    cwd_panes
                        .iter()
                        .any(|&(_, proc_start, _)| (started - proc_start).abs() <= MAX_DIFF)
                })
                .collect();
            for (i, &(panel_id, proc_start, _pid)) in cwd_panes.iter().enumerate() {
                let Some(&&(started, _path, tokens)) = relevant.get(i) else {
                    continue;
                };
                if (started - proc_start).abs() > MAX_DIFF {
                    continue;
                }
                by_panel.insert(panel_id.to_string(), tokens);
            }
        }
        Ok(by_panel)
    }
}

/// Recursively collect `rollout-*.jsonl` files. Depth-capped as a guard; the
/// real layout is `YYYY/MM/DD/` (depth 3).
fn collect_rollout_files(dir: &Path, out: &mut Vec<PathBuf>, depth: u32) {
    if depth > 5 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_rollout_files(&path, out, depth + 1);
        } else if path
            .file_name()
            .and_then(|n| n.to_str())
            .map(|n| n.starts_with("rollout-") && n.ends_with(".jsonl"))
            .unwrap_or(false)
        {
            out.push(path);
        }
    }
}

/// Incrementally parse one rollout file from its last consumed byte offset.
fn scan_rollout_file(state: &mut CodexState, path: &Path) -> anyhow::Result<()> {
    let file_len = std::fs::metadata(path)?.len();
    let mut offset = state.file_positions.get(path).copied().unwrap_or(0);

    if file_len < offset {
        // Truncated/rotated — restart from the top.
        state.sessions.remove(path);
        offset = 0;
    }
    if file_len == offset {
        return Ok(());
    }

    let file = std::fs::File::open(path)?;
    let mut reader = BufReader::new(file);
    reader.seek(SeekFrom::Start(offset))?;

    let mut line_buf = String::new();
    while reader.read_line(&mut line_buf)? > 0 {
        let trimmed = line_buf.trim();
        if !trimmed.is_empty() {
            if let Ok(line) = serde_json::from_str::<RolloutLine>(trimmed) {
                apply_rollout_line(state, path, &line);
            }
        }
        line_buf.clear();
    }

    let new_offset = reader.stream_position()?;
    state.file_positions.insert(path.to_path_buf(), new_offset);
    Ok(())
}

/// Fold one parsed rollout line into the per-session state.
fn apply_rollout_line(state: &mut CodexState, path: &Path, line: &RolloutLine) {
    let Some(payload) = &line.payload else {
        return;
    };
    match line.line_type.as_str() {
        "session_meta" => {
            let (Some(cwd), Some(ts)) = (&payload.cwd, &payload.timestamp) else {
                return;
            };
            let started_at = iso8601_to_unix(ts).unwrap_or(0);
            state.sessions.insert(
                path.to_path_buf(),
                CodexSession {
                    cwd: cwd.clone(),
                    started_at,
                    input: 0,
                    output: 0,
                    cache_read: 0,
                },
            );
        }
        "event_msg" => {
            if payload.event_type.as_deref() != Some("token_count") {
                return;
            }
            let Some(usage) = payload
                .info
                .as_ref()
                .and_then(|i| i.total_token_usage.as_ref())
            else {
                return;
            };
            // total_token_usage is cumulative — the latest event wins.
            if let Some(session) = state.sessions.get_mut(path) {
                session.input = usage.input_tokens;
                session.output = usage.output_tokens + usage.reasoning_output_tokens;
                session.cache_read = usage.cached_input_tokens;
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    const META: &str = r#"{"timestamp":"2026-01-01T00:00:00.000Z","type":"session_meta","payload":{"id":"x","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/c"}}"#;

    /// Write a minimal rollout file: one session_meta + one token_count event.
    /// `usage` = (input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens).
    fn write_rollout(
        dir: &Path,
        name: &str,
        cwd: &str,
        started_iso: &str,
        usage: (u64, u64, u64, u64),
    ) -> PathBuf {
        let path = dir.join(name);
        let meta = format!(
            r#"{{"timestamp":"2026-01-01T00:00:00.000Z","type":"session_meta","payload":{{"id":"x","timestamp":"{started_iso}","cwd":"{cwd}"}}}}"#
        );
        let tc = format!(
            r#"{{"timestamp":"2026-01-01T00:00:01.000Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":{},"cached_input_tokens":{},"output_tokens":{},"reasoning_output_tokens":{},"total_tokens":0}}}}}}}}"#,
            usage.0, usage.1, usage.2, usage.3
        );
        std::fs::write(&path, format!("{meta}\n{tc}\n")).unwrap();
        path
    }

    #[test]
    fn parses_token_count_event_fields() {
        let json = r#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50023,"cached_input_tokens":44160,"output_tokens":481,"reasoning_output_tokens":223,"total_tokens":50504}}}}"#;
        let line: RolloutLine = serde_json::from_str(json).unwrap();
        let usage = line
            .payload
            .unwrap()
            .info
            .unwrap()
            .total_token_usage
            .unwrap();
        assert_eq!(usage.input_tokens, 50023);
        assert_eq!(usage.cached_input_tokens, 44160);
        assert_eq!(usage.output_tokens, 481);
        assert_eq!(usage.reasoning_output_tokens, 223);
    }

    #[test]
    fn parses_session_meta_cwd_and_timestamp() {
        let line: RolloutLine = serde_json::from_str(META).unwrap();
        assert_eq!(line.line_type, "session_meta");
        let p = line.payload.unwrap();
        assert_eq!(p.cwd.as_deref(), Some("/c"));
        assert_eq!(p.timestamp.as_deref(), Some("2026-01-01T00:00:00.000Z"));
    }

    #[test]
    fn apply_rollout_line_folds_meta_then_token_count() {
        let mut state = CodexState::default();
        let path = PathBuf::from("/tmp/rollout-x.jsonl");
        let meta: RolloutLine = serde_json::from_str(META).unwrap();
        apply_rollout_line(&mut state, &path, &meta);

        let tc_json = r#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50023,"cached_input_tokens":44160,"output_tokens":481,"reasoning_output_tokens":223,"total_tokens":50504}}}}"#;
        let tc: RolloutLine = serde_json::from_str(tc_json).unwrap();
        apply_rollout_line(&mut state, &path, &tc);

        let s = state.sessions.get(&path).unwrap();
        assert_eq!(s.cwd, "/c");
        assert_eq!(s.input, 50023);
        // output = output_tokens + reasoning_output_tokens (reasoning is billed output)
        assert_eq!(s.output, 481 + 223);
        // cached_input_tokens → cache_read
        assert_eq!(s.cache_read, 44160);
    }

    #[test]
    fn apply_rollout_line_latest_token_count_wins() {
        let mut state = CodexState::default();
        let path = PathBuf::from("/tmp/rollout-y.jsonl");
        let meta: RolloutLine = serde_json::from_str(META).unwrap();
        apply_rollout_line(&mut state, &path, &meta);

        for (input, output) in [(100u64, 10u64), (250u64, 30u64)] {
            let json = format!(
                r#"{{"type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":{input},"cached_input_tokens":0,"output_tokens":{output},"reasoning_output_tokens":0,"total_tokens":0}}}}}}}}"#
            );
            let line: RolloutLine = serde_json::from_str(&json).unwrap();
            apply_rollout_line(&mut state, &path, &line);
        }
        let s = state.sessions.get(&path).unwrap();
        // cumulative — last event (250/30) replaces, not sums.
        assert_eq!(s.input, 250);
        assert_eq!(s.output, 30);
    }

    #[test]
    fn snapshot_by_panel_emits_four_tuple_from_rollout() {
        let dir = TempDir::new().unwrap();
        write_rollout(
            dir.path(),
            "rollout-a.jsonl",
            "/proj",
            "2026-01-01T01:00:00.000Z",
            (50023, 44160, 481, 223),
        );
        let tracker = CodexUsageTracker {
            sessions_dir: dir.path().to_path_buf(),
            state: Arc::new(Mutex::new(CodexState::default())),
        };
        let base = iso8601_to_unix("2026-01-01T01:00:00.000Z").unwrap();
        let panes = vec![("panel1".to_string(), "/proj".to_string(), base + 3, 100_u32)];
        let by_panel = tracker.snapshot_by_panel(&panes).unwrap();

        let (input, output, cache_read, cache_write) = by_panel["panel1"];
        assert_eq!(input, 50023);
        assert_eq!(output, 481 + 223); // output + reasoning
        assert_eq!(cache_read, 44160); // cached_input_tokens
        assert_eq!(cache_write, 0); // codex has no cache-write
    }

    #[test]
    fn snapshot_by_panel_same_second_spawn_pid_tiebreak() {
        // 3 rollout sessions, same cwd, same start second. Panes share
        // proc_start; PID order must align 1:1 with rollout-path order.
        let dir = TempDir::new().unwrap();
        write_rollout(
            dir.path(),
            "rollout-a.jsonl",
            "/team",
            "2026-01-01T05:00:00.000Z",
            (111, 0, 0, 0),
        );
        write_rollout(
            dir.path(),
            "rollout-b.jsonl",
            "/team",
            "2026-01-01T05:00:00.000Z",
            (222, 0, 0, 0),
        );
        write_rollout(
            dir.path(),
            "rollout-c.jsonl",
            "/team",
            "2026-01-01T05:00:00.000Z",
            (333, 0, 0, 0),
        );
        let tracker = CodexUsageTracker {
            sessions_dir: dir.path().to_path_buf(),
            state: Arc::new(Mutex::new(CodexState::default())),
        };
        let base = iso8601_to_unix("2026-01-01T05:00:00.000Z").unwrap();
        // Panes given out of order; same proc_start, PIDs 9001<9002<9003.
        let panes = vec![
            ("panel3".to_string(), "/team".to_string(), base, 9003_u32),
            ("panel1".to_string(), "/team".to_string(), base, 9001_u32),
            ("panel2".to_string(), "/team".to_string(), base, 9002_u32),
        ];
        let by_panel = tracker.snapshot_by_panel(&panes).unwrap();
        assert_eq!(by_panel.len(), 3, "no tie-refusal — all 3 panels matched");
        // PID order 9001<9002<9003 ↔ path order rollout-a/b/c.
        assert_eq!(by_panel["panel1"].0, 111);
        assert_eq!(by_panel["panel2"].0, 222);
        assert_eq!(by_panel["panel3"].0, 333);
    }

    #[test]
    fn snapshot_by_panel_exceeds_max_diff_skipped() {
        let dir = TempDir::new().unwrap();
        write_rollout(
            dir.path(),
            "rollout-x.jsonl",
            "/far",
            "2026-01-01T00:00:00.000Z",
            (10, 0, 5, 0),
        );
        let tracker = CodexUsageTracker {
            sessions_dir: dir.path().to_path_buf(),
            state: Arc::new(Mutex::new(CodexState::default())),
        };
        let base = iso8601_to_unix("2026-01-01T00:00:00.000Z").unwrap();
        // proc_start = base + 500 → diff 500s > MAX_DIFF(300)
        let panes = vec![("panelX".to_string(), "/far".to_string(), base + 500, 1_u32)];
        let by_panel = tracker.snapshot_by_panel(&panes).unwrap();
        assert!(by_panel.is_empty());
    }

    #[test]
    fn snapshot_by_panel_no_sessions_dir_is_empty() {
        let dir = TempDir::new().unwrap();
        let tracker = CodexUsageTracker {
            sessions_dir: dir.path().to_path_buf(),
            state: Arc::new(Mutex::new(CodexState::default())),
        };
        let panes = vec![("p".to_string(), "/c".to_string(), 1000_i64, 1_u32)];
        assert!(tracker.snapshot_by_panel(&panes).unwrap().is_empty());
    }
}
