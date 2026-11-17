use super::*;

/// Open a persistent events.subscribe connection and stream events into an mpsc channel.
/// Returns Err if the initial connection or ack fails.  The background thread closes
/// the channel on EOF / socket error, which the caller detects as Disconnected.
pub(crate) fn subscribe_events_channel(
    daemon_sock: &PathBuf,
    kinds: &[&str],
) -> Result<std::sync::mpsc::Receiver<Value>, String> {
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "events.subscribe",
        "params": { "kinds": kinds },
    });

    let stream = UnixStream::connect(daemon_sock).map_err(|e| format!("subscribe connect: {e}"))?;
    // 90s read timeout outlasts the daemon's 30s keepalive with margin.
    stream.set_read_timeout(Some(Duration::from_secs(90))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(5))).ok();

    let mut writer = stream
        .try_clone()
        .map_err(|e| format!("subscribe clone: {e}"))?;

    let mut payload =
        serde_json::to_string(&request).map_err(|e| format!("subscribe serialize: {e}"))?;
    payload.push('\n');
    writer
        .write_all(payload.as_bytes())
        .map_err(|e| format!("subscribe write: {e}"))?;
    writer.flush().ok();

    // Read ack (first JSONL line from daemon)
    let mut reader = BufReader::new(stream);
    let mut ack_line = String::new();
    reader
        .read_line(&mut ack_line)
        .map_err(|e| format!("subscribe ack read: {e}"))?;
    let ack: Value =
        serde_json::from_str(ack_line.trim()).map_err(|e| format!("subscribe ack parse: {e}"))?;
    if ack.get("error").map_or(false, |e| !e.is_null()) {
        let msg = ack["error"]["message"].as_str().unwrap_or("unknown");
        return Err(format!("subscribe server error: {msg}"));
    }

    let (tx, rx) = std::sync::mpsc::channel::<Value>();

    thread::spawn(move || {
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) => break, // EOF — daemon closed connection
                Ok(_) => {
                    let trimmed = line.trim_end_matches('\n').trim_end_matches('\r');
                    if trimmed.is_empty() {
                        continue;
                    }
                    if let Ok(v) = serde_json::from_str::<Value>(trimmed) {
                        if v.get("kind").is_some() && tx.send(v).is_err() {
                            break; // receiver dropped
                        }
                    }
                }
                Err(e) => match e.kind() {
                    ErrorKind::WouldBlock | ErrorKind::TimedOut => continue, // keepalive gap
                    _ => break,
                },
            }
        }
    });

    Ok(rx)
}

/// A task argument that was given but names nothing is an error, not an
/// absent argument: an empty shell variable must not silently turn into
/// "track every active task".
pub(crate) fn parse_wait_task_arguments(
    tasks: Option<&str>,
    task: Option<&str>,
) -> Result<Option<std::collections::HashSet<String>>, String> {
    // The single-task exit in run_wait ignores the --tasks set, so the pair
    // would end the wait on one task while the others still run.
    if task.is_some() && tasks.is_some() {
        return Err("--task and --tasks cannot be combined; pass every id in one --tasks list, e.g. --tasks a,b".to_string());
    }
    if task.is_some_and(|id| id.trim().is_empty()) {
        return Err("--task is empty; pass a task id or omit the flag".to_string());
    }
    let Some(tasks) = tasks else {
        return Ok(None);
    };
    let ids: std::collections::HashSet<String> = tasks
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if ids.is_empty() {
        return Err(
            "--tasks names no task ids; pass a comma-separated list or omit the flag".to_string(),
        );
    }
    Ok(Some(ids))
}

/// Tasks of `tracked` that have settled according to the last observed status.
/// Judging from the observed map, not the current list, keeps a settled task
/// that later leaves the list from stalling the wait.
pub(crate) fn wait_settled_count(
    tracked: &std::collections::HashSet<String>,
    statuses: &std::collections::HashMap<String, String>,
) -> u64 {
    tracked
        .iter()
        .filter(|id| {
            statuses
                .get(*id)
                .is_some_and(|status| wait_task_settled(status))
        })
        .count() as u64
}

pub(crate) fn initialize_wait_task_scope(
    explicit_task_ids: Option<&std::collections::HashSet<String>>,
    task_id: Option<&str>,
) -> (std::collections::HashSet<String>, bool) {
    let mut task_ids = explicit_task_ids.cloned().unwrap_or_default();
    let task_argument = task_id.filter(|id| !id.trim().is_empty());
    if let Some(id) = task_argument {
        task_ids.insert(id.to_string());
    }
    let is_explicit = explicit_task_ids.is_some() || task_argument.is_some();
    (task_ids, is_explicit)
}

pub(crate) fn should_discover_wait_tasks(
    explicit_task_scope: bool,
    tracked_initialized: bool,
    tracked_agents_empty: bool,
) -> bool {
    !explicit_task_scope && (!tracked_initialized || tracked_agents_empty)
}

/// Statuses after which the worker no longer works on the task, so a wait
/// scoped to it has nothing left to wait for. Leaving `failed` out made a
/// wait run to its timeout whenever one tracked task failed.
/// Seconds an assignee may sit idle on an unsettled task before `wait` reports
/// it. Hand-off takes tens of seconds before a worker's first output, and a
/// terminal pane reads as idle after six quiet seconds, so a shorter grace would
/// flag workers that are about to start or are thinking silently.
pub(crate) const WAIT_STALL_GRACE: Duration = Duration::from_secs(90);

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct WaitTaskRef {
    assignee: String,
    agent_instance_id: Option<String>,
    status: String,
}

impl WaitTaskRef {
    fn from_task(task: &Value) -> Option<Self> {
        let assignee = task["assignee"].as_str().filter(|name| !name.is_empty())?;
        Some(Self {
            assignee: assignee.to_string(),
            agent_instance_id: task["agent_instance_id"]
                .as_str()
                .filter(|id| !id.is_empty())
                .map(String::from),
            status: task["status"].as_str().unwrap_or("").to_string(),
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct StalledWaitTask {
    task_id: String,
    assignee: String,
    status: String,
    idle_seconds: u64,
}

/// `agent_state` cannot answer this: a terminal or headless agent reads `idle`
/// while it works, and a started task reads `running` after the turn ended.
/// Only a native pane reports its turn (`turn_tracked`), so only it, or a
/// daemon-parked agent, can be called idle. An app without these fields, or an
/// assignee absent from the roster, is never evidence of a stall.
pub(crate) fn wait_assignee_is_idle(task: &WaitTaskRef, agents: &[Value]) -> bool {
    let agent = match &task.agent_instance_id {
        Some(instance) => agents
            .iter()
            .find(|agent| agent["agent_instance_id"].as_str() == Some(instance.as_str())),
        None => agents
            .iter()
            .find(|agent| agent["name"].as_str() == Some(task.assignee.as_str())),
    };
    let Some(agent) = agent else {
        return false;
    };
    if agent["agent_state"].as_str() == Some("parked") {
        return true;
    }
    agent["turn_tracked"].as_bool() == Some(true)
        && agent["turn_in_flight"].as_bool() == Some(false)
}

pub(crate) fn update_wait_stall_tracker(
    tasks: &std::collections::HashMap<String, WaitTaskRef>,
    agents: &[Value],
    idle_since: &mut std::collections::HashMap<String, Instant>,
    now: Instant,
    grace: Duration,
) -> Vec<StalledWaitTask> {
    idle_since.retain(|task_id, _| {
        tasks
            .get(task_id)
            .is_some_and(|task| !wait_task_settled(&task.status))
    });
    let mut stalled = Vec::new();
    for (task_id, task) in tasks {
        if wait_task_settled(&task.status) || !wait_assignee_is_idle(task, agents) {
            idle_since.remove(task_id);
            continue;
        }
        let since = *idle_since.entry(task_id.clone()).or_insert(now);
        let idle = now.saturating_duration_since(since);
        if idle >= grace {
            stalled.push(StalledWaitTask {
                task_id: task_id.clone(),
                assignee: task.assignee.clone(),
                status: task.status.clone(),
                idle_seconds: idle.as_secs(),
            });
        }
    }
    stalled.sort_by(|a, b| a.task_id.cmp(&b.task_id));
    stalled
}

pub(crate) fn wait_task_settled(status: &str) -> bool {
    matches!(
        status,
        "completed" | "review_ready" | "blocked" | "failed" | "cancelled"
    )
}

/// The app checks a settled task's checkout for uncommitted changes just
/// after the status changes, so a wait that returns at once can still see the
/// check pending. This bounds how long a wait re-reads for it: the app's git
/// deadline plus a margin. Past it the value is printed as it stands.
const UNCOMMITTED_CHECK_SETTLE: Duration = Duration::from_secs(8);
const UNCOMMITTED_CHECK_POLL: Duration = Duration::from_millis(250);

/// The pause between polls, cut short so the last one ends at `--timeout`
/// instead of a full interval past it.
fn wait_pause(interval_secs: u64, started: Instant, timeout_secs: u32) -> Duration {
    Duration::from_secs(interval_secs)
        .min(Duration::from_secs(u64::from(timeout_secs)).saturating_sub(started.elapsed()))
}

/// The re-read never runs past the caller's own `--timeout`: a short timeout
/// is how automation decides to give up, so the settle budget is whatever is
/// left of it, capped at `UNCOMMITTED_CHECK_SETTLE`.
fn uncommitted_check_budget(started: Instant, timeout_secs: u32) -> Duration {
    Duration::from_secs(u64::from(timeout_secs))
        .saturating_sub(started.elapsed())
        .min(UNCOMMITTED_CHECK_SETTLE)
}

fn uncommitted_check_pending(value: &Value) -> bool {
    value
        .get("uncommitted_check")
        .and_then(|check| check.get("state"))
        .and_then(Value::as_str)
        == Some("pending")
}

fn collect_has_pending_uncommitted_check(response: &Value) -> bool {
    response["result"]["results"]
        .as_array()
        .is_some_and(|results| results.iter().any(uncommitted_check_pending))
}

fn inbox_task_items(response: &Value, status: &str) -> Vec<Value> {
    response["result"]["items"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter(|item| {
                    item["kind"].as_str() == Some("task") && item["status"].as_str() == Some(status)
                })
                .cloned()
                .collect()
        })
        .unwrap_or_default()
}

/// A successful inbox re-read replaces the items even when none are left in
/// `status`: the task moved on, and the stale item must not be reported. Only
/// a failed call keeps the previous items.
fn inbox_reread(response: Result<Value, String>, status: &str) -> Option<Value> {
    response
        .ok()
        .map(|response| Value::Array(inbox_task_items(&response, status)))
}

/// Inbox task items for a `blocked` or `review_ready` wait that ended, re-read
/// while one of them still has a pending uncommitted-changes check. Empty when
/// every item left `status` during the re-read.
fn settled_inbox_items(
    sock: &PathBuf,
    team: &str,
    status: &str,
    items: Vec<Value>,
    budget: Duration,
) -> Vec<Value> {
    let settled = settle_uncommitted_check(
        Value::Array(items),
        |value| {
            value
                .as_array()
                .is_some_and(|items| items.iter().any(uncommitted_check_pending))
        },
        || {
            inbox_reread(
                rpc_call(sock, "team.inbox", json!({ "team_name": team })),
                status,
            )
        },
        budget,
        UNCOMMITTED_CHECK_POLL,
    );
    settled.as_array().cloned().unwrap_or_default()
}

/// `team.result.collect` for a wait that ended, re-read while a tracked
/// result's uncommitted-changes check is still pending.
fn collect_settled_results(
    sock: &PathBuf,
    team: &str,
    tracked_task_ids: Option<&std::collections::HashSet<String>>,
    budget: Duration,
) -> Option<Value> {
    let fetch = || {
        rpc_call(sock, "team.result.collect", json!({ "team_name": team }))
            .ok()
            .map(|r| filter_result_collect_response(r, tracked_task_ids))
    };
    let first = fetch()?;
    Some(settle_uncommitted_check(
        first,
        collect_has_pending_uncommitted_check,
        fetch,
        budget,
        UNCOMMITTED_CHECK_POLL,
    ))
}

/// Re-reads `current` while `pending` holds, up to `budget`. A failed re-read
/// keeps the last value; the wait still returns.
fn settle_uncommitted_check(
    mut current: Value,
    pending: impl Fn(&Value) -> bool,
    mut refetch: impl FnMut() -> Option<Value>,
    budget: Duration,
    poll: Duration,
) -> Value {
    let deadline = Instant::now() + budget;
    while pending(&current) && Instant::now() < deadline {
        std::thread::sleep(poll);
        if let Some(next) = refetch() {
            current = next;
        }
    }
    current
}

/// Messages carry no task correlation. When the caller named the tasks it is
/// waiting for, an interim report from every agent says nothing about them and
/// must not end the wait.
pub(crate) fn messages_end_any_wait(explicit_task_scope: bool) -> bool {
    !explicit_task_scope
}

/// The one word the leader branches on. A blocked task needs the leader before
/// anything else, a failed one needs a decision, and only without either is
/// the wave done.
pub(crate) fn wait_report_outcome<'a>(statuses: impl IntoIterator<Item = &'a str>) -> &'static str {
    let mut failed = false;
    for status in statuses {
        match status {
            "blocked" => return "blocked",
            "failed" => failed = true,
            _ => {}
        }
    }
    if failed {
        "failed"
    } else {
        "completed"
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum WaitPushSource {
    LocalDaemon,
    /// The local daemon never sees the owning host's task_status events, so
    /// the owner is long-polled through the leader route instead.
    RemoteOwnerWake,
    Disabled,
}

pub(crate) fn wait_push_source(
    has_route: bool,
    push_disabled: bool,
    kinds_empty: bool,
) -> WaitPushSource {
    if push_disabled || kinds_empty {
        WaitPushSource::Disabled
    } else if has_route {
        WaitPushSource::RemoteOwnerWake
    } else {
        WaitPushSource::LocalDaemon
    }
}

pub(crate) const OWNER_WAKE_METHOD: &str = "team.events.wait";
/// The owner caps a hold at 7 s so the reply beats every hop's timeout.
pub(crate) const OWNER_WAKE_HOLD: Duration = Duration::from_millis(7000);
pub(crate) const OWNER_WAKE_MIN_GAP: Duration = Duration::from_secs(1);
/// Each failed attempt can block for the whole transport window (about 31 s)
/// and appends a `route_failed` record to the turn log, so an owner that stays
/// unreachable is left to the interval poll instead of being retried forever.
pub(crate) const OWNER_WAKE_MAX_CONSECUTIVE_RETRIES: u32 = 3;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct OwnerWakeCursor {
    epoch: String,
    revision: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum OwnerWakeStep {
    Wake(OwnerWakeCursor),
    Rearm(OwnerWakeCursor),
    Unsupported,
    Retry,
    Backoff(Duration),
}

/// An owner app older than `team.events.wait` rejects it as `invalid_method`
/// in its own validator; a PeerServer-routed owner answers
/// `method_not_allowed`. An older host daemon refuses it before the owner, and
/// that hop carries only a message (every refusal there becomes -32601), so it
/// is matched by its exact text: it cannot be typed without a daemon change.
pub(crate) fn owner_wake_unsupported(error: &RemoteLeaderCallError) -> bool {
    match error {
        RemoteLeaderCallError::Owner(error) => {
            matches!(
                error.code.as_deref(),
                Some("method_not_allowed" | "invalid_method")
            )
        }
        RemoteLeaderCallError::Hop(message) => {
            *message == format!("method_not_allowed: {OWNER_WAKE_METHOD}")
        }
    }
}

pub(crate) fn owner_wake_step(
    prev: Option<&OwnerWakeCursor>,
    response: Result<Value, RemoteLeaderCallError>,
    interval: Duration,
) -> OwnerWakeStep {
    let response = match response {
        Ok(response) => response,
        Err(error) if owner_wake_unsupported(&error) => return OwnerWakeStep::Unsupported,
        Err(_) => return OwnerWakeStep::Retry,
    };
    let result = &response["result"];
    if result["busy"].as_bool() == Some(true) {
        let hint = result["retry_after_ms"]
            .as_u64()
            .map(Duration::from_millis)
            .unwrap_or(OWNER_WAKE_MIN_GAP);
        return OwnerWakeStep::Backoff(
            hint.clamp(OWNER_WAKE_MIN_GAP, interval.max(OWNER_WAKE_MIN_GAP)),
        );
    }
    let (Some(epoch), Some(revision)) = (result["epoch"].as_str(), result["revision"].as_u64())
    else {
        return OwnerWakeStep::Retry;
    };
    let cursor = OwnerWakeCursor {
        epoch: epoch.to_string(),
        revision,
    };
    match prev {
        Some(prev) if result["changed"].as_bool() == Some(true) || *prev != cursor => {
            OwnerWakeStep::Wake(cursor)
        }
        _ => OwnerWakeStep::Rearm(cursor),
    }
}

pub(crate) fn owner_wake_params(team: &str, since: Option<&OwnerWakeCursor>) -> Value {
    json!({
        "team_name": team,
        "since": since.map(|cursor| json!({
            "epoch": cursor.epoch,
            "revision": cursor.revision,
        })),
        "timeout_ms": OWNER_WAKE_HOLD.as_millis() as u64,
    })
}

pub(crate) fn owner_wake_pause(last_start: Option<Instant>, now: Instant) -> Duration {
    last_start
        .map(|start| OWNER_WAKE_MIN_GAP.saturating_sub(now.saturating_duration_since(start)))
        .unwrap_or(Duration::ZERO)
}

/// Feeds `run_wait`'s wake channel from the owner long-poll. Returning drops
/// the sender, which the wait loop reads as "fall back to polling".
///
/// The call is injected because a test holding `REMOTE_LEADER_ENV_LOCK` would
/// deadlock a loop thread that reached `remote_leader_route()` itself.
pub(crate) fn owner_wake_loop(
    team: &str,
    interval: Duration,
    tx: std::sync::mpsc::Sender<Value>,
    mut call: impl FnMut(Value) -> Result<Value, RemoteLeaderCallError>,
    mut sleep: impl FnMut(Duration),
) {
    let mut cursor: Option<OwnerWakeCursor> = None;
    let mut last_start: Option<Instant> = None;
    let mut retries: u32 = 0;
    loop {
        sleep(owner_wake_pause(last_start, Instant::now()));
        last_start = Some(Instant::now());
        let response = call(owner_wake_params(team, cursor.as_ref()));
        match owner_wake_step(cursor.as_ref(), response, interval) {
            OwnerWakeStep::Wake(next) => {
                retries = 0;
                let event = json!({
                    "kind": "owner_wake",
                    "epoch": next.epoch,
                    "revision": next.revision,
                });
                cursor = Some(next);
                if tx.send(event).is_err() {
                    return;
                }
            }
            OwnerWakeStep::Rearm(next) => {
                retries = 0;
                cursor = Some(next);
            }
            OwnerWakeStep::Backoff(pause) => {
                retries = 0;
                sleep(pause);
            }
            OwnerWakeStep::Unsupported => return,
            OwnerWakeStep::Retry => {
                retries += 1;
                if retries >= OWNER_WAKE_MAX_CONSECUTIVE_RETRIES {
                    eprintln!(
                        "wait: owner long-poll failed {retries} times in a row; polling every {}s",
                        interval.as_secs()
                    );
                    return;
                }
                sleep(interval);
            }
        }
    }
}

pub(crate) fn spawn_remote_owner_wake(
    sock: PathBuf,
    team: String,
    interval: u32,
) -> std::sync::mpsc::Receiver<Value> {
    let (tx, rx) = std::sync::mpsc::channel();
    thread::spawn(move || {
        owner_wake_loop(
            &team,
            Duration::from_secs(u64::from(interval)),
            tx,
            |params| {
                remote_leader_call_typed(
                    &sock,
                    OWNER_WAKE_METHOD,
                    params,
                    remote_leader_timeout(OWNER_WAKE_METHOD, OWNER_WAKE_HOLD),
                )
            },
            thread::sleep,
        )
    });
    rx
}

#[derive(Debug, PartialEq)]
pub(crate) enum PushWait {
    Event(Value),
    Elapsed,
    Closed,
}

pub(crate) fn recv_push_or_interval(
    rx: &std::sync::mpsc::Receiver<Value>,
    wait: Duration,
) -> PushWait {
    use std::sync::mpsc::RecvTimeoutError;
    match rx.recv_timeout(wait) {
        Ok(event) => PushWait::Event(event),
        Err(RecvTimeoutError::Timeout) => PushWait::Elapsed,
        Err(RecvTimeoutError::Disconnected) => PushWait::Closed,
    }
}

#[cfg(test)]
mod owner_wake_tests {
    use super::*;

    fn cursor(epoch: &str, revision: u64) -> OwnerWakeCursor {
        OwnerWakeCursor {
            epoch: epoch.to_string(),
            revision,
        }
    }

    const INTERVAL: Duration = Duration::from_secs(30);

    fn answer(epoch: &str, revision: u64, changed: bool) -> Result<Value, RemoteLeaderCallError> {
        Ok(json!({
            "ok": true,
            "result": {"epoch": epoch, "revision": revision, "changed": changed},
            "remote_leader_proxy": true,
        }))
    }

    fn busy(retry_after_ms: Option<u64>) -> Result<Value, RemoteLeaderCallError> {
        let mut result = json!({"epoch": "e1", "revision": 3, "changed": false, "busy": true});
        if let Some(ms) = retry_after_ms {
            result["retry_after_ms"] = json!(ms);
        }
        Ok(json!({"ok": true, "result": result, "remote_leader_proxy": true}))
    }

    fn owner_error(code: &str, text: &str) -> Result<Value, RemoteLeaderCallError> {
        Err(RemoteLeaderCallError::Owner(RemoteLeaderProxyError {
            code: Some(code.to_string()),
            text: text.to_string(),
        }))
    }

    fn hop_error(message: &str) -> Result<Value, RemoteLeaderCallError> {
        Err(RemoteLeaderCallError::Hop(message.to_string()))
    }

    /// Runs the loop to completion on the test thread. Once `script` is used
    /// up the owner answers "unsupported", so a loop that should have stopped
    /// earlier shows up as extra calls instead of hanging the suite.
    fn run_loop(
        script: Vec<Result<Value, RemoteLeaderCallError>>,
    ) -> (Vec<Value>, Vec<Value>, Vec<Duration>) {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut script = script.into_iter();
        let mut calls = Vec::new();
        let mut sleeps = Vec::new();
        owner_wake_loop(
            "alpha",
            INTERVAL,
            tx,
            |params| {
                calls.push(params);
                script
                    .next()
                    .unwrap_or_else(|| owner_error("method_not_allowed", "script exhausted"))
            },
            |pause| sleeps.push(pause),
        );
        (rx.try_iter().collect(), calls, sleeps)
    }

    #[test]
    fn owner_wake_step_table() {
        use OwnerWakeStep::*;
        let armed = cursor("e1", 3);
        for (name, prev, response, expected) in [
            ("first arm", None, answer("e1", 3, false), Rearm(cursor("e1", 3))),
            ("first arm ignores changed", None, answer("e1", 3, true), Rearm(cursor("e1", 3))),
            ("unchanged revision", Some(&armed), answer("e1", 3, false), Rearm(cursor("e1", 3))),
            ("higher revision", Some(&armed), answer("e1", 4, true), Wake(cursor("e1", 4))),
            ("cursor moved without flag", Some(&armed), answer("e1", 5, false), Wake(cursor("e1", 5))),
            ("epoch change", Some(&armed), answer("e2", 0, true), Wake(cursor("e2", 0))),
            ("rust host rejects", Some(&armed), hop_error("method_not_allowed: team.events.wait"), Unsupported),
            (
                "owner rejects on the PeerServer route",
                Some(&armed),
                owner_error(
                    "method_not_allowed",
                    "remote leader proxy [method_not_allowed]: team.events.wait is served only on the reverse leader route",
                ),
                Unsupported,
            ),
            (
                "old owner app",
                None,
                owner_error("invalid_method", "remote leader proxy [invalid_method]: remote leader command rejected"),
                Unsupported,
            ),
            (
                "owner text mentions the code under another code",
                Some(&armed),
                owner_error(
                    "host_error",
                    "remote leader proxy [host_error]: upstream said method_not_allowed [invalid_method]",
                ),
                Retry,
            ),
            (
                "hop text only contains the daemon refusal",
                Some(&armed),
                hop_error("relay failed: method_not_allowed: team.events.wait"),
                Retry,
            ),
            ("transport error", Some(&armed), hop_error("authorized peer viewer is not connected"), Retry),
            ("malformed result", Some(&armed), Ok(json!({"ok": true, "result": {}})), Retry),
            ("busy with a hint", Some(&armed), busy(Some(2500)), Backoff(Duration::from_millis(2500))),
            ("busy without a hint", Some(&armed), busy(None), Backoff(Duration::from_secs(1))),
            ("busy before arming", None, busy(Some(2500)), Backoff(Duration::from_millis(2500))),
            ("busy hint below the floor", Some(&armed), busy(Some(10)), Backoff(Duration::from_secs(1))),
            ("busy hint above the interval", Some(&armed), busy(Some(600_000)), Backoff(INTERVAL)),
        ] {
            assert_eq!(owner_wake_step(prev, response, INTERVAL), expected, "{name}");
        }
        assert_eq!(
            owner_wake_step(Some(&armed), busy(Some(5000)), Duration::ZERO),
            Backoff(Duration::from_secs(1)),
            "an interval below the floor still backs off by the floor"
        );
    }

    #[test]
    fn owner_wake_loop_sends_wake_on_a_higher_revision() {
        let (events, calls, _) = run_loop(vec![answer("e1", 3, false), answer("e1", 4, true)]);
        assert_eq!(
            events,
            vec![json!({"kind": "owner_wake", "epoch": "e1", "revision": 4})]
        );
        assert_eq!(calls[1]["since"], json!({"epoch": "e1", "revision": 3}));
        assert_eq!(calls[2]["since"], json!({"epoch": "e1", "revision": 4}));
    }

    #[test]
    fn owner_wake_loop_drops_the_sender_when_unsupported() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut calls = 0;
        owner_wake_loop(
            "alpha",
            INTERVAL,
            tx,
            |_| {
                calls += 1;
                hop_error("method_not_allowed: team.events.wait")
            },
            |_| {},
        );
        assert_eq!(calls, 1);
        assert_eq!(
            recv_push_or_interval(&rx, Duration::from_secs(5)),
            PushWait::Closed
        );
    }

    #[test]
    fn recv_push_or_interval_reports_closed_after_the_sender_drops() {
        let (tx, rx) = std::sync::mpsc::channel();
        assert_eq!(
            recv_push_or_interval(&rx, Duration::from_millis(20)),
            PushWait::Elapsed
        );
        tx.send(json!({"kind": "owner_wake"})).unwrap();
        assert_eq!(
            recv_push_or_interval(&rx, Duration::from_secs(5)),
            PushWait::Event(json!({"kind": "owner_wake"}))
        );
        drop(tx);
        assert_eq!(
            recv_push_or_interval(&rx, Duration::from_secs(5)),
            PushWait::Closed
        );
    }

    #[test]
    fn owner_wake_loop_gives_up_after_consecutive_retries() {
        let failures = (0..10)
            .map(|_| hop_error("authorized peer viewer is not connected"))
            .collect();
        let (events, calls, sleeps) = run_loop(failures);
        assert!(events.is_empty());
        assert_eq!(calls.len(), OWNER_WAKE_MAX_CONSECUTIVE_RETRIES as usize);
        assert_eq!(
            sleeps.iter().filter(|pause| **pause == INTERVAL).count(),
            OWNER_WAKE_MAX_CONSECUTIVE_RETRIES as usize - 1
        );
    }

    #[test]
    fn owner_wake_loop_resets_the_retry_budget_on_rearm() {
        let failure = || hop_error("authorized peer viewer is not connected");
        let (_, calls, _) = run_loop(vec![
            failure(),
            failure(),
            answer("e1", 3, false),
            failure(),
            failure(),
        ]);
        assert_eq!(
            calls.len(),
            6,
            "the loop must still be polling after the fifth answer"
        );
    }

    #[test]
    fn owner_wake_loop_resets_the_retry_budget_on_busy() {
        let failure = || hop_error("authorized peer viewer is not connected");
        let (_, calls, _) = run_loop(vec![
            failure(),
            failure(),
            busy(Some(1500)),
            failure(),
            failure(),
        ]);
        assert_eq!(
            calls.len(),
            6,
            "a busy answer reached the owner, so it is not a failure in a row"
        );
    }

    #[test]
    fn owner_wake_loop_backs_off_on_busy_without_moving_the_cursor() {
        let (events, calls, sleeps) = run_loop(vec![
            answer("e1", 3, false),
            busy(Some(2500)),
            answer("e1", 3, false),
        ]);
        assert!(events.is_empty());
        assert!(sleeps.contains(&Duration::from_millis(2500)));
        assert_eq!(calls[2]["since"], json!({"epoch": "e1", "revision": 3}));
    }

    #[test]
    fn owner_wake_params_carry_the_cursor_and_hold() {
        assert_eq!(
            owner_wake_params("alpha", None),
            json!({"team_name": "alpha", "since": null, "timeout_ms": 7000})
        );
        assert_eq!(
            owner_wake_params("alpha", Some(&cursor("e1", 9))),
            json!({
                "team_name": "alpha",
                "since": {"epoch": "e1", "revision": 9},
                "timeout_ms": 7000,
            })
        );
    }

    #[test]
    fn owner_wake_pause_spaces_long_poll_starts_by_a_second() {
        let start = Instant::now();
        assert_eq!(owner_wake_pause(None, start), Duration::ZERO);
        assert_eq!(owner_wake_pause(Some(start), start), Duration::from_secs(1));
        assert_eq!(
            owner_wake_pause(Some(start), start + Duration::from_millis(400)),
            Duration::from_millis(600)
        );
        assert_eq!(
            owner_wake_pause(Some(start), start + Duration::from_secs(8)),
            Duration::ZERO
        );
    }

    #[test]
    fn owner_wake_transport_outlives_the_owner_hold() {
        assert!(remote_leader_timeout(OWNER_WAKE_METHOD, OWNER_WAKE_HOLD) > OWNER_WAKE_HOLD);
        assert!(peer_proto::team_leader::scoped_method_allowed(
            OWNER_WAKE_METHOD
        ));
        assert_eq!(
            remote_leader_rpc_policy(true, OWNER_WAKE_METHOD),
            RemoteLeaderRpcPolicy::Proxy
        );
    }
}

#[cfg(test)]
mod wait_push_source_tests {
    use super::*;

    #[test]
    fn remote_leader_wait_does_not_subscribe_to_the_local_daemon() {
        use WaitPushSource::*;
        for (has_route, push_disabled, kinds_empty, expected) in [
            (false, false, false, LocalDaemon),
            (true, false, false, RemoteOwnerWake),
            (true, true, false, Disabled),
            (true, false, true, Disabled),
            (false, true, false, Disabled),
            (false, false, true, Disabled),
        ] {
            assert_eq!(
                wait_push_source(has_route, push_disabled, kinds_empty),
                expected,
                "route={has_route} disabled={push_disabled} kinds_empty={kinds_empty}"
            );
        }
    }
}

/// Tracked tasks a timed-out wait should be re-armed for. A task the list never
/// returned is still pending: absence is not completion.
pub(crate) fn wait_pending_tasks(
    tracked: &std::collections::HashSet<String>,
    statuses: &std::collections::HashMap<String, String>,
) -> Vec<String> {
    let mut pending: Vec<String> = tracked
        .iter()
        .filter(|id| {
            !statuses
                .get(*id)
                .is_some_and(|status| wait_task_settled(status))
        })
        .cloned()
        .collect();
    pending.sort();
    pending
}

pub(crate) fn run_wait(
    sock: &PathBuf,
    team: &str,
    timeout: u32,
    interval: u32,
    mode: &str,
    task_id: Option<&str>,
    agent_filter: &std::collections::HashSet<String>,
    explicit_task_ids: Option<&std::collections::HashSet<String>>,
) {
    // Prevent infinite loop: clamp interval to at least 1 second
    let interval = interval.max(1);
    let filter_label = if agent_filter.is_empty() {
        "all".to_string()
    } else {
        agent_filter.iter().cloned().collect::<Vec<_>>().join(",")
    };
    eprintln!("Waiting for agents in team '{team}' (timeout: {timeout}s, mode: {mode}, agents: {filter_label})...");
    let wait_leader_session = current_leader_session_id();
    let wait_log = if explicit_task_ids.is_some() || wait_leader_session.is_some() {
        let task_ids = explicit_task_ids
            .map(|ids| ids.iter().cloned().collect())
            .or_else(|| task_id.map(|id| vec![id.to_string()]))
            .unwrap_or_default();
        let wait_id = wait_id();
        let turn_id = turn_id_from_hook_state();
        append_wait_record(
            team,
            &wait_id,
            "start",
            None,
            &task_ids,
            mode,
            timeout,
            wait_leader_session.as_deref(),
            turn_id.as_deref(),
        );
        Some((wait_id, task_ids, wait_leader_session, turn_id))
    } else {
        None
    };
    macro_rules! finish_wait {
        ($outcome:expr) => {{
            if let Some((wait_id, task_ids, leader_session_id, turn_id)) = &wait_log {
                append_wait_record(
                    team,
                    wait_id,
                    "end",
                    Some($outcome),
                    task_ids,
                    mode,
                    timeout,
                    leader_session_id.as_deref(),
                    turn_id.as_deref(),
                );
            }
            return;
        }};
    }

    let (mut initial_task_ids, explicit_task_scope) =
        initialize_wait_task_scope(explicit_task_ids, task_id);
    let track_messages =
        mode == "msg" || (mode == "any" && messages_end_any_wait(explicit_task_scope));
    let needs_team_status = matches!(mode, "report" | "msg" | "any");
    let team_status = if needs_team_status {
        match rpc_call(sock, "team.status", json!({ "team_name": team })) {
            Ok(response) => Some(response),
            Err(error) => {
                eprintln!("wait: could not inspect team '{team}': {error}");
                if let Some((wait_id, task_ids, leader_session_id, turn_id)) = &wait_log {
                    append_wait_record(
                        team,
                        wait_id,
                        "end",
                        Some("error"),
                        task_ids,
                        mode,
                        timeout,
                        leader_session_id.as_deref(),
                        turn_id.as_deref(),
                    );
                }
                process::exit(1);
            }
        }
    } else {
        None
    };
    let status_agents = team_status
        .as_ref()
        .and_then(|response| response["result"]["agents"].as_array());
    let agent_names: Vec<String> = if track_messages {
        status_agents
            .into_iter()
            .flatten()
            .filter_map(|agent| agent["name"].as_str().map(String::from))
            .filter(|name| agent_filter.is_empty() || agent_filter.contains(name))
            .collect()
    } else {
        Vec::new()
    };
    let message_baseline: std::collections::HashSet<String> = if track_messages {
        rpc_call(sock, "team.message.list", json!({ "team_name": team }))
            .ok()
            .and_then(|response| response["result"]["messages"].as_array().cloned())
            .unwrap_or_default()
            .iter()
            .filter_map(|message| message["id"].as_str().map(String::from))
            .collect()
    } else {
        std::collections::HashSet::new()
    };

    // report/any can only make a meaningful decision when a task is known.
    // A plain broadcast has no task or correlation ID, so waiting for it used
    // to consume the entire timeout while displaying report=0/0. Fail before
    // subscribing or polling and point callers to the tracked healthcheck.
    let mut initial_tracked_agents = std::collections::HashSet::new();
    if matches!(mode, "report" | "any") && initial_task_ids.is_empty() {
        if let Some(agents) = status_agents {
            for agent in agents {
                let name = agent["name"].as_str().unwrap_or("");
                if !agent_filter.is_empty() && !agent_filter.contains(name) {
                    continue;
                }
                let status = agent["active_task_status"].as_str().unwrap_or("");
                let stale = agent["active_task_is_stale"].as_bool().unwrap_or(false);
                if stale || matches!(status, "completed" | "failed" | "abandoned" | "cancelled") {
                    continue;
                }
                if let Some(id) = agent["active_task_id"].as_str() {
                    initial_task_ids.insert(id.to_string());
                    if !name.is_empty() {
                        initial_tracked_agents.insert(name.to_string());
                    }
                }
            }
        }
        if initial_task_ids.is_empty() {
            eprintln!(
                "wait: mode '{mode}' has no task or correlation to track; plain broadcast replies cannot be matched. Use 'tm-agent warmup' for ping/pong healthchecks, 'tm-agent fan-out' for tracked work, or pass --tasks <ids>."
            );
            if let Some((wait_id, task_ids, leader_session_id, turn_id)) = &wait_log {
                append_wait_record(
                    team,
                    wait_id,
                    "end",
                    Some("error"),
                    task_ids,
                    mode,
                    timeout,
                    leader_session_id.as_deref(),
                    turn_id.as_deref(),
                );
            }
            process::exit(1);
        }
    }

    // B1: daemon push subscribe — eliminates 1-3s polling sleep when available.
    // Idle mode uses team.status (no matching event kind) so keep polling there.
    let push_disabled = env::var("TERMMESH_WAIT_PUSH_DISABLE")
        .map(|v| matches!(v.as_str(), "1" | "true" | "yes"))
        .unwrap_or(false);
    let subscribe_kinds: &[&str] = match mode {
        "report" | "any" => &["task_status", "reply"],
        "blocked" | "review_ready" => &["task_status"],
        _ => &[],
    };
    let push_source = wait_push_source(
        remote_leader_route().is_some(),
        push_disabled,
        subscribe_kinds.is_empty(),
    );
    let mut event_rx: Option<std::sync::mpsc::Receiver<Value>> = match push_source {
        WaitPushSource::Disabled => None,
        WaitPushSource::RemoteOwnerWake => {
            eprintln!("wait: remote leader — waking on owner events (long-poll)");
            Some(spawn_remote_owner_wake(
                sock.clone(),
                team.to_string(),
                interval,
            ))
        }
        // events.subscribe lives on the daemon socket, not the app socket.
        // Resolve it here so the caller's app `sock` is not misrouted.
        WaitPushSource::LocalDaemon => match detect_daemon_socket() {
            Some(ds) => match subscribe_events_channel(&ds, subscribe_kinds) {
                Ok(rx) => {
                    eprintln!(
                        "wait: subscribed to push events ({})",
                        subscribe_kinds.join(",")
                    );
                    Some(rx)
                }
                Err(e) => {
                    eprintln!("wait: subscribe failed: {e}; falling back to polling");
                    None
                }
            },
            None => {
                eprintln!("wait: daemon socket not found; using polling");
                None
            }
        },
    };

    let wait_started = std::time::Instant::now();
    let mut elapsed: u32 = 0;
    let mut current_interval: u64 = 0; // first poll is immediate (no sleep)
    let min_interval: u64 = 1;
    let max_interval: u64 = interval as u64;
    let mut prev_progress_count: usize = 0;
    // For report mode: snapshot task IDs on first poll so we can track them
    // even after agents drop active_task_id on completion.
    // If explicit --tasks are provided, use those directly (no auto-discovery).
    let mut tracked_task_ids = initial_task_ids;
    let mut tracked_initialized = !tracked_task_ids.is_empty();
    // Accumulating set of agents observed with an active task at any poll. Used by
    // the result.status fallback so it doesn't count team members who were never
    // delegated to in this round (the root cause of wait hangs on partial fan-out).
    let mut tracked_agents = initial_tracked_agents;
    // Last status seen per tracked task: the outcome word and the timeout
    // report come from here, not from another round of RPCs.
    let mut tracked_statuses: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    let mut stall_tasks: std::collections::HashMap<String, WaitTaskRef> =
        std::collections::HashMap::new();
    let mut stall_idle_since: std::collections::HashMap<String, Instant> =
        std::collections::HashMap::new();
    while elapsed < timeout {
        if current_interval > 0 {
            let pause = wait_pause(current_interval, wait_started, timeout);
            // B1: a push event ends the sleep early; a quiet stream keeps the
            // configured cadence.
            if let Some(ref rx) = event_rx {
                if recv_push_or_interval(rx, pause) == PushWait::Closed {
                    eprintln!("wait: subscribe stream closed; falling back to polling");
                    event_rx = None;
                }
            } else {
                thread::sleep(pause);
            }
            elapsed = wait_started.elapsed().as_secs() as u32;
        }
        let mut report_done = false;
        let mut report_progress = "0/0".to_string();
        let mut msg_done = false;
        let mut msg_progress = "0/0".to_string();

        if mode == "report" || mode == "any" {
            // Every poll: observe agents that currently have an active task and
            // accumulate both their task IDs and names. Re-running on each poll
            // (not just the first) closes the race where wait fires before
            // delegate's task is visible in team.status.
            // Explicit --task/--tasks correlation is closed: another task that
            // happens to be active must not extend this wait's completion set.
            if should_discover_wait_tasks(
                explicit_task_scope,
                tracked_initialized,
                tracked_agents.is_empty(),
            ) {
                if let Ok(r) = rpc_call(sock, "team.status", json!({ "team_name": team })) {
                    if let Some(agents) = r["result"]["agents"].as_array() {
                        for a in agents {
                            let name = a["name"].as_str().unwrap_or("");
                            if !agent_filter.is_empty() && !agent_filter.contains(name) {
                                continue;
                            }
                            if let Some(tid) = a["active_task_id"].as_str() {
                                let status = a["active_task_status"].as_str().unwrap_or("");
                                // Only track tasks that are currently active (not already done)
                                if matches!(status, "completed" | "failed" | "abandoned") {
                                    continue;
                                }
                                // Skip stale tasks from previous sessions — they'll never
                                // complete and would cause wait to hang forever.
                                let is_stale = a["active_task_is_stale"].as_bool().unwrap_or(false);
                                if is_stale {
                                    continue;
                                }
                                tracked_task_ids.insert(tid.to_string());
                                if !name.is_empty() {
                                    tracked_agents.insert(name.to_string());
                                }
                            }
                        }
                        if !tracked_task_ids.is_empty() {
                            tracked_initialized = true;
                        }
                    }
                }
            }

            if tracked_initialized && !tracked_task_ids.is_empty() {
                // Track by task IDs — immune to agents dropping active_task_id on completion
                if let Ok(r) = rpc_call(sock, "team.task.list", json!({ "team_name": team })) {
                    if let Some(tasks) = r["result"]["tasks"].as_array() {
                        let total = tracked_task_ids.len() as u64;
                        for task in tasks {
                            let tid = task["id"].as_str().unwrap_or("");
                            if !tracked_task_ids.contains(tid) {
                                continue;
                            }
                            let status = task["status"].as_str().unwrap_or("");
                            tracked_statuses.insert(tid.to_string(), status.to_string());
                            if let Some(task_ref) = WaitTaskRef::from_task(task) {
                                stall_tasks.insert(tid.to_string(), task_ref);
                            }
                        }
                        let done = wait_settled_count(&tracked_task_ids, &tracked_statuses);
                        report_done = total > 0 && done >= total;
                        report_progress = format!("{done}/{total}");
                    }
                }
            } else {
                // Fallback: result.status restricted to the agents we care about.
                // Precedence: explicit --agents filter > accumulated tracked_agents
                // > active_only (server-side filter to agents with non-terminal task).
                // This prevents wait from waiting on team members who were never
                // delegated to in this round (root cause of partial-fan-out hangs).
                let mut params = json!({ "team_name": team });
                if !agent_filter.is_empty() {
                    let names: Vec<String> = agent_filter.iter().cloned().collect();
                    params["agents"] = json!(names);
                } else if !tracked_agents.is_empty() {
                    let names: Vec<String> = tracked_agents.iter().cloned().collect();
                    params["agents"] = json!(names);
                } else {
                    params["active_only"] = json!(true);
                }
                if let Ok(rs) = rpc_call(sock, "team.result.status", params) {
                    let done = rs["result"]["completed"].as_u64().unwrap_or(0);
                    let total = rs["result"]["total"].as_u64().unwrap_or(0);
                    report_done = rs["result"]["all_done"].as_bool().unwrap_or(false);
                    report_progress = format!("{done}/{total}");
                }
            }
        }

        if track_messages {
            match rpc_call(sock, "team.message.list", json!({ "team_name": team })) {
                Ok(r) => {
                    if let Some(messages) = r["result"]["messages"].as_array() {
                        let senders: std::collections::HashSet<&str> = messages
                            .iter()
                            .filter(|message| {
                                message["id"]
                                    .as_str()
                                    .map(|id| !message_baseline.contains(id))
                                    .unwrap_or(false)
                            })
                            .filter_map(|message| message["from"].as_str())
                            .collect();
                        let reported = senders
                            .iter()
                            .filter(|sender| agent_names.iter().any(|agent| agent == **sender))
                            .count();
                        let total = agent_names.len();
                        msg_done = reported >= total && total > 0;
                        msg_progress = format!("{reported}/{total}");
                    }
                }
                Err(e) => eprintln!("  Warning: message.list RPC failed: {e}"),
            }
        }

        let mut inbox_blocked: Vec<Value> = Vec::new();
        let mut inbox_review: Vec<Value> = Vec::new();
        let mut task_status: Option<String> = None;
        let mut task_obj = json!(null);

        if mode == "blocked" || mode == "review_ready" || mode == "idle" || task_id.is_some() {
            if let Some(tid) = task_id {
                // Batch team.inbox + team.task.get into a single socket connection
                let p_inbox = serde_json::to_string(&json!({
                    "jsonrpc": "2.0", "id": 1,
                    "method": "team.inbox", "params": { "team_name": team }
                }))
                .unwrap_or_default();
                let p_task_get = serde_json::to_string(&json!({
                    "jsonrpc": "2.0", "id": 2,
                    "method": "team.task.get", "params": { "team_name": team, "task_id": tid }
                }))
                .unwrap_or_default();
                // rpc_batch only reaches the local socket; under a remote leader
                // route both methods must go through the proxy instead.
                let batched = if remote_leader_route().is_none() {
                    rpc_batch(sock, &[p_inbox, p_task_get]).ok()
                } else {
                    None
                };
                let (inbox_r, task_r) = match batched {
                    Some(mut results) if results.len() >= 2 => {
                        let tr = results.remove(1);
                        let ir = results.remove(0);
                        (Ok(ir), Ok(tr))
                    }
                    _ => (
                        rpc_call(sock, "team.inbox", json!({ "team_name": team })),
                        rpc_call(
                            sock,
                            "team.task.get",
                            json!({ "team_name": team, "task_id": tid }),
                        ),
                    ),
                };
                match inbox_r {
                    Ok(r) => {
                        if let Some(items) = r["result"]["items"].as_array() {
                            inbox_blocked = items
                                .iter()
                                .filter(|i| {
                                    i["kind"].as_str() == Some("task")
                                        && i["status"].as_str() == Some("blocked")
                                })
                                .cloned()
                                .collect();
                            inbox_review = items
                                .iter()
                                .filter(|i| {
                                    i["kind"].as_str() == Some("task")
                                        && i["status"].as_str() == Some("review_ready")
                                })
                                .cloned()
                                .collect();
                        }
                    }
                    Err(e) => eprintln!("  Warning: inbox RPC failed: {e}"),
                }
                match task_r {
                    Ok(r) => {
                        if r["ok"].as_bool().unwrap_or(false) {
                            task_obj = r["result"].clone();
                            task_status = task_obj["status"].as_str().map(String::from);
                            if let Some(task_ref) = WaitTaskRef::from_task(&task_obj) {
                                stall_tasks.insert(tid.to_string(), task_ref);
                            }
                        }
                    }
                    Err(e) => eprintln!("  Warning: task.get RPC failed for {tid}: {e}"),
                }
            } else {
                match rpc_call(sock, "team.inbox", json!({ "team_name": team })) {
                    Ok(r) => {
                        if let Some(items) = r["result"]["items"].as_array() {
                            inbox_blocked = items
                                .iter()
                                .filter(|i| {
                                    i["kind"].as_str() == Some("task")
                                        && i["status"].as_str() == Some("blocked")
                                })
                                .cloned()
                                .collect();
                            inbox_review = items
                                .iter()
                                .filter(|i| {
                                    i["kind"].as_str() == Some("task")
                                        && i["status"].as_str() == Some("review_ready")
                                })
                                .cloned()
                                .collect();
                        }
                    }
                    Err(e) => eprintln!("  Warning: inbox RPC failed: {e}"),
                }
            }
        }

        if let Some(tid) = task_id {
            let st = task_status.as_deref().unwrap_or("unknown");
            eprintln!("  [{elapsed}/{timeout}s] task={tid} status={st}");
            if wait_task_settled(st) {
                let task_obj = settle_uncommitted_check(
                    task_obj.clone(),
                    uncommitted_check_pending,
                    || {
                        rpc_call(
                            sock,
                            "team.task.get",
                            json!({ "team_name": team, "task_id": tid }),
                        )
                        .ok()
                        .filter(|r| r["ok"].as_bool().unwrap_or(false))
                        .map(|r| r["result"].clone())
                    },
                    uncommitted_check_budget(wait_started, timeout),
                    UNCOMMITTED_CHECK_POLL,
                );
                println!(
                    "{}",
                    pretty(&json!({ "result": { "team_name": team, "task": task_obj } }))
                );
                finish_wait!(wait_outcome_for_status(st));
            }
        }

        if explicit_task_scope && matches!(mode, "report" | "any") && !stall_tasks.is_empty() {
            if let Ok(r) = rpc_call(sock, "team.status", json!({ "team_name": team })) {
                let agents = r["result"]["agents"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                let stalled = update_wait_stall_tracker(
                    &stall_tasks,
                    &agents,
                    &mut stall_idle_since,
                    Instant::now(),
                    WAIT_STALL_GRACE,
                );
                if !stalled.is_empty() {
                    let items: Vec<Value> = stalled
                        .iter()
                        .map(|task| {
                            json!({
                                "task_id": task.task_id,
                                "assignee": task.assignee,
                                "status": task.status,
                                "idle_seconds": task.idle_seconds,
                            })
                        })
                        .collect();
                    eprintln!(
                        "An assignee has been idle for {}s or more with an unsettled task.",
                        WAIT_STALL_GRACE.as_secs()
                    );
                    println!(
                        "{}",
                        pretty(&json!({
                            "result": { "team_name": team, "outcome": "stalled", "stalled": items }
                        }))
                    );
                    finish_wait!("stalled");
                }
            }
        }

        match mode {
            "report" => {
                eprintln!("  [{elapsed}/{timeout}s] {report_progress} agents reported (report)");
                if report_done {
                    eprintln!("All agents have reported results.");
                    if let Some(filtered) = collect_settled_results(
                        sock,
                        team,
                        explicit_task_scope.then_some(&tracked_task_ids),
                        uncommitted_check_budget(wait_started, timeout),
                    ) {
                        println!("{}", pretty(&filtered));
                    }
                    finish_wait!(wait_report_outcome(
                        tracked_statuses.values().map(String::as_str)
                    ));
                }
            }
            "msg" => {
                eprintln!("  [{elapsed}/{timeout}s] {msg_progress} agents messaged (msg)");
                if msg_done {
                    eprintln!("All agents have posted messages.");
                    if let Ok(r) = rpc_call(sock, "team.message.list", json!({ "team_name": team }))
                    {
                        println!("{}", pretty(&r));
                    }
                    finish_wait!("completed");
                }
            }
            "any" => {
                if track_messages {
                    eprintln!(
                        "  [{elapsed}/{timeout}s] report={report_progress} msg={msg_progress} (any)"
                    );
                } else {
                    eprintln!("  [{elapsed}/{timeout}s] report={report_progress} (any, tasks)");
                }
                if report_done {
                    let outcome = if !inbox_blocked.is_empty() {
                        "blocked"
                    } else {
                        wait_report_outcome(tracked_statuses.values().map(String::as_str))
                    };
                    eprintln!("All tracked tasks have settled: {outcome}.");
                    if let Some(mut result) = collect_settled_results(
                        sock,
                        team,
                        explicit_task_scope.then_some(&tracked_task_ids),
                        uncommitted_check_budget(wait_started, timeout),
                    ) {
                        if result["result"].is_null() {
                            result["result"] = json!({});
                        }
                        if let Some(body) = result["result"].as_object_mut() {
                            body.insert("outcome".to_string(), json!(outcome));
                        }
                        println!("{}", pretty(&result));
                    }
                    finish_wait!(outcome);
                }
                if msg_done {
                    eprintln!("All agents have posted messages.");
                    if let Ok(r) = rpc_call(sock, "team.message.list", json!({ "team_name": team }))
                    {
                        println!("{}", pretty(&r));
                    }
                    finish_wait!("completed");
                }
            }
            "blocked" => {
                eprintln!("  [{elapsed}/{timeout}s] blocked={}", inbox_blocked.len());
                let items = if inbox_blocked.is_empty() {
                    Vec::new()
                } else {
                    settled_inbox_items(
                        sock,
                        team,
                        "blocked",
                        inbox_blocked.clone(),
                        uncommitted_check_budget(wait_started, timeout),
                    )
                };
                if !items.is_empty() {
                    eprintln!("A task is blocked.");
                    println!(
                        "{}",
                        pretty(&json!({
                            "result": { "team_name": team, "items": items, "count": items.len() }
                        }))
                    );
                    finish_wait!("blocked");
                }
            }
            "review_ready" => {
                eprintln!(
                    "  [{elapsed}/{timeout}s] review_ready={}",
                    inbox_review.len()
                );
                let items = if inbox_review.is_empty() {
                    Vec::new()
                } else {
                    settled_inbox_items(
                        sock,
                        team,
                        "review_ready",
                        inbox_review.clone(),
                        uncommitted_check_budget(wait_started, timeout),
                    )
                };
                if !items.is_empty() {
                    eprintln!("A task is ready for review.");
                    println!(
                        "{}",
                        pretty(&json!({
                            "result": { "team_name": team, "items": items, "count": items.len() }
                        }))
                    );
                    finish_wait!("review_ready");
                }
            }
            "idle" => {
                if let Ok(r) = rpc_call(sock, "team.status", json!({ "team_name": team })) {
                    if let Some(agents) = r["result"]["agents"].as_array() {
                        let filtered: Vec<&Value> = if agent_filter.is_empty() {
                            agents.iter().collect()
                        } else {
                            agents
                                .iter()
                                .filter(|a| {
                                    a["name"]
                                        .as_str()
                                        .map(|n| agent_filter.contains(n))
                                        .unwrap_or(false)
                                })
                                .collect()
                        };
                        let idle_count = filtered
                            .iter()
                            .filter(|a| a["agent_state"].as_str() == Some("idle"))
                            .count();
                        let active_count = filtered
                            .iter()
                            .filter(|a| {
                                matches!(
                                    a["agent_state"].as_str(),
                                    Some("running" | "blocked" | "review_ready")
                                )
                            })
                            .count();
                        let total = idle_count + active_count;
                        eprintln!("  [{elapsed}/{timeout}s] idle={idle_count}/{total}");
                        if total > 0 && idle_count == total {
                            let idle_agents: Vec<&&Value> = filtered
                                .iter()
                                .filter(|a| a["agent_state"].as_str() == Some("idle"))
                                .collect();
                            println!(
                                "{}",
                                pretty(&json!({
                                    "result": { "team_name": team, "agents": idle_agents, "count": idle_count }
                                }))
                            );
                            finish_wait!("completed");
                        }
                    }
                }
            }
            _ => {
                eprintln!("Unknown wait mode: {mode}");
                if let Some((wait_id, task_ids, leader_session_id, turn_id)) = &wait_log {
                    append_wait_record(
                        team,
                        wait_id,
                        "end",
                        Some("error"),
                        task_ids,
                        mode,
                        timeout,
                        leader_session_id.as_deref(),
                        turn_id.as_deref(),
                    );
                }
                process::exit(1);
            }
        }

        // Adaptive polling: speed up on progress, slow down on idle
        let current_progress_count: usize = {
            let r = report_progress
                .split('/')
                .next()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0usize);
            let m = msg_progress
                .split('/')
                .next()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0usize);
            r + m + inbox_blocked.len() + inbox_review.len()
        };
        if current_progress_count > prev_progress_count {
            current_interval = min_interval;
            prev_progress_count = current_progress_count;
        } else {
            current_interval = (current_interval + 1).min(max_interval);
        }
    }

    eprintln!("Timeout: not all agents reported within {timeout}s");
    if tracked_initialized && !tracked_task_ids.is_empty() {
        // The leader re-arms for `pending` only; a team-wide result.status
        // would hand it other waits' tasks.
        let pending = wait_pending_tasks(&tracked_task_ids, &tracked_statuses);
        let mut tasks: Vec<Value> = tracked_task_ids
            .iter()
            .map(|id| json!({ "id": id, "status": tracked_statuses.get(id) }))
            .collect();
        tasks.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
        println!(
            "{}",
            pretty(&json!({
                "result": { "team_name": team, "outcome": "timeout", "tasks": tasks, "pending": pending }
            }))
        );
    } else if let Ok(r) = rpc_call(sock, "team.result.status", json!({ "team_name": team })) {
        println!("{}", pretty(&r));
    }
    if let Some((wait_id, task_ids, leader_session_id, turn_id)) = &wait_log {
        append_wait_record(
            team,
            wait_id,
            "end",
            Some("timeout"),
            task_ids,
            mode,
            timeout,
            leader_session_id.as_deref(),
            turn_id.as_deref(),
        );
    }
    process::exit(1);
}

pub(crate) fn wait_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let pid = process::id() as u128;
    format!(
        "{:08x}-{:04x}-4{:03x}-8{:03x}-{:012x}",
        (nanos >> 96) as u32,
        (nanos >> 80) as u16,
        ((nanos >> 68) as u16) & 0x0fff,
        ((nanos >> 56) as u16) & 0x0fff,
        (nanos ^ pid) & 0xffffffffffff
    )
}

pub(crate) fn wait_outcome_for_status(status: &str) -> &'static str {
    match status {
        "blocked" => "blocked",
        "review_ready" => "review_ready",
        "completed" => "completed",
        "failed" => "failed",
        "cancelled" => "cancelled",
        _ => "error",
    }
}

pub(crate) fn append_wait_record(
    team: &str,
    wait_id: &str,
    phase: &str,
    outcome: Option<&str>,
    task_ids: &[String],
    mode: &str,
    timeout: u32,
    leader_session_id: Option<&str>,
    turn_id: Option<&str>,
) {
    let Ok(path) = turn_log_path() else { return };
    let mut record = json!({"event":"leader_wait","phase":phase,"wait_id":wait_id,"task_ids":task_ids,"mode":mode,"timeout_s":timeout,"team":team,"ts":iso8601_utc_now()});
    if let Some(outcome) = outcome {
        record["outcome"] = json!(outcome);
    }
    if let Some(session) = leader_session_id {
        record["leader_session_id"] = json!(session);
    }
    if let Some(turn_id) = turn_id {
        record["turn_id"] = json!(turn_id);
    }
    let _ = append_turn_record(&path, &record);
}

#[cfg(test)]
mod wait_task_scope_tests {
    use super::*;

    #[test]
    fn explicit_tasks_form_a_closed_wait_scope() {
        let explicit = std::collections::HashSet::from(["requested-task".to_string()]);
        let (scope, is_explicit) = initialize_wait_task_scope(Some(&explicit), None);

        assert!(is_explicit);
        assert_eq!(scope, explicit);
        assert!(!should_discover_wait_tasks(is_explicit, true, true));
    }

    #[test]
    fn single_task_argument_forms_a_closed_wait_scope() {
        let (scope, is_explicit) = initialize_wait_task_scope(None, Some("requested-task"));

        assert!(is_explicit);
        assert_eq!(
            scope,
            std::collections::HashSet::from(["requested-task".to_string()])
        );
        assert!(!should_discover_wait_tasks(is_explicit, true, true));
    }

    #[test]
    fn given_but_empty_task_arguments_are_rejected() {
        for tasks in ["", ",", " , ,"] {
            assert!(
                parse_wait_task_arguments(Some(tasks), None).is_err(),
                "{tasks:?}"
            );
        }
        for task in ["", "  "] {
            assert!(
                parse_wait_task_arguments(None, Some(task)).is_err(),
                "{task:?}"
            );
        }
    }

    #[test]
    fn task_and_tasks_together_are_rejected() {
        for (tasks, task) in [("a,b", "x"), ("a", "a"), ("", "x"), (",", "")] {
            let error = parse_wait_task_arguments(Some(tasks), Some(task)).unwrap_err();
            assert!(error.contains("--tasks"), "{tasks:?} {task:?}: {error}");
        }
    }

    #[test]
    fn omitted_or_populated_task_arguments_are_accepted() {
        assert_eq!(parse_wait_task_arguments(None, None), Ok(None));
        assert_eq!(
            parse_wait_task_arguments(Some(" a, b ,,"), None),
            Ok(Some(std::collections::HashSet::from([
                "a".to_string(),
                "b".to_string()
            ])))
        );
        assert_eq!(parse_wait_task_arguments(None, Some("a")), Ok(None));
    }

    #[test]
    fn absent_task_arguments_allow_active_task_discovery() {
        let (scope, is_explicit) = initialize_wait_task_scope(None, None);

        assert!(!is_explicit);
        assert!(scope.is_empty());
        assert!(should_discover_wait_tasks(is_explicit, false, true));
    }
}

#[cfg(test)]
mod wait_any_scope_tests {
    use super::*;

    fn task_with_check(state: &str) -> Value {
        json!({ "id": "t1", "status": "review_ready", "uncommitted_check": { "state": state } })
    }

    #[test]
    fn a_settled_wait_rereads_a_pending_uncommitted_check_until_it_lands() {
        let mut reads = vec![task_with_check("checked"), task_with_check("pending")];
        let settled = settle_uncommitted_check(
            task_with_check("pending"),
            uncommitted_check_pending,
            || reads.pop(),
            Duration::from_secs(5),
            Duration::ZERO,
        );
        assert_eq!(settled["uncommitted_check"]["state"], "checked");
        assert!(reads.is_empty());
    }

    #[test]
    fn a_check_that_never_lands_ends_the_reread_at_the_budget() {
        let mut calls = 0;
        let settled = settle_uncommitted_check(
            task_with_check("pending"),
            uncommitted_check_pending,
            || {
                calls += 1;
                None
            },
            Duration::from_millis(30),
            Duration::from_millis(5),
        );
        assert_eq!(settled["uncommitted_check"]["state"], "pending");
        assert!(calls >= 1);
    }

    #[test]
    fn a_task_without_a_pending_check_is_returned_without_a_reread() {
        for task in [
            task_with_check("checked"),
            task_with_check("skipped"),
            json!({ "id": "t1", "status": "blocked", "uncommitted_check": null }),
            json!({ "id": "t1", "status": "blocked" }),
        ] {
            let settled = settle_uncommitted_check(
                task.clone(),
                uncommitted_check_pending,
                || panic!("no re-read expected"),
                Duration::from_secs(5),
                Duration::ZERO,
            );
            assert_eq!(settled, task);
        }
    }

    #[test]
    fn inbox_task_items_keep_only_tasks_in_the_waited_status() {
        let response = json!({ "result": { "items": [
            { "kind": "task", "status": "review_ready", "task_id": "a" },
            { "kind": "task", "status": "blocked", "task_id": "b" },
            { "kind": "message", "status": "review_ready", "task_id": "c" },
        ] } });
        let items = inbox_task_items(&response, "review_ready");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["task_id"], "a");
        assert!(inbox_task_items(&json!({ "result": null }), "blocked").is_empty());
    }

    #[test]
    fn a_poll_pause_ends_at_the_wait_timeout() {
        let started = Instant::now() - Duration::from_millis(1500);
        assert!(wait_pause(10, started, 2) <= Duration::from_millis(500));
        assert_eq!(wait_pause(10, started, 1), Duration::ZERO);
        assert_eq!(wait_pause(3, Instant::now(), 3600), Duration::from_secs(3));
    }

    #[test]
    fn the_uncommitted_check_reread_never_outlasts_the_wait_timeout() {
        let started = Instant::now();
        assert_eq!(uncommitted_check_budget(started, 0), Duration::ZERO);
        assert!(uncommitted_check_budget(started, 1) <= Duration::from_secs(1));
        assert_eq!(
            uncommitted_check_budget(started, 3600),
            UNCOMMITTED_CHECK_SETTLE
        );
        let long_ago = Instant::now() - Duration::from_secs(10);
        assert_eq!(uncommitted_check_budget(long_ago, 5), Duration::ZERO);
    }

    #[test]
    fn a_successful_inbox_reread_drops_a_task_that_left_the_status() {
        let moved_on = Ok(json!({ "result": { "items": [
            { "kind": "task", "status": "in_progress", "task_id": "a" },
        ] } }));
        assert_eq!(inbox_reread(moved_on, "review_ready"), Some(json!([])));
        assert_eq!(inbox_reread(Err("socket".into()), "review_ready"), None);
    }

    #[test]
    fn a_collect_with_any_pending_result_is_pending() {
        let pending = json!({ "result": { "results": [
            { "task_id": "a", "uncommitted_check": { "state": "checked" } },
            { "task_id": "b", "uncommitted_check": { "state": "pending" } },
        ] } });
        let settled = json!({ "result": { "results": [
            { "task_id": "a", "uncommitted_check": { "state": "checked" } },
            { "task_id": "b", "uncommitted_check": null },
        ] } });
        assert!(collect_has_pending_uncommitted_check(&pending));
        assert!(!collect_has_pending_uncommitted_check(&settled));
        assert!(!collect_has_pending_uncommitted_check(
            &json!({ "result": null })
        ));
    }

    #[test]
    fn failed_and_cancelled_tasks_settle_a_tracked_wait() {
        for status in [
            "completed",
            "review_ready",
            "blocked",
            "failed",
            "cancelled",
        ] {
            assert!(wait_task_settled(status), "{status}");
        }
        // `abandoned` is not a TaskStatus the daemon accepts; it was a stale
        // name in the single-task exit.
        for status in ["pending", "assigned", "in_progress", "abandoned", ""] {
            assert!(!wait_task_settled(status), "{status:?}");
        }
    }

    #[test]
    fn messages_end_any_only_without_a_task_scope() {
        assert!(!messages_end_any_wait(true));
        assert!(messages_end_any_wait(false));
    }

    fn stall_task(assignee: &str, instance: Option<&str>, status: &str) -> WaitTaskRef {
        WaitTaskRef {
            assignee: assignee.to_string(),
            agent_instance_id: instance.map(String::from),
            status: status.to_string(),
        }
    }

    fn native_agent(name: &str, instance: &str, in_flight: bool) -> Value {
        json!({
            "name": name,
            "agent_instance_id": instance,
            "agent_state": if in_flight { "running" } else { "idle" },
            "turn_tracked": true,
            "turn_in_flight": in_flight,
        })
    }

    fn one_task(task: WaitTaskRef) -> std::collections::HashMap<String, WaitTaskRef> {
        std::collections::HashMap::from([("t1".to_string(), task)])
    }

    fn stalls_now(agent: Value) -> bool {
        let tasks = one_task(stall_task("reviewer", None, "assigned"));
        let mut since = std::collections::HashMap::new();
        !update_wait_stall_tracker(&tasks, &[agent], &mut since, Instant::now(), Duration::ZERO)
            .is_empty()
    }

    #[test]
    fn stall_is_reported_only_after_the_grace_elapses() {
        let tasks = one_task(stall_task("reviewer", None, "assigned"));
        let agents = vec![native_agent("reviewer", "r1", false)];
        let mut since = std::collections::HashMap::new();
        let start = Instant::now();
        let grace = Duration::from_secs(90);

        assert!(update_wait_stall_tracker(&tasks, &agents, &mut since, start, grace).is_empty());
        let before = start + Duration::from_secs(89);
        assert!(update_wait_stall_tracker(&tasks, &agents, &mut since, before, grace).is_empty());
        let after = start + Duration::from_secs(90);
        let stalled = update_wait_stall_tracker(&tasks, &agents, &mut since, after, grace);
        assert_eq!(
            stalled,
            vec![StalledWaitTask {
                task_id: "t1".to_string(),
                assignee: "reviewer".to_string(),
                status: "assigned".to_string(),
                idle_seconds: 90,
            }]
        );
    }

    #[test]
    fn a_turn_in_flight_resets_the_stall_timer() {
        let tasks = one_task(stall_task("reviewer", None, "in_progress"));
        let idle = vec![native_agent("reviewer", "r1", false)];
        let running = vec![native_agent("reviewer", "r1", true)];
        let mut since = std::collections::HashMap::new();
        let start = Instant::now();
        let grace = Duration::from_secs(90);

        update_wait_stall_tracker(&tasks, &idle, &mut since, start, grace);
        let mid = start + Duration::from_secs(60);
        update_wait_stall_tracker(&tasks, &running, &mut since, mid, grace);
        let later = start + Duration::from_secs(120);
        assert!(update_wait_stall_tracker(&tasks, &idle, &mut since, later, grace).is_empty());
        let end = later + Duration::from_secs(90);
        assert_eq!(
            update_wait_stall_tracker(&tasks, &idle, &mut since, end, grace).len(),
            1
        );
    }

    #[test]
    fn only_a_tracked_turn_that_ended_or_a_parked_agent_counts_as_stalled() {
        assert!(stalls_now(native_agent("reviewer", "r1", false)));
        assert!(!stalls_now(native_agent("reviewer", "r1", true)));
        // A started task reads `running` on the board after the turn ended;
        // the turn signal still says nobody is working it.
        let mut started = native_agent("reviewer", "r1", false);
        started["agent_state"] = json!("running");
        assert!(stalls_now(started));
        let mut stale = native_agent("reviewer", "r1", false);
        stale["agent_state"] = json!("assigned_stale");
        assert!(stalls_now(stale));
        assert!(stalls_now(json!({
            "name": "reviewer", "agent_instance_id": "r1", "agent_state": "parked",
        })));
    }

    #[test]
    fn an_agent_without_a_turn_signal_is_never_stalled() {
        // Terminal and headless agents read `idle` while they work.
        assert!(!stalls_now(json!({
            "name": "reviewer", "agent_instance_id": "r1", "agent_state": "idle",
            "turn_tracked": false,
        })));
        // An app that predates these fields says nothing either way.
        assert!(!stalls_now(json!({
            "name": "reviewer", "agent_instance_id": "r1", "agent_state": "idle",
        })));
    }

    #[test]
    fn an_unknown_assignee_or_settled_task_is_never_stalled() {
        let grace = Duration::ZERO;
        let mut since = std::collections::HashMap::new();
        let absent = one_task(stall_task("ghost", None, "assigned"));
        let agents = vec![native_agent("reviewer", "r1", false)];
        assert!(
            update_wait_stall_tracker(&absent, &agents, &mut since, Instant::now(), grace)
                .is_empty()
        );

        let settled = one_task(stall_task("reviewer", None, "completed"));
        assert!(
            update_wait_stall_tracker(&settled, &agents, &mut since, Instant::now(), grace)
                .is_empty()
        );
        assert!(since.is_empty());
    }

    #[test]
    fn the_instance_id_selects_between_agents_that_share_a_name() {
        let grace = Duration::ZERO;
        let agents = vec![
            native_agent("reviewer", "r1", true),
            native_agent("reviewer", "r2", false),
        ];
        let mut since = std::collections::HashMap::new();
        let busy = one_task(stall_task("reviewer", Some("r1"), "assigned"));
        assert!(
            update_wait_stall_tracker(&busy, &agents, &mut since, Instant::now(), grace).is_empty()
        );
        let quiet = one_task(stall_task("reviewer", Some("r2"), "assigned"));
        assert_eq!(
            update_wait_stall_tracker(&quiet, &agents, &mut since, Instant::now(), grace).len(),
            1
        );
    }

    #[test]
    fn a_task_without_an_assignee_is_not_tracked() {
        assert_eq!(
            WaitTaskRef::from_task(&json!({ "status": "assigned" })),
            None
        );
        assert_eq!(
            WaitTaskRef::from_task(&json!({
                "assignee": "reviewer",
                "agent_instance_id": "",
                "status": "assigned",
            })),
            Some(stall_task("reviewer", None, "assigned"))
        );
    }

    #[test]
    fn explicit_task_scope_filters_old_collect_results() {
        let tracked = std::collections::HashSet::from(["requested".to_string()]);
        let response = json!({
            "ok": true,
            "result": {
                "results": [
                    {"task_id": "old", "content": "old result"},
                    {"task_id": "requested", "content": "requested result"},
                    {"content": "uncorrelated result"}
                ]
            }
        });

        let filtered = filter_result_collect_response(response, Some(&tracked));
        let results = filtered["result"]["results"].as_array().unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["task_id"], "requested");
    }

    #[test]
    fn unscoped_collect_results_are_preserved() {
        let response = json!({
            "result": {
                "results": [
                    {"task_id": "old"},
                    {"task_id": "requested"}
                ]
            }
        });
        let filtered = filter_result_collect_response(response.clone(), None);
        assert_eq!(filtered, response);
    }

    #[test]
    fn blocked_outranks_failed_outranks_completed() {
        assert_eq!(wait_report_outcome(["completed", "completed"]), "completed");
        assert_eq!(wait_report_outcome(["completed", "failed"]), "failed");
        assert_eq!(
            wait_report_outcome(["failed", "blocked", "completed"]),
            "blocked"
        );
        assert_eq!(wait_report_outcome(std::iter::empty::<&str>()), "completed");
    }

    #[test]
    fn a_settled_task_that_leaves_the_list_still_counts_as_done() {
        let tracked = std::collections::HashSet::from([
            "gone".to_string(),
            "running".to_string(),
            "unseen".to_string(),
        ]);
        let mut statuses = std::collections::HashMap::from([
            ("gone".to_string(), "completed".to_string()),
            ("running".to_string(), "in_progress".to_string()),
        ]);
        assert_eq!(wait_settled_count(&tracked, &statuses), 1);
        assert_eq!(
            wait_pending_tasks(&tracked, &statuses),
            vec!["running", "unseen"]
        );

        statuses.insert("running".to_string(), "failed".to_string());
        assert_eq!(wait_settled_count(&tracked, &statuses), 2);
        statuses.insert("unseen".to_string(), "cancelled".to_string());
        assert_eq!(wait_settled_count(&tracked, &statuses), 3);
        assert!(wait_pending_tasks(&tracked, &statuses).is_empty());
    }

    #[test]
    fn timeout_reports_tracked_tasks_that_have_not_settled() {
        let tracked = std::collections::HashSet::from([
            "done".to_string(),
            "running".to_string(),
            "unseen".to_string(),
        ]);
        let statuses = std::collections::HashMap::from([
            ("done".to_string(), "failed".to_string()),
            ("running".to_string(), "in_progress".to_string()),
        ]);
        assert_eq!(
            wait_pending_tasks(&tracked, &statuses),
            vec!["running", "unseen"]
        );
    }
}

#[cfg(test)]
mod rwait_tests {
    use super::*;

    #[test]
    fn maps_terminal_task_statuses_to_wait_outcomes() {
        assert_eq!(wait_outcome_for_status("completed"), "completed");
        assert_eq!(wait_outcome_for_status("review_ready"), "review_ready");
        assert_eq!(wait_outcome_for_status("blocked"), "blocked");
        assert_eq!(wait_outcome_for_status("failed"), "failed");
        assert_eq!(wait_outcome_for_status("cancelled"), "cancelled");
        assert_eq!(wait_outcome_for_status("abandoned"), "error");
    }
}
