use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{bail, Result};
use serde_json::json;
use tempfile::tempdir;
use tm_coordinator::event_log::LocalJournalEventLog;
use tm_coordinator::model::{FencingToken, HostId, IntentEvent, ProjectId, TaskId};
use tm_coordinator::{Api, Config, EventLog, Reducer};

struct FailingReadLog;

impl EventLog for FailingReadLog {
    fn append(&self, _event: &IntentEvent) -> Result<()> {
        Ok(())
    }

    fn read_all(&self) -> Result<Vec<IntentEvent>> {
        bail!("read_all failed")
    }

    fn health(&self) -> serde_json::Value {
        json!({"status": "test"})
    }

    fn is_available(&self) -> bool {
        true
    }
}

struct SlowCountingLog {
    events: Mutex<Vec<IntentEvent>>,
}

impl EventLog for SlowCountingLog {
    fn append(&self, event: &IntentEvent) -> Result<()> {
        std::thread::sleep(Duration::from_millis(50));
        self.events.lock().unwrap().push(event.clone());
        Ok(())
    }

    fn read_all(&self) -> Result<Vec<IntentEvent>> {
        Ok(self.events.lock().unwrap().clone())
    }

    fn health(&self) -> serde_json::Value {
        json!({"status": "test"})
    }

    fn is_available(&self) -> bool {
        true
    }
}

#[test]
fn replay_rebuilds_projects_and_tasks_from_local_journal() {
    let dir = tempdir().unwrap();
    let log = LocalJournalEventLog::new(dir.path().join("events.ndjson"));
    let project_id = ProjectId::new_random();
    let task_id = TaskId::new_random();
    let project_event = IntentEvent::new(
        "project_added",
        Some("req-project".to_string()),
        Some(project_id.clone()),
        json!({"root_path": "/tmp/repo", "name": "repo"}),
    );
    let task_event = IntentEvent::new(
        "task_created",
        Some("req-task".to_string()),
        Some(project_id.clone()),
        json!({"task_id": task_id, "title": "slice", "body": "body", "priority": 2, "depends_on": []}),
    );
    log.append(&project_event).unwrap();
    log.append(&task_event).unwrap();

    let events = log.read_all().unwrap();
    let reducer = Reducer::replay(&events).unwrap();

    assert_eq!(reducer.projects().unwrap().len(), 1);
    assert_eq!(reducer.tasks(Some(&project_id), None, 10).unwrap().len(), 1);
    assert_eq!(reducer.watermark().unwrap(), 2);
}

#[test]
fn duplicate_request_id_returns_original_event_without_second_append() {
    let dir = tempdir().unwrap();
    let log: Arc<dyn EventLog> =
        Arc::new(LocalJournalEventLog::new(dir.path().join("events.ndjson")));
    let api = Api::for_tests(log.clone()).unwrap();

    let first = api
        .handle(
            "project.add",
            json!({"request_id": "same", "root_path": "/tmp/repo", "name": "repo"}),
        )
        .unwrap();
    let second = api
        .handle(
            "project.add",
            json!({"request_id": "same", "root_path": "/tmp/other", "name": "other"}),
        )
        .unwrap();

    assert_eq!(first["event"]["event_id"], second["event"]["event_id"]);
    assert_eq!(second["idempotent"], true);
    assert_eq!(log.read_all().unwrap().len(), 1);
}

#[test]
fn concurrent_duplicate_request_id_serializes_append_and_reduce() {
    let log = Arc::new(SlowCountingLog {
        events: Mutex::new(Vec::new()),
    });
    let api = Api::for_tests(log.clone()).unwrap();
    let first_api = api.clone();
    let second_api = api.clone();

    let first = std::thread::spawn(move || {
        first_api
            .handle(
                "project.add",
                json!({"request_id": "same-race", "root_path": "/tmp/repo", "name": "repo"}),
            )
            .unwrap()
    });
    let second = std::thread::spawn(move || {
        second_api
            .handle(
                "project.add",
                json!({"request_id": "same-race", "root_path": "/tmp/other", "name": "other"}),
            )
            .unwrap()
    });

    let first = first.join().unwrap();
    let second = second.join().unwrap();

    assert_eq!(first["event"]["event_id"], second["event"]["event_id"]);
    assert_eq!(log.read_all().unwrap().len(), 1);
}

/// An unreadable log used to abort the open, which killed the process and
/// left a client staring at a missing socket — reported as "Coordinator
/// Offline", the one diagnosis that hides the actual cause. It now starts
/// degraded so the cause can be read off `orchestration.status`.
#[test]
fn api_open_survives_an_unreadable_event_log_and_says_why() {
    let dir = tempdir().unwrap();
    let config = Config {
        enabled: true,
        socket_path: dir.path().join("coord.sock"),
        reducer_path: dir.path().join("reducer.sqlite"),
        journal_path: None,
        use_local_journal: true,
    };

    let api = Api::open_with_event_log(config, Arc::new(FailingReadLog))
        .expect("an unreadable log must not stop the coordinator from serving");

    let status = api.handle("orchestration.status", json!({})).unwrap();
    assert_eq!(status["mem_mesh_available"], false);
    assert!(
        status["mem_mesh"]["degraded_reason"]
            .as_str()
            .unwrap_or_default()
            .contains("read_all failed"),
        "the reason has to reach the client: {status}"
    );

    // Reads answer; writes are refused under one name rather than whatever
    // the backend happened to say at its own failure point.
    assert!(api.handle("task.list", json!({})).is_ok());
    assert!(api.handle("host.list", json!({})).is_ok());
    let refused = api
        .handle(
            "project.add",
            json!({"request_id": "p1", "root_path": "/tmp/repo", "name": "repo"}),
        )
        .unwrap_err()
        .to_string();
    assert!(refused.contains("EVENT_LOG_UNAVAILABLE"), "{refused}");
}

/// The reducer is persisted, so a degraded start must not answer from the
/// state a previous healthy run left on disk — that is data this process
/// cannot justify from the log it just failed to read. The file itself has to
/// survive, though, so a later healthy start still recovers it.
#[test]
fn a_degraded_start_serves_nothing_it_cannot_justify_and_keeps_the_file() {
    let dir = tempdir().unwrap();
    let reducer_path = dir.path().join("reducer.sqlite");
    let journal_path = dir.path().join("events.ndjson");
    let config = |use_local: bool| Config {
        enabled: true,
        socket_path: dir.path().join("coord.sock"),
        reducer_path: reducer_path.clone(),
        journal_path: Some(journal_path.clone()),
        use_local_journal: use_local,
    };

    // A healthy run that records one project.
    let healthy = Api::open_with_event_log(
        config(true),
        Arc::new(LocalJournalEventLog::new(journal_path.clone())),
    )
    .unwrap();
    healthy
        .handle(
            "project.add",
            json!({"request_id": "p1", "root_path": "/tmp/repo", "name": "repo"}),
        )
        .unwrap();
    assert_eq!(
        healthy.handle("project.list", json!({})).unwrap()["projects"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    drop(healthy);

    let degraded = Api::open_with_event_log(config(true), Arc::new(FailingReadLog)).unwrap();
    assert!(
        degraded.handle("project.list", json!({})).unwrap()["projects"]
            .as_array()
            .unwrap()
            .is_empty(),
        "a degraded start must not serve the previous run's projection"
    );

    // Recovery: the same on-disk state is back once the log can be read.
    drop(degraded);
    let recovered = Api::open_with_event_log(
        config(true),
        Arc::new(LocalJournalEventLog::new(journal_path.clone())),
    )
    .unwrap();
    assert_eq!(
        recovered.handle("project.list", json!({})).unwrap()["projects"]
            .as_array()
            .unwrap()
            .len(),
        1,
        "the degraded run must not have destroyed the projection"
    );
}

#[test]
fn invalid_task_state_transition_is_rejected_during_replay() {
    let project_id = ProjectId::new_random();
    let task_id = TaskId::new_random();
    let reducer = Reducer::in_memory().unwrap();
    reducer
        .apply(&IntentEvent::new(
            "task_created",
            Some("req-task".to_string()),
            Some(project_id),
            json!({"task_id": task_id, "title": "slice", "body": "", "depends_on": []}),
        ))
        .unwrap();

    let result = reducer.apply(&IntentEvent::new(
        "task_status_changed",
        Some("bad-transition".to_string()),
        None,
        json!({"task_id": task_id, "status": "merged"}),
    ));

    assert!(result
        .unwrap_err()
        .to_string()
        .contains("invalid task transition"));
}

#[test]
fn newer_fence_invalidates_stale_token() {
    let dir = tempdir().unwrap();
    let log: Arc<dyn EventLog> =
        Arc::new(LocalJournalEventLog::new(dir.path().join("events.ndjson")));
    let api = Api::for_tests(log).unwrap();
    let task_id = TaskId::new_random();

    let first = api
        .handle(
            "fence",
            json!({"request_id": "f1", "task_id": task_id, "holder": "executor"}),
        )
        .unwrap();
    let first_token: FencingToken =
        serde_json::from_value(first["event"]["payload"]["token"].clone()).unwrap();

    let second = api
        .handle(
            "fence",
            json!({"request_id": "f2", "task_id": task_id, "holder": "reviewer"}),
        )
        .unwrap();
    let second_token: FencingToken =
        serde_json::from_value(second["event"]["payload"]["token"].clone()).unwrap();

    assert!(!api
        .is_current_fence(task_id.as_str(), None, first_token.as_str())
        .unwrap());
    assert!(api
        .is_current_fence(task_id.as_str(), None, second_token.as_str())
        .unwrap());
}

#[test]
fn expired_fence_token_is_not_current() {
    let dir = tempdir().unwrap();
    let log: Arc<dyn EventLog> =
        Arc::new(LocalJournalEventLog::new(dir.path().join("events.ndjson")));
    let api = Api::for_tests(log).unwrap();
    let task_id = TaskId::new_random();

    let issued = api
        .handle(
            "fence",
            json!({"request_id": "expired", "task_id": task_id, "holder": "executor", "ttl_ms": 0}),
        )
        .unwrap();
    let token: FencingToken =
        serde_json::from_value(issued["event"]["payload"]["token"].clone()).unwrap();

    assert!(!api
        .is_current_fence(task_id.as_str(), None, token.as_str())
        .unwrap());
}

fn api_with_project_task() -> (Arc<Api>, ProjectId, TaskId) {
    let dir = tempdir().unwrap();
    let log: Arc<dyn EventLog> =
        Arc::new(LocalJournalEventLog::new(dir.path().join("events.ndjson")));
    let api = Api::for_tests(log).unwrap();
    let project = api
        .handle(
            "project.add",
            json!({"request_id": "project", "root_path": "/tmp/repo", "name": "repo"}),
        )
        .unwrap();
    let project_id: ProjectId =
        serde_json::from_value(project["event"]["project_id"].clone()).unwrap();
    let task = api
        .handle(
            "task.create",
            json!({"request_id": "task", "project_id": project_id, "title": "slice", "body": ""}),
        )
        .unwrap();
    let task_id: TaskId =
        serde_json::from_value(task["event"]["payload"]["task_id"].clone()).unwrap();
    (api, project_id, task_id)
}

fn observe_host(
    api: &Api,
    request_id: &str,
    host: &str,
    load: f64,
    used_slots: u32,
    roots: Vec<&str>,
) -> HostId {
    let host_id = HostId::try_from(host.to_string()).unwrap();
    api.handle(
        "host.observe",
        json!({
            "request_id": request_id,
            "host_id": host_id,
            "os": "macos",
            "arch": "arm64",
            "load": load,
            "total_slots": 4,
            "used_slots": used_slots,
            "project_roots": roots,
            "live": true
        }),
    )
    .unwrap();
    host_id
}

/// Which machine holds a project's leader is the first question once a
/// project spans hosts, and no single machine can answer it alone.
#[test]
fn leader_projects_round_trip_and_must_be_hosted_projects() {
    let dir = tempdir().unwrap();
    let log: Arc<dyn EventLog> =
        Arc::new(LocalJournalEventLog::new(dir.path().join("events.ndjson")));
    let api = Api::for_tests(log).unwrap();

    api.handle(
        "host.observe",
        json!({
            "request_id": "obs-leader",
            "host_id": "hst_leader",
            "os": "macos", "arch": "arm64", "load": 0.0,
            "total_slots": 0, "used_slots": 0,
            "project_roots": ["/repo/alpha", "/repo/beta"],
            "leader_projects": ["/repo/beta"],
            "live": true
        }),
    )
    .unwrap();

    let hosts = api.handle("host.list", json!({})).unwrap();
    let row = &hosts["hosts"][0];
    assert_eq!(row["leader_projects"], json!(["/repo/beta"]));

    // A host cannot lead a project it does not even have.
    let stray = api.handle(
        "host.observe",
        json!({
            "request_id": "obs-stray",
            "host_id": "hst_leader",
            "os": "macos", "arch": "arm64", "load": 0.0,
            "total_slots": 0, "used_slots": 0,
            "project_roots": ["/repo/alpha"],
            "leader_projects": ["/repo/gamma"],
            "live": true
        }),
    );
    assert!(stray.is_err(), "stray leader project should be rejected");

    // Observations recorded before the field existed must still replay.
    let legacy = api.handle(
        "host.observe",
        json!({
            "request_id": "obs-legacy",
            "host_id": "hst_legacy",
            "os": "linux", "arch": "x86_64", "load": 0.0,
            "total_slots": 0, "used_slots": 0,
            "project_roots": ["/repo/alpha"],
            "live": true
        }),
    );
    assert!(legacy.is_ok(), "omitted leader_projects must default to empty");
}

#[test]
fn placement_policy_prefers_repo_local_capacity_then_load_and_supports_manual_override() {
    let (api, _project_id, task_id) = api_with_project_task();
    let h1 = observe_host(&api, "h1", "hst_aaaa", 0.1, 1, vec!["/tmp/repo"]);
    let h2 = observe_host(&api, "h2", "hst_bbbb", 0.9, 0, vec!["/tmp/repo"]);
    observe_host(&api, "h3", "hst_cccc", 0.0, 0, vec!["/other"]);

    let placed = api
        .handle(
            "task.place",
            json!({"request_id": "place", "task_id": task_id}),
        )
        .unwrap();
    assert_eq!(
        placed["event"]["payload"]["placement"]["host_id"],
        h2.as_str()
    );

    let task2 = api
        .handle(
            "task.create",
            json!({"request_id": "task2", "project_id": placed["event"]["payload"]["attempt"]["project_id"], "title": "manual", "body": ""}),
        )
        .unwrap();
    let task2_id: TaskId =
        serde_json::from_value(task2["event"]["payload"]["task_id"].clone()).unwrap();
    let manual = api
        .handle(
            "task.place",
            json!({"request_id": "manual", "task_id": task2_id, "host_id": h1}),
        )
        .unwrap();
    assert_eq!(
        manual["event"]["payload"]["placement"]["host_id"],
        "hst_aaaa"
    );
}

#[test]
fn suspect_quarantine_reassign_rotates_fence_and_cancels_old_attempt() {
    let (api, _project_id, task_id) = api_with_project_task();
    let h1 = observe_host(&api, "h1", "hst_1111", 0.1, 0, vec!["/tmp/repo"]);
    let h2 = observe_host(&api, "h2", "hst_2222", 0.2, 0, vec!["/tmp/repo"]);
    let first = api
        .handle(
            "task.place",
            json!({"request_id": "place", "task_id": task_id, "host_id": h1}),
        )
        .unwrap();
    let first_attempt = first["event"]["payload"]["attempt_id"].clone();
    let first_token = first["event"]["payload"]["token"].clone();

    api.handle(
        "task.suspect",
        json!({"request_id": "suspect", "task_id": task_id, "reason": "heartbeat stale"}),
    )
    .unwrap();
    api.handle(
        "task.quarantine",
        json!({"request_id": "quarantine", "task_id": task_id, "reason": "zombie"}),
    )
    .unwrap();
    let reassigned = api
        .handle(
            "task.reassign",
            json!({"request_id": "reassign", "task_id": task_id, "host_id": h2, "reason": "move"}),
        )
        .unwrap();
    assert_ne!(reassigned["event"]["payload"]["attempt_id"], first_attempt);
    assert_ne!(reassigned["event"]["payload"]["token"], first_token);

    let attempts = api
        .handle("attempt.list", json!({"task_id": task_id}))
        .unwrap();
    assert_eq!(attempts["attempts"][0]["status"], "cancelled");
    assert_eq!(attempts["attempts"][1]["status"], "created");
}

#[test]
fn stale_attempt_cannot_record_review_snapshot() {
    let (api, _project_id, task_id) = api_with_project_task();
    let h1 = observe_host(&api, "h1", "hst_3333", 0.1, 0, vec!["/tmp/repo"]);
    let h2 = observe_host(&api, "h2", "hst_4444", 0.2, 0, vec!["/tmp/repo"]);
    let first = api
        .handle(
            "task.place",
            json!({"request_id": "place", "task_id": task_id, "host_id": h1}),
        )
        .unwrap();
    let first_attempt = first["event"]["payload"]["attempt_id"].clone();
    let first_token = first["event"]["payload"]["token"].clone();
    api.handle(
        "task.suspect",
        json!({"request_id": "suspect", "task_id": task_id}),
    )
    .unwrap();
    api.handle(
        "task.reassign",
        json!({"request_id": "reassign", "task_id": task_id, "host_id": h2}),
    )
    .unwrap();

    let err = api
        .handle(
            "review.snapshot",
            json!({
                "request_id": "stale-review",
                "task_id": task_id,
                "attempt_id": first_attempt,
                "fencing_token": first_token,
                "base_sha": "base",
                "head_sha": "head",
                "diff_digest": "sha256:abc"
            }),
        )
        .unwrap_err()
        .to_string();
    assert!(err.contains("stale_attempt_reported"));
}

#[test]
fn review_approve_enqueues_merge_and_validates_snapshot_evidence() {
    let (api, _project_id, task_id) = api_with_project_task();
    let host = observe_host(&api, "h1", "hst_5555", 0.1, 0, vec!["/tmp/repo"]);
    let placed = api
        .handle(
            "task.place",
            json!({"request_id": "place", "task_id": task_id, "host_id": host}),
        )
        .unwrap();
    let attempt_id = placed["event"]["payload"]["attempt_id"].clone();
    let token = placed["event"]["payload"]["token"].clone();
    let snapshot = api
        .handle(
            "review.snapshot",
            json!({
                "request_id": "snapshot",
                "task_id": task_id,
                "attempt_id": attempt_id,
                "fencing_token": token,
                "base_sha": "base",
                "head_sha": "head",
                "diff_digest": "sha256:good",
                "summary": "ready",
                "files": [{"path":"daemon/x","kind":"modified","add":1,"del":0}]
            }),
        )
        .unwrap();
    let snapshot_id = snapshot["event"]["payload"]["snapshot_id"].clone();
    let mismatch = api
        .handle(
            "approve",
            json!({
                "request_id": "bad-approve",
                "task_id": task_id,
                "attempt_id": attempt_id,
                "fencing_token": token,
                "reviewer": "reviewer",
                "snapshot_id": snapshot_id,
                "head_sha": "other",
                "diff_digest": "sha256:good"
            }),
        )
        .unwrap_err()
        .to_string();
    assert!(mismatch.contains("snapshot evidence mismatch"));

    api.handle(
        "approve",
        json!({
            "request_id": "approve",
            "task_id": task_id,
            "attempt_id": attempt_id,
            "fencing_token": token,
            "reviewer": "reviewer",
            "snapshot_id": snapshot_id,
            "head_sha": "head",
            "diff_digest": "sha256:good"
        }),
    )
    .unwrap();
    let queue = api.handle("merge.queue", json!({})).unwrap();
    assert_eq!(queue["items"][0]["status"], "queued");
}

fn approved_queue_fixture(
    suffix: &str,
) -> (Arc<Api>, TaskId, serde_json::Value, serde_json::Value) {
    let (api, _project_id, task_id) = api_with_project_task();
    let host = observe_host(
        &api,
        &format!("host-{suffix}"),
        &format!("hst_{suffix}"),
        0.1,
        0,
        vec!["/tmp/repo"],
    );
    let placed = api
        .handle(
            "task.place",
            json!({"request_id": format!("place-{suffix}"), "task_id": task_id, "host_id": host}),
        )
        .unwrap();
    let attempt_id = placed["event"]["payload"]["attempt_id"].clone();
    let token = placed["event"]["payload"]["token"].clone();
    let snapshot = api
        .handle(
            "review.snapshot",
            json!({"request_id":format!("snapshot-{suffix}"),"task_id":task_id,"attempt_id":attempt_id,"fencing_token":token,"base_sha":"base","head_sha":"head","diff_digest":format!("sha256:{suffix}")}),
        )
        .unwrap();
    let snapshot_id = snapshot["event"]["payload"]["snapshot_id"].clone();
    api.handle(
        "approve",
        json!({"request_id":format!("approve-{suffix}"),"task_id":task_id,"attempt_id":attempt_id,"fencing_token":token,"reviewer":"reviewer","snapshot_id":snapshot_id,"head_sha":"head","diff_digest":format!("sha256:{suffix}")}),
    )
    .unwrap();
    let queue = api.handle("merge.queue", json!({})).unwrap();
    (
        api,
        task_id,
        attempt_id,
        queue["items"][0]["queue_id"].clone(),
    )
}

#[test]
fn merge_queue_transitions_are_serialized_and_state_checked() {
    let (api, _project_id, task_id) = api_with_project_task();
    let host = observe_host(&api, "h1", "hst_6666", 0.1, 0, vec!["/tmp/repo"]);
    let placed = api
        .handle(
            "task.place",
            json!({"request_id": "place", "task_id": task_id, "host_id": host}),
        )
        .unwrap();
    let attempt_id = placed["event"]["payload"]["attempt_id"].clone();
    let token = placed["event"]["payload"]["token"].clone();
    let snapshot = api
        .handle(
            "review.snapshot",
            json!({"request_id":"snapshot","task_id":task_id,"attempt_id":attempt_id,"fencing_token":token,"base_sha":"base","head_sha":"head","diff_digest":"sha256:q"}),
        )
        .unwrap();
    let snapshot_id = snapshot["event"]["payload"]["snapshot_id"].clone();
    api.handle(
        "approve",
        json!({"request_id":"approve","task_id":task_id,"attempt_id":attempt_id,"fencing_token":token,"reviewer":"reviewer","snapshot_id":snapshot_id,"head_sha":"head","diff_digest":"sha256:q"}),
    )
    .unwrap();
    let queue = api.handle("merge.queue", json!({})).unwrap();
    let queue_id = queue["items"][0]["queue_id"].clone();

    api.handle(
        "merge.queue.transition",
        json!({"request_id":"running","queue_id":queue_id,"status":"running"}),
    )
    .unwrap();
    api.handle(
        "merge.queue.transition",
        json!({"request_id":"merged","queue_id":queue_id,"status":"merged"}),
    )
    .unwrap();
    let invalid = api
        .handle(
            "merge.queue.transition",
            json!({"request_id":"again","queue_id":queue_id,"status":"running"}),
        )
        .unwrap_err()
        .to_string();
    assert!(invalid.contains("invalid merge queue transition"));
}

#[test]
fn running_to_failed_updates_task_and_attempt_projection() {
    let (api, task_id, _attempt_id, queue_id) = approved_queue_fixture("7777");

    api.handle(
        "merge.queue.transition",
        json!({"request_id":"running-failed","queue_id":queue_id,"status":"running"}),
    )
    .unwrap();
    api.handle(
        "merge.queue.transition",
        json!({"request_id":"failed","queue_id":queue_id,"status":"failed","last_error":"merge failed"}),
    )
    .unwrap();

    let task = api.handle("task.get", json!({"task_id": task_id})).unwrap();
    assert_eq!(task["task"]["status"], "failed");
    assert_eq!(task["attempts"][0]["status"], "failed");
    let queue = api.handle("merge.queue", json!({})).unwrap();
    assert_eq!(queue["items"][0]["status"], "failed");
    assert_eq!(queue["items"][0]["last_error"], "merge failed");
}

#[test]
fn running_to_cancelled_updates_task_and_attempt_projection() {
    let (api, task_id, _attempt_id, queue_id) = approved_queue_fixture("8888");

    api.handle(
        "merge.queue.transition",
        json!({"request_id":"running-cancelled","queue_id":queue_id,"status":"running"}),
    )
    .unwrap();
    api.handle(
        "merge.queue.transition",
        json!({"request_id":"cancelled","queue_id":queue_id,"status":"cancelled"}),
    )
    .unwrap();

    let task = api.handle("task.get", json!({"task_id": task_id})).unwrap();
    assert_eq!(task["task"]["status"], "cancelled");
    assert_eq!(task["attempts"][0]["status"], "cancelled");
    let queue = api.handle("merge.queue", json!({})).unwrap();
    assert_eq!(queue["items"][0]["status"], "cancelled");
}

/// A second `task.place` on an already-placed task is refused.
///
/// `Placed -> Placed` is a legal status transition (any state may repeat), so
/// the status check alone let a retry mint a second attempt and fence while
/// the first attempt kept running on its original host, never told it had
/// lost the task. That is two hosts owning one task — the thing fencing
/// exists to prevent, slipping past on the very first placement.
///
/// A retry that lost its idempotency key is the realistic way in, so the
/// second call here deliberately uses a fresh `request_id`.
#[test]
fn placing_an_already_placed_task_is_refused() {
    let (api, _project_id, task_id) = api_with_project_task();
    let h1 = observe_host(&api, "h1", "hst_1111", 0.1, 0, vec!["/tmp/repo"]);
    let h2 = observe_host(&api, "h2", "hst_2222", 0.2, 0, vec!["/tmp/repo"]);

    let first = api
        .handle(
            "task.place",
            json!({"request_id": "place-1", "task_id": task_id, "host_id": h1}),
        )
        .unwrap();
    let first_attempt = first["event"]["payload"]["attempt_id"].clone();

    let second = api.handle(
        "task.place",
        json!({"request_id": "place-2", "task_id": task_id, "host_id": h2}),
    );
    assert!(second.is_err(), "a second placement must not be accepted");

    let task = api
        .handle("task.get", json!({"task_id": task_id}))
        .unwrap();
    assert_eq!(
        task["task"]["current_attempt_id"], first_attempt,
        "the original attempt must still own the task"
    );
    let live: Vec<_> = task["attempts"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|a| a["status"] != "cancelled")
        .collect();
    assert_eq!(live.len(), 1, "exactly one attempt may be live: {live:?}");
}

/// Replaying a log twice reaches the same state, and a duplicated event is a
/// no-op rather than a second application.
///
/// This is the invariant the events-dedup short-circuit depends on. It only
/// holds because an event and its reduction now commit together: before that
/// they were separate autocommits, so a crash between them left a projection
/// the log could never repair — every later replay saw the event_id already
/// present and skipped the reduction that was missing.
#[test]
fn folding_the_same_log_twice_reaches_the_same_state() {
    let dir = tempdir().unwrap();
    let log = Arc::new(LocalJournalEventLog::new(dir.path().join("events.ndjson")));
    let api = Api::for_tests(log.clone() as Arc<dyn EventLog>).unwrap();
    let project = api
        .handle(
            "project.add",
            json!({"request_id": "project", "root_path": "/tmp/repo", "name": "repo"}),
        )
        .unwrap();
    let project_id: ProjectId =
        serde_json::from_value(project["event"]["project_id"].clone()).unwrap();
    let task = api
        .handle(
            "task.create",
            json!({"request_id": "task", "project_id": project_id, "title": "slice", "body": ""}),
        )
        .unwrap();
    let task_id: TaskId =
        serde_json::from_value(task["event"]["payload"]["task_id"].clone()).unwrap();
    let host_id = observe_host(&api, "h1", "hst_1111", 0.1, 0, vec!["/tmp/repo"]);
    api.handle(
        "task.place",
        json!({"request_id": "place", "task_id": task_id, "host_id": host_id}),
    )
    .unwrap();

    let events = log.read_all().unwrap();
    assert!(!events.is_empty());

    let once = Reducer::replay(&events).unwrap();
    let doubled: Vec<_> = events.iter().chain(events.iter()).cloned().collect();
    let twice = Reducer::replay(&doubled).unwrap();

    assert_eq!(
        serde_json::to_value(once.tasks(None, None, 100).unwrap()).unwrap(),
        serde_json::to_value(twice.tasks(None, None, 100).unwrap()).unwrap(),
        "a duplicated log must not change the projection"
    );
    assert_eq!(
        once.watermark().unwrap(),
        twice.watermark().unwrap(),
        "a duplicated event must not advance the watermark twice"
    );
}

/// A reduction that fails leaves no trace of its event, so the same event can
/// be applied successfully later.
///
/// This is what the transaction buys, and the events-dedup short-circuit
/// depends on it. Previously the `events` row and the reduction were separate
/// autocommits: a reduction that failed part-way still left the event row
/// behind, and every later replay found that event_id present, returned
/// early, and never ran the reduction that was missing — the projection could
/// not be repaired by replaying the log, which is the one recovery mechanism
/// an event-sourced store has.
///
/// A `task_placed` naming a task that does not exist is the cheapest way to
/// make a reduction fail after the event row has been written.
#[test]
fn a_failed_reduction_leaves_no_event_behind() {
    let reducer = Reducer::in_memory().unwrap();
    let missing_task = TaskId::try_from("tsk_does_not_exist".to_string()).unwrap();
    let attempt_id = "att_1111";
    let event = IntentEvent::new(
        "task_placed",
        Some("place-torn".to_string()),
        None,
        json!({
            "attempt": {
                "attempt_id": attempt_id,
                "task_id": missing_task,
                "host_id": "hst_1111",
                "status": "created",
                "created_at_ms": 1,
                "updated_at_ms": 1
            },
            "placement": {"host_id": "hst_1111", "mode": "worktree"},
            "task_id": missing_task,
            "attempt_id": attempt_id,
            "token": "fen_1111"
        }),
    );

    assert!(
        reducer.apply(&event).is_err(),
        "placing onto a missing task must fail"
    );
    assert!(
        reducer
            .event_by_request_id("place-torn")
            .unwrap()
            .is_none(),
        "a failed reduction must not leave its event row committed"
    );
    assert_eq!(
        reducer.watermark().unwrap(),
        0,
        "a failed reduction must not advance the watermark"
    );
}
