use crate::event_log::{EventLog, LocalJournalEventLog, MemMeshUnavailableEventLog};
use crate::model::{AttemptId, FencingToken, IntentEvent, ProjectId, TaskId, TaskStatus};
use crate::reducer::Reducer;
use anyhow::{bail, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast;

#[derive(Debug, Clone)]
pub struct Config {
    pub enabled: bool,
    pub socket_path: PathBuf,
    pub reducer_path: PathBuf,
    pub journal_path: Option<PathBuf>,
    pub use_local_journal: bool,
}

impl Config {
    pub fn from_env() -> Self {
        let enabled = std::env::var("TERMMESH_COORDINATOR_ENABLED")
            .ok()
            .as_deref()
            == Some("1")
            || std::env::var("TERMMESH_DISTRIBUTED_WORKSPACES_V1")
                .ok()
                .as_deref()
                == Some("1");
        let tmp = std::env::temp_dir();
        let socket_path = std::env::var_os("TERMMESH_COORDINATOR_UNIX_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|| tmp.join("tm-coordinator.sock"));
        let base = dirs::data_dir()
            .unwrap_or_else(|| tmp.clone())
            .join("term-mesh")
            .join("coordinator");
        let reducer_path = std::env::var_os("TERMMESH_COORDINATOR_REDUCER_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|| base.join("reducer.sqlite"));
        let journal_path = std::env::var_os("TERMMESH_COORDINATOR_LOCAL_JOURNAL_PATH")
            .map(PathBuf::from)
            .or_else(|| Some(base.join("local-journal.ndjson")));
        let use_local_journal = std::env::var("TERMMESH_COORDINATOR_LOCAL_JOURNAL")
            .ok()
            .as_deref()
            == Some("1");
        Self {
            enabled,
            socket_path,
            reducer_path,
            journal_path,
            use_local_journal,
        }
    }
}

pub struct Api {
    config: Config,
    reducer: Mutex<Reducer>,
    event_log: Arc<dyn EventLog>,
    event_tx: broadcast::Sender<IntentEvent>,
}

impl Api {
    pub fn open(config: Config) -> Result<Arc<Self>> {
        let event_log: Arc<dyn EventLog> = if config.use_local_journal {
            Arc::new(LocalJournalEventLog::new(
                config.journal_path.clone().expect("journal path"),
            ))
        } else {
            Arc::new(MemMeshUnavailableEventLog)
        };
        Self::open_with_event_log(config, event_log)
    }

    pub fn open_with_event_log(config: Config, event_log: Arc<dyn EventLog>) -> Result<Arc<Self>> {
        let reducer = if std::env::var("TERMMESH_COORDINATOR_REDUCER_RESET")
            .ok()
            .as_deref()
            == Some("1")
        {
            let _ = std::fs::remove_file(&config.reducer_path);
            Reducer::open(&config.reducer_path)?
        } else {
            Reducer::open(&config.reducer_path)?
        };
        for event in event_log.read_all()? {
            reducer.apply(&event)?;
        }
        let (event_tx, _) = broadcast::channel(256);
        Ok(Arc::new(Self {
            config,
            reducer: Mutex::new(reducer),
            event_log,
            event_tx,
        }))
    }

    pub fn for_tests(event_log: Arc<dyn EventLog>) -> Result<Arc<Self>> {
        let (event_tx, _) = broadcast::channel(256);
        Ok(Arc::new(Self {
            config: Config {
                enabled: true,
                socket_path: PathBuf::from("/tmp/tm-coordinator-test.sock"),
                reducer_path: PathBuf::from(":memory:"),
                journal_path: None,
                use_local_journal: true,
            },
            reducer: Mutex::new(Reducer::in_memory()?),
            event_log,
            event_tx,
        }))
    }

    pub fn subscribe(&self) -> broadcast::Receiver<IntentEvent> {
        self.event_tx.subscribe()
    }

    pub fn handle(&self, method: &str, params: Value) -> Result<Value> {
        match method {
            "orchestration.status" => self.status(),
            "project.list" => self.project_list(),
            "project.add" => self.project_add(params),
            "task.list" => self.task_list(params),
            "task.get" => self.task_get(params),
            "task.create" => self.task_create(params),
            "attempt.list" => self.attempt_list(params),
            "fence" => self.fence(params),
            _ => bail!("METHOD_NOT_FOUND: {method}"),
        }
    }

    fn status(&self) -> Result<Value> {
        let reducer = self.reducer.lock().expect("reducer mutex poisoned");
        Ok(json!({
            "version": env!("CARGO_PKG_VERSION"),
            "socket_path": self.config.socket_path,
            "reducer_watermark": reducer.watermark()?,
            "mem_mesh": self.event_log.health(),
            "known_host_count": 0,
            "pending_merge_count": 0,
            "feature_flags": {
                "enabled": self.config.enabled,
                "remote_hosts": false,
                "app_socket_adapter": false,
                "daemon_adapter": false
            },
            "focus_adapter_calls": 0
        }))
    }

    fn project_list(&self) -> Result<Value> {
        let reducer = self.reducer.lock().expect("reducer mutex poisoned");
        Ok(json!({ "projects": reducer.projects()? }))
    }

    fn project_add(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            request_id: String,
            root_path: String,
            name: Option<String>,
        }
        let p: Params = serde_json::from_value(params)?;
        if !Path::new(&p.root_path).is_absolute() {
            bail!("INVALID_PARAMS: root_path must be absolute");
        }
        self.mutate(
            &p.request_id,
            "project_added",
            Some(ProjectId::new_random()),
            json!({
                "root_path": p.root_path,
                "name": p.name
            }),
        )
    }

    fn task_list(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            project_id: Option<ProjectId>,
            status: Option<TaskStatus>,
            limit: Option<i64>,
        }
        let p: Params = serde_json::from_value(params)?;
        let reducer = self.reducer.lock().expect("reducer mutex poisoned");
        Ok(
            json!({ "tasks": reducer.tasks(p.project_id.as_ref(), p.status, p.limit.unwrap_or(100))? }),
        )
    }

    fn task_get(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            task_id: TaskId,
        }
        let p: Params = serde_json::from_value(params)?;
        let reducer = self.reducer.lock().expect("reducer mutex poisoned");
        let task = reducer.task(&p.task_id)?;
        let attempts = reducer.attempts(&p.task_id)?;
        Ok(
            json!({ "task": task, "attempts": attempts, "latest_review_snapshot": null, "merge_queue": null }),
        )
    }

    fn task_create(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            request_id: String,
            project_id: ProjectId,
            title: String,
            body: String,
            priority: Option<i64>,
            depends_on: Option<Vec<TaskId>>,
        }
        let p: Params = serde_json::from_value(params)?;
        let task_id = TaskId::new_random();
        self.mutate(
            &p.request_id,
            "task_created",
            Some(p.project_id),
            json!({
                "task_id": task_id,
                "title": p.title,
                "body": p.body,
                "priority": p.priority.unwrap_or(0),
                "depends_on": p.depends_on.unwrap_or_default(),
                "created_by": "leader"
            }),
        )
    }

    fn attempt_list(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            task_id: TaskId,
        }
        let p: Params = serde_json::from_value(params)?;
        let reducer = self.reducer.lock().expect("reducer mutex poisoned");
        Ok(json!({ "attempts": reducer.attempts(&p.task_id)? }))
    }

    fn fence(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            request_id: String,
            task_id: TaskId,
            attempt_id: Option<AttemptId>,
            holder: String,
            ttl_ms: Option<u64>,
        }
        let p: Params = serde_json::from_value(params)?;
        let expires_at_ms = p
            .ttl_ms
            .map(|ttl| crate::model::now_ms().saturating_add(ttl));
        self.mutate(
            &p.request_id,
            "fence_issued",
            None,
            json!({
                "task_id": p.task_id,
                "attempt_id": p.attempt_id,
                "holder": p.holder,
                "token": FencingToken::new_random(),
                "expires_at_ms": expires_at_ms
            }),
        )
    }

    fn mutate(
        &self,
        request_id: &str,
        kind: &str,
        project_id: Option<ProjectId>,
        payload: Value,
    ) -> Result<Value> {
        if request_id.trim().is_empty() {
            bail!("INVALID_PARAMS: request_id is required");
        }
        let (result, event_to_publish) = {
            let reducer = self.reducer.lock().expect("reducer mutex poisoned");
            if let Some(existing) = reducer.event_by_request_id(request_id)? {
                return Ok(json!({ "accepted": true, "idempotent": true, "event": existing }));
            }
            let event = IntentEvent::new(kind, Some(request_id.to_string()), project_id, payload);
            self.event_log.append(&event)?;
            reducer.apply(&event)?;
            (
                json!({ "accepted": true, "idempotent": false, "event": event }),
                event,
            )
        };
        let _ = self.event_tx.send(event_to_publish);
        Ok(result)
    }

    pub fn is_current_fence(
        &self,
        task_id: &str,
        attempt_id: Option<&str>,
        token: &str,
    ) -> Result<bool> {
        let task_id = TaskId::from_str(task_id).map_err(|e| anyhow::anyhow!(e))?;
        let attempt_id = attempt_id
            .map(AttemptId::from_str)
            .transpose()
            .map_err(|e| anyhow::anyhow!(e))?;
        let token = FencingToken::from_str(token).map_err(|e| anyhow::anyhow!(e))?;
        let reducer = self.reducer.lock().expect("reducer mutex poisoned");
        reducer.is_current_fence(&task_id, attempt_id.as_ref(), &token)
    }
}
