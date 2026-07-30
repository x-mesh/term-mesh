use crate::fence::FenceRecord;
use crate::model::{
    now_ms, Attempt, AttemptId, FencingToken, HostId, HostObservation, IntentEvent, MergeQueueId,
    MergeQueueItem, MergeQueueStatus, Placement, Project, ProjectId, ProjectState, ReviewSnapshot,
    ReviewSnapshotId, Task, TaskId, TaskStatus,
};
use anyhow::{bail, Result};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use serde_json::Value;
use std::path::Path;
use std::str::FromStr;

/// Best-effort 0600 on a file we just created. A failure here is not worth
/// refusing to start over — the caller is already holding an open handle, and
/// the socket in front of this is uid-gated — but it is worth recording.
#[cfg(unix)]
fn restrict_to_owner(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    if path == Path::new(":memory:") {
        return;
    }
    if let Err(error) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)) {
        tracing::warn!(path = %path.display(), %error, "could not restrict permissions");
    }
}

#[cfg(not(unix))]
fn restrict_to_owner(_path: &Path) {}

pub struct Reducer {
    conn: Connection,
}

impl Reducer {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(path)?;
        // Same reasoning that gates the socket to 0600: this file holds task
        // titles and bodies, project roots and the host inventory. Leaving it
        // at the ambient umask (commonly 022) made the data at rest readable
        // by anyone on the machine while the socket in front of it was shut.
        restrict_to_owner(path);
        let this = Self { conn };
        this.init()?;
        Ok(this)
    }

    /// A read-only view of an existing database, for serving queries while a
    /// writer holds its own connection.
    ///
    /// Opened `SQLITE_OPEN_READ_ONLY` so a query path cannot mutate by
    /// accident, and without `init()` — the schema belongs to the writer, and
    /// creating tables from here would be a write. In WAL mode (set by the
    /// writer at open) readers do not block the writer and the writer does
    /// not block readers, which is the entire point: an fsync on the write
    /// path used to stall every reader behind the same mutex.
    pub fn open_read_only(path: &Path) -> Result<Self> {
        let conn = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        Ok(Self { conn })
    }

    pub fn in_memory() -> Result<Self> {
        let this = Self {
            conn: Connection::open_in_memory()?,
        };
        this.init()?;
        Ok(this)
    }

    fn init(&self) -> Result<()> {
        self.conn.execute_batch(
            r#"
            PRAGMA journal_mode=WAL;
            PRAGMA busy_timeout=5000;
            CREATE TABLE IF NOT EXISTS events(
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT NOT NULL UNIQUE,
                request_id TEXT UNIQUE,
                kind TEXT NOT NULL,
                project_id TEXT,
                ts_ms INTEGER NOT NULL,
                event_json TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS projects(
                project_id TEXT PRIMARY KEY,
                root_path TEXT NOT NULL,
                name TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                state TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS tasks(
                task_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                status TEXT NOT NULL,
                priority INTEGER NOT NULL,
                depends_on_json TEXT NOT NULL,
                created_by TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                current_attempt_id TEXT,
                placement_json TEXT,
                last_reason TEXT
            );
            CREATE TABLE IF NOT EXISTS attempts(
                attempt_id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL,
                project_id TEXT NOT NULL,
                status TEXT NOT NULL,
                host_id TEXT NOT NULL,
                pane_ref_json TEXT,
                worktree_path TEXT,
                base_ref TEXT,
                head_ref TEXT,
                head_sha TEXT,
                fencing_token TEXT,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS hosts(
                host_id TEXT PRIMARY KEY,
                os TEXT NOT NULL,
                arch TEXT NOT NULL,
                load REAL NOT NULL,
                total_slots INTEGER,
                used_slots INTEGER NOT NULL,
                project_roots_json TEXT NOT NULL,
                leader_projects_json TEXT NOT NULL DEFAULT '[]',
                live INTEGER NOT NULL,
                quarantined INTEGER NOT NULL,
                observed_at_ms INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS fences(
                task_id TEXT NOT NULL,
                attempt_key TEXT NOT NULL,
                attempt_id TEXT,
                holder TEXT NOT NULL,
                token TEXT NOT NULL UNIQUE,
                generation INTEGER NOT NULL,
                expires_at_ms INTEGER,
                PRIMARY KEY(task_id, attempt_key)
            );
            CREATE TABLE IF NOT EXISTS review_snapshots(
                snapshot_id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL,
                attempt_id TEXT NOT NULL,
                base_sha TEXT NOT NULL,
                head_sha TEXT NOT NULL,
                diff_digest TEXT NOT NULL,
                summary TEXT NOT NULL,
                files_json TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS merge_queue(
                queue_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                task_id TEXT NOT NULL,
                attempt_id TEXT NOT NULL,
                snapshot_id TEXT,
                head_sha TEXT,
                diff_digest TEXT,
                status TEXT NOT NULL,
                approved_by TEXT NOT NULL,
                approved_at_ms INTEGER NOT NULL,
                last_error TEXT
            );
            "#,
        )?;
        // `CREATE TABLE IF NOT EXISTS` never widens a table that already
        // exists, so a database written before a column was added keeps the
        // old shape and every query naming the new column fails. There is no
        // schema-version ledger here yet; adding the column and ignoring the
        // "duplicate column" error is the whole migration.
        let _ = self.conn.execute(
            "ALTER TABLE hosts ADD COLUMN leader_projects_json TEXT NOT NULL DEFAULT '[]'",
            [],
        );
        let _ = self
            .conn
            .execute("ALTER TABLE tasks ADD COLUMN last_reason TEXT", []);
        let _ = self
            .conn
            .execute("ALTER TABLE merge_queue ADD COLUMN snapshot_id TEXT", []);
        let _ = self
            .conn
            .execute("ALTER TABLE merge_queue ADD COLUMN head_sha TEXT", []);
        let _ = self
            .conn
            .execute("ALTER TABLE merge_queue ADD COLUMN diff_digest TEXT", []);
        // Existing projections predate evidence on `MergeQueueItem`. Recover
        // the exact approved snapshot from the journal event, then its head
        // and digest from the snapshot projection. Fresh projections and new
        // events already populate all three columns directly.
        self.conn.execute_batch(
            r#"
            UPDATE merge_queue
               SET snapshot_id = (
                   SELECT json_extract(events.event_json, '$.payload.snapshot_id')
                     FROM events
                    WHERE events.kind = 'attempt_approved'
                      AND json_extract(events.event_json, '$.payload.merge_queue_item.queue_id') = merge_queue.queue_id
                    LIMIT 1
               )
             WHERE snapshot_id IS NULL;
            UPDATE merge_queue
               SET head_sha = (SELECT head_sha FROM review_snapshots WHERE snapshot_id = merge_queue.snapshot_id),
                   diff_digest = (SELECT diff_digest FROM review_snapshots WHERE snapshot_id = merge_queue.snapshot_id)
             WHERE head_sha IS NULL OR diff_digest IS NULL;
            "#,
        )?;
        // `total_slots` had to become nullable so "capacity unknown" stops
        // reading as "capacity zero", and no `ALTER TABLE` can relax a NOT
        // NULL. Recreating is safe here in a way it would not be for a table
        // holding originals: `hosts` is a pure projection, and every row is
        // rebuilt by replaying the event log at open.
        let legacy_not_null = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('hosts')
                 WHERE name = 'total_slots' AND \"notnull\" = 1",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0)
            > 0;
        if legacy_not_null {
            self.conn.execute_batch(
                r#"
                DROP TABLE hosts;
                CREATE TABLE hosts(
                    host_id TEXT PRIMARY KEY,
                    os TEXT NOT NULL,
                    arch TEXT NOT NULL,
                    load REAL NOT NULL,
                    total_slots INTEGER,
                    used_slots INTEGER NOT NULL,
                    project_roots_json TEXT NOT NULL,
                    leader_projects_json TEXT NOT NULL DEFAULT '[]',
                    live INTEGER NOT NULL,
                    quarantined INTEGER NOT NULL,
                    observed_at_ms INTEGER NOT NULL
                );
                "#,
            )?;
        }
        Ok(())
    }

    pub fn replay(events: &[IntentEvent]) -> Result<Self> {
        let reducer = Self::in_memory()?;
        for event in events {
            reducer.apply(event)?;
        }
        Ok(reducer)
    }

    pub fn watermark(&self) -> Result<i64> {
        Ok(self
            .conn
            .query_row("SELECT COALESCE(MAX(seq), 0) FROM events", [], |row| {
                row.get(0)
            })?)
    }

    /// Ids of every event already folded in, for a caller replaying a log
    /// against a projection that survived the last run.
    ///
    /// `apply` is idempotent on its own — the events table rejects a repeat —
    /// but startup was paying a transaction and a round trip per historical
    /// event to be told "already have it", every time, for the life of the
    /// log. One read up front turns that into a set lookup.
    ///
    /// Not `watermark()`: `seq` is this table's own autoincrement, not a
    /// position in the log, so it cannot say where a replay should resume.
    pub fn applied_event_ids(&self) -> Result<std::collections::HashSet<String>> {
        let mut stmt = self.conn.prepare("SELECT event_id FROM events")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        rows.collect::<std::result::Result<std::collections::HashSet<_>, _>>()
            .map_err(Into::into)
    }

    pub fn event_by_request_id(&self, request_id: &str) -> Result<Option<IntentEvent>> {
        self.conn
            .query_row(
                "SELECT event_json FROM events WHERE request_id=?1",
                params![request_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .map(|json| serde_json::from_str(&json).map_err(Into::into))
            .transpose()
    }

    pub fn apply(&self, event: &IntentEvent) -> Result<()> {
        // The event row and everything it implies land together or not at all.
        //
        // Without this they were separate autocommits, and the dedup below
        // turned a torn write into a permanent one: a crash after the event
        // row committed but before (or partway through) its reduction left a
        // projection that did not match the log, and every future replay found
        // the event_id already present, returned here, and never ran the
        // reduction that would have repaired it. Folding the same log twice
        // has to reach the same state; that only holds if a fold is atomic.
        //
        // `unchecked_transaction` because `apply` takes `&self`. Safe here:
        // every caller (`replay`, `Api::mutate`, startup catch-up) invokes it
        // at the top level, so these never nest.
        let tx = self.conn.unchecked_transaction()?;
        let json = serde_json::to_string(event)?;
        let inserted = self.conn.execute(
            "INSERT OR IGNORE INTO events(event_id,request_id,kind,project_id,ts_ms,event_json) VALUES(?1,?2,?3,?4,?5,?6)",
            params![
                event.event_id.as_str(),
                event.request_id.as_deref(),
                event.kind,
                event.project_id.as_ref().map(|p| p.as_str()),
                event.ts_ms as i64,
                json
            ],
        )?;
        if inserted == 0 {
            // Already applied. Nothing was written, so letting the transaction
            // roll back on drop is the whole cleanup.
            return Ok(());
        }

        let reduced = match event.kind.as_str() {
            "project_added" => self.reduce_project_added(event),
            "task_created" => self.reduce_task_created(event),
            "task_status_changed" => self.reduce_task_status_changed(event),
            "attempt_created" => self.reduce_attempt_created(event),
            "host_observed" => self.reduce_host_observed(event),
            "task_placed" => self.reduce_task_placed(event, TaskStatus::Placed),
            "task_reassigned" => self.reduce_task_placed(event, TaskStatus::Reassigned),
            "task_suspected" => self.reduce_task_lifecycle(event, TaskStatus::Suspect),
            "task_quarantined" => self.reduce_task_lifecycle(event, TaskStatus::Quarantined),
            "review_snapshot_recorded" => self.reduce_review_snapshot_recorded(event),
            "attempt_approved" => self.reduce_attempt_approved(event),
            "attempt_rejected" => self.reduce_attempt_rejected(event),
            "merge_queue_transitioned" => self.reduce_merge_queue_transitioned(event),
            "fence_issued" => self.reduce_fence_issued(event),
            _ => Ok(()),
        };
        reduced?;
        tx.commit()?;
        Ok(())
    }

    pub fn projects(&self) -> Result<Vec<Project>> {
        let mut stmt = self.conn.prepare(
            "SELECT project_id,root_path,name,created_at_ms,updated_at_ms,state FROM projects ORDER BY created_at_ms",
        )?;
        let rows = stmt.query_map([], |row| {
            let project_id = ProjectId::from_str(&row.get::<_, String>(0)?)
                .map_err(|e| rusqlite::Error::ToSqlConversionFailure(e.into()))?;
            let state = match row.get::<_, String>(5)?.as_str() {
                "archived" => ProjectState::Archived,
                _ => ProjectState::Active,
            };
            Ok(Project {
                project_id,
                root_path: row.get(1)?,
                name: row.get(2)?,
                created_at_ms: row.get::<_, i64>(3)? as u64,
                updated_at_ms: row.get::<_, i64>(4)? as u64,
                hosts: Vec::new(),
                state,
            })
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn tasks(
        &self,
        project_id: Option<&ProjectId>,
        status: Option<TaskStatus>,
        limit: i64,
    ) -> Result<Vec<Task>> {
        // Filter in SQL rather than loading every row and discarding most of
        // them.
        let mut sql = String::from(
            "SELECT task_id,project_id,title,body,status,priority,depends_on_json,created_by,created_at_ms,updated_at_ms,current_attempt_id,placement_json,last_reason
             FROM tasks",
        );
        let mut clauses: Vec<&str> = Vec::new();
        if project_id.is_some() {
            clauses.push("project_id=:project_id");
        }
        let status_text = status.as_ref().map(status_string).transpose()?;
        if status_text.is_some() {
            clauses.push("status=:status");
        }
        if !clauses.is_empty() {
            sql.push_str(" WHERE ");
            sql.push_str(&clauses.join(" AND "));
        }
        sql.push_str(" ORDER BY priority DESC, created_at_ms LIMIT :limit");

        let mut stmt = self.conn.prepare(&sql)?;
        let mut bindings: Vec<(&str, &dyn rusqlite::ToSql)> = Vec::new();
        let project_text = project_id.map(|id| id.as_str().to_string());
        if let Some(project_text) = project_text.as_ref() {
            bindings.push((":project_id", project_text));
        }
        if let Some(status_text) = status_text.as_ref() {
            bindings.push((":status", status_text));
        }
        let limit = limit.max(0);
        bindings.push((":limit", &limit));
        let rows = stmt.query_map(bindings.as_slice(), row_to_task)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn task(&self, task_id: &TaskId) -> Result<Option<Task>> {
        // By primary key, not by scanning. This is on the write path — every
        // place, update, reassign, suspect, quarantine and fence check reads a
        // task first — and terminal tasks are never deleted, so loading and
        // JSON-decoding the whole table to find one row made each write cost
        // grow with everything the coordinator had ever been asked to do.
        self.conn
            .query_row(
                "SELECT task_id,project_id,title,body,status,priority,depends_on_json,created_by,created_at_ms,updated_at_ms,current_attempt_id,placement_json,last_reason
                 FROM tasks WHERE task_id=?1",
                params![task_id.as_str()],
                row_to_task,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn attempts(&self, task_id: &TaskId) -> Result<Vec<Attempt>> {
        let mut stmt = self.conn.prepare(
            "SELECT attempt_id,task_id,project_id,status,host_id,pane_ref_json,worktree_path,base_ref,head_ref,head_sha,fencing_token,created_at_ms,updated_at_ms
             FROM attempts WHERE task_id=?1 ORDER BY created_at_ms",
        )?;
        let rows = stmt.query_map(params![task_id.as_str()], row_to_attempt)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn hosts(&self) -> Result<Vec<HostObservation>> {
        let mut stmt = self.conn.prepare(
            "SELECT host_id,os,arch,load,total_slots,used_slots,project_roots_json,leader_projects_json,live,quarantined,observed_at_ms
             FROM hosts ORDER BY host_id",
        )?;
        let rows = stmt.query_map([], row_to_host)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn project_root(&self, project_id: &ProjectId) -> Result<Option<String>> {
        self.conn
            .query_row(
                "SELECT root_path FROM projects WHERE project_id=?1",
                params![project_id.as_str()],
                |row| row.get(0),
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn choose_host(
        &self,
        project_id: &ProjectId,
        manual_host_id: Option<&HostId>,
    ) -> Result<HostObservation> {
        let root_path = self
            .project_root(project_id)?
            .ok_or_else(|| anyhow::anyhow!("project not found"))?;
        let mut eligible: Vec<HostObservation> = self
            .hosts()?
            .into_iter()
            .filter(|host| host.is_eligible_for(&root_path))
            .collect();
        if let Some(host_id) = manual_host_id {
            return eligible
                .into_iter()
                .find(|host| &host.host_id == host_id)
                .ok_or_else(|| anyhow::anyhow!("manual host override is not eligible"));
        }
        eligible.sort_by(|a, b| {
            // Hosts that reported capacity come first, and only then by how
            // much: a host that never said outranking one that said "three
            // free" would let a guess beat a fact. Within the unknown group
            // load and id decide, so the order stays deterministic.
            b.has_known_capacity()
                .cmp(&a.has_known_capacity())
                .then_with(|| b.available_slots().cmp(&a.available_slots()))
                .then_with(|| {
                    a.load
                        .partial_cmp(&b.load)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
                .then_with(|| a.host_id.as_str().cmp(b.host_id.as_str()))
        });
        eligible
            .into_iter()
            .next()
            .ok_or_else(|| anyhow::anyhow!("no eligible host"))
    }

    pub fn latest_review_snapshot(&self, task_id: &TaskId) -> Result<Option<ReviewSnapshot>> {
        self.conn
            .query_row(
                "SELECT snapshot_id,task_id,attempt_id,base_sha,head_sha,diff_digest,summary,files_json,created_at_ms
                 FROM review_snapshots WHERE task_id=?1 ORDER BY created_at_ms DESC LIMIT 1",
                params![task_id.as_str()],
                row_to_review_snapshot,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn latest_review_snapshot_for_attempt(
        &self,
        task_id: &TaskId,
        attempt_id: &AttemptId,
    ) -> Result<Option<ReviewSnapshot>> {
        self.conn
            .query_row(
                "SELECT snapshot_id,task_id,attempt_id,base_sha,head_sha,diff_digest,summary,files_json,created_at_ms
                 FROM review_snapshots WHERE task_id=?1 AND attempt_id=?2
                 ORDER BY created_at_ms DESC, rowid DESC LIMIT 1",
                params![task_id.as_str(), attempt_id.as_str()],
                row_to_review_snapshot,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn review_snapshot(&self, snapshot_id: &str) -> Result<Option<ReviewSnapshot>> {
        self.conn
            .query_row(
                "SELECT snapshot_id,task_id,attempt_id,base_sha,head_sha,diff_digest,summary,files_json,created_at_ms
                 FROM review_snapshots WHERE snapshot_id=?1",
                params![snapshot_id],
                row_to_review_snapshot,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn merge_queue(
        &self,
        project_id: Option<&ProjectId>,
        status: Option<MergeQueueStatus>,
    ) -> Result<Vec<MergeQueueItem>> {
        let mut items = self.all_merge_queue()?;
        if let Some(project_id) = project_id {
            items.retain(|item| &item.project_id == project_id);
        }
        if let Some(status) = status {
            items.retain(|item| item.status == status);
        }
        Ok(items)
    }

    pub fn merge_queue_item(&self, queue_id: &MergeQueueId) -> Result<Option<MergeQueueItem>> {
        // Same reason as `task`: a point lookup on the write path, against a
        // table nothing ever deletes from.
        self.conn
            .query_row(
                "SELECT queue_id,project_id,task_id,attempt_id,snapshot_id,head_sha,diff_digest,status,approved_by,approved_at_ms,last_error
                 FROM merge_queue WHERE queue_id=?1",
                params![queue_id.as_str()],
                row_to_merge_queue_item,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn current_fence(
        &self,
        task_id: &TaskId,
        attempt_id: Option<&AttemptId>,
    ) -> Result<Option<FenceRecord>> {
        self.conn
            .query_row(
                "SELECT task_id,attempt_id,holder,token,generation,expires_at_ms FROM fences WHERE task_id=?1 AND attempt_key=?2",
                params![task_id.as_str(), fence_attempt_key(attempt_id)],
                |row| {
                    Ok(FenceRecord {
                        task_id: TaskId::from_str(&row.get::<_, String>(0)?).map_err(to_sql_err)?,
                        attempt_id: row
                            .get::<_, Option<String>>(1)?
                            .map(|v| AttemptId::from_str(&v).map_err(to_sql_err))
                            .transpose()?,
                        holder: row.get(2)?,
                        token: FencingToken::from_str(&row.get::<_, String>(3)?).map_err(to_sql_err)?,
                        generation: row.get(4)?,
                        expires_at_ms: row.get::<_, Option<i64>>(5)?.map(|v| v as u64),
                    })
                },
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn is_current_fence(
        &self,
        task_id: &TaskId,
        attempt_id: Option<&AttemptId>,
        token: &FencingToken,
    ) -> Result<bool> {
        Ok(self
            .current_fence(task_id, attempt_id)?
            .is_some_and(|record| {
                record.token == *token
                    && record
                        .expires_at_ms
                        .is_none_or(|expires| expires > now_ms())
            }))
    }

    fn reduce_project_added(&self, event: &IntentEvent) -> Result<()> {
        let project_id = event
            .project_id
            .clone()
            .unwrap_or_else(ProjectId::new_random);
        let root_path = required_str(&event.payload, "root_path")?;
        let name = event
            .payload
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or_else(|| root_path.rsplit('/').next().unwrap_or("project"));
        self.conn.execute(
            "INSERT OR IGNORE INTO projects(project_id,root_path,name,created_at_ms,updated_at_ms,state) VALUES(?1,?2,?3,?4,?5,'active')",
            params![project_id.as_str(), root_path, name, event.ts_ms as i64, event.ts_ms as i64],
        )?;
        Ok(())
    }

    fn reduce_task_created(&self, event: &IntentEvent) -> Result<()> {
        let project_id = event
            .project_id
            .clone()
            .ok_or_else(|| anyhow::anyhow!("task_created missing project_id"))?;
        let task_id = event
            .payload
            .get("task_id")
            .and_then(|v| v.as_str())
            .map(TaskId::from_str)
            .transpose()
            .map_err(|e| anyhow::anyhow!(e))?
            .unwrap_or_else(TaskId::new_random);
        let depends_on: Vec<TaskId> = event
            .payload
            .get("depends_on")
            .cloned()
            .map(serde_json::from_value)
            .transpose()?
            .unwrap_or_default();
        self.conn.execute(
            "INSERT OR IGNORE INTO tasks(task_id,project_id,title,body,status,priority,depends_on_json,created_by,created_at_ms,updated_at_ms,current_attempt_id,placement_json)
             VALUES(?1,?2,?3,?4,'pending',?5,?6,?7,?8,?9,NULL,NULL)",
            params![
                task_id.as_str(),
                project_id.as_str(),
                required_str(&event.payload, "title")?,
                event.payload.get("body").and_then(|v| v.as_str()).unwrap_or(""),
                event.payload.get("priority").and_then(|v| v.as_i64()).unwrap_or(0),
                serde_json::to_string(&depends_on)?,
                event.payload.get("created_by").and_then(|v| v.as_str()).unwrap_or("leader"),
                event.ts_ms as i64,
                event.ts_ms as i64
            ],
        )?;
        Ok(())
    }

    fn reduce_task_status_changed(&self, event: &IntentEvent) -> Result<()> {
        let task_id = TaskId::from_str(required_str(&event.payload, "task_id")?)
            .map_err(|e| anyhow::anyhow!(e))?;
        let next: TaskStatus = serde_json::from_value(
            event
                .payload
                .get("status")
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("missing status"))?,
        )?;
        let Some(current) = self.task(&task_id)? else {
            bail!("task not found");
        };
        if !current.status.can_transition_to(&next) {
            bail!("invalid task transition {:?} -> {:?}", current.status, next);
        }
        self.conn.execute(
            "UPDATE tasks SET status=?1, updated_at_ms=?2,
             last_reason=COALESCE(?4, last_reason) WHERE task_id=?3",
            params![
                serde_json::to_value(next)?.as_str().unwrap(),
                event.ts_ms as i64,
                task_id.as_str(),
                event.payload.get("reason").and_then(|v| v.as_str())
            ],
        )?;
        Ok(())
    }

    fn reduce_attempt_created(&self, event: &IntentEvent) -> Result<()> {
        let attempt: Attempt = serde_json::from_value(event.payload.clone())?;
        self.conn.execute(
            "INSERT OR IGNORE INTO attempts(attempt_id,task_id,project_id,status,host_id,pane_ref_json,worktree_path,base_ref,head_ref,head_sha,fencing_token,created_at_ms,updated_at_ms)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
            params![
                attempt.attempt_id.as_str(),
                attempt.task_id.as_str(),
                attempt.project_id.as_str(),
                attempt.status,
                attempt.host_id.as_str(),
                attempt.pane_ref.map(|p| serde_json::to_string(&p)).transpose()?,
                attempt.worktree_path,
                attempt.base_ref,
                attempt.head_ref,
                attempt.head_sha,
                attempt.fencing_token.map(|t| t.to_string()),
                attempt.created_at_ms as i64,
                attempt.updated_at_ms as i64
            ],
        )?;
        Ok(())
    }

    fn reduce_host_observed(&self, event: &IntentEvent) -> Result<()> {
        let observation: HostObservation = serde_json::from_value(event.payload.clone())?;
        self.conn.execute(
            "INSERT INTO hosts(host_id,os,arch,load,total_slots,used_slots,project_roots_json,leader_projects_json,live,quarantined,observed_at_ms)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
             ON CONFLICT(host_id) DO UPDATE SET os=excluded.os, arch=excluded.arch, load=excluded.load,
             total_slots=excluded.total_slots, used_slots=excluded.used_slots, project_roots_json=excluded.project_roots_json,
             leader_projects_json=excluded.leader_projects_json,
             live=excluded.live, quarantined=excluded.quarantined, observed_at_ms=excluded.observed_at_ms",
            params![
                observation.host_id.as_str(),
                observation.os,
                observation.arch,
                observation.load,
                observation.total_slots,
                observation.used_slots,
                serde_json::to_string(&observation.project_roots)?,
                serde_json::to_string(&observation.leader_projects)?,
                observation.live as i64,
                observation.quarantined as i64,
                observation.observed_at_ms as i64,
            ],
        )?;
        Ok(())
    }

    fn reduce_task_placed(&self, event: &IntentEvent, status: TaskStatus) -> Result<()> {
        let attempt: Attempt = serde_json::from_value(
            event
                .payload
                .get("attempt")
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("missing attempt"))?,
        )?;
        let placement: Placement = serde_json::from_value(
            event
                .payload
                .get("placement")
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("missing placement"))?,
        )?;
        let task = self
            .task(&attempt.task_id)?
            .ok_or_else(|| anyhow::anyhow!("task not found"))?;
        if !task.status.can_transition_to(&status) {
            bail!("invalid task transition {:?} -> {:?}", task.status, status);
        }
        // Every other live attempt for this task loses, whichever event got us
        // here. Scoping this to `Reassigned` meant a second `task_placed` took
        // over `current_attempt_id` while the previous attempt stayed
        // `created` — still running somewhere the coordinator no longer
        // tracked. The API now refuses that second placement outright, but the
        // reducer replays whatever the log already holds, so it repairs rather
        // than rejects: on a first placement there is nothing to cancel and
        // this updates no rows.
        for old_attempt in self.attempts(&attempt.task_id)?.into_iter().filter(|old| {
            old.attempt_id != attempt.attempt_id
                && !matches!(old.status.as_str(), "merged" | "failed" | "cancelled")
        }) {
            self.release_host_slot(&old_attempt.host_id)?;
        }
        self.conn.execute(
            "UPDATE attempts SET status='cancelled', updated_at_ms=?1 WHERE task_id=?2 AND attempt_id<>?3 AND status NOT IN ('merged','failed','cancelled')",
            params![event.ts_ms as i64, attempt.task_id.as_str(), attempt.attempt_id.as_str()],
        )?;
        self.insert_attempt(&attempt)?;
        // Provisionally spend a slot on the host we just chose.
        //
        // `used_slots` is otherwise only ever written by `host.observe`, so
        // between one report and the next every placement saw the same stale
        // capacity: a burst of placements all ranked the same host best and
        // all landed on it, well past what it had said it could take. Counting
        // our own decision closes that window. The next observation overwrites
        // this with the truth, so the estimate cannot drift for long, and a
        // host missing from the table simply updates no rows.
        self.conn.execute(
            "UPDATE hosts SET used_slots = used_slots + 1 WHERE host_id=?1",
            params![placement.host_id.as_str()],
        )?;
        self.conn.execute(
            "UPDATE tasks SET status=?1,current_attempt_id=?2,placement_json=?3,updated_at_ms=?4 WHERE task_id=?5",
            params![
                status_string(&status)?,
                attempt.attempt_id.as_str(),
                serde_json::to_string(&placement)?,
                event.ts_ms as i64,
                attempt.task_id.as_str()
            ],
        )?;
        self.upsert_fence_from_payload(event)?;
        Ok(())
    }

    fn reduce_task_lifecycle(&self, event: &IntentEvent, status: TaskStatus) -> Result<()> {
        let task_id = TaskId::from_str(required_str(&event.payload, "task_id")?)
            .map_err(|e| anyhow::anyhow!(e))?;
        let task = self
            .task(&task_id)?
            .ok_or_else(|| anyhow::anyhow!("task not found"))?;
        if !task.status.can_transition_to(&status) {
            bail!("invalid task transition {:?} -> {:?}", task.status, status);
        }
        // Every one of these transitions is something going wrong, and each
        // carries a reason the caller went to the trouble of writing. Keeping
        // it only in the event means a client reading the task board sees a
        // task stop dead with nothing to explain it — which is exactly how it
        // read before: a status of `suspect` and eight rows of "not reported".
        // A later reason replaces an earlier one; the current state is what a
        // board asks about, and the history is in the journal either way.
        self.conn.execute(
            "UPDATE tasks SET status=?1, updated_at_ms=?2, last_reason=COALESCE(?4, last_reason)
             WHERE task_id=?3",
            params![
                status_string(&status)?,
                event.ts_ms as i64,
                task_id.as_str(),
                event.payload.get("reason").and_then(|v| v.as_str())
            ],
        )?;
        Ok(())
    }

    fn reduce_review_snapshot_recorded(&self, event: &IntentEvent) -> Result<()> {
        let snapshot: ReviewSnapshot = serde_json::from_value(event.payload.clone())?;
        self.conn.execute(
            "INSERT OR IGNORE INTO review_snapshots(snapshot_id,task_id,attempt_id,base_sha,head_sha,diff_digest,summary,files_json,created_at_ms)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
            params![
                snapshot.snapshot_id.as_str(),
                snapshot.task_id.as_str(),
                snapshot.attempt_id.as_str(),
                snapshot.base_sha,
                snapshot.head_sha,
                snapshot.diff_digest,
                snapshot.summary,
                serde_json::to_string(&snapshot.files)?,
                snapshot.created_at_ms as i64
            ],
        )?;
        self.conn.execute(
            "UPDATE tasks SET status='review_ready', updated_at_ms=?1 WHERE task_id=?2",
            params![event.ts_ms as i64, snapshot.task_id.as_str()],
        )?;
        self.conn.execute(
            "UPDATE attempts SET status='review_ready', head_sha=?1, updated_at_ms=?2 WHERE attempt_id=?3",
            params![snapshot.head_sha, event.ts_ms as i64, snapshot.attempt_id.as_str()],
        )?;
        Ok(())
    }

    fn reduce_attempt_approved(&self, event: &IntentEvent) -> Result<()> {
        let mut queue_value = event
            .payload
            .get("merge_queue_item")
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("missing merge_queue_item"))?;
        // Events written before approval evidence became part of the queue
        // model still carry the exact snapshot id at payload level. Hydrate
        // those fields before deserializing so journal replay remains valid.
        // A snapshot the projection no longer holds degrades that one item to
        // "no evidence" rather than failing the whole replay.
        if queue_value.get("snapshot_id").is_none() {
            let snapshot_id = required_str(&event.payload, "snapshot_id")?;
            let queue_object = queue_value
                .as_object_mut()
                .ok_or_else(|| anyhow::anyhow!("merge_queue_item must be an object"))?;
            queue_object.insert("snapshot_id".to_string(), snapshot_id.into());
            if let Some(snapshot) = self.review_snapshot(snapshot_id)? {
                queue_object.insert("head_sha".to_string(), snapshot.head_sha.into());
                queue_object.insert("diff_digest".to_string(), snapshot.diff_digest.into());
            }
        }
        let queue: MergeQueueItem = serde_json::from_value(queue_value)?;
        let task = self
            .task(&queue.task_id)?
            .ok_or_else(|| anyhow::anyhow!("task not found"))?;
        if !task.status.can_transition_to(&TaskStatus::Approved) {
            bail!("invalid task transition {:?} -> approved", task.status);
        }
        self.conn.execute(
            "UPDATE tasks SET status='queued_for_merge', updated_at_ms=?1 WHERE task_id=?2",
            params![event.ts_ms as i64, queue.task_id.as_str()],
        )?;
        self.conn.execute(
            "UPDATE attempts SET status='approved', updated_at_ms=?1 WHERE attempt_id=?2",
            params![event.ts_ms as i64, queue.attempt_id.as_str()],
        )?;
        self.insert_merge_queue(&queue)
    }

    fn reduce_attempt_rejected(&self, event: &IntentEvent) -> Result<()> {
        let task_id = TaskId::from_str(required_str(&event.payload, "task_id")?)
            .map_err(|e| anyhow::anyhow!(e))?;
        let attempt_id = AttemptId::from_str(required_str(&event.payload, "attempt_id")?)
            .map_err(|e| anyhow::anyhow!(e))?;
        let task = self
            .task(&task_id)?
            .ok_or_else(|| anyhow::anyhow!("task not found"))?;
        if !task.status.can_transition_to(&TaskStatus::Rejected) {
            bail!("invalid task transition {:?} -> rejected", task.status);
        }
        // A reviewer's reason is the most useful sentence on the whole board;
        // it has to survive onto the task like every other stop reason.
        self.conn.execute(
            "UPDATE tasks SET status='rejected', updated_at_ms=?1,
             last_reason=COALESCE(?3, last_reason) WHERE task_id=?2",
            params![
                event.ts_ms as i64,
                task_id.as_str(),
                event.payload.get("reason").and_then(|v| v.as_str())
            ],
        )?;
        self.conn.execute(
            "UPDATE attempts SET status='rejected', updated_at_ms=?1 WHERE attempt_id=?2",
            params![event.ts_ms as i64, attempt_id.as_str()],
        )?;
        Ok(())
    }

    fn reduce_merge_queue_transitioned(&self, event: &IntentEvent) -> Result<()> {
        let queue_id = MergeQueueId::from_str(required_str(&event.payload, "queue_id")?)
            .map_err(|e| anyhow::anyhow!(e))?;
        let next: MergeQueueStatus = serde_json::from_value(
            event
                .payload
                .get("status")
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("missing status"))?,
        )?;
        let item = self
            .merge_queue_item(&queue_id)?
            .ok_or_else(|| anyhow::anyhow!("merge queue item not found"))?;
        if !item.status.can_transition_to(&next) {
            bail!(
                "invalid merge queue transition {:?} -> {:?}",
                item.status,
                next
            );
        }
        let last_error = event.payload.get("last_error").and_then(|v| v.as_str());
        self.conn.execute(
            "UPDATE merge_queue SET status=?1,last_error=?2 WHERE queue_id=?3",
            params![status_string(&next)?, last_error, queue_id.as_str()],
        )?;
        let terminal_status = match next {
            MergeQueueStatus::Merged => Some("merged"),
            MergeQueueStatus::Failed => Some("failed"),
            MergeQueueStatus::Cancelled => Some("cancelled"),
            MergeQueueStatus::Queued | MergeQueueStatus::Running => None,
        };
        if let Some(status) = terminal_status {
            let attempt = self
                .attempts(&item.task_id)?
                .into_iter()
                .find(|attempt| attempt.attempt_id == item.attempt_id)
                .ok_or_else(|| anyhow::anyhow!("attempt not found"))?;
            if !matches!(attempt.status.as_str(), "merged" | "failed" | "cancelled") {
                self.release_host_slot(&attempt.host_id)?;
            }
            self.conn.execute(
                "UPDATE tasks SET status=?1, updated_at_ms=?2 WHERE task_id=?3",
                params![status, event.ts_ms as i64, item.task_id.as_str()],
            )?;
            self.conn.execute(
                "UPDATE attempts SET status=?1, updated_at_ms=?2 WHERE attempt_id=?3",
                params![status, event.ts_ms as i64, item.attempt_id.as_str()],
            )?;
        }
        Ok(())
    }

    fn reduce_fence_issued(&self, event: &IntentEvent) -> Result<()> {
        self.upsert_fence_from_payload(event)
    }

    fn upsert_fence_from_payload(&self, event: &IntentEvent) -> Result<()> {
        let task_id = TaskId::from_str(required_str(&event.payload, "task_id")?)
            .map_err(|e| anyhow::anyhow!(e))?;
        let attempt_id = event
            .payload
            .get("attempt_id")
            .and_then(|v| v.as_str())
            .map(AttemptId::from_str)
            .transpose()
            .map_err(|e| anyhow::anyhow!(e))?;
        let generation = self
            .current_fence(&task_id, attempt_id.as_ref())?
            .map(|f| f.generation + 1)
            .unwrap_or(1);
        let token = event
            .payload
            .get("token")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("missing token"))?;
        self.conn.execute(
            "INSERT INTO fences(task_id,attempt_key,attempt_id,holder,token,generation,expires_at_ms)
             VALUES(?1,?2,?3,?4,?5,?6,?7)
             ON CONFLICT(task_id, attempt_key) DO UPDATE SET holder=excluded.holder, token=excluded.token, generation=excluded.generation, expires_at_ms=excluded.expires_at_ms",
            params![
                task_id.as_str(),
                fence_attempt_key(attempt_id.as_ref()),
                attempt_id.as_ref().map(|a| a.as_str()),
                required_str(&event.payload, "holder")?,
                token,
                generation,
                event.payload.get("expires_at_ms").and_then(|v| v.as_i64())
            ],
        )?;
        // The attempt row carries a copy of the token, and it is what every
        // reader gets: `task.get` returns `attempts[]`, and there is no RPC
        // that exposes the `fences` table. Leaving the copy behind made that
        // copy silently wrong the moment anyone re-fenced — a caller would
        // read a token, send it, and be told `stale_fencing_token` with no way
        // to see why or to ask for the current one. The only workaround was to
        // issue a fresh fence, which takes the token away from whoever is
        // actually running the attempt: the precise thing fencing exists to
        // prevent. Updating both together is what makes the readable copy
        // true.
        //
        // A fence with no attempt (task-scoped) or for an attempt that does
        // not exist matches no row; `fence` is deliberately unchecked, so that
        // is a legal call and not an error here.
        if let Some(attempt_id) = attempt_id.as_ref() {
            self.conn.execute(
                "UPDATE attempts SET fencing_token=?1, updated_at_ms=?2 WHERE attempt_id=?3",
                params![token, event.ts_ms as i64, attempt_id.as_str()],
            )?;
        }
        Ok(())
    }

    fn insert_attempt(&self, attempt: &Attempt) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO attempts(attempt_id,task_id,project_id,status,host_id,pane_ref_json,worktree_path,base_ref,head_ref,head_sha,fencing_token,created_at_ms,updated_at_ms)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
            params![
                attempt.attempt_id.as_str(),
                attempt.task_id.as_str(),
                attempt.project_id.as_str(),
                attempt.status,
                attempt.host_id.as_str(),
                attempt.pane_ref.as_ref().map(serde_json::to_string).transpose()?,
                attempt.worktree_path,
                attempt.base_ref,
                attempt.head_ref,
                attempt.head_sha,
                attempt.fencing_token.as_ref().map(|t| t.to_string()),
                attempt.created_at_ms as i64,
                attempt.updated_at_ms as i64
            ],
        )?;
        Ok(())
    }

    fn release_host_slot(&self, host_id: &HostId) -> Result<()> {
        let used_slots = self
            .conn
            .query_row(
                "SELECT used_slots FROM hosts WHERE host_id=?1",
                params![host_id.as_str()],
                |row| row.get::<_, i64>(0),
            )
            .optional()?;
        if let Some(used_slots) = used_slots {
            let remaining = (used_slots.max(0) as u32).saturating_sub(1);
            self.conn.execute(
                "UPDATE hosts SET used_slots=?1 WHERE host_id=?2",
                params![remaining as i64, host_id.as_str()],
            )?;
        }
        Ok(())
    }

    fn insert_merge_queue(&self, item: &MergeQueueItem) -> Result<()> {
        self.conn.execute(
            "INSERT OR IGNORE INTO merge_queue(queue_id,project_id,task_id,attempt_id,snapshot_id,head_sha,diff_digest,status,approved_by,approved_at_ms,last_error)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
            params![
                item.queue_id.as_str(),
                item.project_id.as_str(),
                item.task_id.as_str(),
                item.attempt_id.as_str(),
                item.snapshot_id.as_ref().map(ReviewSnapshotId::as_str),
                item.head_sha,
                item.diff_digest,
                status_string(&item.status)?,
                item.approved_by,
                item.approved_at_ms as i64,
                item.last_error
            ],
        )?;
        Ok(())
    }

    fn all_merge_queue(&self) -> Result<Vec<MergeQueueItem>> {
        let mut stmt = self.conn.prepare(
            "SELECT queue_id,project_id,task_id,attempt_id,snapshot_id,head_sha,diff_digest,status,approved_by,approved_at_ms,last_error
             FROM merge_queue ORDER BY approved_at_ms",
        )?;
        let rows = stmt.query_map([], row_to_merge_queue_item)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }
}

fn required_str<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("missing {key}"))
}

fn fence_attempt_key(attempt_id: Option<&AttemptId>) -> &str {
    attempt_id.map(AttemptId::as_str).unwrap_or("")
}

fn row_to_task(row: &rusqlite::Row<'_>) -> rusqlite::Result<Task> {
    let status: TaskStatus =
        serde_json::from_str(&format!("\"{}\"", row.get::<_, String>(4)?)).map_err(to_sql_err)?;
    Ok(Task {
        task_id: TaskId::from_str(&row.get::<_, String>(0)?).map_err(to_sql_err)?,
        project_id: ProjectId::from_str(&row.get::<_, String>(1)?).map_err(to_sql_err)?,
        title: row.get(2)?,
        body: row.get(3)?,
        status,
        priority: row.get(5)?,
        depends_on: serde_json::from_str(&row.get::<_, String>(6)?).map_err(to_sql_err)?,
        created_by: row.get(7)?,
        created_at_ms: row.get::<_, i64>(8)? as u64,
        updated_at_ms: row.get::<_, i64>(9)? as u64,
        current_attempt_id: row
            .get::<_, Option<String>>(10)?
            .map(|v| AttemptId::from_str(&v).map_err(to_sql_err))
            .transpose()?,
        placement: row
            .get::<_, Option<String>>(11)?
            .map(|v| serde_json::from_str(&v).map_err(to_sql_err))
            .transpose()?,
        last_reason: row.get::<_, Option<String>>(12)?,
    })
}

fn row_to_attempt(row: &rusqlite::Row<'_>) -> rusqlite::Result<Attempt> {
    Ok(Attempt {
        attempt_id: AttemptId::from_str(&row.get::<_, String>(0)?).map_err(to_sql_err)?,
        task_id: TaskId::from_str(&row.get::<_, String>(1)?).map_err(to_sql_err)?,
        project_id: ProjectId::from_str(&row.get::<_, String>(2)?).map_err(to_sql_err)?,
        status: row.get(3)?,
        host_id: HostId::from_str(&row.get::<_, String>(4)?).map_err(to_sql_err)?,
        pane_ref: row
            .get::<_, Option<String>>(5)?
            .map(|v| serde_json::from_str(&v).map_err(to_sql_err))
            .transpose()?,
        worktree_path: row.get(6)?,
        base_ref: row.get(7)?,
        head_ref: row.get(8)?,
        head_sha: row.get(9)?,
        fencing_token: row
            .get::<_, Option<String>>(10)?
            .map(|v| FencingToken::from_str(&v).map_err(to_sql_err))
            .transpose()?,
        created_at_ms: row.get::<_, i64>(11)? as u64,
        updated_at_ms: row.get::<_, i64>(12)? as u64,
    })
}

fn row_to_host(row: &rusqlite::Row<'_>) -> rusqlite::Result<HostObservation> {
    Ok(HostObservation {
        host_id: HostId::from_str(&row.get::<_, String>(0)?).map_err(to_sql_err)?,
        os: row.get(1)?,
        arch: row.get(2)?,
        load: row.get(3)?,
        total_slots: row.get::<_, Option<i64>>(4)?.map(|slots| slots as u32),
        used_slots: row.get::<_, i64>(5)? as u32,
        project_roots: serde_json::from_str(&row.get::<_, String>(6)?).map_err(to_sql_err)?,
        leader_projects: serde_json::from_str(&row.get::<_, String>(7)?).map_err(to_sql_err)?,
        live: row.get::<_, i64>(8)? != 0,
        quarantined: row.get::<_, i64>(9)? != 0,
        observed_at_ms: row.get::<_, i64>(10)? as u64,
    })
}

fn row_to_review_snapshot(row: &rusqlite::Row<'_>) -> rusqlite::Result<ReviewSnapshot> {
    Ok(ReviewSnapshot {
        snapshot_id: crate::model::ReviewSnapshotId::from_str(&row.get::<_, String>(0)?)
            .map_err(to_sql_err)?,
        task_id: TaskId::from_str(&row.get::<_, String>(1)?).map_err(to_sql_err)?,
        attempt_id: AttemptId::from_str(&row.get::<_, String>(2)?).map_err(to_sql_err)?,
        base_sha: row.get(3)?,
        head_sha: row.get(4)?,
        diff_digest: row.get(5)?,
        summary: row.get(6)?,
        files: serde_json::from_str(&row.get::<_, String>(7)?).map_err(to_sql_err)?,
        created_at_ms: row.get::<_, i64>(8)? as u64,
    })
}

fn row_to_merge_queue_item(row: &rusqlite::Row<'_>) -> rusqlite::Result<MergeQueueItem> {
    let status: MergeQueueStatus =
        serde_json::from_str(&format!("\"{}\"", row.get::<_, String>(7)?)).map_err(to_sql_err)?;
    Ok(MergeQueueItem {
        queue_id: MergeQueueId::from_str(&row.get::<_, String>(0)?).map_err(to_sql_err)?,
        project_id: ProjectId::from_str(&row.get::<_, String>(1)?).map_err(to_sql_err)?,
        task_id: TaskId::from_str(&row.get::<_, String>(2)?).map_err(to_sql_err)?,
        attempt_id: AttemptId::from_str(&row.get::<_, String>(3)?).map_err(to_sql_err)?,
        // NULL survives the backfill when a row's journal event or snapshot
        // is gone. That row must read as "no evidence"; erroring here would
        // take every queue read down with it.
        snapshot_id: row
            .get::<_, Option<String>>(4)?
            .map(|value| crate::model::ReviewSnapshotId::from_str(&value).map_err(to_sql_err))
            .transpose()?,
        head_sha: row.get(5)?,
        diff_digest: row.get(6)?,
        status,
        approved_by: row.get(8)?,
        approved_at_ms: row.get::<_, i64>(9)? as u64,
        last_error: row.get(10)?,
    })
}

fn status_string<T: serde::Serialize>(value: &T) -> Result<String> {
    serde_json::to_value(value)?
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| anyhow::anyhow!("status did not serialize as string"))
}

fn to_sql_err<E: std::fmt::Display>(err: E) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(err.to_string().into())
}
