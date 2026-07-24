//! `orchestration.status` is the only read the review board makes to decide
//! what to show, so its shape is a contract rather than a debug dump. It used
//! to be neither: the coordinator emitted `mem_mesh`, `feature_flags` and
//! `focus_adapter_calls`, while the app read `mem_mesh_available`,
//! `suspect_host`, `fenced_zombie` and `panel_runs` — four keys that were
//! never sent. Nothing failed loudly. The app fell through to its defaults,
//! and the most damaging default was `mem_mesh_available ?? true`, which
//! reported a healthy log while the default backend rejected every append.
//!
//! These tests pin the keys, and pin that the flags can actually change.
//! A flag that is structurally unable to move is indistinguishable from a
//! flag that is broken, which is how the hardcoded `false` trio survived.

use std::sync::Arc;

use serde_json::json;
use tempfile::tempdir;
use tm_coordinator::event_log::{LocalJournalEventLog, MemMeshUnavailableEventLog};
use tm_coordinator::{Api, EventLog};

fn api_with_working_log() -> (tempfile::TempDir, Arc<Api>) {
    let dir = tempdir().unwrap();
    let log: Arc<dyn EventLog> =
        Arc::new(LocalJournalEventLog::new(dir.path().join("events.ndjson")));
    let api = Api::for_tests(log).unwrap();
    (dir, api)
}

fn status(api: &Api) -> serde_json::Value {
    api.handle("orchestration.status", json!({})).unwrap()
}

/// Every key the app reads has to be present. This is the test that would
/// have caught the original mismatch, so it asserts presence by name rather
/// than comparing whole objects — a value can change, an absent key is a bug.
#[test]
fn status_reports_every_key_the_review_board_reads() {
    let (_dir, api) = api_with_working_log();
    let status = status(&api);

    for key in [
        "mem_mesh_available",
        "suspect_host",
        "fenced_zombie",
        "panel_runs",
    ] {
        assert!(
            status.get(key).is_some(),
            "status is missing `{key}`, which the review board reads: {status}"
        );
    }

    // The board distinguishes "no panel runs" from "coordinator too old to
    // know", so this must be an empty list and never a missing key.
    assert!(status["panel_runs"].is_array());
}

/// The failure this whole contract exists to surface: a log that rejects
/// every append must not read as healthy.
#[test]
fn mem_mesh_available_follows_whether_the_log_can_append() {
    let unavailable = Api::for_tests(Arc::new(MemMeshUnavailableEventLog)).unwrap();
    assert_eq!(status(&unavailable)["mem_mesh_available"], false);

    let (_dir, working) = api_with_working_log();
    assert_eq!(status(&working)["mem_mesh_available"], true);
}

/// `remote_hosts` used to be a hardcoded `false`. It reports whether host
/// observations actually reach the reducer, so it has to move when one does.
#[test]
fn remote_hosts_turns_true_once_an_observation_lands() {
    let (_dir, api) = api_with_working_log();
    assert_eq!(status(&api)["feature_flags"]["remote_hosts"], false);
    assert_eq!(status(&api)["known_host_count"], 0);

    api.handle(
        "host.observe",
        json!({
            "request_id": "obs-1",
            "os": "linux",
            "arch": "aarch64",
            "load": 0.5,
            "total_slots": 4,
            "used_slots": 1,
            "project_roots": ["/root/demo-project"],
            "leader_projects": ["/root/demo-project"]
        }),
    )
    .unwrap();

    assert_eq!(status(&api)["feature_flags"]["remote_hosts"], true);
    assert_eq!(status(&api)["known_host_count"], 1);
}

/// Both badges are derived from task state, so both have to flip when a task
/// reaches the state that names them.
#[test]
fn suspect_and_quarantined_tasks_raise_their_badges() {
    let (_dir, api) = api_with_working_log();
    assert_eq!(status(&api)["suspect_host"], false);
    assert_eq!(status(&api)["fenced_zombie"], false);

    let project = api
        .handle(
            "project.add",
            json!({"request_id": "prj-1", "root_path": "/tmp/repo", "name": "repo"}),
        )
        .unwrap();
    let project_id = project["event"]["project_id"].as_str().unwrap().to_string();

    let mut task_ids = Vec::new();
    for (index, request_id) in ["tsk-1", "tsk-2"].iter().enumerate() {
        let created = api
            .handle(
                "task.create",
                json!({
                    "request_id": request_id,
                    "project_id": project_id,
                    "title": format!("task {index}"),
                    "body": ""
                }),
            )
            .unwrap();
        task_ids.push(
            created["event"]["payload"]["task_id"]
                .as_str()
                .unwrap()
                .to_string(),
        );
    }

    api.handle(
        "task.suspect",
        json!({"request_id": "sus-1", "task_id": task_ids[0], "reason": "heartbeat stale"}),
    )
    .unwrap();
    assert_eq!(status(&api)["suspect_host"], true);
    assert_eq!(status(&api)["fenced_zombie"], false);

    api.handle(
        "task.quarantine",
        json!({"request_id": "qtn-1", "task_id": task_ids[1], "reason": "fence lost"}),
    )
    .unwrap();
    assert_eq!(status(&api)["fenced_zombie"], true);
}

/// The two adapters were never built. Reporting them as `false` invited the
/// reading "a flag turns this on"; a string says the code is absent. The
/// call counter went with them — a counter that can only ever be zero is the
/// same lie in another shape.
#[test]
fn unbuilt_adapters_say_so_instead_of_reporting_a_disabled_flag() {
    let (_dir, api) = api_with_working_log();
    let status = status(&api);

    assert_eq!(
        status["feature_flags"]["app_socket_adapter"],
        "not_implemented"
    );
    assert_eq!(status["feature_flags"]["daemon_adapter"], "not_implemented");
    assert!(
        status.get("focus_adapter_calls").is_none(),
        "focus_adapter_calls counts calls through adapters that do not exist"
    );
}

/// Work delegated from a pane already has an identity — the team task board's
/// — and the coordinator's half of the story (which host, which attempt,
/// where in the merge queue) is an attribute of that work. Minting a second
/// id here made one job into two records whose statuses drifted apart.
#[test]
fn a_task_can_keep_the_id_the_work_already_has() {
    let (_dir, api) = api_with_working_log();
    let project = api
        .handle(
            "project.add",
            json!({"request_id": "prj", "root_path": "/tmp/repo", "name": "repo"}),
        )
        .unwrap();
    let project_id = project["event"]["project_id"].as_str().unwrap().to_string();

    // A team task id: no `tsk_` prefix, because the team board does not use one.
    let adopted = api
        .handle(
            "task.create",
            json!({
                "request_id": "adopt",
                "project_id": project_id,
                "title": "work that already exists",
                "body": "",
                "task_id": "c259ab1f"
            }),
        )
        .unwrap();
    assert_eq!(adopted["event"]["payload"]["task_id"], "c259ab1f");

    // And it is reachable by that id, so placement and status land on the
    // same work the agent is reporting against.
    let fetched = api
        .handle("task.get", json!({"task_id": "c259ab1f"}))
        .unwrap();
    assert_eq!(fetched["task"]["title"], "work that already exists");

    // Without one, the coordinator still names the task itself.
    let minted = api
        .handle(
            "task.create",
            json!({
                "request_id": "mint",
                "project_id": project_id,
                "title": "work that starts here",
                "body": ""
            }),
        )
        .unwrap();
    assert!(minted["event"]["payload"]["task_id"]
        .as_str()
        .unwrap()
        .starts_with("tsk_"));
}
