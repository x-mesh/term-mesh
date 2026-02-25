use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::watcher::WatcherHandle;
use crate::worktree;

// ---------------------------------------------------------------------------
// Data types — Sessions
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Spawning,
    Running,
    Suspended,
    Terminated,
}

impl SessionStatus {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Spawning => "spawning",
            Self::Running => "running",
            Self::Suspended => "suspended",
            Self::Terminated => "terminated",
        }
    }

    fn from_str(s: &str) -> Self {
        match s {
            "spawning" => Self::Spawning,
            "running" => Self::Running,
            "suspended" => Self::Suspended,
            "terminated" => Self::Terminated,
            _ => Self::Terminated,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentSession {
    pub id: String,
    pub name: String,
    pub repo_path: String,
    pub worktree_name: String,
    pub worktree_path: String,
    pub worktree_branch: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    pub status: SessionStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    pub tracked_pids: Vec<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub panel_id: Option<String>,
    pub created_at_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub terminated_at_ms: Option<u64>,
}

#[derive(Debug, Deserialize)]
pub struct SpawnParams {
    pub repo_path: String,
    #[serde(default = "default_count")]
    pub count: usize,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub command: Option<String>,
}

fn default_count() -> usize {
    1
}

// ---------------------------------------------------------------------------
// Data types — Tasks (Phase 2)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Pending,
    Assigned,
    InProgress,
    Completed,
    Failed,
    Cancelled,
}

impl TaskStatus {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Assigned => "assigned",
            Self::InProgress => "in_progress",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }

    fn from_str(s: &str) -> Option<Self> {
        match s {
            "pending" => Some(Self::Pending),
            "assigned" => Some(Self::Assigned),
            "in_progress" => Some(Self::InProgress),
            "completed" => Some(Self::Completed),
            "failed" => Some(Self::Failed),
            "cancelled" => Some(Self::Cancelled),
            _ => None,
        }
    }

    /// Check if transitioning from `self` to `target` is valid.
    fn can_transition_to(&self, target: Self) -> bool {
        matches!(
            (self, target),
            (Self::Pending, Self::Assigned)
                | (Self::Pending, Self::Cancelled)
                | (Self::Assigned, Self::InProgress)
                | (Self::Assigned, Self::Cancelled)
                | (Self::InProgress, Self::Completed)
                | (Self::InProgress, Self::Failed)
                | (Self::InProgress, Self::Cancelled)
        )
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    pub status: TaskStatus,
    pub priority: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub assignee: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_by: Option<String>,
    pub deps: Vec<String>,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskLogEntry {
    pub id: i64,
    pub task_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    pub message: String,
    pub created_at_ms: u64,
}

#[derive(Debug, Deserialize)]
pub struct TaskCreateParams {
    pub title: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub priority: Option<i32>,
    #[serde(default)]
    pub created_by: Option<String>,
    #[serde(default)]
    pub deps: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
pub struct TaskUpdateParams {
    pub id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub priority: Option<i32>,
    #[serde(default)]
    pub assignee: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct TaskAssignParams {
    pub task_id: String,
    pub agent_id: String,
}

#[derive(Debug, Deserialize)]
pub struct TaskListParams {
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub assignee: Option<String>,
}

// ---------------------------------------------------------------------------
// Data types — Messages (Phase 2)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentMessage {
    pub id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from_agent: Option<String>,
    pub to_agent: String,
    pub content: String,
    pub read: bool,
    pub created_at_ms: u64,
}

#[derive(Debug, Deserialize)]
pub struct MessageSendParams {
    #[serde(default)]
    pub from_agent: Option<String>,
    pub to_agent: String,
    pub content: String,
}

#[derive(Debug, Deserialize)]
pub struct MessageListParams {
    pub agent_id: String,
    #[serde(default)]
    pub unread_only: Option<bool>,
    #[serde(default)]
    pub limit: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct MessageAckParams {
    pub message_ids: Vec<i64>,
}

// ---------------------------------------------------------------------------
// AgentSessionManager
// ---------------------------------------------------------------------------

pub struct AgentSessionManager {
    inner: Mutex<Inner>,
}

struct Inner {
    db: Connection,
    sessions: HashMap<String, AgentSession>,
    pending_inputs: HashMap<String, Vec<PendingInput>>,
}

/// A pending text input to be delivered to an agent's PTY via Swift polling.
#[derive(Debug, Clone, Serialize)]
pub struct PendingInput {
    pub session_id: String,
    pub text: String,
    pub created_at_ms: u64,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

impl AgentSessionManager {
    /// Open (or create) the SQLite database and run migrations.
    pub fn new(db_path: PathBuf) -> anyhow::Result<Self> {
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let db = Connection::open(&db_path)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")?;

        // Phase 1 tables
        db.execute_batch(
            "CREATE TABLE IF NOT EXISTS agent_sessions (
                id               TEXT PRIMARY KEY,
                name             TEXT NOT NULL,
                repo_path        TEXT NOT NULL,
                worktree_name    TEXT NOT NULL,
                worktree_path    TEXT NOT NULL,
                worktree_branch  TEXT NOT NULL,
                command          TEXT,
                status           TEXT NOT NULL DEFAULT 'spawning',
                pid              INTEGER,
                panel_id         TEXT,
                created_at_ms    INTEGER NOT NULL,
                terminated_at_ms INTEGER
            );

            CREATE TABLE IF NOT EXISTS session_pids (
                session_id TEXT NOT NULL REFERENCES agent_sessions(id),
                pid        INTEGER NOT NULL,
                PRIMARY KEY (session_id, pid)
            );

            -- Phase 2 tables
            CREATE TABLE IF NOT EXISTS tasks (
                id          TEXT PRIMARY KEY,
                title       TEXT NOT NULL,
                description TEXT,
                status      TEXT NOT NULL DEFAULT 'pending',
                priority    INTEGER NOT NULL DEFAULT 0,
                assignee    TEXT REFERENCES agent_sessions(id),
                created_by  TEXT REFERENCES agent_sessions(id),
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS task_deps (
                task_id    TEXT NOT NULL REFERENCES tasks(id),
                depends_on TEXT NOT NULL REFERENCES tasks(id),
                PRIMARY KEY (task_id, depends_on)
            );

            CREATE TABLE IF NOT EXISTS task_log (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id    TEXT REFERENCES tasks(id),
                agent_id   TEXT REFERENCES agent_sessions(id),
                message    TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS agent_messages (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                from_agent    TEXT REFERENCES agent_sessions(id),
                to_agent      TEXT NOT NULL REFERENCES agent_sessions(id),
                content       TEXT NOT NULL,
                read          INTEGER NOT NULL DEFAULT 0,
                created_at_ms INTEGER NOT NULL
            );"
        )?;

        // Migration: add priority column if missing (existing DBs from Phase 1)
        let has_priority: bool = db
            .prepare("SELECT COUNT(*) FROM pragma_table_info('tasks') WHERE name='priority'")
            .and_then(|mut s| s.query_row([], |r| r.get::<_, i64>(0)))
            .map(|c| c > 0)
            .unwrap_or(false);
        if !has_priority {
            let _ = db.execute_batch(
                "ALTER TABLE tasks ADD COLUMN priority INTEGER NOT NULL DEFAULT 0"
            );
        }

        // Load non-terminated sessions into memory
        let mut sessions = HashMap::new();
        {
            let mut stmt = db.prepare(
                "SELECT s.id, s.name, s.repo_path, s.worktree_name, s.worktree_path,
                        s.worktree_branch, s.command, s.status, s.pid, s.panel_id,
                        s.created_at_ms, s.terminated_at_ms
                 FROM agent_sessions s
                 WHERE s.status != 'terminated'"
            )?;

            let rows = stmt.query_map([], |row| {
                let id: String = row.get(0)?;
                Ok(AgentSession {
                    id: id.clone(),
                    name: row.get(1)?,
                    repo_path: row.get(2)?,
                    worktree_name: row.get(3)?,
                    worktree_path: row.get(4)?,
                    worktree_branch: row.get(5)?,
                    command: row.get(6)?,
                    status: SessionStatus::from_str(&row.get::<_, String>(7)?),
                    pid: row.get::<_, Option<u32>>(8)?,
                    tracked_pids: Vec::new(), // loaded below
                    panel_id: row.get(9)?,
                    created_at_ms: row.get(10)?,
                    terminated_at_ms: row.get(11)?,
                })
            })?;

            for row in rows {
                let session = row?;
                sessions.insert(session.id.clone(), session);
            }

            // Load tracked PIDs
            let mut pid_stmt = db.prepare(
                "SELECT session_id, pid FROM session_pids"
            )?;
            let pid_rows = pid_stmt.query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, u32>(1)?))
            })?;
            for row in pid_rows {
                let (session_id, pid) = row?;
                if let Some(session) = sessions.get_mut(&session_id) {
                    session.tracked_pids.push(pid);
                }
            }
        }

        let count = sessions.len();
        if count > 0 {
            tracing::info!("loaded {count} active agent session(s) from DB");
        }

        Ok(Self {
            inner: Mutex::new(Inner { db, sessions, pending_inputs: HashMap::new() }),
        })
    }

    /// Spawn `count` new agent sessions, each with its own worktree.
    pub fn spawn(
        &self,
        params: SpawnParams,
        watcher: &WatcherHandle,
    ) -> Result<Vec<AgentSession>, String> {
        let mut results = Vec::with_capacity(params.count);

        for i in 0..params.count {
            let name = params
                .name
                .as_ref()
                .map(|n| {
                    if params.count > 1 {
                        format!("{n}-{}", i + 1)
                    } else {
                        n.clone()
                    }
                })
                .unwrap_or_else(|| format!("agent-{}", i + 1));

            // Create worktree via existing worktree module
            let wt_params = serde_json::json!({ "repo_path": params.repo_path });
            let wt_info = worktree::create(wt_params)?;

            // Watch the worktree directory
            watcher.watch_path(&wt_info.path);

            let session = AgentSession {
                id: uuid::Uuid::new_v4().to_string(),
                name,
                repo_path: params.repo_path.clone(),
                worktree_name: wt_info.name.clone(),
                worktree_path: wt_info.path.clone(),
                worktree_branch: wt_info.branch.clone(),
                command: params.command.clone(),
                status: SessionStatus::Running,
                pid: None,
                tracked_pids: Vec::new(),
                panel_id: None,
                created_at_ms: now_ms(),
                terminated_at_ms: None,
            };

            // Persist to DB + memory
            {
                let inner = self.inner.lock().unwrap();
                inner.db.execute(
                    "INSERT INTO agent_sessions
                        (id, name, repo_path, worktree_name, worktree_path, worktree_branch,
                         command, status, pid, panel_id, created_at_ms, terminated_at_ms)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                    params![
                        session.id,
                        session.name,
                        session.repo_path,
                        session.worktree_name,
                        session.worktree_path,
                        session.worktree_branch,
                        session.command,
                        session.status.as_str(),
                        session.pid,
                        session.panel_id,
                        session.created_at_ms,
                        session.terminated_at_ms,
                    ],
                ).map_err(|e| format!("DB insert failed: {e}"))?;
            }

            // Insert into memory map (separate lock scope)
            {
                let mut inner = self.inner.lock().unwrap();
                inner.sessions.insert(session.id.clone(), session.clone());
            }

            tracing::info!(
                "spawned agent session {} ({}) at {}",
                session.id, session.name, session.worktree_path
            );

            results.push(session);
        }

        Ok(results)
    }

    /// List agent sessions. If `include_terminated` is false, only active sessions.
    pub fn list(&self, include_terminated: bool) -> Vec<AgentSession> {
        let inner = self.inner.lock().unwrap();
        if include_terminated {
            // Also fetch terminated sessions from DB
            let mut all: Vec<AgentSession> = inner.sessions.values().cloned().collect();

            if let Ok(mut stmt) = inner.db.prepare(
                "SELECT id, name, repo_path, worktree_name, worktree_path, worktree_branch,
                        command, status, pid, panel_id, created_at_ms, terminated_at_ms
                 FROM agent_sessions WHERE status = 'terminated'"
            ) {
                if let Ok(rows) = stmt.query_map([], |row| {
                    Ok(AgentSession {
                        id: row.get(0)?,
                        name: row.get(1)?,
                        repo_path: row.get(2)?,
                        worktree_name: row.get(3)?,
                        worktree_path: row.get(4)?,
                        worktree_branch: row.get(5)?,
                        command: row.get(6)?,
                        status: SessionStatus::from_str(&row.get::<_, String>(7)?),
                        pid: row.get::<_, Option<u32>>(8)?,
                        tracked_pids: Vec::new(),
                        panel_id: row.get(9)?,
                        created_at_ms: row.get(10)?,
                        terminated_at_ms: row.get(11)?,
                    })
                }) {
                    for row in rows.flatten() {
                        all.push(row);
                    }
                }
            }

            all.sort_by_key(|s| s.created_at_ms);
            all
        } else {
            let mut active: Vec<AgentSession> = inner.sessions.values().cloned().collect();
            active.sort_by_key(|s| s.created_at_ms);
            active
        }
    }

    /// Get a single session by ID.
    pub fn get(&self, id: &str) -> Option<AgentSession> {
        let inner = self.inner.lock().unwrap();
        if let Some(s) = inner.sessions.get(id) {
            return Some(s.clone());
        }

        // Check DB for terminated sessions
        inner.db.query_row(
            "SELECT id, name, repo_path, worktree_name, worktree_path, worktree_branch,
                    command, status, pid, panel_id, created_at_ms, terminated_at_ms
             FROM agent_sessions WHERE id = ?1",
            params![id],
            |row| {
                Ok(AgentSession {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    repo_path: row.get(2)?,
                    worktree_name: row.get(3)?,
                    worktree_path: row.get(4)?,
                    worktree_branch: row.get(5)?,
                    command: row.get(6)?,
                    status: SessionStatus::from_str(&row.get::<_, String>(7)?),
                    pid: row.get::<_, Option<u32>>(8)?,
                    tracked_pids: Vec::new(),
                    panel_id: row.get(9)?,
                    created_at_ms: row.get(10)?,
                    terminated_at_ms: row.get(11)?,
                })
            },
        ).ok()
    }

    /// Terminate an agent session: kill processes, unwatch, remove worktree, update DB.
    pub fn terminate(
        &self,
        id: &str,
        force: bool,
        watcher: &WatcherHandle,
    ) -> Result<(), String> {
        let session = {
            let inner = self.inner.lock().unwrap();
            inner.sessions.get(id).cloned()
        };

        let session = session.ok_or_else(|| format!("session not found: {id}"))?;

        if session.status == SessionStatus::Terminated {
            return Ok(());
        }

        // Kill tracked PIDs
        let signal = if force { libc::SIGKILL } else { libc::SIGTERM };
        for &pid in &session.tracked_pids {
            unsafe { libc::kill(pid as i32, signal); }
        }
        if let Some(pid) = session.pid {
            unsafe { libc::kill(pid as i32, signal); }
        }

        // Unwatch worktree
        watcher.unwatch_path(&session.worktree_path);

        // Remove worktree
        let remove_params = serde_json::json!({
            "repo_path": session.repo_path,
            "name": session.worktree_name,
        });
        if let Err(e) = worktree::remove(remove_params) {
            tracing::warn!("failed to remove worktree {}: {e}", session.worktree_name);
        }

        // Update DB and memory
        let ts = now_ms();
        {
            let mut inner = self.inner.lock().unwrap();
            let _ = inner.db.execute(
                "UPDATE agent_sessions SET status = 'terminated', terminated_at_ms = ?1 WHERE id = ?2",
                params![ts, id],
            );
            let _ = inner.db.execute(
                "DELETE FROM session_pids WHERE session_id = ?1",
                params![id],
            );
            // Reset assigned/in_progress tasks back to pending
            let _ = inner.db.execute(
                "UPDATE tasks SET assignee = NULL, status = 'pending', updated_at_ms = ?1
                 WHERE assignee = ?2 AND status IN ('assigned', 'in_progress')",
                params![ts, id],
            );
            inner.sessions.remove(id);
        }

        tracing::info!("terminated agent session {id} ({})", session.name);
        Ok(())
    }

    /// Bind a UI panel to a session.
    pub fn bind_panel(&self, session_id: &str, panel_id: &str) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap();
        let session = inner.sessions.get_mut(session_id)
            .ok_or_else(|| format!("session not found: {session_id}"))?;
        session.panel_id = Some(panel_id.to_string());
        let _ = inner.db.execute(
            "UPDATE agent_sessions SET panel_id = ?1 WHERE id = ?2",
            params![panel_id, session_id],
        );
        tracing::debug!("bound panel {panel_id} to session {session_id}");
        Ok(())
    }

    /// Unbind a UI panel from a session (session stays alive).
    pub fn unbind_panel(&self, session_id: &str) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap();
        let session = inner.sessions.get_mut(session_id)
            .ok_or_else(|| format!("session not found: {session_id}"))?;
        session.panel_id = None;
        let _ = inner.db.execute(
            "UPDATE agent_sessions SET panel_id = NULL WHERE id = ?1",
            params![session_id],
        );
        tracing::debug!("unbound panel from session {session_id}");
        Ok(())
    }

    /// Register an additional PID for a session.
    pub fn add_pid(&self, session_id: &str, pid: u32) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap();
        if !inner.sessions.contains_key(session_id) {
            return Err(format!("session not found: {session_id}"));
        }
        let (need_insert_pid, need_set_main) = {
            let session = inner.sessions.get_mut(session_id).unwrap();
            let need_insert = !session.tracked_pids.contains(&pid);
            let need_main = session.pid.is_none();
            if need_insert {
                session.tracked_pids.push(pid);
            }
            if need_main {
                session.pid = Some(pid);
                session.status = SessionStatus::Running;
            }
            (need_insert, need_main)
        };
        if need_insert_pid {
            let _ = inner.db.execute(
                "INSERT OR IGNORE INTO session_pids (session_id, pid) VALUES (?1, ?2)",
                params![session_id, pid],
            );
        }
        if need_set_main {
            let _ = inner.db.execute(
                "UPDATE agent_sessions SET pid = ?1, status = 'running' WHERE id = ?2",
                params![pid, session_id],
            );
        }
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Task CRUD (Phase 2)
    // -----------------------------------------------------------------------

    /// Create a new task.
    pub fn task_create(&self, params: TaskCreateParams) -> Result<Task, String> {
        let inner = self.inner.lock().unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let ts = now_ms();
        let priority = params.priority.unwrap_or(0);

        inner.db.execute(
            "INSERT INTO tasks (id, title, description, status, priority, assignee, created_by, created_at_ms, updated_at_ms)
             VALUES (?1, ?2, ?3, 'pending', ?4, NULL, ?5, ?6, ?7)",
            params![id, params.title, params.description, priority, params.created_by, ts, ts],
        ).map_err(|e| format!("DB insert failed: {e}"))?;

        // Insert deps
        let deps = params.deps.unwrap_or_default();
        for dep in &deps {
            inner.db.execute(
                "INSERT INTO task_deps (task_id, depends_on) VALUES (?1, ?2)",
                params![id, dep],
            ).map_err(|e| format!("dep insert failed: {e}"))?;
        }

        // Log creation
        inner.db.execute(
            "INSERT INTO task_log (task_id, agent_id, message, created_at_ms) VALUES (?1, ?2, ?3, ?4)",
            params![id, params.created_by, "task created", ts],
        ).map_err(|e| format!("log insert failed: {e}"))?;

        Ok(Task {
            id,
            title: params.title,
            description: params.description,
            status: TaskStatus::Pending,
            priority,
            assignee: None,
            created_by: params.created_by,
            deps,
            created_at_ms: ts,
            updated_at_ms: ts,
        })
    }

    /// Get a task by ID (with deps loaded).
    pub fn task_get(&self, id: &str) -> Result<Task, String> {
        let inner = self.inner.lock().unwrap();
        let task = inner.db.query_row(
            "SELECT id, title, description, status, priority, assignee, created_by, created_at_ms, updated_at_ms
             FROM tasks WHERE id = ?1",
            params![id],
            |row| {
                Ok(Task {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    description: row.get(2)?,
                    status: TaskStatus::from_str(&row.get::<_, String>(3)?).unwrap_or(TaskStatus::Pending),
                    priority: row.get(4)?,
                    assignee: row.get(5)?,
                    created_by: row.get(6)?,
                    deps: Vec::new(),
                    created_at_ms: row.get(7)?,
                    updated_at_ms: row.get(8)?,
                })
            },
        ).map_err(|_| format!("task not found: {id}"))?;

        let deps = Self::load_deps(&inner.db, id);
        Ok(Task { deps, ..task })
    }

    /// List tasks with optional filters, ordered by priority DESC.
    pub fn task_list(&self, params: TaskListParams) -> Vec<Task> {
        let inner = self.inner.lock().unwrap();
        let mut sql = String::from(
            "SELECT id, title, description, status, priority, assignee, created_by, created_at_ms, updated_at_ms FROM tasks WHERE 1=1"
        );
        let mut bind_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(ref status) = params.status {
            bind_values.push(Box::new(status.clone()));
            sql.push_str(&format!(" AND status = ?{}", bind_values.len()));
        }
        if let Some(ref assignee) = params.assignee {
            bind_values.push(Box::new(assignee.clone()));
            sql.push_str(&format!(" AND assignee = ?{}", bind_values.len()));
        }
        sql.push_str(" ORDER BY priority DESC, created_at_ms ASC");

        let mut stmt = match inner.db.prepare(&sql) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };

        let refs: Vec<&dyn rusqlite::types::ToSql> = bind_values.iter().map(|b| b.as_ref()).collect();
        let rows = match stmt.query_map(refs.as_slice(), |row| {
            Ok(Task {
                id: row.get(0)?,
                title: row.get(1)?,
                description: row.get(2)?,
                status: TaskStatus::from_str(&row.get::<_, String>(3)?).unwrap_or(TaskStatus::Pending),
                priority: row.get(4)?,
                assignee: row.get(5)?,
                created_by: row.get(6)?,
                deps: Vec::new(),
                created_at_ms: row.get(7)?,
                updated_at_ms: row.get(8)?,
            })
        }) {
            Ok(r) => r,
            Err(_) => return Vec::new(),
        };

        let mut tasks: Vec<Task> = rows.flatten().collect();
        // Load deps for each task
        for task in &mut tasks {
            task.deps = Self::load_deps(&inner.db, &task.id);
        }
        tasks
    }

    /// Update a task (partial update + state machine validation).
    pub fn task_update(&self, params: TaskUpdateParams) -> Result<Task, String> {
        let inner = self.inner.lock().unwrap();

        // Load current task
        let current = inner.db.query_row(
            "SELECT status, assignee FROM tasks WHERE id = ?1",
            params![params.id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
        ).map_err(|_| format!("task not found: {}", params.id))?;

        let current_status = TaskStatus::from_str(&current.0)
            .ok_or_else(|| format!("invalid current status: {}", current.0))?;

        // Validate status transition if provided
        if let Some(ref status_str) = params.status {
            let new_status = TaskStatus::from_str(status_str)
                .ok_or_else(|| format!("invalid status: {status_str}"))?;
            if !current_status.can_transition_to(new_status) {
                return Err(format!(
                    "invalid transition: {} -> {}",
                    current_status.as_str(),
                    new_status.as_str()
                ));
            }
        }

        let ts = now_ms();
        let mut sets = vec!["updated_at_ms = ?1".to_string()];
        let mut bind_values: Vec<Box<dyn rusqlite::types::ToSql>> = vec![Box::new(ts)];

        if let Some(ref title) = params.title {
            bind_values.push(Box::new(title.clone()));
            sets.push(format!("title = ?{}", bind_values.len()));
        }
        if let Some(ref desc) = params.description {
            bind_values.push(Box::new(desc.clone()));
            sets.push(format!("description = ?{}", bind_values.len()));
        }
        if let Some(ref status) = params.status {
            bind_values.push(Box::new(status.clone()));
            sets.push(format!("status = ?{}", bind_values.len()));
        }
        if let Some(ref priority) = params.priority {
            bind_values.push(Box::new(*priority));
            sets.push(format!("priority = ?{}", bind_values.len()));
        }
        // Allow clearing assignee by sending explicit null
        if params.assignee.is_some() {
            bind_values.push(Box::new(params.assignee.clone()));
            sets.push(format!("assignee = ?{}", bind_values.len()));
        }

        bind_values.push(Box::new(params.id.clone()));
        let id_idx = bind_values.len();
        let sql = format!("UPDATE tasks SET {} WHERE id = ?{}", sets.join(", "), id_idx);

        let refs: Vec<&dyn rusqlite::types::ToSql> = bind_values.iter().map(|b| b.as_ref()).collect();
        inner.db.execute(&sql, refs.as_slice())
            .map_err(|e| format!("update failed: {e}"))?;

        // Log the change
        let mut log_parts = Vec::new();
        if params.title.is_some() { log_parts.push("title"); }
        if params.description.is_some() { log_parts.push("description"); }
        if let Some(ref s) = params.status { log_parts.push(s); }
        if params.priority.is_some() { log_parts.push("priority"); }
        if params.assignee.is_some() { log_parts.push("assignee"); }
        let log_msg = format!("updated: {}", log_parts.join(", "));
        let _ = inner.db.execute(
            "INSERT INTO task_log (task_id, agent_id, message, created_at_ms) VALUES (?1, NULL, ?2, ?3)",
            params![params.id, log_msg, ts],
        );

        drop(inner);
        self.task_get(&params.id)
    }

    /// Assign a task to an agent (checks deps + agent validity).
    pub fn task_assign(&self, params: TaskAssignParams) -> Result<Task, String> {
        let inner = self.inner.lock().unwrap();

        // Verify agent exists and is active
        if !inner.sessions.contains_key(&params.agent_id) {
            return Err(format!("agent not found or terminated: {}", params.agent_id));
        }

        // Load current task status
        let current_status_str: String = inner.db.query_row(
            "SELECT status FROM tasks WHERE id = ?1",
            params![params.task_id],
            |row| row.get(0),
        ).map_err(|_| format!("task not found: {}", params.task_id))?;

        let current_status = TaskStatus::from_str(&current_status_str)
            .ok_or_else(|| format!("invalid status: {current_status_str}"))?;

        // Only pending tasks can be assigned
        if !current_status.can_transition_to(TaskStatus::Assigned) {
            return Err(format!(
                "cannot assign task in status: {}",
                current_status.as_str()
            ));
        }

        // Check all deps are completed
        let deps = Self::load_deps(&inner.db, &params.task_id);
        if !deps.is_empty() {
            let placeholders: Vec<String> = deps.iter().enumerate().map(|(i, _)| format!("?{}", i + 1)).collect();
            let sql = format!(
                "SELECT COUNT(*) FROM tasks WHERE id IN ({}) AND status != 'completed'",
                placeholders.join(", ")
            );
            let mut stmt = inner.db.prepare(&sql).map_err(|e| format!("query failed: {e}"))?;
            let dep_refs: Vec<&dyn rusqlite::types::ToSql> = deps.iter().map(|d| d as &dyn rusqlite::types::ToSql).collect();
            let incomplete: i64 = stmt.query_row(dep_refs.as_slice(), |row| row.get(0))
                .map_err(|e| format!("dep check failed: {e}"))?;
            if incomplete > 0 {
                return Err(format!("{incomplete} dependency(ies) not yet completed"));
            }
        }

        let ts = now_ms();
        inner.db.execute(
            "UPDATE tasks SET assignee = ?1, status = 'assigned', updated_at_ms = ?2 WHERE id = ?3",
            params![params.agent_id, ts, params.task_id],
        ).map_err(|e| format!("assign failed: {e}"))?;

        let _ = inner.db.execute(
            "INSERT INTO task_log (task_id, agent_id, message, created_at_ms) VALUES (?1, ?2, ?3, ?4)",
            params![params.task_id, params.agent_id, format!("assigned to {}", params.agent_id), ts],
        );

        drop(inner);
        self.task_get(&params.task_id)
    }

    /// Get task log entries.
    pub fn task_log(&self, task_id: &str, limit: Option<i64>) -> Vec<TaskLogEntry> {
        let inner = self.inner.lock().unwrap();
        let limit = limit.unwrap_or(100);
        let mut stmt = match inner.db.prepare(
            "SELECT id, task_id, agent_id, message, created_at_ms FROM task_log
             WHERE task_id = ?1 ORDER BY id DESC LIMIT ?2"
        ) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };

        let rows = match stmt.query_map(params![task_id, limit], |row| {
            Ok(TaskLogEntry {
                id: row.get(0)?,
                task_id: row.get(1)?,
                agent_id: row.get(2)?,
                message: row.get(3)?,
                created_at_ms: row.get(4)?,
            })
        }) {
            Ok(r) => r,
            Err(_) => return Vec::new(),
        };

        rows.flatten().collect()
    }

    // -----------------------------------------------------------------------
    // Messages (Phase 2)
    // -----------------------------------------------------------------------

    /// Send a message to an agent.
    pub fn message_send(&self, params: MessageSendParams) -> Result<AgentMessage, String> {
        let mut inner = self.inner.lock().unwrap();

        // Verify recipient exists and is active
        if !inner.sessions.contains_key(&params.to_agent) {
            return Err(format!("recipient agent not found or terminated: {}", params.to_agent));
        }

        let ts = now_ms();
        inner.db.execute(
            "INSERT INTO agent_messages (from_agent, to_agent, content, read, created_at_ms)
             VALUES (?1, ?2, ?3, 0, ?4)",
            params![params.from_agent, params.to_agent, params.content, ts],
        ).map_err(|e| format!("message insert failed: {e}"))?;

        // Auto-enqueue input for PTY delivery
        let from_label = params.from_agent.as_deref().unwrap_or("dashboard");
        let formatted = format!("[MSG from {}]: {}", from_label, params.content);
        inner.pending_inputs
            .entry(params.to_agent.clone())
            .or_default()
            .push(PendingInput {
                session_id: params.to_agent.clone(),
                text: formatted,
                created_at_ms: ts,
            });

        let id = inner.db.last_insert_rowid();
        Ok(AgentMessage {
            id,
            from_agent: params.from_agent,
            to_agent: params.to_agent,
            content: params.content,
            read: false,
            created_at_ms: ts,
        })
    }

    /// List messages for an agent.
    pub fn message_list(&self, params: MessageListParams) -> Vec<AgentMessage> {
        let inner = self.inner.lock().unwrap();
        let limit = params.limit.unwrap_or(50);
        let unread_only = params.unread_only.unwrap_or(false);

        let sql = if unread_only {
            "SELECT id, from_agent, to_agent, content, read, created_at_ms FROM agent_messages
             WHERE to_agent = ?1 AND read = 0 ORDER BY created_at_ms DESC LIMIT ?2"
        } else {
            "SELECT id, from_agent, to_agent, content, read, created_at_ms FROM agent_messages
             WHERE to_agent = ?1 ORDER BY created_at_ms DESC LIMIT ?2"
        };

        let mut stmt = match inner.db.prepare(sql) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };

        let rows = match stmt.query_map(params![params.agent_id, limit], |row| {
            Ok(AgentMessage {
                id: row.get(0)?,
                from_agent: row.get(1)?,
                to_agent: row.get(2)?,
                content: row.get(3)?,
                read: row.get::<_, i32>(4)? != 0,
                created_at_ms: row.get(5)?,
            })
        }) {
            Ok(r) => r,
            Err(_) => return Vec::new(),
        };

        rows.flatten().collect()
    }

    /// Acknowledge (mark as read) a list of message IDs.
    pub fn message_ack(&self, message_ids: &[i64]) -> Result<usize, String> {
        if message_ids.is_empty() {
            return Ok(0);
        }
        let inner = self.inner.lock().unwrap();
        let placeholders: Vec<String> = message_ids.iter().enumerate().map(|(i, _)| format!("?{}", i + 1)).collect();
        let sql = format!(
            "UPDATE agent_messages SET read = 1 WHERE id IN ({})",
            placeholders.join(", ")
        );
        let mut stmt = inner.db.prepare(&sql).map_err(|e| format!("prepare failed: {e}"))?;
        let refs: Vec<&dyn rusqlite::types::ToSql> = message_ids.iter().map(|id| id as &dyn rusqlite::types::ToSql).collect();
        let count = stmt.execute(refs.as_slice()).map_err(|e| format!("ack failed: {e}"))?;
        Ok(count)
    }

    // -----------------------------------------------------------------------
    // Pending Input Queue (PTY injection via Swift polling)
    // -----------------------------------------------------------------------

    /// Enqueue text to be delivered to an agent's PTY.
    pub fn enqueue_input(&self, session_id: &str, text: &str) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap();
        match inner.sessions.get(session_id) {
            Some(s) if s.status != SessionStatus::Terminated => {}
            Some(_) => return Err(format!("session is terminated: {session_id}")),
            None => return Err(format!("session not found: {session_id}")),
        }
        inner.pending_inputs
            .entry(session_id.to_string())
            .or_default()
            .push(PendingInput {
                session_id: session_id.to_string(),
                text: text.to_string(),
                created_at_ms: now_ms(),
            });
        Ok(())
    }

    /// Drain all pending inputs (called by Swift app via polling).
    pub fn poll_inputs(&self) -> Vec<PendingInput> {
        let mut inner = self.inner.lock().unwrap();
        let mut all = Vec::new();
        for (_, queue) in inner.pending_inputs.drain() {
            all.extend(queue);
        }
        all
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    fn load_deps(db: &Connection, task_id: &str) -> Vec<String> {
        let mut stmt = match db.prepare("SELECT depends_on FROM task_deps WHERE task_id = ?1") {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let rows = match stmt.query_map(params![task_id], |row| row.get::<_, String>(0)) {
            Ok(r) => r,
            Err(_) => return Vec::new(),
        };
        rows.flatten().collect()
    }

    /// Terminate all active sessions (called during graceful shutdown).
    pub fn terminate_all(&self, watcher: &WatcherHandle) {
        let ids: Vec<String> = {
            let inner = self.inner.lock().unwrap();
            inner.sessions.keys().cloned().collect()
        };

        for id in ids {
            if let Err(e) = self.terminate(&id, false, watcher) {
                tracing::warn!("failed to terminate session {id}: {e}");
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Default DB path
// ---------------------------------------------------------------------------

pub fn default_db_path() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("term-mesh")
        .join("agent_sessions.db")
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn test_manager() -> (tempfile::TempDir, AgentSessionManager) {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("test.db");
        let mgr = AgentSessionManager::new(db_path).unwrap();
        (dir, mgr)
    }

    #[test]
    fn new_creates_tables() {
        let (_dir, mgr) = test_manager();
        let inner = mgr.inner.lock().unwrap();
        // Verify tables exist
        let count: i64 = inner.db.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN
             ('agent_sessions', 'session_pids', 'tasks', 'task_deps', 'task_log')",
            [],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(count, 5);
    }

    #[test]
    fn list_empty() {
        let (_dir, mgr) = test_manager();
        assert!(mgr.list(false).is_empty());
        assert!(mgr.list(true).is_empty());
    }

    #[test]
    fn get_nonexistent() {
        let (_dir, mgr) = test_manager();
        assert!(mgr.get("nonexistent").is_none());
    }

    #[test]
    fn bind_unbind_panel() {
        let (_dir, mgr) = test_manager();

        // Insert a fake session directly
        {
            let inner = mgr.inner.lock().unwrap();
            inner.db.execute(
                "INSERT INTO agent_sessions
                    (id, name, repo_path, worktree_name, worktree_path, worktree_branch,
                     status, created_at_ms)
                 VALUES ('s1', 'test', '/repo', 'wt', '/wt', 'branch', 'running', 1000)",
                [],
            ).unwrap();
        }
        // Also add to memory
        {
            let mut inner = mgr.inner.lock().unwrap();
            inner.sessions.insert("s1".to_string(), AgentSession {
                id: "s1".into(),
                name: "test".into(),
                repo_path: "/repo".into(),
                worktree_name: "wt".into(),
                worktree_path: "/wt".into(),
                worktree_branch: "branch".into(),
                command: None,
                status: SessionStatus::Running,
                pid: None,
                tracked_pids: vec![],
                panel_id: None,
                created_at_ms: 1000,
                terminated_at_ms: None,
            });
        }

        mgr.bind_panel("s1", "panel-123").unwrap();
        let s = mgr.get("s1").unwrap();
        assert_eq!(s.panel_id, Some("panel-123".into()));

        mgr.unbind_panel("s1").unwrap();
        let s = mgr.get("s1").unwrap();
        assert!(s.panel_id.is_none());
    }

    #[test]
    fn add_pid_sets_main() {
        let (_dir, mgr) = test_manager();
        {
            let mut inner = mgr.inner.lock().unwrap();
            inner.db.execute(
                "INSERT INTO agent_sessions
                    (id, name, repo_path, worktree_name, worktree_path, worktree_branch,
                     status, created_at_ms)
                 VALUES ('s2', 'test2', '/repo', 'wt2', '/wt2', 'b2', 'spawning', 2000)",
                [],
            ).unwrap();
            inner.sessions.insert("s2".to_string(), AgentSession {
                id: "s2".into(),
                name: "test2".into(),
                repo_path: "/repo".into(),
                worktree_name: "wt2".into(),
                worktree_path: "/wt2".into(),
                worktree_branch: "b2".into(),
                command: None,
                status: SessionStatus::Spawning,
                pid: None,
                tracked_pids: vec![],
                panel_id: None,
                created_at_ms: 2000,
                terminated_at_ms: None,
            });
        }

        mgr.add_pid("s2", 12345).unwrap();
        let s = mgr.get("s2").unwrap();
        assert_eq!(s.pid, Some(12345));
        assert_eq!(s.tracked_pids, vec![12345]);
        assert_eq!(s.status, SessionStatus::Running);
    }

    // --- Phase 2 Task Tests ---

    fn insert_fake_agent(mgr: &AgentSessionManager, id: &str) {
        let mut inner = mgr.inner.lock().unwrap();
        inner.db.execute(
            "INSERT INTO agent_sessions
                (id, name, repo_path, worktree_name, worktree_path, worktree_branch,
                 status, created_at_ms)
             VALUES (?1, ?1, '/repo', 'wt', '/wt', 'b', 'running', 1000)",
            params![id],
        ).unwrap();
        inner.sessions.insert(id.to_string(), AgentSession {
            id: id.into(),
            name: id.into(),
            repo_path: "/repo".into(),
            worktree_name: "wt".into(),
            worktree_path: "/wt".into(),
            worktree_branch: "b".into(),
            command: None,
            status: SessionStatus::Running,
            pid: None,
            tracked_pids: vec![],
            panel_id: None,
            created_at_ms: 1000,
            terminated_at_ms: None,
        });
    }

    #[test]
    fn task_create_and_get() {
        let (_dir, mgr) = test_manager();
        let task = mgr.task_create(TaskCreateParams {
            title: "Test task".into(),
            description: Some("A description".into()),
            priority: Some(5),
            created_by: None,
            deps: None,
        }).unwrap();

        assert_eq!(task.title, "Test task");
        assert_eq!(task.status, TaskStatus::Pending);
        assert_eq!(task.priority, 5);

        let fetched = mgr.task_get(&task.id).unwrap();
        assert_eq!(fetched.title, "Test task");
        assert_eq!(fetched.description, Some("A description".into()));
    }

    #[test]
    fn task_list_with_filters() {
        let (_dir, mgr) = test_manager();
        insert_fake_agent(&mgr, "a1");

        let t1 = mgr.task_create(TaskCreateParams {
            title: "High priority".into(),
            description: None,
            priority: Some(10),
            created_by: None,
            deps: None,
        }).unwrap();
        let _t2 = mgr.task_create(TaskCreateParams {
            title: "Low priority".into(),
            description: None,
            priority: Some(1),
            created_by: None,
            deps: None,
        }).unwrap();

        // List all — should be ordered by priority DESC
        let all = mgr.task_list(TaskListParams { status: None, assignee: None });
        assert_eq!(all.len(), 2);
        assert_eq!(all[0].title, "High priority");

        // Assign t1 and filter by status
        mgr.task_assign(TaskAssignParams {
            task_id: t1.id.clone(),
            agent_id: "a1".into(),
        }).unwrap();

        let assigned = mgr.task_list(TaskListParams {
            status: Some("assigned".into()),
            assignee: None,
        });
        assert_eq!(assigned.len(), 1);
        assert_eq!(assigned[0].id, t1.id);

        let by_agent = mgr.task_list(TaskListParams {
            status: None,
            assignee: Some("a1".into()),
        });
        assert_eq!(by_agent.len(), 1);
    }

    #[test]
    fn task_update_state_machine() {
        let (_dir, mgr) = test_manager();
        insert_fake_agent(&mgr, "a1");

        let task = mgr.task_create(TaskCreateParams {
            title: "SM test".into(),
            description: None,
            priority: None,
            created_by: None,
            deps: None,
        }).unwrap();

        // Invalid: pending -> in_progress (must go through assigned)
        let err = mgr.task_update(TaskUpdateParams {
            id: task.id.clone(),
            title: None,
            description: None,
            status: Some("in_progress".into()),
            priority: None,
            assignee: None,
        });
        assert!(err.is_err());

        // Valid: pending -> cancelled
        let updated = mgr.task_update(TaskUpdateParams {
            id: task.id.clone(),
            title: None,
            description: None,
            status: Some("cancelled".into()),
            priority: None,
            assignee: None,
        }).unwrap();
        assert_eq!(updated.status, TaskStatus::Cancelled);

        // Create another to test full lifecycle
        let t2 = mgr.task_create(TaskCreateParams {
            title: "Lifecycle".into(),
            description: None,
            priority: None,
            created_by: None,
            deps: None,
        }).unwrap();

        // pending -> assigned (via task_assign)
        mgr.task_assign(TaskAssignParams {
            task_id: t2.id.clone(),
            agent_id: "a1".into(),
        }).unwrap();

        // assigned -> in_progress
        let t2 = mgr.task_update(TaskUpdateParams {
            id: t2.id.clone(),
            title: None,
            description: None,
            status: Some("in_progress".into()),
            priority: None,
            assignee: None,
        }).unwrap();
        assert_eq!(t2.status, TaskStatus::InProgress);

        // in_progress -> completed
        let t2 = mgr.task_update(TaskUpdateParams {
            id: t2.id.clone(),
            title: None,
            description: None,
            status: Some("completed".into()),
            priority: None,
            assignee: None,
        }).unwrap();
        assert_eq!(t2.status, TaskStatus::Completed);
    }

    #[test]
    fn task_assign_checks_deps() {
        let (_dir, mgr) = test_manager();
        insert_fake_agent(&mgr, "a1");

        // Create dep task (not completed)
        let dep = mgr.task_create(TaskCreateParams {
            title: "Dep task".into(),
            description: None,
            priority: None,
            created_by: None,
            deps: None,
        }).unwrap();

        // Create task with dep
        let task = mgr.task_create(TaskCreateParams {
            title: "Blocked task".into(),
            description: None,
            priority: None,
            created_by: None,
            deps: Some(vec![dep.id.clone()]),
        }).unwrap();

        // Should fail — dep not completed
        let err = mgr.task_assign(TaskAssignParams {
            task_id: task.id.clone(),
            agent_id: "a1".into(),
        });
        assert!(err.is_err());
        assert!(err.unwrap_err().contains("not yet completed"));

        // Complete the dep: pending -> assigned -> in_progress -> completed
        mgr.task_assign(TaskAssignParams {
            task_id: dep.id.clone(),
            agent_id: "a1".into(),
        }).unwrap();
        mgr.task_update(TaskUpdateParams {
            id: dep.id.clone(),
            title: None,
            description: None,
            status: Some("in_progress".into()),
            priority: None,
            assignee: None,
        }).unwrap();
        mgr.task_update(TaskUpdateParams {
            id: dep.id.clone(),
            title: None,
            description: None,
            status: Some("completed".into()),
            priority: None,
            assignee: None,
        }).unwrap();

        // Now assign should succeed
        let assigned = mgr.task_assign(TaskAssignParams {
            task_id: task.id.clone(),
            agent_id: "a1".into(),
        }).unwrap();
        assert_eq!(assigned.status, TaskStatus::Assigned);
    }

    #[test]
    fn task_log_records_changes() {
        let (_dir, mgr) = test_manager();

        let task = mgr.task_create(TaskCreateParams {
            title: "Log test".into(),
            description: None,
            priority: None,
            created_by: None,
            deps: None,
        }).unwrap();

        mgr.task_update(TaskUpdateParams {
            id: task.id.clone(),
            title: Some("Updated title".into()),
            description: None,
            status: None,
            priority: None,
            assignee: None,
        }).unwrap();

        let log = mgr.task_log(&task.id, None);
        assert!(log.len() >= 2); // create + update
        // Most recent first
        assert!(log[0].message.contains("updated"));
        assert!(log[1].message.contains("created"));
    }

    #[test]
    fn message_send_and_list() {
        let (_dir, mgr) = test_manager();
        insert_fake_agent(&mgr, "a1");
        insert_fake_agent(&mgr, "a2");

        let msg = mgr.message_send(MessageSendParams {
            from_agent: Some("a1".into()),
            to_agent: "a2".into(),
            content: "hello".into(),
        }).unwrap();

        assert_eq!(msg.to_agent, "a2");
        assert!(!msg.read);

        let inbox = mgr.message_list(MessageListParams {
            agent_id: "a2".into(),
            unread_only: Some(true),
            limit: None,
        });
        assert_eq!(inbox.len(), 1);
        assert_eq!(inbox[0].content, "hello");

        // a1 inbox should be empty
        let a1_inbox = mgr.message_list(MessageListParams {
            agent_id: "a1".into(),
            unread_only: None,
            limit: None,
        });
        assert!(a1_inbox.is_empty());
    }

    #[test]
    fn message_ack() {
        let (_dir, mgr) = test_manager();
        insert_fake_agent(&mgr, "a1");
        insert_fake_agent(&mgr, "a2");

        let m1 = mgr.message_send(MessageSendParams {
            from_agent: Some("a1".into()),
            to_agent: "a2".into(),
            content: "msg1".into(),
        }).unwrap();
        let m2 = mgr.message_send(MessageSendParams {
            from_agent: Some("a1".into()),
            to_agent: "a2".into(),
            content: "msg2".into(),
        }).unwrap();

        let count = mgr.message_ack(&[m1.id, m2.id]).unwrap();
        assert_eq!(count, 2);

        // Unread should be empty now
        let unread = mgr.message_list(MessageListParams {
            agent_id: "a2".into(),
            unread_only: Some(true),
            limit: None,
        });
        assert!(unread.is_empty());

        // But all messages still visible
        let all = mgr.message_list(MessageListParams {
            agent_id: "a2".into(),
            unread_only: Some(false),
            limit: None,
        });
        assert_eq!(all.len(), 2);
        assert!(all.iter().all(|m| m.read));
    }
}
