use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{bail, Result};
use serde_json::json;
use tempfile::tempdir;
use tm_coordinator::event_log::LocalJournalEventLog;
use tm_coordinator::model::{FencingToken, IntentEvent, ProjectId, TaskId};
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

#[test]
fn api_open_propagates_event_log_read_errors() {
    let dir = tempdir().unwrap();
    let config = Config {
        enabled: true,
        socket_path: dir.path().join("coord.sock"),
        reducer_path: dir.path().join("reducer.sqlite"),
        journal_path: None,
        use_local_journal: true,
    };

    let err = match Api::open_with_event_log(config, Arc::new(FailingReadLog)) {
        Ok(_) => panic!("Api::open_with_event_log unexpectedly succeeded"),
        Err(err) => err.to_string(),
    };

    assert!(err.contains("read_all failed"));
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
