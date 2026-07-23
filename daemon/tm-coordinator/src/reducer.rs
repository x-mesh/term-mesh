use crate::fence::FenceRecord;
use crate::model::{
    now_ms, Attempt, AttemptId, FencingToken, HostId, IntentEvent, Project, ProjectId,
    ProjectState, Task, TaskId, TaskStatus,
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
            "#,
        )?;
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

    fn reduce_fence_issued(&self, event: &IntentEvent) -> Result<()> {
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

fn to_sql_err<E: std::fmt::Display>(err: E) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(err.to_string().into())
}
