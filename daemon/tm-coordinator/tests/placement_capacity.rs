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

/// A burst of placements does not all land on the same host.
///
/// `used_slots` is only ever reported by `host.observe`, so between two
/// reports every placement saw the same stale capacity: each one ranked the
/// same host best and went there, past what that host had said it could take.
/// Counting our own placement closes that window.
///
/// Both hosts get one free slot and are separated only by load, so the first
/// task has an unambiguous winner and the second must go elsewhere.
#[test]
fn a_second_placement_does_not_reuse_a_host_it_just_filled() {
    let (_dir, api) = new_api();
    let (project_id, first_task) = project_with_task(&api, "burst");
    observe_with_slots(&api, "h1", "hst_1111", 4, 3, 0.1);
    observe_with_slots(&api, "h2", "hst_2222", 4, 3, 0.9);

    let second = api
        .handle(
            "task.create",
            json!({
                "request_id": "burst-tsk-2",
                "project_id": project_id,
                "title": "second",
                "body": ""
            }),
        )
        .unwrap();
    let second_task = second["event"]["payload"]["task_id"].as_str().unwrap().to_string();

    let first_placed = api
        .handle(
            "task.place",
            json!({"request_id": "place-1", "task_id": first_task}),
        )
        .unwrap();
    assert_eq!(
        placed_host(&first_placed),
        "hst_1111",
        "the lighter-loaded host wins the first placement"
    );

    let second_placed = api
        .handle(
            "task.place",
            json!({"request_id": "place-2", "task_id": second_task}),
        )
        .unwrap();
    assert_eq!(
        placed_host(&second_placed),
        "hst_2222",
        "its one free slot is spoken for, so the next task goes elsewhere"
    );
}

/// Two hosts alike in capacity and load resolve the same way every time.
///
/// The sort ends on host_id precisely so that case has an answer; without a
/// test, a later change to the comparator could make placement depend on row
/// order and nobody would notice until two runs disagreed.
#[test]
fn identical_hosts_break_the_tie_the_same_way_every_time() {
    let mut winners = Vec::new();
    for round in 0..3 {
        let (_dir, api) = new_api();
        let (_project_id, task_id) = project_with_task(&api, &format!("tie-{round}"));
        // Observed in opposite orders across rounds: if anything downstream
        // depended on insertion order, these would disagree.
        if round % 2 == 0 {
            observe_with_slots(&api, "a", "hst_aaaa", 4, 1, 0.5);
            observe_with_slots(&api, "b", "hst_bbbb", 4, 1, 0.5);
        } else {
            observe_with_slots(&api, "b", "hst_bbbb", 4, 1, 0.5);
            observe_with_slots(&api, "a", "hst_aaaa", 4, 1, 0.5);
        }
        let placed = api
            .handle("task.place", json!({"request_id": "place", "task_id": task_id}))
            .unwrap();
        winners.push(placed_host(&placed).to_string());
    }
    assert_eq!(
        winners,
        vec!["hst_aaaa", "hst_aaaa", "hst_aaaa"],
        "a tie must resolve on host_id, regardless of the order they were observed"
    );
}
