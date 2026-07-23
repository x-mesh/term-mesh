use crate::fence::FenceRecord;
use crate::model::{
    now_ms, Attempt, AttemptId, FencingToken, HostId, HostObservation, IntentEvent, MergeQueueId,
    MergeQueueItem, MergeQueueStatus, Placement, Project, ProjectId, ProjectState, ReviewSnapshot,
    Task, TaskId, TaskStatus,
};
use anyhow::{bail, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;
use std::path::Path;
use std::str::FromStr;

pub struct Reducer {
    conn: Connection,
}

impl Reducer {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(path)?;
        let this = Self { conn };
        this.init()?;
        Ok(this)
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
                placement_json TEXT
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
                total_slots INTEGER NOT NULL,
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
            return Ok(());
        }

        match event.kind.as_str() {
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
        }
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
        let mut all = self.all_tasks()?;
        if let Some(project_id) = project_id {
            all.retain(|task| &task.project_id == project_id);
        }
        if let Some(status) = status {
            all.retain(|task| task.status == status);
        }
        all.truncate(limit.max(0) as usize);
        Ok(all)
    }

    pub fn task(&self, task_id: &TaskId) -> Result<Option<Task>> {
        Ok(self
            .all_tasks()?
            .into_iter()
            .find(|task| &task.task_id == task_id))
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
            b.available_slots()
                .cmp(&a.available_slots())
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
        Ok(self
            .all_merge_queue()?
            .into_iter()
            .find(|item| &item.queue_id == queue_id))
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

    fn all_tasks(&self) -> Result<Vec<Task>> {
        let mut stmt = self.conn.prepare(
            "SELECT task_id,project_id,title,body,status,priority,depends_on_json,created_by,created_at_ms,updated_at_ms,current_attempt_id,placement_json
             FROM tasks ORDER BY priority DESC, created_at_ms",
        )?;
        let rows = stmt.query_map([], row_to_task)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
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
            "UPDATE tasks SET status=?1, updated_at_ms=?2 WHERE task_id=?3",
            params![
                serde_json::to_value(next)?.as_str().unwrap(),
                event.ts_ms as i64,
                task_id.as_str()
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
        if matches!(status, TaskStatus::Reassigned) {
            self.conn.execute(
                "UPDATE attempts SET status='cancelled', updated_at_ms=?1 WHERE task_id=?2 AND attempt_id<>?3 AND status NOT IN ('merged','failed','cancelled')",
                params![event.ts_ms as i64, attempt.task_id.as_str(), attempt.attempt_id.as_str()],
            )?;
        }
        self.insert_attempt(&attempt)?;
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
        self.conn.execute(
            "UPDATE tasks SET status=?1, updated_at_ms=?2 WHERE task_id=?3",
            params![
                status_string(&status)?,
                event.ts_ms as i64,
                task_id.as_str()
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
        let queue: MergeQueueItem = serde_json::from_value(
            event
                .payload
                .get("merge_queue_item")
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("missing merge_queue_item"))?,
        )?;
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
        self.conn.execute(
            "UPDATE tasks SET status='rejected', updated_at_ms=?1 WHERE task_id=?2",
            params![event.ts_ms as i64, task_id.as_str()],
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

    fn insert_merge_queue(&self, item: &MergeQueueItem) -> Result<()> {
        self.conn.execute(
            "INSERT OR IGNORE INTO merge_queue(queue_id,project_id,task_id,attempt_id,status,approved_by,approved_at_ms,last_error)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
            params![
                item.queue_id.as_str(),
                item.project_id.as_str(),
                item.task_id.as_str(),
                item.attempt_id.as_str(),
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
            "SELECT queue_id,project_id,task_id,attempt_id,status,approved_by,approved_at_ms,last_error
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
        total_slots: row.get::<_, i64>(4)? as u32,
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
        serde_json::from_str(&format!("\"{}\"", row.get::<_, String>(4)?)).map_err(to_sql_err)?;
    Ok(MergeQueueItem {
        queue_id: MergeQueueId::from_str(&row.get::<_, String>(0)?).map_err(to_sql_err)?,
        project_id: ProjectId::from_str(&row.get::<_, String>(1)?).map_err(to_sql_err)?,
        task_id: TaskId::from_str(&row.get::<_, String>(2)?).map_err(to_sql_err)?,
        attempt_id: AttemptId::from_str(&row.get::<_, String>(3)?).map_err(to_sql_err)?,
        status,
        approved_by: row.get(5)?,
        approved_at_ms: row.get::<_, i64>(6)? as u64,
        last_error: row.get(7)?,
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
