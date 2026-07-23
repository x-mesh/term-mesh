use crate::event_log::{EventLog, LocalJournalEventLog, MemMeshUnavailableEventLog};
use crate::model::{
    now_ms, Attempt, AttemptId, FencingToken, HostId, HostObservation, IntentEvent, MergeQueueId,
    MergeQueueItem, MergeQueueStatus, PaneRef, Placement, ProjectId, ReviewFileSummary,
    ReviewSnapshot, ReviewSnapshotId, TaskId, TaskStatus,
};
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
            "host.list" => self.host_list(),
            "host.observe" => self.host_observe(params),
            "task.list" => self.task_list(params),
            "task.get" => self.task_get(params),
            "task.create" => self.task_create(params),
            "task.place" => self.task_place(params),
            "task.reassign" => self.task_reassign(params),
            "task.suspect" => self.task_suspect(params),
            "task.quarantine" => self.task_quarantine(params),
            "attempt.list" => self.attempt_list(params),
            "fence" => self.fence(params),
            "review.snapshot" => self.review_snapshot(params),
            "approve" => self.approve(params),
            "reject" => self.reject(params),
            "merge.queue" => self.merge_queue(params),
            "merge.queue.transition" => self.merge_queue_transition(params),
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
            "known_host_count": reducer.hosts()?.len(),
            "pending_merge_count": reducer.merge_queue(None, Some(MergeQueueStatus::Queued))?.len(),
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

    fn host_list(&self) -> Result<Value> {
        let reducer = self.reducer.lock().expect("reducer mutex poisoned");
        Ok(json!({ "hosts": reducer.hosts()? }))
    }

    fn host_observe(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            request_id: String,
            host_id: Option<HostId>,
            os: String,
            arch: String,
            load: f64,
            total_slots: u32,
            used_slots: u32,
            project_roots: Vec<String>,
            #[serde(default)]
            leader_projects: Vec<String>,
            live: Option<bool>,
            quarantined: Option<bool>,
            observed_at_ms: Option<u64>,
        }
        let p: Params = serde_json::from_value(params)?;
        if p.used_slots > p.total_slots {
            bail!("INVALID_PARAMS: used_slots exceeds total_slots");
        }
        // A leader has to sit in a project this host actually hosts —
        // otherwise the table would claim a machine leads work it does not
        // even have a checkout of.
        if let Some(stray) = p
            .leader_projects
            .iter()
            .find(|root| !p.project_roots.contains(root))
        {
            bail!("INVALID_PARAMS: leader project {stray} is not among project_roots");
        }
        let observation = HostObservation {
            host_id: p.host_id.unwrap_or_else(HostId::new_random),
            os: p.os,
            arch: p.arch,
            load: p.load,
            total_slots: p.total_slots,
            used_slots: p.used_slots,
            project_roots: p.project_roots,
            leader_projects: p.leader_projects,
            live: p.live.unwrap_or(true),
            quarantined: p.quarantined.unwrap_or(false),
            observed_at_ms: p.observed_at_ms.unwrap_or_else(now_ms),
        };
        self.mutate(
            &p.request_id,
            "host_observed",
            None,
            serde_json::to_value(observation)?,
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
        let latest_review_snapshot = reducer.latest_review_snapshot(&p.task_id)?;
        let merge_queue = match &task {
            Some(task) => reducer.merge_queue(Some(&task.project_id), None)?,
            None => Vec::new(),
        }
        .into_iter()
        .filter(|item| item.task_id == p.task_id)
        .collect::<Vec<_>>();
        Ok(
            json!({ "task": task, "attempts": attempts, "latest_review_snapshot": latest_review_snapshot, "merge_queue": merge_queue }),
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

    fn task_place(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            request_id: String,
            task_id: TaskId,
            host_id: Option<HostId>,
            mode: Option<String>,
            agent_name: Option<String>,
            ttl_ms: Option<u64>,
        }
        let p: Params = serde_json::from_value(params)?;
        let request_id = p.request_id.clone();
        self.mutate_checked(&request_id, "task_placed", None, |reducer| {
            let task = reducer
                .task(&p.task_id)?
                .ok_or_else(|| anyhow::anyhow!("task not found"))?;
            if !task.status.can_transition_to(&TaskStatus::Placed) {
                bail!("invalid task transition {:?} -> placed", task.status);
            }
            let host = reducer.choose_host(&task.project_id, p.host_id.as_ref())?;
            let attempt_id = AttemptId::new_random();
            let token = FencingToken::new_random();
            let pane_ref = p.agent_name.as_ref().map(|agent_name| PaneRef {
                host_id: host.host_id.clone(),
                app_socket_path: None,
                workspace_id: None,
                panel_id: None,
                agent_name: Some(agent_name.clone()),
            });
            let placement = Placement {
                host_id: host.host_id.clone(),
                pane_ref: pane_ref.clone(),
                mode: p.mode.clone().unwrap_or_else(|| "headless".to_string()),
            };
            let attempt = Attempt {
                attempt_id: attempt_id.clone(),
                task_id: task.task_id.clone(),
                project_id: task.project_id.clone(),
                status: "created".to_string(),
                host_id: host.host_id,
                pane_ref,
                worktree_path: None,
                base_ref: None,
                head_ref: None,
                head_sha: None,
                fencing_token: Some(token.clone()),
                created_at_ms: now_ms(),
                updated_at_ms: now_ms(),
            };
            Ok(json!({
                "task_id": task.task_id,
                "attempt_id": attempt_id,
                "attempt": attempt,
                "placement": placement,
                "holder": "coordinator",
                "token": token,
                "expires_at_ms": p.ttl_ms.map(|ttl| now_ms().saturating_add(ttl))
            }))
        })
    }

    fn task_reassign(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            request_id: String,
            task_id: TaskId,
            host_id: Option<HostId>,
            mode: Option<String>,
            agent_name: Option<String>,
            reason: Option<String>,
            ttl_ms: Option<u64>,
        }
        let p: Params = serde_json::from_value(params)?;
        let request_id = p.request_id.clone();
        self.mutate_checked(&request_id, "task_reassigned", None, |reducer| {
            let task = reducer
                .task(&p.task_id)?
                .ok_or_else(|| anyhow::anyhow!("task not found"))?;
            if !task.status.can_transition_to(&TaskStatus::Reassigned) {
                bail!("invalid task transition {:?} -> reassigned", task.status);
            }
            let host = reducer.choose_host(&task.project_id, p.host_id.as_ref())?;
            let attempt_id = AttemptId::new_random();
            let token = FencingToken::new_random();
            let pane_ref = p.agent_name.as_ref().map(|agent_name| PaneRef {
                host_id: host.host_id.clone(),
                app_socket_path: None,
                workspace_id: None,
                panel_id: None,
                agent_name: Some(agent_name.clone()),
            });
            let placement = Placement {
                host_id: host.host_id.clone(),
                pane_ref: pane_ref.clone(),
                mode: p.mode.clone().unwrap_or_else(|| "headless".to_string()),
            };
            let attempt = Attempt {
                attempt_id: attempt_id.clone(),
                task_id: task.task_id.clone(),
                project_id: task.project_id.clone(),
                status: "created".to_string(),
                host_id: host.host_id,
                pane_ref,
                worktree_path: None,
                base_ref: None,
                head_ref: None,
                head_sha: None,
                fencing_token: Some(token.clone()),
                created_at_ms: now_ms(),
                updated_at_ms: now_ms(),
            };
            Ok(json!({
                "task_id": task.task_id,
                "attempt_id": attempt_id,
                "attempt": attempt,
                "placement": placement,
                "holder": "coordinator",
                "token": token,
                "reason": p.reason,
                "expires_at_ms": p.ttl_ms.map(|ttl| now_ms().saturating_add(ttl))
            }))
        })
    }

    fn task_suspect(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            request_id: String,
            task_id: TaskId,
            reason: Option<String>,
        }
        let p: Params = serde_json::from_value(params)?;
        let request_id = p.request_id.clone();
        self.mutate_checked(&request_id, "task_suspected", None, |reducer| {
            let task = reducer
                .task(&p.task_id)?
                .ok_or_else(|| anyhow::anyhow!("task not found"))?;
            if !task.status.can_transition_to(&TaskStatus::Suspect) {
                bail!("invalid task transition {:?} -> suspect", task.status);
            }
            Ok(json!({"task_id": p.task_id, "reason": p.reason}))
        })
    }

    fn task_quarantine(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            request_id: String,
            task_id: TaskId,
            reason: Option<String>,
        }
        let p: Params = serde_json::from_value(params)?;
        let request_id = p.request_id.clone();
        self.mutate_checked(&request_id, "task_quarantined", None, |reducer| {
            let task = reducer
                .task(&p.task_id)?
                .ok_or_else(|| anyhow::anyhow!("task not found"))?;
            if !task.status.can_transition_to(&TaskStatus::Quarantined) {
                bail!("invalid task transition {:?} -> quarantined", task.status);
            }
            Ok(json!({"task_id": p.task_id, "reason": p.reason}))
        })
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

    fn review_snapshot(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            request_id: String,
            task_id: TaskId,
            attempt_id: AttemptId,
            fencing_token: FencingToken,
            base_sha: String,
            head_sha: String,
            diff_digest: String,
            summary: Option<String>,
            files: Option<Vec<ReviewFileSummary>>,
        }
        let p: Params = serde_json::from_value(params)?;
        let request_id = p.request_id.clone();
        self.mutate_checked(
            &request_id,
            "review_snapshot_recorded",
            project_for_task(&p.task_id, self)?,
            |reducer| {
                require_current_attempt_and_fence(
                    reducer,
                    &p.task_id,
                    &p.attempt_id,
                    &p.fencing_token,
                )?;
                validate_sha_digest(&p.base_sha, &p.head_sha, &p.diff_digest)?;
                let snapshot = ReviewSnapshot {
                    snapshot_id: ReviewSnapshotId::new_random(),
                    task_id: p.task_id.clone(),
                    attempt_id: p.attempt_id.clone(),
                    base_sha: p.base_sha.clone(),
                    head_sha: p.head_sha.clone(),
                    diff_digest: p.diff_digest.clone(),
                    summary: p.summary.clone().unwrap_or_default(),
                    files: p.files.clone().unwrap_or_default(),
                    created_at_ms: now_ms(),
                };
                Ok(serde_json::to_value(snapshot)?)
            },
        )
    }

    fn approve(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            request_id: String,
            task_id: TaskId,
            attempt_id: AttemptId,
            fencing_token: FencingToken,
            reviewer: String,
            snapshot_id: ReviewSnapshotId,
            head_sha: String,
            diff_digest: String,
        }
        let p: Params = serde_json::from_value(params)?;
        let request_id = p.request_id.clone();
        self.mutate_checked(&request_id, "attempt_approved", None, |reducer| {
            require_current_attempt_and_fence(
                reducer,
                &p.task_id,
                &p.attempt_id,
                &p.fencing_token,
            )?;
            let snapshot = reducer
                .review_snapshot(p.snapshot_id.as_str())?
                .ok_or_else(|| anyhow::anyhow!("review snapshot not found"))?;
            if snapshot.task_id != p.task_id
                || snapshot.attempt_id != p.attempt_id
                || snapshot.head_sha != p.head_sha
                || snapshot.diff_digest != p.diff_digest
            {
                bail!("snapshot evidence mismatch");
            }
            let task = reducer
                .task(&p.task_id)?
                .ok_or_else(|| anyhow::anyhow!("task not found"))?;
            let item = MergeQueueItem {
                queue_id: MergeQueueId::new_random(),
                project_id: task.project_id,
                task_id: p.task_id.clone(),
                attempt_id: p.attempt_id.clone(),
                status: MergeQueueStatus::Queued,
                approved_by: p.reviewer.clone(),
                approved_at_ms: now_ms(),
                last_error: None,
            };
            Ok(json!({
                "task_id": p.task_id,
                "attempt_id": p.attempt_id,
                "snapshot_id": p.snapshot_id,
                "reviewer": p.reviewer,
                "merge_queue_item": item
            }))
        })
    }

    fn reject(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            request_id: String,
            task_id: TaskId,
            attempt_id: AttemptId,
            fencing_token: FencingToken,
            reviewer: String,
            reason: String,
        }
        let p: Params = serde_json::from_value(params)?;
        let request_id = p.request_id.clone();
        self.mutate_checked(&request_id, "attempt_rejected", None, |reducer| {
            require_current_attempt_and_fence(
                reducer,
                &p.task_id,
                &p.attempt_id,
                &p.fencing_token,
            )?;
            Ok(json!({
                "task_id": p.task_id,
                "attempt_id": p.attempt_id,
                "reviewer": p.reviewer,
                "reason": p.reason
            }))
        })
    }

    fn merge_queue(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            project_id: Option<ProjectId>,
            status: Option<MergeQueueStatus>,
        }
        let p: Params = serde_json::from_value(params)?;
        let reducer = self.reducer.lock().expect("reducer mutex poisoned");
        Ok(json!({ "items": reducer.merge_queue(p.project_id.as_ref(), p.status)? }))
    }

    fn merge_queue_transition(&self, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Params {
            request_id: String,
            queue_id: MergeQueueId,
            status: MergeQueueStatus,
            last_error: Option<String>,
        }
        let p: Params = serde_json::from_value(params)?;
        let request_id = p.request_id.clone();
        self.mutate_checked(&request_id, "merge_queue_transitioned", None, |reducer| {
            let item = reducer
                .merge_queue_item(&p.queue_id)?
                .ok_or_else(|| anyhow::anyhow!("merge queue item not found"))?;
            if !item.status.can_transition_to(&p.status) {
                bail!(
                    "invalid merge queue transition {:?} -> {:?}",
                    item.status,
                    p.status
                );
            }
            Ok(json!({"queue_id": p.queue_id, "status": p.status, "last_error": p.last_error}))
        })
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

    fn mutate_checked<F>(
        &self,
        request_id: &str,
        kind: &str,
        project_id: Option<ProjectId>,
        build_payload: F,
    ) -> Result<Value>
    where
        F: FnOnce(&Reducer) -> Result<Value>,
    {
        if request_id.trim().is_empty() {
            bail!("INVALID_PARAMS: request_id is required");
        }
        let (result, event_to_publish) = {
            let reducer = self.reducer.lock().expect("reducer mutex poisoned");
            if let Some(existing) = reducer.event_by_request_id(request_id)? {
                return Ok(json!({ "accepted": true, "idempotent": true, "event": existing }));
            }
            let payload = build_payload(&reducer)?;
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

fn require_current_attempt_and_fence(
    reducer: &Reducer,
    task_id: &TaskId,
    attempt_id: &AttemptId,
    token: &FencingToken,
) -> Result<()> {
    let task = reducer
        .task(task_id)?
        .ok_or_else(|| anyhow::anyhow!("task not found"))?;
    if task.current_attempt_id.as_ref() != Some(attempt_id) {
        bail!("stale_attempt_reported");
    }
    if !reducer.is_current_fence(task_id, Some(attempt_id), token)? {
        bail!("stale_fencing_token");
    }
    Ok(())
}

fn validate_sha_digest(base_sha: &str, head_sha: &str, diff_digest: &str) -> Result<()> {
    if base_sha.trim().is_empty() || head_sha.trim().is_empty() {
        bail!("INVALID_PARAMS: base_sha and head_sha are required");
    }
    if !diff_digest.starts_with("sha256:") || diff_digest.len() <= "sha256:".len() {
        bail!("INVALID_PARAMS: diff_digest must start with sha256:");
    }
    Ok(())
}

fn project_for_task(task_id: &TaskId, api: &Api) -> Result<Option<ProjectId>> {
    let reducer = api.reducer.lock().expect("reducer mutex poisoned");
    Ok(reducer.task(task_id)?.map(|task| task.project_id))
}
