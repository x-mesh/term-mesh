use super::*;

pub(crate) fn run_xmb_bridge(sock: &PathBuf, timeout_secs: u32, leader_session: Option<&str>) {
    eprintln!("[xmb-bridge] starting (timeout: {timeout_secs}s)");
    let mut handled = 0_u64;
    stream_events(sock, timeout_secs, &["reply"], leader_session, |event| {
        if let Err(e) = handle_xmb_reply_event(event, &mut handled) {
            eprintln!("[xmb-bridge] warning: {e}");
        }
    });
    eprintln!("[xmb-bridge] stopped (updates: {handled})");
}

pub(crate) fn handle_xmb_reply_event(event: Value, handled: &mut u64) -> Result<(), String> {
    if event.get("kind").and_then(Value::as_str) != Some("reply") {
        return Ok(());
    }
    let Some(header) = event.get("header").and_then(Value::as_str) else {
        return Ok(());
    };
    let Some(parsed) = parse_xmb_header(header) else {
        return Ok(());
    };
    let Some(xmb_status) = xmb_status_for_protocol_status(&parsed.status) else {
        eprintln!(
            "[xmb-bridge] skip {} / {}: unsupported STATUS {}",
            parsed.project, parsed.task_id, parsed.status
        );
        return Ok(());
    };

    let tasks_path = resolve_xmb_tasks_path(&parsed.project)?;
    let outcome = update_xmb_task_status(&tasks_path, &parsed.task_id, xmb_status)?;
    match outcome {
        XmbUpdateOutcome::Updated { old_status } => {
            *handled += 1;
            eprintln!(
                "[xmb-bridge] {} / {}: {} -> {}",
                parsed.project, parsed.task_id, old_status, xmb_status
            );
        }
        XmbUpdateOutcome::SkippedSameStatus => {
            eprintln!(
                "[xmb-bridge] {} / {}: already {}",
                parsed.project, parsed.task_id, xmb_status
            );
        }
    }
    Ok(())
}

pub(crate) fn stream_events<F>(
    sock: &PathBuf,
    timeout_secs: u32,
    kinds: &[&str],
    leader_session: Option<&str>,
    mut on_event: F,
) where
    F: FnMut(Value),
{
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "events.subscribe",
        "params": {
            "kinds": kinds,
            "timeout": if timeout_secs > 0 { Some(timeout_secs as u64) } else { None::<u64> },
            "leader_session_id": leader_session,
        },
    });

    let stream = match UnixStream::connect(sock) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: cannot connect to daemon socket: {e}");
            process::exit(1);
        }
    };

    let read_timeout_secs: u64 = if timeout_secs > 0 {
        (timeout_secs as u64).saturating_add(10)
    } else {
        90
    };
    stream
        .set_read_timeout(Some(Duration::from_secs(read_timeout_secs)))
        .ok();
    stream.set_write_timeout(Some(Duration::from_secs(10))).ok();

    let mut writer = match stream.try_clone() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: socket clone failed: {e}");
            process::exit(1);
        }
    };

    let mut payload = serde_json::to_string(&request).expect("request serialization cannot fail");
    payload.push('\n');
    if let Err(e) = writer.write_all(payload.as_bytes()) {
        eprintln!("error: failed to send subscribe request: {e}");
        process::exit(1);
    }
    writer.flush().ok();

    let mut reader = BufReader::new(&stream);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {
                let trimmed = line.trim_end_matches('\n').trim_end_matches('\r');
                if trimmed.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(trimmed) {
                    Ok(value) if value.get("kind").is_some() => on_event(value),
                    Ok(_) => {}
                    Err(e) => eprintln!("[events] invalid JSONL event: {e}"),
                }
            }
            Err(e) => {
                use std::io::ErrorKind;
                match e.kind() {
                    ErrorKind::WouldBlock | ErrorKind::TimedOut => {
                        if timeout_secs > 0 {
                            eprintln!("[events] read timeout; exiting");
                            break;
                        }
                        continue;
                    }
                    _ => {
                        eprintln!("[events] stream error: {e}");
                        break;
                    }
                }
            }
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct XmbHeader {
    status: String,
    project: String,
    task_id: String,
}

pub(crate) fn parse_xmb_header(header: &str) -> Option<XmbHeader> {
    let mut status = None;
    let mut task = None;
    for line in header.lines() {
        let trimmed = line.trim();
        if let Some(value) = trimmed.strip_prefix("STATUS:") {
            status = Some(value.trim().to_ascii_uppercase());
        } else if let Some(value) = trimmed.strip_prefix("XMB_TASK:") {
            task = parse_xmb_task_ref(value.trim());
        }
    }
    let (project, task_id) = task?;
    Some(XmbHeader {
        status: status?,
        project,
        task_id,
    })
}

pub(crate) fn parse_xmb_task_ref(value: &str) -> Option<(String, String)> {
    let (project, task_id) = value.split_once('/')?;
    if !is_valid_xmb_project(project) || !is_valid_xmb_task_id(task_id) {
        return None;
    }
    Some((project.to_string(), task_id.to_string()))
}

pub(crate) fn is_valid_xmb_project(project: &str) -> bool {
    !project.is_empty()
        && project
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

pub(crate) fn is_valid_xmb_task_id(task_id: &str) -> bool {
    let Some(rest) = task_id.strip_prefix('t') else {
        return false;
    };
    !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit())
}

pub(crate) fn xmb_status_for_protocol_status(status: &str) -> Option<&'static str> {
    match status {
        "DONE" => Some("completed"),
        "BLOCKED" => Some("blocked"),
        "NEEDS_REVIEW" => Some("review_ready"),
        "FAILED" => Some("failed"),
        _ => None,
    }
}

pub(crate) fn resolve_xmb_tasks_path(project: &str) -> Result<PathBuf, String> {
    let cwd = env::current_dir().map_err(|e| format!("current_dir: {e}"))?;
    let rel = Path::new(".xm")
        .join("build")
        .join("projects")
        .join(project)
        .join("phases")
        .join("02-plan")
        .join("tasks.json");
    let local = cwd.join(&rel);
    if local.exists() {
        return Ok(local);
    }
    if let Some(root) = git_root(&cwd) {
        let rooted = root.join(&rel);
        if rooted.exists() {
            return Ok(rooted);
        }
    }
    Err(format!(
        "tasks.json not found for project {project} from {}",
        cwd.display()
    ))
}

pub(crate) fn git_root(cwd: &Path) -> Option<PathBuf> {
    let output = std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(cwd)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let root = String::from_utf8(output.stdout).ok()?;
    let root = root.trim();
    if root.is_empty() {
        None
    } else {
        Some(PathBuf::from(root))
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum XmbUpdateOutcome {
    Updated { old_status: String },
    SkippedSameStatus,
}

pub(crate) fn update_xmb_task_status(
    tasks_path: &Path,
    task_id: &str,
    status: &str,
) -> Result<XmbUpdateOutcome, String> {
    let text = fs::read_to_string(tasks_path)
        .map_err(|e| format!("read {}: {e}", tasks_path.display()))?;
    let mut doc: Value =
        serde_json::from_str(&text).map_err(|e| format!("parse {}: {e}", tasks_path.display()))?;
    let tasks = doc
        .get_mut("tasks")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| format!("{}: missing tasks array", tasks_path.display()))?;
    let task = tasks
        .iter_mut()
        .find(|task| task.get("id").and_then(Value::as_str) == Some(task_id))
        .ok_or_else(|| format!("task {task_id} not found in {}", tasks_path.display()))?;

    let old_status = task
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    if old_status == status {
        return Ok(XmbUpdateOutcome::SkippedSameStatus);
    }

    task["status"] = json!(status);
    let now = iso8601_utc_now();
    match status {
        "completed" => task["completed_at"] = json!(now),
        "blocked" | "review_ready" | "failed" => task["updated_at"] = json!(now),
        _ => {}
    }

    let rendered = serde_json::to_string_pretty(&doc)
        .map_err(|e| format!("serialize {}: {e}", tasks_path.display()))?;
    write_atomic(tasks_path, &(rendered + "\n"))?;
    Ok(XmbUpdateOutcome::Updated { old_status })
}

pub(crate) fn write_atomic(path: &Path, content: &str) -> Result<(), String> {
    let dir = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    let filename = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("tasks.json");
    let tmp = dir.join(format!(".{filename}.tmp"));
    fs::write(&tmp, content).map_err(|e| format!("write {}: {e}", tmp.display()))?;
    fs::rename(&tmp, path)
        .map_err(|e| format!("rename {} -> {}: {e}", tmp.display(), path.display()))
}

pub(crate) fn iso8601_utc_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let (year, month, day, hour, min, sec) = unix_ts_to_ymd_hms(now);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{min:02}:{sec:02}Z")
}

// ── xk-bridge: daemon events → x-kit .xm writeback ───────────────────
// Generalizes xmb-bridge. Contract: x-kit docs/term-mesh-integration.md.
// Reply headers carry `XK_TASK: <plugin>/<project>/<ref>` (+ optional
// `XK_CORR: ce-XXXXXXXX`); legacy `XMB_TASK: <project>/<tid>` still maps to
// plugin "build". Writeback targets: x-build tasks.json transitions, the
// active .xm/traces/*.jsonl session, and .xm/metrics/sessions.jsonl.

pub(crate) struct XkBridgeState {
    handled: u64,
    /// (plugin/project/ref, status) pairs already applied — idempotency guard.
    seen: std::collections::HashSet<(String, String)>,
    xm_root: Option<PathBuf>,
    /// T2 xk_run mirroring: panel run id → mirrored board task id.
    panel_tasks: std::collections::HashMap<String, String>,
    /// (run, board status) transitions already applied — duplicate/out-of-order guard.
    panel_applied: std::collections::HashSet<(String, String)>,
    /// Swift app socket for `team.task.*` board mirroring; None → mirroring disabled.
    app_sock: Option<PathBuf>,
    /// Team whose task board mirrors panel runs.
    team: String,
}

pub(crate) fn run_xk_bridge(sock: &PathBuf, timeout_secs: u32, leader_session: Option<&str>) {
    eprintln!("[xk-bridge] starting (timeout: {timeout_secs}s)");
    let xm_root = resolve_xk_xm_root();
    match &xm_root {
        Some(p) => eprintln!("[xk-bridge] .xm root: {}", p.display()),
        None => {
            eprintln!(
            "[xk-bridge] warning: no .xm directory found from {} — trace/metric writeback disabled",
            env::current_dir().map(|p| p.display().to_string()).unwrap_or_default()
        )
        }
    }
    // T2: xk_run (x-panel run telemetry, XK-EVENTS-v1) is mirrored onto the team
    // task board so a leader `tm-agent wait`s on a panel instead of polling files.
    // Board mutations go over the APP socket (team.task.* is Swift-served) — its
    // absence disables mirroring only; .xm writeback keeps working.
    let app_sock = detect_socket();
    if app_sock.is_none() {
        eprintln!("[xk-bridge] warning: no app socket — xk_run task-board mirroring disabled");
    }
    let team = resolve_team_name(None);
    let mut state = XkBridgeState {
        handled: 0,
        seen: std::collections::HashSet::new(),
        xm_root,
        panel_tasks: std::collections::HashMap::new(),
        panel_applied: std::collections::HashSet::new(),
        app_sock,
        team,
    };
    stream_events(
        sock,
        timeout_secs,
        &["reply", "task_status", "xk_run"],
        leader_session,
        |event| {
            if let Err(e) = handle_xk_event(event, &mut state) {
                eprintln!("[xk-bridge] warning: {e}");
            }
        },
    );
    eprintln!("[xk-bridge] stopped (updates: {})", state.handled);
}

pub(crate) fn handle_xk_event(event: Value, state: &mut XkBridgeState) -> Result<(), String> {
    match event.get("kind").and_then(Value::as_str) {
        Some("reply") => handle_xk_reply(&event, state),
        Some("task_status") => handle_xk_task_status(&event, state),
        Some("xk_run") => handle_xk_run(&event, state),
        _ => Ok(()),
    }
}

pub(crate) fn handle_xk_reply(event: &Value, state: &mut XkBridgeState) -> Result<(), String> {
    let Some(header) = event.get("header").and_then(Value::as_str) else {
        return Ok(());
    };
    let Some(parsed) = parse_xk_header(header) else {
        return Ok(());
    };
    let task_ref_full = format!("{}/{}/{}", parsed.plugin, parsed.project, parsed.task_ref);
    if !state
        .seen
        .insert((task_ref_full.clone(), parsed.status.clone()))
    {
        return Ok(()); // same (ref, status) already applied
    }
    let Some(xk_status) = xmb_status_for_protocol_status(&parsed.status) else {
        eprintln!(
            "[xk-bridge] skip {task_ref_full}: unsupported STATUS {}",
            parsed.status
        );
        return Ok(());
    };
    let agent = event
        .get("agent")
        .and_then(Value::as_str)
        .unwrap_or("agent");
    let team = event.get("team").and_then(Value::as_str).unwrap_or("");

    // 1) build plugin → x-build tasks.json transition (reuses xmb machinery).
    if parsed.plugin == "build" && is_valid_xmb_task_id(&parsed.task_ref) {
        match resolve_xmb_tasks_path(&parsed.project)
            .and_then(|p| update_xmb_task_status(&p, &parsed.task_ref, xk_status))
        {
            Ok(XmbUpdateOutcome::Updated { old_status }) => {
                eprintln!("[xk-bridge] {task_ref_full}: {old_status} -> {xk_status}");
            }
            Ok(XmbUpdateOutcome::SkippedSameStatus) => {
                eprintln!("[xk-bridge] {task_ref_full}: already {xk_status}");
            }
            Err(e) => eprintln!("[xk-bridge] tasks.json: {e}"),
        }
    }

    if let Some(root) = state.xm_root.clone() {
        let ts = iso8601_utc_now();
        // 2) agent_step into the active trace session (if one is running).
        if let Some(trace_path) = xk_active_trace_path(&root) {
            let session_id = trace_path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("term-mesh")
                .to_string();
            let entry = json!({
                "type": "agent_step",
                "id": task_ref_full,
                "backend": "term-mesh",
                "role": agent,
                "team": team,
                "status": xk_status,
                "source": "xk-bridge",
                "session_id": session_id,
                "ts": ts,
                "v": 1,
            });
            if let Err(e) = xk_append_jsonl(&trace_path, &entry) {
                eprintln!("[xk-bridge] trace: {e}");
            }
        }
        // 3) terminal statuses → task_complete metric (joins on correlation_id).
        if matches!(xk_status, "completed" | "failed") {
            let metric = json!({
                "type": "task_complete",
                "backend": "term-mesh",
                "plugin": parsed.plugin,
                "project": parsed.project,
                "taskId": parsed.task_ref,
                "role": agent,
                "team": team,
                "success": xk_status == "completed",
                "correlation_id": parsed.corr,
                "timestamp": ts,
            });
            // Path matches x-build's cost engine (ROOT = .xm/build).
            let metrics_path = root.join("build").join("metrics").join("sessions.jsonl");
            if let Err(e) = xk_append_jsonl(&metrics_path, &metric) {
                eprintln!("[xk-bridge] metrics: {e}");
            }
        }
    }

    state.handled += 1;
    Ok(())
}

pub(crate) fn handle_xk_task_status(
    event: &Value,
    state: &mut XkBridgeState,
) -> Result<(), String> {
    let team = event.get("team").and_then(Value::as_str).unwrap_or("");
    // Events published by x-kit's own tm-bridge use synthetic `xk:` teams —
    // writing those back into .xm would echo-loop.
    if team.starts_with("xk:") {
        return Ok(());
    }
    let Some(root) = state.xm_root.clone() else {
        return Ok(());
    };
    let Some(trace_path) = xk_active_trace_path(&root) else {
        return Ok(());
    };
    let task_id = event.get("task_id").and_then(Value::as_str).unwrap_or("");
    let status = event.get("status").and_then(Value::as_str).unwrap_or("");
    if task_id.is_empty() || status.is_empty() {
        return Ok(());
    }
    if !state
        .seen
        .insert((format!("tm/{team}/{task_id}"), status.to_string()))
    {
        return Ok(());
    }
    let session_id = trace_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("term-mesh")
        .to_string();
    let entry = json!({
        "type": "agent_step",
        "id": format!("tm/{team}/{task_id}"),
        "backend": "term-mesh",
        "role": event.get("agent").and_then(Value::as_str).unwrap_or("agent"),
        "team": team,
        "status": status,
        "step": "task_status",
        "source": "xk-bridge",
        "session_id": session_id,
        "ts": iso8601_utc_now(),
        "v": 1,
    });
    xk_append_jsonl(&trace_path, &entry)?;
    state.handled += 1;
    Ok(())
}

/// T2 (docs/xk-panel-phase2.md): mirror x-panel run lifecycle (`xk_run`,
/// XK-EVENTS-v1) onto the team task board — one task per run, transitioning
/// pending → in_progress → completed/blocked — so a leader can `tm-agent wait`
/// on a panel instead of polling `.xm/…/status.json`.
///
/// Rules: run-level events only (per-model progress stays off the board);
/// idempotent per (run, status); never creates a task for an already-terminal
/// run; unknown contract versions are skipped, not errors.
pub(crate) fn handle_xk_run(event: &Value, state: &mut XkBridgeState) -> Result<(), String> {
    if event.get("v").and_then(Value::as_u64).unwrap_or(1) != 1 {
        return Ok(()); // unknown major version — ignore (XK-EVENTS-v1 rule 5)
    }
    let run = event.get("run").and_then(Value::as_str).unwrap_or("");
    if run.is_empty() {
        return Ok(());
    }
    if !event
        .get("model")
        .and_then(Value::as_str)
        .unwrap_or("")
        .is_empty()
    {
        return Ok(()); // per-model progress event — board tracks the run, not models
    }
    let Some(app_sock) = state.app_sock.clone() else {
        return Ok(()); // no app → no board; .xm writeback continues elsewhere
    };
    let phase = event.get("phase").and_then(Value::as_str).unwrap_or("");
    let terminal = matches!(phase, "done" | "failed");

    let task_id = match state.panel_tasks.get(run) {
        Some(id) => id.clone(),
        None if terminal => return Ok(()), // late/replayed terminal event — never create for it
        None => {
            let run_kind = event
                .get("run_kind")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .unwrap_or("run");
            let title_txt = event
                .get("title")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .unwrap_or(run);
            let ns = if run_kind == "cross" {
                "cross"
            } else {
                "panel"
            };
            let created = rpc_call(
                &app_sock,
                "team.task.create",
                json!({
                    "team_name": state.team,
                    "title": format!("panel:{run_kind} {title_txt}"),
                    "description": format!(
                        "x-panel {run_kind} run {run} — mirrored by xk-bridge; live detail: .xm/{ns}/{run}/status.json"
                    ),
                }),
            )?;
            let id = created["result"]["id"].as_str().unwrap_or("").to_string();
            if !created["ok"].as_bool().unwrap_or(false) || id.is_empty() {
                return Err(format!("xk_run task.create failed: {}", pretty(&created)));
            }
            eprintln!("[xk-bridge] panel run {run} → board task {id}");
            state.handled += 1;
            state.panel_tasks.insert(run.to_string(), id.clone());
            id
        }
    };

    let status = match phase {
        "done" => "completed",
        "failed" => "blocked",
        _ => "in_progress",
    };
    if !state
        .panel_applied
        .insert((run.to_string(), status.to_string()))
    {
        return Ok(()); // duplicate / out-of-order — the board already has this state
    }
    let mut params = json!({
        "team_name": state.team,
        "task_id": task_id,
        "status": status,
    });
    if status == "completed" {
        params["result"] = json!(format!("x-panel run {run} finished"));
    } else if status == "blocked" {
        params["result"] = json!(format!("x-panel run {run} failed"));
        params["blocked_reason"] = json!(format!("x-panel reported phase=failed for run {run}"));
    }
    let updated = rpc_call(&app_sock, "team.task.update", params)?;
    if !updated["ok"].as_bool().unwrap_or(false) {
        return Err(format!("xk_run task.update failed: {}", pretty(&updated)));
    }
    state.handled += 1;
    eprintln!("[xk-bridge] panel run {run}: board task {task_id} → {status}");
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct XkHeader {
    status: String,
    corr: Option<String>,
    plugin: String,
    project: String,
    task_ref: String,
}

pub(crate) fn parse_xk_header(header: &str) -> Option<XkHeader> {
    let mut status = None;
    let mut corr = None;
    let mut task: Option<(String, String, String)> = None;
    for line in header.lines() {
        let trimmed = line.trim();
        if let Some(value) = trimmed.strip_prefix("STATUS:") {
            status = Some(value.trim().to_ascii_uppercase());
        } else if let Some(value) = trimmed.strip_prefix("XK_TASK:") {
            // XK_TASK wins over a legacy XMB_TASK regardless of line order.
            if let Some(t) = parse_xk_task_ref(value.trim()) {
                task = Some(t);
            }
        } else if let Some(value) = trimmed.strip_prefix("XK_CORR:") {
            let v = value.trim();
            if !v.is_empty() && v != "n/a" {
                corr = Some(v.to_string());
            }
        } else if let Some(value) = trimmed.strip_prefix("XMB_TASK:") {
            if task.is_none() {
                if let Some((project, tid)) = parse_xmb_task_ref(value.trim()) {
                    task = Some(("build".to_string(), project, tid));
                }
            }
        }
    }
    let (plugin, project, task_ref) = task?;
    Some(XkHeader {
        status: status?,
        corr,
        plugin,
        project,
        task_ref,
    })
}

pub(crate) fn parse_xk_task_ref(value: &str) -> Option<(String, String, String)> {
    let mut parts = value.splitn(3, '/');
    let plugin = parts.next()?;
    let project = parts.next()?;
    let task_ref = parts.next()?;
    if !is_valid_xk_segment(plugin) || !is_valid_xk_segment(project) || !is_valid_xk_ref(task_ref) {
        return None;
    }
    Some((
        plugin.to_ascii_lowercase(),
        project.to_string(),
        task_ref.to_string(),
    ))
}

pub(crate) fn is_valid_xk_segment(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

pub(crate) fn is_valid_xk_ref(s: &str) -> bool {
    // No '/', no whitespace, no '..' — a ref can never escape its directory.
    !s.is_empty()
        && !s.contains("..")
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
}

/// Resolve the .xm root like x-kit's resolveSharedRoot(): cwd → git toplevel →
/// main repo via git-common-dir (worktree case). None disables writeback.
pub(crate) fn resolve_xk_xm_root() -> Option<PathBuf> {
    let cwd = env::current_dir().ok()?;
    let local = cwd.join(".xm");
    if local.is_dir() {
        return Some(local);
    }
    if let Some(root) = git_root(&cwd) {
        let p = root.join(".xm");
        if p.is_dir() {
            return Some(p);
        }
    }
    let output = std::process::Command::new("git")
        .args(["rev-parse", "--git-common-dir"])
        .current_dir(&cwd)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let common = String::from_utf8(output.stdout).ok()?;
    let common = common.trim();
    if common.is_empty() {
        return None;
    }
    let common_path = if Path::new(common).is_absolute() {
        PathBuf::from(common)
    } else {
        cwd.join(common)
    };
    let p = common_path.parent()?.join(".xm");
    if p.is_dir() {
        Some(p)
    } else {
        None
    }
}

/// The active trace session file, per `.xm/traces/.active` (stores a path or
/// bare filename ending in .jsonl). None when no session is running.
pub(crate) fn xk_active_trace_path(xm_root: &Path) -> Option<PathBuf> {
    let marker = xm_root.join("traces").join(".active");
    let content = fs::read_to_string(&marker).ok()?;
    let value = content.trim();
    if value.is_empty() {
        return None;
    }
    let fname = Path::new(value).file_name()?.to_str()?;
    if !fname.ends_with(".jsonl") {
        return None;
    }
    let path = xm_root.join("traces").join(fname);
    if path.exists() {
        Some(path)
    } else {
        None
    }
}

pub(crate) fn xk_append_jsonl(path: &Path, entry: &Value) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    }
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| format!("open {}: {e}", path.display()))?;
    let mut line =
        serde_json::to_string(entry).map_err(|e| format!("serialize {}: {e}", path.display()))?;
    line.push('\n');
    file.write_all(line.as_bytes())
        .map_err(|e| format!("append {}: {e}", path.display()))
}

#[cfg(test)]
mod xk_bridge_tests {
    use super::*;
    use std::ffi::OsString;
    use std::sync::MutexGuard;

    const REMOTE_LEADER_ENV: [&str; 5] = [
        "TERMMESH_LEADER_GRANT_ID",
        "TERMMESH_LEADER_PROJECT_ID",
        "TERMMESH_LEADER_TEAM_UUID",
        "TERMMESH_LEADER_EXPIRES_AT",
        "TERMMESH_LEADER_PEER_ID",
    ];
    /// Keep socket-backed bridge tests on their fake app socket even when the
    /// caller is itself a scoped remote leader. Process environment mutation
    /// is serialized, and every original (including non-UTF-8) value is put
    /// back before another guarded test can run.
    struct LocalRpcEnv {
        saved: Vec<(&'static str, Option<OsString>)>,
        restore_hook: Option<Box<dyn FnOnce()>>,
        _lock: MutexGuard<'static, ()>,
    }

    impl LocalRpcEnv {
        fn new() -> Self {
            REMOTE_LEADER_ENV_LOCK_HELD.with(|held| {
                assert!(!held.get(), "LocalRpcEnv cannot be nested");
            });
            let lock = REMOTE_LEADER_ENV_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            Self::new_with_lock(lock)
        }

        fn new_with_lock(lock: MutexGuard<'static, ()>) -> Self {
            Self::new_with_lock_and_restore_hook(lock, None)
        }

        fn new_with_lock_and_restore_hook(
            lock: MutexGuard<'static, ()>,
            restore_hook: Option<Box<dyn FnOnce()>>,
        ) -> Self {
            REMOTE_LEADER_ENV_LOCK_HELD.with(|held| {
                assert!(!held.get(), "LocalRpcEnv cannot be nested");
                held.set(true);
            });
            let saved = REMOTE_LEADER_ENV
                .iter()
                .map(|&key| {
                    let value = std::env::var_os(key);
                    std::env::remove_var(key);
                    (key, value)
                })
                .collect();
            Self {
                saved,
                restore_hook,
                _lock: lock,
            }
        }
    }

    impl Drop for LocalRpcEnv {
        fn drop(&mut self) {
            for (key, value) in &self.saved {
                match value {
                    Some(value) => std::env::set_var(key, value),
                    None => std::env::remove_var(key),
                }
            }
            if let Some(restore_hook) = self.restore_hook.take() {
                restore_hook();
            }
            REMOTE_LEADER_ENV_LOCK_HELD.with(|held| held.set(false));
        }
    }

    fn header(lines: &[&str]) -> String {
        lines.join("\n")
    }

    fn with_remote_leader_env_fixture(
        fixture: &[(&'static str, Option<OsString>)],
        test: impl FnOnce(LocalRpcEnv),
    ) -> (
        std::thread::Result<()>,
        Vec<(&'static str, Option<OsString>)>,
    ) {
        let lock = REMOTE_LEADER_ENV_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let original = REMOTE_LEADER_ENV
            .iter()
            .map(|&key| (key, std::env::var_os(key)))
            .collect::<Vec<_>>();
        for (key, value) in fixture {
            match value {
                Some(value) => std::env::set_var(key, value),
                None => std::env::remove_var(key),
            }
        }
        let observed = std::sync::Arc::new(std::sync::Mutex::new(None));
        let observed_for_hook = observed.clone();
        let restore_hook = Box::new(move || {
            let restored = REMOTE_LEADER_ENV
                .iter()
                .map(|&key| (key, std::env::var_os(key)))
                .collect::<Vec<_>>();
            for (key, value) in original {
                match value {
                    Some(value) => std::env::set_var(key, value),
                    None => std::env::remove_var(key),
                }
            }
            *observed_for_hook
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(restored);
        });
        let local_rpc = LocalRpcEnv::new_with_lock_and_restore_hook(lock, Some(restore_hook));
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| test(local_rpc)));
        let restored = observed
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take()
            .expect("LocalRpcEnv restore hook must run");
        (result, restored)
    }

    #[test]
    fn local_rpc_env_rejects_nested_construction_without_blocking() {
        let _local_rpc = LocalRpcEnv::new();
        let nested = std::panic::catch_unwind(LocalRpcEnv::new);
        assert!(nested.is_err(), "nested construction must be rejected");
    }

    #[test]
    fn local_rpc_env_restores_explicit_set_and_unset_values() {
        let fixture = [
            (REMOTE_LEADER_ENV[0], Some(OsString::from("saved-grant"))),
            (REMOTE_LEADER_ENV[1], None),
        ];
        let (result, restored) = with_remote_leader_env_fixture(&fixture, |local_rpc| {
            assert_eq!(local_rpc.saved[0], fixture[0]);
            assert_eq!(local_rpc.saved[1], fixture[1]);
            assert!(REMOTE_LEADER_ENV
                .iter()
                .all(|key| std::env::var_os(key).is_none()));
        });
        assert!(result.is_ok());
        assert_eq!(restored[0], fixture[0]);
        assert_eq!(restored[1], fixture[1]);
    }

    #[cfg(unix)]
    #[test]
    fn local_rpc_env_restores_non_utf8_value() {
        use std::os::unix::ffi::OsStringExt;

        let fixture = [(
            REMOTE_LEADER_ENV[2],
            Some(OsString::from_vec(vec![b't', b'e', b'a', b'm', 0xff])),
        )];
        let (result, restored) = with_remote_leader_env_fixture(&fixture, drop);
        assert!(result.is_ok());
        assert_eq!(restored[2], fixture[0]);
    }

    #[test]
    fn local_rpc_env_restores_values_during_unwind() {
        let fixture = [(REMOTE_LEADER_ENV[3], Some(OsString::from("saved-expiry")))];
        let (result, restored) = with_remote_leader_env_fixture(&fixture, |_local_rpc| {
            panic!("exercise LocalRpcEnv::drop during unwind");
        });
        assert!(result.is_err());
        assert_eq!(restored[3], fixture[0]);
    }

    #[test]
    fn parses_xk_task_header() {
        let h = header(&[
            "STATUS: DONE",
            "FILES: none",
            "XK_TASK: op/refine-20260707/r2",
            "XK_CORR: ce-abc12345",
        ]);
        let parsed = parse_xk_header(&h).expect("parse");
        assert_eq!(parsed.status, "DONE");
        assert_eq!(parsed.plugin, "op");
        assert_eq!(parsed.project, "refine-20260707");
        assert_eq!(parsed.task_ref, "r2");
        assert_eq!(parsed.corr.as_deref(), Some("ce-abc12345"));
    }

    #[test]
    fn legacy_xmb_task_maps_to_build_plugin() {
        let h = header(&["STATUS: BLOCKED", "XMB_TASK: my-proj/t3"]);
        let parsed = parse_xk_header(&h).expect("parse");
        assert_eq!(parsed.plugin, "build");
        assert_eq!(parsed.project, "my-proj");
        assert_eq!(parsed.task_ref, "t3");
        assert_eq!(parsed.corr, None);
    }

    #[test]
    fn xk_task_wins_over_xmb_regardless_of_order() {
        let h = header(&[
            "STATUS: DONE",
            "XMB_TASK: legacy/t1",
            "XK_TASK: build/new-proj/t9",
        ]);
        let parsed = parse_xk_header(&h).expect("parse");
        assert_eq!(parsed.project, "new-proj");
        assert_eq!(parsed.task_ref, "t9");

        let h2 = header(&[
            "STATUS: DONE",
            "XK_TASK: build/new-proj/t9",
            "XMB_TASK: legacy/t1",
        ]);
        let parsed2 = parse_xk_header(&h2).expect("parse");
        assert_eq!(parsed2.project, "new-proj");
    }

    #[test]
    fn rejects_traversal_and_malformed_refs() {
        assert_eq!(parse_xk_task_ref("op/../../etc"), None);
        assert_eq!(parse_xk_task_ref("op/proj/../escape"), None);
        assert_eq!(parse_xk_task_ref("op/proj/a/b"), None); // '/' in ref
        assert_eq!(parse_xk_task_ref("op/proj/"), None);
        assert_eq!(parse_xk_task_ref("op/proj"), None); // too few segments
        assert_eq!(parse_xk_task_ref("op//r1"), None); // empty project
        assert_eq!(parse_xk_task_ref("op/pr oj/r1"), None); // whitespace
        assert!(parse_xk_task_ref("solver/run-1/step.2").is_some());
    }

    #[test]
    fn missing_status_or_task_yields_none() {
        assert_eq!(parse_xk_header("XK_TASK: op/p/r1"), None);
        assert_eq!(parse_xk_header("STATUS: DONE"), None);
    }

    #[test]
    fn corr_na_is_dropped() {
        let h = header(&["STATUS: DONE", "XK_TASK: op/p/r1", "XK_CORR: n/a"]);
        assert_eq!(parse_xk_header(&h).expect("parse").corr, None);
    }

    #[test]
    fn active_trace_path_resolves_marker_forms() {
        let dir = std::env::temp_dir().join(format!("xk-bridge-test-{}", process::id()));
        let traces = dir.join("traces");
        fs::create_dir_all(&traces).expect("mkdir");
        fs::write(traces.join("op-1.jsonl"), "").expect("touch");

        // Path form (as written by trace subcommand `start`)
        fs::write(traces.join(".active"), ".xm/traces/op-1.jsonl\n").expect("marker");
        assert_eq!(xk_active_trace_path(&dir), Some(traces.join("op-1.jsonl")));

        // Bare filename form
        fs::write(traces.join(".active"), "op-1.jsonl").expect("marker");
        assert_eq!(xk_active_trace_path(&dir), Some(traces.join("op-1.jsonl")));

        // Stale marker (file gone) → None
        fs::write(traces.join(".active"), "gone.jsonl").expect("marker");
        assert_eq!(xk_active_trace_path(&dir), None);

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn reply_event_dedupes_same_ref_and_status() {
        let mut state = xk_state(None); // no .xm/app — exercises the pure dedupe/parse path
        let ev = json!({
            "kind": "reply",
            "team": "my-team",
            "agent": "executor",
            "task_id": "T-1",
            "header": "STATUS: DONE\nXK_TASK: op/p/r1",
        });
        handle_xk_event(ev.clone(), &mut state).expect("first");
        assert_eq!(state.handled, 1);
        handle_xk_event(ev, &mut state).expect("dup");
        assert_eq!(state.handled, 1, "duplicate (ref,status) must be skipped");

        // Same ref, different status → applies
        let ev2 = json!({
            "kind": "reply",
            "team": "my-team",
            "agent": "executor",
            "task_id": "T-1",
            "header": "STATUS: FAILED\nXK_TASK: op/p/r1",
        });
        handle_xk_event(ev2, &mut state).expect("second status");
        assert_eq!(state.handled, 2);
    }

    #[test]
    fn xk_team_task_status_events_are_ignored() {
        let mut state = xk_state(None);
        let ev = json!({
            "kind": "task_status",
            "team": "xk:my-project",
            "task_id": "op-1",
            "status": "in_progress",
        });
        handle_xk_event(ev, &mut state).expect("ok");
        assert_eq!(state.handled, 0);
    }

    #[test]
    fn append_jsonl_appends_lines() {
        let dir = std::env::temp_dir().join(format!("xk-append-test-{}", process::id()));
        let path = dir.join("out.jsonl");
        xk_append_jsonl(&path, &json!({"a": 1})).expect("first");
        xk_append_jsonl(&path, &json!({"b": 2})).expect("second");
        let text = fs::read_to_string(&path).expect("read");
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0], r#"{"a":1}"#);
        fs::remove_dir_all(&dir).ok();
    }

    // ── T2: xk_run → task board mirroring ──

    fn xk_state(app_sock: Option<PathBuf>) -> XkBridgeState {
        XkBridgeState {
            handled: 0,
            seen: std::collections::HashSet::new(),
            xm_root: None,
            panel_tasks: std::collections::HashMap::new(),
            panel_applied: std::collections::HashSet::new(),
            app_sock,
            team: "test-team".to_string(),
        }
    }

    fn xk_run_event(phase: &str, model: &str) -> Value {
        json!({
            "kind": "xk_run", "v": 1, "source": "x-panel",
            "run": "20260707-r1", "run_kind": "review",
            "phase": phase, "model": model, "state": "running",
            "elapsed_ms": 10, "title": "diff HEAD~1", "ts_ms": 1,
        })
    }

    /// Fake app socket serving team.task.create/update; records requests.
    fn fake_app_socket() -> (PathBuf, std::sync::Arc<std::sync::Mutex<Vec<Value>>>) {
        let dir = std::env::temp_dir().join(format!(
            "xk-run-app-{}-{}",
            process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("app.sock");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let calls = std::sync::Arc::new(std::sync::Mutex::new(Vec::<Value>::new()));
        let calls2 = calls.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { break };
                let calls3 = calls2.clone();
                std::thread::spawn(move || {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut line = String::new();
                    if reader.read_line(&mut line).is_ok() && !line.trim().is_empty() {
                        let req: Value = serde_json::from_str(&line).unwrap_or(json!({}));
                        let method = req["method"].as_str().unwrap_or("").to_string();
                        calls3.lock().unwrap().push(req);
                        let result = if method == "team.task.create" {
                            json!({"ok": true, "result": {"id": "TASK-1"}})
                        } else {
                            json!({"ok": true, "result": {}})
                        };
                        let mut w = stream;
                        let _ = w.write_all(format!("{result}\n").as_bytes());
                    }
                });
            }
        });
        (path, calls)
    }

    #[test]
    fn xk_run_mirrors_lifecycle_onto_board_idempotently() {
        let _local_rpc = LocalRpcEnv::new();
        let (sock, calls) = fake_app_socket();
        let mut state = xk_state(Some(sock));
        // starting → create + in_progress
        handle_xk_run(&xk_run_event("starting", ""), &mut state).expect("starting");
        // duplicate / same-status phases coalesce (no extra board writes)
        handle_xk_run(&xk_run_event("round1", ""), &mut state).expect("round1");
        handle_xk_run(&xk_run_event("round2", ""), &mut state).expect("round2");
        // per-model events never touch the board
        handle_xk_run(&xk_run_event("round2", "codex"), &mut state).expect("model event");
        // done → completed
        handle_xk_run(&xk_run_event("done", ""), &mut state).expect("done");
        let calls = calls.lock().unwrap();
        let methods: Vec<&str> = calls
            .iter()
            .map(|c| c["method"].as_str().unwrap())
            .collect();
        assert_eq!(
            methods,
            vec!["team.task.create", "team.task.update", "team.task.update"],
            "create + in_progress + completed, nothing else"
        );
        assert!(calls[0]["params"]["title"]
            .as_str()
            .unwrap()
            .starts_with("panel:review "));
        assert_eq!(calls[1]["params"]["status"], "in_progress");
        assert_eq!(calls[2]["params"]["status"], "completed");
        assert_eq!(calls[2]["params"]["task_id"], "TASK-1");
    }

    #[test]
    fn xk_run_failed_maps_to_blocked_with_reason() {
        let _local_rpc = LocalRpcEnv::new();
        let (sock, calls) = fake_app_socket();
        let mut state = xk_state(Some(sock));
        handle_xk_run(&xk_run_event("starting", ""), &mut state).expect("starting");
        handle_xk_run(&xk_run_event("failed", ""), &mut state).expect("failed");
        let calls = calls.lock().unwrap();
        let last = calls.last().unwrap();
        assert_eq!(last["params"]["status"], "blocked");
        assert!(last["params"]["blocked_reason"]
            .as_str()
            .unwrap()
            .contains("failed"));
    }

    #[test]
    fn xk_run_guards_skip_without_touching_the_board() {
        let _local_rpc = LocalRpcEnv::new();
        // no app socket → no-op, no error
        let mut no_app = xk_state(None);
        handle_xk_run(&xk_run_event("starting", ""), &mut no_app).expect("no app");
        assert_eq!(no_app.handled, 0);

        let (sock, calls) = fake_app_socket();
        let mut state = xk_state(Some(sock));
        // unknown contract version → skipped
        let mut v2 = xk_run_event("starting", "");
        v2["v"] = json!(2);
        handle_xk_run(&v2, &mut state).expect("v2");
        // terminal event for a run the bridge never saw → no task created
        handle_xk_run(&xk_run_event("done", ""), &mut state).expect("late done");
        // empty run id → skipped
        let mut no_run = xk_run_event("starting", "");
        no_run["run"] = json!("");
        handle_xk_run(&no_run, &mut state).expect("no run");
        assert!(calls.lock().unwrap().is_empty(), "board untouched");
    }
}

#[cfg(test)]
mod xmb_bridge_tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn parse_xmb_header_extracts_status_project_and_task() {
        let parsed = parse_xmb_header(
            "STATUS: NEEDS_REVIEW\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\nXMB_TASK: agent-feedback-loop/t3\n",
        )
        .unwrap();

        assert_eq!(
            parsed,
            XmbHeader {
                status: "NEEDS_REVIEW".into(),
                project: "agent-feedback-loop".into(),
                task_id: "t3".into(),
            }
        );
        assert_eq!(
            xmb_status_for_protocol_status(&parsed.status),
            Some("review_ready")
        );
    }

    #[test]
    fn parse_xmb_header_rejects_invalid_task_ref() {
        assert!(parse_xmb_header("STATUS: DONE\nXMB_TASK: ../bad/t3\n").is_none());
        assert!(parse_xmb_header("STATUS: DONE\nXMB_TASK: project/task3\n").is_none());
    }

    #[test]
    fn update_xmb_task_status_is_idempotent() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-xmb-bridge-test-{unique}"));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tasks.json");
        fs::write(
            &path,
            r#"{"tasks":[{"id":"t3","name":"demo","status":"running"}]}"#,
        )
        .unwrap();

        let first = update_xmb_task_status(&path, "t3", "completed").unwrap();
        assert!(
            matches!(first, XmbUpdateOutcome::Updated { old_status } if old_status == "running")
        );

        let second = update_xmb_task_status(&path, "t3", "completed").unwrap();
        assert_eq!(second, XmbUpdateOutcome::SkippedSameStatus);

        let doc: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(doc["tasks"][0]["status"].as_str(), Some("completed"));
        assert!(doc["tasks"][0]["completed_at"].as_str().is_some());

        fs::remove_dir_all(dir).ok();
    }
}
