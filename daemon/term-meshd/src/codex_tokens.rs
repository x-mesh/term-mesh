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

    /// Per-panel token count correlated by process start time, with a PID
    /// tiebreaker for same-second spawns.
    ///
    /// `panes`: (panel_id, cwd, proc_start_unix, pid) from PaneTracker.
    ///
    /// `etime` (pane start) and `threads.created_at` are both 1-second
    /// resolution, so a team that spawns several Codex agents within the same
    /// second produces identical timestamps and a plain nearest-time match
    /// ties. Within one cwd we therefore align *spawn order* to *creation
    /// order*: panes sorted by (proc_start, pid) zip 1:1 against threads sorted
    /// by (created_at, rowid). PID is monotonic with spawn order; rowid is
    /// monotonic with insertion order. The 300s `MAX_DIFF` guard still drops
    /// stale threads so a count mismatch cannot bind a pane to an old thread.
    /// Returns: panel_id → tokens_used.
    pub fn snapshot_by_panel(
        &self,
        panes: &[(String, String, i64, u32)],
    ) -> anyhow::Result<HashMap<String, u64>> {
        const MAX_DIFF: i64 = 300;
        let conn = Connection::open_with_flags(
            &self.db_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        // rowid ASC breaks the same-second created_at tie in insertion order.
        let mut stmt = conn.prepare(
            "SELECT cwd, tokens_used, created_at FROM threads \
             WHERE archived = 0 ORDER BY created_at ASC, rowid ASC",
        )?;
        // (tokens_used, created_at) per cwd, in (created_at, rowid) order.
        let mut threads_by_cwd: HashMap<String, Vec<(u64, i64)>> = HashMap::new();
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)? as u64,
                r.get::<_, i64>(2)?,
            ))
        })?;
        for row in rows {
            let (cwd, tokens, created_at) = row?;
            threads_by_cwd.entry(cwd).or_default().push((tokens, created_at));
        }

        // Group panes by cwd.
        let mut panes_by_cwd: HashMap<&str, Vec<(&str, i64, u32)>> = HashMap::new();
        for (panel_id, cwd, proc_start, pid) in panes {
            panes_by_cwd
                .entry(cwd.as_str())
                .or_default()
                .push((panel_id.as_str(), *proc_start, *pid));
        }

        let mut by_panel = HashMap::new();
        for (cwd, mut cwd_panes) in panes_by_cwd {
            let Some(cwd_threads) = threads_by_cwd.get(cwd) else {
                continue;
            };
            // Spawn order: earlier proc_start first, PID breaks the same-second tie.
            cwd_panes.sort_unstable_by_key(|&(_, proc_start, pid)| (proc_start, pid));
            // Drop stale threads not near any pane (keeps the index-zip aligned).
            let relevant: Vec<&(u64, i64)> = cwd_threads
                .iter()
                .filter(|(_, created_at)| {
                    cwd_panes
                        .iter()
                        .any(|&(_, proc_start, _)| (created_at - proc_start).abs() <= MAX_DIFF)
                })
                .collect();
            for (i, &(panel_id, proc_start, _pid)) in cwd_panes.iter().enumerate() {
                let Some(&&(tokens, created_at)) = relevant.get(i) else {
                    continue;
                };
                if (created_at - proc_start).abs() > MAX_DIFF {
                    continue;
                }
                by_panel.insert(panel_id.to_string(), tokens);
            }
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
        // Sorted by (created_at, rowid): [t1@1000, t2@1060].
        // Panes sorted by (proc_start, pid): [panelA@1005, panelB@1062].
        // Index-zip: panelA→t1, panelB→t2.
        let panes = vec![
            ("panelA".to_string(), "/project/foo".to_string(), 1005_i64, 100_u32),
            ("panelB".to_string(), "/project/foo".to_string(), 1062_i64, 200_u32),
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
        // t3 created_at=1100; proc_start=0 → diff=1100 > 300 → not relevant → skipped
        let panes = vec![("panelX".to_string(), "/project/bar".to_string(), 0_i64, 1_u32)];
        let by_panel = tracker.snapshot_by_panel(&panes).unwrap();
        assert!(by_panel.is_empty());
    }

    #[test]
    fn snapshot_by_panel_same_second_spawn_pid_tiebreak() {
        // 3 Codex agents spawned in the same second → identical proc_start.
        // 3 threads created in the same second → identical created_at.
        // PID (spawn order) ↔ rowid (insertion = creation order) must align them
        // 1:1 with no tie-refusal skip.
        let dir = TempDir::new().unwrap();
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
        // Inserted in creation order; all share created_at=5000.
        conn.execute("INSERT INTO threads VALUES ('th1', '/team/cwd', 111, 0, 5000, 5000)", [])
            .unwrap();
        conn.execute("INSERT INTO threads VALUES ('th2', '/team/cwd', 222, 0, 5001, 5000)", [])
            .unwrap();
        conn.execute("INSERT INTO threads VALUES ('th3', '/team/cwd', 333, 0, 5002, 5000)", [])
            .unwrap();
        let tracker = CodexUsageTracker { db_path };
        // Panes given out of order; same proc_start, distinct PIDs 9001<9002<9003.
        let panes = vec![
            ("panel3".to_string(), "/team/cwd".to_string(), 5000_i64, 9003_u32),
            ("panel1".to_string(), "/team/cwd".to_string(), 5000_i64, 9001_u32),
            ("panel2".to_string(), "/team/cwd".to_string(), 5000_i64, 9002_u32),
        ];
        let by_panel = tracker.snapshot_by_panel(&panes).unwrap();
        assert_eq!(by_panel.len(), 3, "no tie-refusal — all 3 panels matched");
        // PID order 9001<9002<9003 ↔ creation order th1,th2,th3.
        assert_eq!(by_panel["panel1"], 111);
        assert_eq!(by_panel["panel2"], 222);
        assert_eq!(by_panel["panel3"], 333);
    }
}
