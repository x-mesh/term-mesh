//! Capacity is a three-valued answer — a number, zero, or "I cannot say" —
//! and the wire used to have room for only two of them. The app mirrors a
//! peer roster and has no basis for a slot count, so it sent `0/0` meaning
//! "unknown"; `is_eligible_for` read that as "full" and refused to place work
//! on any host the app reported, whether the caller asked for automatic
//! placement or named the host outright.
//!
//! Nothing was misspelled. Both sides wrote `total_slots` and disagreed only
//! on what zero meant, which is the kind of drift a field-name audit cannot
//! see — it shows up only when a value is put through the whole path.

use std::sync::Arc;

use serde_json::{json, Value};
use tempfile::tempdir;
use tm_coordinator::event_log::LocalJournalEventLog;
use tm_coordinator::{Api, EventLog};

fn new_api() -> (tempfile::TempDir, Arc<Api>) {
    let dir = tempdir().unwrap();
    let log: Arc<dyn EventLog> =
        Arc::new(LocalJournalEventLog::new(dir.path().join("events.ndjson")));
    (dir, Api::for_tests(log).unwrap())
}

fn project_with_task(api: &Api, request: &str) -> (String, String) {
    let project = api
        .handle(
            "project.add",
            json!({"request_id": format!("{request}-prj"), "root_path": "/tmp/repo", "name": "repo"}),
        )
        .unwrap();
    let project_id = project["event"]["project_id"].as_str().unwrap().to_string();
    let task = api
        .handle(
            "task.create",
            json!({
                "request_id": format!("{request}-tsk"),
                "project_id": project_id,
                "title": "work",
                "body": ""
            }),
        )
        .unwrap();
    let task_id = task["event"]["payload"]["task_id"]
        .as_str()
        .unwrap()
        .to_string();
    (project_id, task_id)
}

/// Exactly what `CoordinatorHostObservation.rpcParams` puts on the wire: no
/// slot fields at all.
fn observe_as_the_app_does(api: &Api, request_id: &str, host_id: &str) {
    api.handle(
        "host.observe",
        json!({
            "request_id": request_id,
            "host_id": host_id,
            "os": "",
            "arch": "",
            "load": 0,
            "project_roots": ["/tmp/repo"],
            "leader_projects": ["/tmp/repo"],
            "live": true
        }),
    )
    .unwrap();
}

fn observe_with_slots(api: &Api, request_id: &str, host_id: &str, total: u32, used: u32, load: f64) {
    api.handle(
        "host.observe",
        json!({
            "request_id": request_id,
            "host_id": host_id,
            "os": "linux",
            "arch": "aarch64",
            "load": load,
            "total_slots": total,
            "used_slots": used,
            "project_roots": ["/tmp/repo"],
            "live": true
        }),
    )
    .unwrap();
}

fn placed_host(result: &Value) -> &str {
    result["event"]["payload"]["placement"]["host_id"]
        .as_str()
        .unwrap()
}

/// The regression itself, both ways a caller can ask.
#[test]
fn a_host_that_reported_no_capacity_number_is_still_placeable() {
    let (_dir, api) = new_api();
    let (_project_id, task_id) = project_with_task(&api, "auto");
    observe_as_the_app_does(&api, "obs-1", "hst_appreported");

    let manual = api
        .handle(
            "task.place",
            json!({"request_id": "p1", "task_id": task_id, "host_id": "hst_appreported"}),
        )
        .unwrap();
    assert_eq!(placed_host(&manual), "hst_appreported");

    let (_dir2, api2) = new_api();
    let (_project_id2, task_id2) = project_with_task(&api2, "auto2");
    observe_as_the_app_does(&api2, "obs-2", "hst_appreported");
    let automatic = api2
        .handle("task.place", json!({"request_id": "p2", "task_id": task_id2}))
        .unwrap();
    assert_eq!(placed_host(&automatic), "hst_appreported");
}

/// A reported zero still means full. Relaxing the unknown case must not
/// relax the case the check was written for.
#[test]
fn a_host_that_reported_zero_free_slots_is_still_refused() {
    let (_dir, api) = new_api();
    let (_project_id, task_id) = project_with_task(&api, "full");
    observe_with_slots(&api, "obs-full", "hst_full", 4, 4, 0.0);

    let automatic = api
        .handle("task.place", json!({"request_id": "p1", "task_id": task_id}))
        .unwrap_err()
        .to_string();
    assert!(automatic.contains("no eligible host"), "{automatic}");

    let manual = api
        .handle(
            "task.place",
            json!({"request_id": "p2", "task_id": task_id, "host_id": "hst_full"}),
        )
        .unwrap_err()
        .to_string();
    assert!(manual.contains("not eligible"), "{manual}");
}

/// A host that answered outranks one that stayed silent, however little it
/// has left — otherwise a guess beats a fact.
#[test]
fn a_known_capacity_outranks_an_unknown_one() {
    let (_dir, api) = new_api();
    let (_project_id, task_id) = project_with_task(&api, "rank");
    // The silent host is idle and would win on load alone.
    observe_as_the_app_does(&api, "obs-unknown", "hst_unknown");
    observe_with_slots(&api, "obs-known", "hst_known", 4, 3, 0.9);

    let placed = api
        .handle("task.place", json!({"request_id": "p1", "task_id": task_id}))
        .unwrap();
    assert_eq!(placed_host(&placed), "hst_known");
}

/// Unknown is a fallback, not a dead end: with no host reporting capacity,
/// one of the silent ones still has to be chosen.
#[test]
fn unknown_hosts_are_used_when_nobody_reported_capacity() {
    let (_dir, api) = new_api();
    let (_project_id, task_id) = project_with_task(&api, "fallback");
    observe_as_the_app_does(&api, "obs-a", "hst_aaaa");
    observe_as_the_app_does(&api, "obs-b", "hst_bbbb");

    let placed = api
        .handle("task.place", json!({"request_id": "p1", "task_id": task_id}))
        .unwrap();
    assert!(placed_host(&placed).starts_with("hst_"), "{placed}");
}

/// Absent and zero have to stay distinguishable after a round trip, or the
/// reader is back to guessing which one it was told.
#[test]
fn host_list_reports_absent_capacity_as_absent_not_zero() {
    let (_dir, api) = new_api();
    observe_as_the_app_does(&api, "obs-1", "hst_unknown");
    observe_with_slots(&api, "obs-2", "hst_zero", 0, 0, 0.0);

    let hosts = api.handle("host.list", json!({})).unwrap();
    let rows = hosts["hosts"].as_array().unwrap();
    let unknown = rows
        .iter()
        .find(|row| row["host_id"] == "hst_unknown")
        .unwrap();
    let zero = rows.iter().find(|row| row["host_id"] == "hst_zero").unwrap();

    assert!(
        unknown.get("total_slots").is_none(),
        "unknown capacity must not surface as a number: {unknown}"
    );
    assert_eq!(zero["total_slots"], 0);
}

/// `used_slots` without a total is not a contradiction to reject — it is a
/// reporter telling us what it does know.
#[test]
fn used_slots_without_a_total_is_accepted() {
    let (_dir, api) = new_api();
    let accepted = api.handle(
        "host.observe",
        json!({
            "request_id": "obs-partial",
            "host_id": "hst_partial",
            "os": "linux",
            "arch": "aarch64",
            "load": 0.2,
            "used_slots": 3,
            "project_roots": ["/tmp/repo"],
            "live": true
        }),
    );
    assert!(accepted.is_ok(), "{accepted:?}");

    let overcommitted = api
        .handle(
            "host.observe",
            json!({
                "request_id": "obs-over",
                "host_id": "hst_over",
                "os": "linux",
                "arch": "aarch64",
                "load": 0.2,
                "total_slots": 2,
                "used_slots": 3,
                "project_roots": ["/tmp/repo"],
                "live": true
            }),
        )
        .unwrap_err()
        .to_string();
    assert!(overcommitted.contains("used_slots exceeds total_slots"));
}
