use rusqlite::{Connection, OpenFlags};
use std::collections::HashMap;
use std::path::PathBuf;

/// Tracks Codex token usage by querying ~/.codex/state_5.sqlite.
/// Opens read-only on every tick to avoid WAL lock contention with the
/// running Codex process (no long-held connection).
pub struct CodexUsageTracker {
    pub db_path: PathBuf,
}

impl CodexUsageTracker {
    /// Returns Some if ~/.codex/state_5.sqlite exists, None otherwise.
    pub fn new() -> Option<Self> {
        let db_path = dirs::home_dir()?.join(".codex").join("state_5.sqlite");
        if db_path.exists() {
            Some(Self { db_path })
        } else {
            None
        }
    }

    /// Current-session token count keyed by cwd.
    /// Returns only the most recently updated (active) thread per cwd.
    /// Returns: cwd → tokens_used of the latest thread
    #[allow(dead_code)]
    pub fn snapshot_by_project(&self) -> anyhow::Result<HashMap<String, u64>> {
        let conn = Connection::open_with_flags(
            &self.db_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        // Join each thread against the per-cwd MAX(updated_at) to pick the latest only.
        let mut stmt = conn.prepare(
            "SELECT t.cwd, t.tokens_used \
             FROM threads t \
             INNER JOIN ( \
               SELECT cwd, MAX(updated_at) AS max_ts \
               FROM threads WHERE archived = 0 GROUP BY cwd \
             ) latest ON t.cwd = latest.cwd AND t.updated_at = latest.max_ts \
             WHERE t.archived = 0",
        )?;
        let rows: HashMap<String, u64> = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64)))?
            .collect::<Result<_, _>>()?;
        Ok(rows)
    }

    /// Per-panel token count correlated by process start time.
    /// `panes`: (panel_id, cwd, proc_start_unix) from PaneTracker.
    /// Matches each pane to the Codex thread created closest to `proc_start_unix`
    /// (within 300s). Refuses the match when two threads are within 1s (ambiguous).
    /// Returns: panel_id → tokens_used.
    pub fn snapshot_by_panel(
        &self,
        panes: &[(String, String, i64)],
    ) -> anyhow::Result<HashMap<String, u64>> {
        const MAX_DIFF: i64 = 300;
        const TIE: i64 = 1;
        let conn = Connection::open_with_flags(
            &self.db_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        let mut stmt = conn.prepare(
            "SELECT cwd, tokens_used, created_at FROM threads WHERE archived = 0",
        )?;
        // (cwd, tokens_used, created_at)
        let threads: Vec<(String, u64, i64)> = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)? as u64,
                    r.get::<_, i64>(2)?,
                ))
            })?
            .collect::<Result<_, _>>()?;

        let mut by_panel = HashMap::new();
        for (panel_id, cwd, proc_start) in panes {
            let mut candidates: Vec<(i64, u64)> = threads
                .iter()
                .filter(|(tcwd, _, _)| tcwd == cwd)
                .map(|(_, tokens, created_at)| ((created_at - proc_start).abs(), *tokens))
                .collect();
            if candidates.is_empty() {
                continue;
            }
            candidates.sort_unstable_by_key(|&(diff, _)| diff);
            let (best_diff, best_tokens) = candidates[0];
            if best_diff > MAX_DIFF {
                continue;
            }
            if candidates.len() >= 2 && candidates[1].0 - best_diff <= TIE {
                tracing::debug!(
                    "codex.token.skip reason=ambiguous-start-time panel={panel_id}"
                );
                continue;
            }
            by_panel.insert(panel_id.clone(), best_tokens);
        }
        Ok(by_panel)
    }

}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn create_test_db(dir: &TempDir) -> PathBuf {
        let db_path = dir.path().join("state_5.sqlite");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                cwd TEXT NOT NULL,
                tokens_used INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL,
                created_at INTEGER NOT NULL DEFAULT 0
            );",
        )
        .unwrap();
        // Two active threads in same cwd; created_at differs by 60s
        conn.execute(
            "INSERT INTO threads VALUES ('t1', '/project/foo', 1000, 0, 1000, 1000)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO threads VALUES ('t2', '/project/foo', 500, 0, 1001, 1060)",
            [],
        )
        .unwrap();
        // Different cwd
        conn.execute(
            "INSERT INTO threads VALUES ('t3', '/project/bar', 2000, 0, 1002, 1100)",
            [],
        )
        .unwrap();
        // Archived thread — must be excluded from totals
        conn.execute(
            "INSERT INTO threads VALUES ('t4', '/project/foo', 999, 1, 1003, 1200)",
            [],
        )
        .unwrap();
        db_path
    }

    #[test]
    fn snapshot_returns_most_recent_thread_not_sum() {
        let dir = TempDir::new().unwrap();
        let db_path = create_test_db(&dir);
        let tracker = CodexUsageTracker { db_path };
        let snap = tracker.snapshot_by_project().unwrap();

        assert_eq!(snap.len(), 2);
        // t2 has updated_at=1001 > t1's 1000 → t2's 500 tokens, NOT sum 1500
        // t4 archived=1 is excluded; t3 is the only bar thread → 2000
        assert_eq!(snap["/project/foo"], 500);
        assert_eq!(snap["/project/bar"], 2000);
    }


    #[test]
    fn snapshot_empty_table_returns_empty_map() {
        let dir = TempDir::new().unwrap();
        let db_path = dir.path().join("state_5.sqlite");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                cwd TEXT NOT NULL,
                tokens_used INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL
            );",
        )
        .unwrap();
        let tracker = CodexUsageTracker { db_path };
        let snap = tracker.snapshot_by_project().unwrap();
        assert!(snap.is_empty());
    }

    #[test]
    fn snapshot_missing_db_returns_error() {
        let tracker = CodexUsageTracker {
            db_path: PathBuf::from("/nonexistent/state_5.sqlite"),
        };
        assert!(tracker.snapshot_by_project().is_err());
    }

    #[test]
    fn all_archived_returns_empty_map() {
        let dir = TempDir::new().unwrap();
        let db_path = dir.path().join("state_5.sqlite");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                cwd TEXT NOT NULL,
                tokens_used INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL
            );",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO threads VALUES ('t1', '/project/foo', 1000, 1, 1000)",
            [],
        )
        .unwrap();
        let tracker = CodexUsageTracker { db_path };
        let snap = tracker.snapshot_by_project().unwrap();
        assert!(snap.is_empty());
    }

    #[test]
    fn snapshot_by_panel_same_cwd_two_panes_distinct_threads() {
        let dir = TempDir::new().unwrap();
        // t1 created_at=1000, t2 created_at=1060 (both in /project/foo)
        let db_path = create_test_db(&dir);
        let tracker = CodexUsageTracker { db_path };
        // panelA proc_start=1005 → closest to t1 (created_at=1000, diff=5)
        // panelB proc_start=1062 → closest to t2 (created_at=1060, diff=2)
        let panes = vec![
            ("panelA".to_string(), "/project/foo".to_string(), 1005_i64),
            ("panelB".to_string(), "/project/foo".to_string(), 1062_i64),
        ];
        let by_panel = tracker.snapshot_by_panel(&panes).unwrap();
        assert_eq!(by_panel.len(), 2);
        assert_eq!(by_panel["panelA"], 1000); // t1.tokens_used
        assert_eq!(by_panel["panelB"], 500);  // t2.tokens_used
    }

    #[test]
    fn snapshot_by_panel_exceeds_max_diff_skipped() {
        let dir = TempDir::new().unwrap();
        let db_path = create_test_db(&dir);
        let tracker = CodexUsageTracker { db_path };
        // t3 created_at=1100; proc_start=0 → diff=1100 > 300 → skipped
        let panes = vec![("panelX".to_string(), "/project/bar".to_string(), 0_i64)];
        let by_panel = tracker.snapshot_by_panel(&panes).unwrap();
        assert!(by_panel.is_empty());
    }
}
