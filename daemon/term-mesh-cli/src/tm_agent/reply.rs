use super::*;

pub(crate) fn parse_cli_flag(flag: &Option<String>) -> std::collections::HashSet<String> {
    let mut result = std::collections::HashSet::new();
    if let Some(val) = flag {
        for item in val.split(',') {
            let item = item.trim();
            if !item.is_empty() {
                result.insert(item.to_string());
            }
        }
    }
    result
}

// ── Hybrid result delivery helpers ────────────────────────────────────

pub(crate) fn results_dir(team: &str) -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join(".term-mesh/results").join(team)
}

pub(crate) fn sanitized_result_filename(filename: &str) -> String {
    let safe_filename: String = filename
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_' || *c == '.')
        .collect();
    if safe_filename.is_empty() {
        "unknown.md".to_string()
    } else {
        safe_filename
    }
}

pub(crate) fn result_file_path(team: &str, filename: &str) -> PathBuf {
    results_dir(team).join(sanitized_result_filename(filename))
}

pub(crate) fn reply_alias_filename(agent_name: &str, agent_instance_id: Option<&str>) -> String {
    agent_instance_id
        .filter(|id| !id.is_empty())
        .map(|id| format!("{agent_name}-{id}-reply.md"))
        .unwrap_or_else(|| format!("{agent_name}-reply.md"))
}

pub(crate) fn write_result_file(
    team: &str,
    filename: &str,
    content: &str,
) -> Result<PathBuf, String> {
    let path = result_file_path(team, filename);
    atomic_write_file(&path, content)?;
    Ok(path)
}

pub(crate) fn lexical_absolute_path(path: &Path) -> PathBuf {
    use std::path::Component;

    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("/"))
            .join(path)
    };
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

pub(crate) fn expanded_report_path(raw: &str) -> PathBuf {
    let raw = raw.trim().trim_matches(|c| matches!(c, '`' | '\'' | '"'));
    let home = env::var("HOME").unwrap_or_default();
    let expanded = raw
        .strip_prefix("~/")
        .map(|rest| PathBuf::from(&home).join(rest))
        .or_else(|| {
            raw.strip_prefix("$HOME/")
                .map(|rest| PathBuf::from(&home).join(rest))
        })
        .or_else(|| {
            raw.strip_prefix("${HOME}/")
                .map(|rest| PathBuf::from(&home).join(rest))
        })
        .unwrap_or_else(|| PathBuf::from(raw));
    lexical_absolute_path(&expanded)
}

/// A reply alias and `<task_id>.md` are durable copies of the submitted reply,
/// not separate detailed reports. Rejecting those paths prevents FULL_REPORT
/// from pointing back to the reply that contains the header itself.
pub(crate) fn normalize_self_referential_full_report(
    content: &str,
    durable_copy_paths: &[PathBuf],
) -> (String, Option<String>) {
    let (headers, _) = reply_header_and_summary(content, 0);
    let full_report = headers["full_report"].as_str().unwrap_or("n/a").trim();
    let is_self_reference = !full_report.eq_ignore_ascii_case("n/a")
        && !full_report.eq_ignore_ascii_case("none")
        && durable_copy_paths
            .iter()
            .map(|path| lexical_absolute_path(path))
            .any(|path| expanded_report_path(full_report) == path);
    if !is_self_reference {
        return (content.to_string(), None);
    }

    let normalized = split_inline_headers(
        content,
        &["STATUS", "FILES", "VERIFY", "NEXT", "FULL_REPORT"],
    )
    .lines()
    .map(|line| {
        let trimmed = line.trim_start();
        if trimmed.strip_prefix("FULL_REPORT:").is_some() {
            let indent = &line[..line.len() - trimmed.len()];
            format!("{indent}FULL_REPORT: n/a")
        } else {
            line.to_string()
        }
    })
    .collect::<Vec<_>>()
    .join("\n");
    (normalized, Some(full_report.to_string()))
}

#[derive(Clone, Copy)]
#[cfg(test)]
pub(crate) enum AtomicWriteFault {
    Write,
    Sync,
    Rename,
}

pub(crate) fn atomic_write_file(path: &Path, content: &str) -> Result<(), String> {
    atomic_write_file_inner(path, content, false, false, false)
}

#[cfg(test)]
pub(crate) fn atomic_write_file_with_fault(
    path: &Path,
    content: &str,
    fault: Option<AtomicWriteFault>,
) -> Result<(), String> {
    atomic_write_file_inner(
        path,
        content,
        matches!(fault, Some(AtomicWriteFault::Write)),
        matches!(fault, Some(AtomicWriteFault::Sync)),
        matches!(fault, Some(AtomicWriteFault::Rename)),
    )
}

pub(crate) fn atomic_write_file_inner(
    path: &Path,
    content: &str,
    fail_write: bool,
    fail_sync: bool,
    fail_rename: bool,
) -> Result<(), String> {
    let dir = path
        .parent()
        .ok_or_else(|| format!("missing parent for {}", path.display()))?;
    std::fs::create_dir_all(dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    let filename = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("result");

    for attempt in 0..16 {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let tmp = dir.join(format!(
            ".{filename}.{}.{}.{}.tmp",
            process::id(),
            nonce,
            attempt
        ));
        let mut file = match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
        {
            Ok(file) => file,
            Err(e) if e.kind() == ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("create temp {}: {e}", tmp.display())),
        };
        let write_result = if fail_write {
            Err(std::io::Error::other("injected write failure"))
        } else {
            file.write_all(content.as_bytes())
        };
        if let Err(e) = write_result {
            let _ = fs::remove_file(&tmp);
            return Err(format!("write {}: {e}", tmp.display()));
        }
        let sync_result = if fail_sync {
            Err(std::io::Error::other("injected sync failure"))
        } else {
            file.sync_all()
        };
        if let Err(e) = sync_result {
            let _ = fs::remove_file(&tmp);
            return Err(format!("sync {}: {e}", tmp.display()));
        }
        drop(file);
        let rename_result = if fail_rename {
            Err(std::io::Error::other("injected rename failure"))
        } else {
            fs::rename(&tmp, path)
        };
        if let Err(e) = rename_result {
            let _ = fs::remove_file(&tmp);
            return Err(format!(
                "rename {} -> {}: {e}",
                tmp.display(),
                path.display()
            ));
        }
        return Ok(());
    }

    Err(format!(
        "failed to create unique temp file for {}",
        path.display()
    ))
}

pub(crate) fn require_durable_reply(
    alias: Result<PathBuf, String>,
    task: Option<Result<PathBuf, String>>,
) -> Result<(Option<PathBuf>, Option<PathBuf>, Vec<String>), String> {
    let (alias_path, alias_error) = match alias {
        Ok(path) => (Some(path), None),
        Err(error) => (None, Some(error)),
    };
    let (task_path, task_error) = match task {
        Some(Ok(path)) => (Some(path), None),
        Some(Err(error)) => (None, Some(error)),
        None => (None, None),
    };
    let errors = [alias_error, task_error]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>();
    if alias_path.is_some() || task_path.is_some() {
        return Ok((alias_path, task_path, errors));
    }
    Err(format!(
        "failed to preserve durable reply: {}",
        errors.join("; ")
    ))
}

/// Pick the task that `tm-agent reply` should close, plus the full list of
/// non-terminal candidate task ids for that sender.
///
/// Priority: non-stale tasks first, then `in_progress` over `assigned`/other,
/// then most recent `created_at` wins. Returns `(selected_id, all_candidates)`.
pub(crate) fn select_reply_task(
    sock: &PathBuf,
    team: &str,
    sender: &str,
    agent_instance_id: Option<&str>,
) -> (Option<String>, Vec<String>) {
    let Ok(task_resp) = rpc_call(
        sock,
        "team.task.list",
        json!({ "team_name": team, "assignee": sender }),
    ) else {
        return (None, Vec::new());
    };
    let Some(tasks) = task_resp["result"]["tasks"].as_array() else {
        return (None, Vec::new());
    };
    select_reply_task_from_tasks(tasks, agent_instance_id)
}

pub(crate) fn select_reply_task_from_tasks(
    tasks: &[Value],
    agent_instance_id: Option<&str>,
) -> (Option<String>, Vec<String>) {
    let mut candidates: Vec<&Value> = tasks
        .iter()
        .filter(|t| {
            let st = t["status"].as_str().unwrap_or("");
            !is_terminal_task_status(st)
                && agent_instance_id.map_or(true, |id| t["agent_instance_id"].as_str() == Some(id))
        })
        .collect();
    // Sort by (non-stale first, in_progress first, created_at desc).
    candidates.sort_by(|a, b| {
        let stale_a = a["is_stale"].as_bool().unwrap_or(false);
        let stale_b = b["is_stale"].as_bool().unwrap_or(false);
        let ip_a = a["status"].as_str() == Some("in_progress");
        let ip_b = b["status"].as_str() == Some("in_progress");
        let created_a = a["created_at"].as_str().unwrap_or("");
        let created_b = b["created_at"].as_str().unwrap_or("");
        stale_a
            .cmp(&stale_b) // false < true → non-stale first
            .then_with(|| ip_b.cmp(&ip_a)) // true < false swap → in_progress first
            .then_with(|| created_b.cmp(created_a)) // newer created_at first
    });
    let all: Vec<String> = candidates
        .iter()
        .filter_map(|t| t["id"].as_str().map(str::to_string))
        .collect();
    let selected = all.first().cloned();
    (selected, all)
}

/// Resolve the current pane to its durable instance before a bare reply scans
/// the task board. This is deliberately best-effort: an unavailable or stale
/// roster must preserve the existing ambiguity path, not prevent the reply
/// from being recorded.
pub(crate) fn current_reply_instance_id(
    sock: &PathBuf,
    team: &str,
    sender: &str,
) -> Option<String> {
    if let Some(instance_id) = env::var("TERMMESH_AGENT_INSTANCE_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
    {
        return Some(instance_id);
    }
    let panel_id = env::var("TERMMESH_PANEL_ID")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let workspace_id = env::var("TERMMESH_WORKSPACE_ID")
        .ok()
        .filter(|value| !value.trim().is_empty());
    if panel_id.is_none() && workspace_id.is_none() {
        return None;
    }
    let status = rpc_call(sock, "team.status", json!({ "team_name": team })).ok()?;
    let agents = status["result"]["agents"].as_array()?;
    instance_id_from_current_pane(agents, sender, panel_id.as_deref(), workspace_id.as_deref())
}

pub(crate) fn instance_id_from_current_pane(
    agents: &[Value],
    sender: &str,
    panel_id: Option<&str>,
    workspace_id: Option<&str>,
) -> Option<String> {
    let matches = agents.iter().filter(|agent| {
        agent["name"].as_str() == Some(sender)
            && panel_id.map_or_else(
                || {
                    workspace_id
                        .map(|workspace| agent["workspace_id"].as_str() == Some(workspace))
                        .unwrap_or(false)
                },
                |panel| agent["panel_id"].as_str() == Some(panel),
            )
    });
    let instance_ids = matches
        .filter_map(|agent| agent["agent_instance_id"].as_str())
        .collect::<Vec<_>>();
    match instance_ids.as_slice() {
        [instance_id] => Some((*instance_id).to_string()),
        _ => None,
    }
}

/// Resolve the durable instance that owns a reply. A task id is itself an
/// authoritative attribution key, so it can resolve a duplicated role without
/// reviving the old name-only "pick a sibling" behavior.
pub(crate) fn reply_agent_instance_id(
    sock: &PathBuf,
    team: &str,
    sender: &str,
    explicit_instance_id: Option<&str>,
    task_id: Option<&str>,
) -> Result<Option<String>, String> {
    if let Some(task_id) = task_id {
        let task = rpc_call(
            sock,
            "team.task.get",
            json!({ "team_name": team, "task_id": task_id }),
        )?;
        return task_instance_for_reply(&task["result"], task_id, sender, explicit_instance_id);
    }
    let status = rpc_call(sock, "team.status", json!({ "team_name": team }))?;
    let matches = status["result"]["agents"]
        .as_array()
        .map(|agents| {
            agents
                .iter()
                .filter(|agent| agent["name"].as_str() == Some(sender))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if let Some(explicit) = explicit_instance_id {
        return matches
            .iter()
            .any(|agent| agent["agent_instance_id"].as_str() == Some(explicit))
            .then(|| Some(explicit.to_string()))
            .ok_or_else(|| {
                format!("agent_instance_id {explicit} is not a {sender} in team {team}")
            });
    }
    match matches.as_slice() {
        [] => Err(format!("agent {sender} not found in team {team}")),
        [agent] => Ok(agent["agent_instance_id"].as_str().map(str::to_owned)),
        _ => Err(format!(
            "multiple agents named {sender}; pass --task-id or --agent-instance-id"
        )),
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum HeadlessProbe {
    Skip,
    Allow,
    RejectIfHeadless,
}

/// `headless.send` addresses an agent by name alone, so a send that names a
/// pane, an instance, or a task's pinned owner must not take that route.
pub(crate) fn headless_probe_for_send(
    has_selector: bool,
    task_bound: bool,
    pinned_instance_id: Option<&str>,
) -> HeadlessProbe {
    if has_selector || pinned_instance_id.is_some() {
        HeadlessProbe::Skip
    } else if task_bound {
        HeadlessProbe::RejectIfHeadless
    } else {
        HeadlessProbe::Allow
    }
}

pub(crate) fn is_terminal_task_status(status: &str) -> bool {
    matches!(
        status,
        "completed" | "failed" | "abandoned" | "cancelled" | "superseded"
    )
}

pub(crate) fn validate_followup_task(
    task: &Value,
    task_id: &str,
    target: &str,
    selected_instance_id: Option<&str>,
) -> Result<Option<String>, String> {
    match task["id"].as_str() {
        None | Some("") => return Err(format!("task {task_id} not found")),
        Some(found) if found != task_id => {
            return Err(format!(
                "task lookup for {task_id} answered with task {found}; refusing to bind the send"
            ))
        }
        Some(_) => {}
    }
    if task["assignee"].as_str() != Some(target) {
        return Err(format!("task {task_id} is not assigned to {target}"));
    }
    let status = task["status"].as_str().unwrap_or("");
    if is_terminal_task_status(status) {
        return Err(format!(
            "task {task_id} is {status} (terminal); delegate a new task instead of reopening it"
        ));
    }
    let task_instance = task["agent_instance_id"]
        .as_str()
        .filter(|id| !id.is_empty());
    match (task_instance, selected_instance_id) {
        (Some(owner), Some(selected)) if owner != selected => Err(format!(
            "task {task_id} does not belong to agent_instance_id {selected}"
        )),
        (Some(owner), _) => Ok(Some(owner.to_string())),
        (None, selected) => Ok(selected.map(str::to_string)),
    }
}

/// Build the text of a send bound to an existing task, plus the durable
/// instance it must be routed to. Nothing is written to the board.
pub(crate) fn resolve_task_followup(
    sock: &PathBuf,
    team: &str,
    target: &str,
    task_id: &str,
    panel_id: Option<&str>,
    explicit_instance_id: Option<&str>,
    text: &str,
    no_report: bool,
) -> Result<(String, Option<String>), String> {
    let response = successful_rpc_envelope(rpc_call(
        sock,
        "team.task.get",
        json!({ "team_name": team, "task_id": task_id }),
    ))?;
    let task = &response["result"];
    let selected = command_agent_instance_id(sock, team, target, panel_id, explicit_instance_id)?;
    let instance = validate_followup_task(task, task_id, target, selected.as_deref())?;
    let instruction = format_task_instruction(sock, team, task, text, no_report, None, None);
    Ok((instruction, instance))
}

pub(crate) fn task_instance_for_reply(
    task: &Value,
    task_id: &str,
    sender: &str,
    explicit_instance_id: Option<&str>,
) -> Result<Option<String>, String> {
    if task["assignee"].as_str() != Some(sender) {
        return Err(format!("task {task_id} is not assigned to {sender}"));
    }
    let instance = task["agent_instance_id"].as_str().map(str::to_owned);
    if let Some(explicit) = explicit_instance_id {
        if instance.as_deref() != Some(explicit) {
            return Err(format!(
                "task {task_id} does not belong to agent_instance_id {explicit}"
            ));
        }
    }
    Ok(instance)
}

/// Bare replies retain the unique-name/single-task compatibility path, but
/// must never guess when one sender owns more than one live task.
pub(crate) fn unambiguous_reply_task(candidates: &[String]) -> Result<Option<String>, String> {
    match candidates {
        [] => Ok(None),
        [only] => Ok(Some(only.clone())),
        many => Err(format!(
            "ambiguous active tasks: {}; pass --task-id explicitly",
            many.join(" ")
        )),
    }
}

/// Which task a bare `reply` closes, and the reason it closes none.
///
/// Returns `(task_to_close, withheld_reason)`. Ambiguity is a withheld
/// transition, not a refused reply: the caller records the reply either way and
/// only skips `team.task.update`, because closing another instance's task is
/// destructive while losing the verdict strands whoever is waiting for it.
///
/// Split from the command so the decision is testable without a socket.
pub(crate) fn reply_task_decision(
    selected: Option<String>,
    candidates: &[String],
) -> (Option<String>, Option<String>) {
    match unambiguous_reply_task(candidates) {
        Ok(task_id) => (task_id.or(selected), None),
        Err(message) => (None, Some(message)),
    }
}

pub(crate) fn return_retry_delays_ms(text_delivered: bool, context: &str) -> &'static [u64] {
    // Long-paste contexts (init prompt, delegate payload) used to need an
    // 800ms first delay to avoid the paste truncation race. That race is
    // now resolved at the source by chunking ghostty_surface_text calls in
    // Swift's processPaste, so the init path can use the default cadence.
    // Keeping the branch as a no-op for easy future tuning if a regression
    // surfaces; the explicit context match documents the historical issue.
    let _ = context;
    if text_delivered {
        // First delay raised from 20 ms → 250 ms so the Return key arrives after
        // codex has fully rendered the pasted text and is ready to accept input.
        // Swift asyncTeamSendKey also holds an additional 250 ms post-Return gate
        // before releasing the next paste, providing two layers of protection.
        //
        // Long tail (1500/2500/4000 ms) added defensively for the Layer-2
        // congestion race: during multi-agent `create`, simultaneous panel/CLI
        // startup + layout churn can keep the freshly spawned panel from being
        // key-ready well past 1 s. The common case still resolves at attempt 1
        // (250 ms); only a stubborn panel walks the tail (~11 s worst case).
        &[250, 400, 600, 800, 1000, 1500, 2500, 4000]
    } else {
        &[200, 500, 1000, 2000]
    }
}

pub(crate) fn send_return_key_params(
    team: &str,
    target: &str,
    panel_id: Option<&str>,
    agent_instance_id: Option<&str>,
    send_sequence_id: Option<&str>,
) -> Value {
    json!({
        "team_name": team,
        "agent_name": target,
        "key": "return",
        "panel_id": panel_id,
        "agent_instance_id": agent_instance_id,
        "send_sequence_id": send_sequence_id,
    })
}

pub(crate) fn created_agent_selector(
    created_agents: &[Value],
    index: usize,
) -> (Option<&str>, Option<&str>) {
    let created = created_agents.get(index);
    (
        created.and_then(|value| value["agent_instance_id"].as_str()),
        created.and_then(|value| value["panel_id"].as_str()),
    )
}

pub(crate) fn send_return_key_with_retry(
    sock: &PathBuf,
    team: &str,
    target: &str,
    text_delivered: bool,
    context: &str,
    panel_id: Option<&str>,
    agent_instance_id: Option<&str>,
    send_sequence_id: Option<&str>,
    return_required: Option<bool>,
) -> bool {
    if return_required == Some(false) {
        // The acknowledgement declared the turn submitted on the text write
        // (native transport): there is no Return to press, so skip the first
        // delay and the send_key round trip entirely.
        eprintln!("send_key.skip context={context} reason=return_not_required");
        return true;
    }
    let delays = return_retry_delays_ms(text_delivered, context);
    eprintln!(
        "send_key.skip_or_retry context={context} text_delivered={text_delivered} attempts={} delays_ms={}",
        delays.len(),
        delays
            .iter()
            .map(u64::to_string)
            .collect::<Vec<_>>()
            .join(",")
    );

    for (attempt, delay_ms) in delays.iter().enumerate() {
        if *delay_ms > 0 {
            std::thread::sleep(Duration::from_millis(*delay_ms));
        }
        eprintln!("team.send_key attempt {}/{}", attempt + 1, delays.len());
        match rpc_call(
            sock,
            "team.send_key",
            send_return_key_params(team, target, panel_id, agent_instance_id, send_sequence_id),
        ) {
            Ok(r) if r["ok"].as_bool().unwrap_or(false) => return true,
            Ok(_) | Err(_) => {}
        }
    }

    eprintln!(
        "  Warning: Return key delivery failed after {} retries",
        delays.len()
    );
    false
}

/// Resolve the durable selected member before a delegate starts.  `panel_id`
/// is only a transient locator; every retry carries this instance selector so
/// a restart or mixed-transport failure cannot silently land on a same-name
/// sibling.  Returning `None` preserves the legacy unique-name path, while a
/// duplicate name without an instance is rejected by the Swift RPC.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct ResolvedDelegateTarget {
    pub(crate) agent_instance_id: Option<String>,
    pub(crate) working_directory: Option<String>,
}

pub(crate) fn selected_delegate_target(
    sock: &PathBuf,
    team: &str,
    target: &str,
    panel_id: Option<&str>,
    explicit_instance_id: Option<&str>,
) -> Result<ResolvedDelegateTarget, String> {
    let status = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(status) => status,
        Err(error) if panel_id.is_some() || explicit_instance_id.is_some() => {
            return Err(format!(
                "cannot resolve delegate target before dispatch: {error}"
            ));
        }
        Err(_) => return Ok(ResolvedDelegateTarget::default()),
    };
    let agents = match status["result"]["agents"].as_array() {
        Some(agents) => agents,
        None if panel_id.is_some() || explicit_instance_id.is_some() => {
            return Err(
                "team.status response has no agents array; cannot resolve exact delegate target"
                    .into(),
            );
        }
        None => return Ok(ResolvedDelegateTarget::default()),
    };
    delegate_target_from_agents(agents, target, panel_id, explicit_instance_id)
}

pub(crate) fn delegate_target_from_agents(
    agents: &[Value],
    target: &str,
    panel_id: Option<&str>,
    explicit_instance_id: Option<&str>,
) -> Result<ResolvedDelegateTarget, String> {
    let instance = if let Some(explicit) = explicit_instance_id {
        let matches = agents
            .iter()
            .filter(|agent| {
                agent["name"].as_str() == Some(target)
                    && agent["agent_instance_id"].as_str() == Some(explicit)
            })
            .collect::<Vec<_>>();
        match matches.as_slice() {
            [_] => Some(explicit.to_string()),
            [] => {
                return Err(format!(
                    "agent instance {explicit} is not registered as {target} in the selected team"
                ))
            }
            _ => return Err(format!("agent instance {explicit} is not unique")),
        }
    } else {
        instance_id_from_agents(agents, target, panel_id)?
    };
    let placement = instance.as_deref().and_then(|instance_id| {
        agents.iter().find(|agent| {
            agent["agent_instance_id"].as_str() == Some(instance_id)
                && agent["name"].as_str() == Some(target)
        })
    });
    Ok(ResolvedDelegateTarget {
        agent_instance_id: instance,
        working_directory: placement
            .and_then(|agent| agent["working_directory"].as_str())
            .filter(|path| !path.is_empty())
            .map(str::to_string),
    })
}

/// Resolve an optional panel selector to the durable instance selector used by
/// every subsequent RPC. Explicit instance IDs need no name lookup; panel IDs
/// must identify exactly one same-name member or the command fails before it
/// can fall back to the server's ambiguous name path.
pub(crate) fn command_agent_instance_id(
    sock: &PathBuf,
    team: &str,
    target: &str,
    panel_id: Option<&str>,
    explicit_instance_id: Option<&str>,
) -> Result<Option<String>, String> {
    if let Some(instance_id) = explicit_instance_id {
        return Ok(Some(instance_id.to_string()));
    }
    let Some(panel_id) = panel_id else {
        return Ok(None);
    };
    let status = rpc_call(sock, "team.status", json!({ "team_name": team }))?;
    let agents = status["result"]["agents"]
        .as_array()
        .ok_or_else(|| "team.status response has no agents array".to_string())?;
    instance_id_from_agents(agents, target, Some(panel_id))
}

pub(crate) fn exact_command_agent_instance_id(
    sock: &PathBuf,
    team: &str,
    target: &str,
    panel_id: Option<&str>,
    explicit_instance_id: Option<&str>,
) -> Result<String, String> {
    if let Some(instance_id) =
        command_agent_instance_id(sock, team, target, panel_id, explicit_instance_id)?
    {
        return Ok(instance_id);
    }
    let status =
        successful_rpc_envelope(rpc_call(sock, "team.status", json!({ "team_name": team })))?;
    let agents = status["result"]["agents"]
        .as_array()
        .ok_or_else(|| "team.status response has no agents array".to_string())?;
    instance_id_from_agents(agents, target, None)?
        .ok_or_else(|| format!("agent {target} has no unique durable agent_instance_id"))
}

pub(crate) fn instance_id_from_agents(
    agents: &[Value],
    target: &str,
    panel_id: Option<&str>,
) -> Result<Option<String>, String> {
    let matches = agents
        .iter()
        .filter(|agent| {
            agent["name"].as_str() == Some(target)
                && panel_id.map_or(true, |panel| agent["panel_id"].as_str() == Some(panel))
        })
        .collect::<Vec<_>>();
    match matches.as_slice() {
        [agent] => agent["agent_instance_id"]
            .as_str()
            .map(|id| Some(id.to_string()))
            .ok_or_else(|| format!("agent {target} has no agent_instance_id")),
        [] if panel_id.is_some() => Err(format!(
            "no agent named {target} matches panel {}; pass --agent-instance-id instead",
            panel_id.unwrap_or_default()
        )),
        [] => Ok(None),
        _ if panel_id.is_some() => Err(format!(
            "panel {} matches multiple agents named {target}; pass --agent-instance-id",
            panel_id.unwrap_or_default()
        )),
        _ => Ok(None),
    }
}

pub(crate) fn truncate_summary(content: &str, max_chars: usize) -> String {
    if content.chars().count() <= max_chars {
        return content.to_string();
    }
    format!("{}...", content.chars().take(max_chars).collect::<String>())
}

/// Inserts a newline before each secondary " KEY:" occurrence so a header
/// crammed onto one line ("STATUS: DONE FILES: none VERIFY: n/a ...") is
/// reshaped into the per-line form the line-based parser expects. The first
/// KEY: on each line is preserved in place; only the 2nd+ are split out.
pub(crate) fn split_inline_headers(content: &str, keys: &[&str]) -> String {
    let mut out = String::with_capacity(content.len() + 32);
    for line in content.lines() {
        let mut cuts: Vec<usize> = Vec::new();
        for key in keys {
            // Match " KEY:" (leading whitespace required) to avoid splitting
            // mid-word matches like "PRESTATUS:" or values that happen to
            // contain "STATUS:" without a boundary.
            let needle = format!(" {key}:");
            let mut start = 0;
            while let Some(idx) = line[start..].find(&needle) {
                let abs = start + idx + 1; // +1 skips the leading space, keeps KEY:
                cuts.push(abs);
                start = start + idx + needle.len();
            }
        }
        if cuts.is_empty() {
            out.push_str(line);
            out.push('\n');
        } else {
            cuts.sort();
            let mut prev = 0;
            for cut in cuts {
                out.push_str(line[prev..cut].trim_end());
                out.push('\n');
                prev = cut;
            }
            out.push_str(line[prev..].trim_end());
            out.push('\n');
        }
    }
    out
}

/// Map a protocol STATUS string to (task_state, detail_field_name).
/// Returns None if the status is unrecognised (caller should exit 2).
pub(crate) fn protocol_status_to_task_state(status: &str) -> Option<&'static str> {
    match status {
        "DONE" => Some("completed"),
        "BLOCKED" => Some("blocked"),
        "NEEDS_REVIEW" => Some("review_ready"),
        _ => None,
    }
}

pub(crate) fn reply_header_and_summary(content: &str, summary_chars: usize) -> (Value, String) {
    let header_keys = ["STATUS", "FILES", "VERIFY", "NEXT", "FULL_REPORT"];
    // Agents (notably codex) sometimes emit all 5 fields on a single line —
    // the line-based loop below would then capture only STATUS and drop the
    // rest as "n/a". Normalize secondary " KEY:" occurrences into newlines
    // first so the parser sees one header per line either way.
    let normalized = split_inline_headers(content, &header_keys);
    let mut headers = serde_json::Map::new();
    let mut body_lines = Vec::new();
    for line in normalized.lines() {
        let trimmed = line.trim();
        let mut matched = false;
        for key in header_keys {
            if let Some(value) = trimmed.strip_prefix(&format!("{key}:")) {
                headers
                    .entry(key.to_ascii_lowercase())
                    .or_insert_with(|| json!(value.trim()));
                matched = true;
                break;
            }
        }
        if !matched {
            body_lines.push(line);
        }
    }
    for key in header_keys {
        headers
            .entry(key.to_ascii_lowercase())
            .or_insert_with(|| json!("n/a"));
    }
    let joined = body_lines.join("\n");
    let body = joined.trim();
    let body = body
        .strip_prefix("SUMMARY:")
        .unwrap_or(body)
        .trim()
        .to_string();
    (
        Value::Object(headers),
        truncate_summary(&body, summary_chars),
    )
}

pub(crate) fn compact_result_collect_response(mut resp: Value, include_summary: bool) -> Value {
    if let Some(results) = resp
        .get_mut("result")
        .and_then(|r| r.get_mut("results"))
        .and_then(|r| r.as_array_mut())
    {
        for result in results {
            if let Some(obj) = result.as_object_mut() {
                let content = obj
                    .get("content")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let (headers, summary) = reply_header_and_summary(&content, 700);
                // result_path is the canonical durable copy of this reply. Keep
                // it as separate metadata; it is not a FULL_REPORT and must not
                // replace the separately-authored path in the submitted header.
                obj.insert("headers".to_string(), headers);
                if include_summary {
                    obj.insert("summary".to_string(), json!(summary));
                }
                obj.remove("content");
            }
        }
    }
    resp
}

pub(crate) fn filter_result_collect_response(
    mut resp: Value,
    tracked_task_ids: Option<&std::collections::HashSet<String>>,
) -> Value {
    let Some(tracked_task_ids) = tracked_task_ids else {
        return resp;
    };
    if let Some(results) = resp
        .get_mut("result")
        .and_then(|result| result.get_mut("results"))
        .and_then(Value::as_array_mut)
    {
        results.retain(|result| {
            result
                .get("task_id")
                .and_then(Value::as_str)
                .is_some_and(|task_id| tracked_task_ids.contains(task_id))
        });
    }
    resp
}

pub(crate) fn task_unblock_params(team: &str, task_id: &str, correction: Option<&str>) -> Value {
    let mut params = json!({
        "team_name": team,
        "task_id": task_id,
    });
    if let Some(correction) = correction {
        params["correction"] = json!(correction);
    }
    params
}

pub(crate) fn cleanup_old_results(team: &str) {
    let dir = results_dir(team);
    if let Ok(entries) = std::fs::read_dir(&dir) {
        let cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(24 * 3600);
        for entry in entries.flatten() {
            if let Ok(meta) = entry.metadata() {
                if let Ok(modified) = meta.modified() {
                    if modified < cutoff {
                        let _ = std::fs::remove_file(entry.path());
                    }
                }
            }
        }
    }
}

// ── Board helpers ────────────────────────────────────────────────────

/// Detect the git root by walking up from `start`, falling back to `start`.
pub(crate) fn find_project_root(start: &std::path::Path) -> PathBuf {
    let mut dir = start.to_path_buf();
    loop {
        if dir.join(".git").exists() {
            return dir;
        }
        match dir.parent() {
            Some(p) => dir = p.to_path_buf(),
            None => return start.to_path_buf(),
        }
    }
}

/// Create `.xm/{behavior_type}/{run-id}/board.jsonl` under the project root.
/// Returns `(board_path, run_id)` where `board_path` is absolute.
pub(crate) fn create_board(behavior_type: &str) -> Result<(PathBuf, String), String> {
    use std::time::{SystemTime, UNIX_EPOCH};

    let cwd = env::current_dir().map_err(|e| format!("current_dir: {e}"))?;
    let project_root = find_project_root(&cwd);

    // run-id: {behavior_type}-{YYYYMMDD-HHMMSS}-{random_hex_4}
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    // Compute calendar fields from Unix timestamp (UTC, no external crate needed).
    let (year, month, day, hour, min, sec) = unix_ts_to_ymd_hms(now);
    let rand_hex = {
        // Use low bits of nanos for entropy.
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .subsec_nanos();
        format!("{:04x}", (nanos ^ (process::id() << 16)) & 0xFFFF)
    };
    let run_id =
        format!("{behavior_type}-{year:04}{month:02}{day:02}-{hour:02}{min:02}{sec:02}-{rand_hex}");

    let board_dir = project_root.join(".xm").join(behavior_type).join(&run_id);

    std::fs::create_dir_all(&board_dir)
        .map_err(|e| format!("create_dir_all {}: {e}", board_dir.display()))?;

    let board_path = board_dir.join("board.jsonl");
    std::fs::File::create(&board_path)
        .map_err(|e| format!("create board.jsonl {}: {e}", board_path.display()))?;

    Ok((board_path, run_id))
}

/// Return the absolute board path as a string suitable for template injection.
pub(crate) fn board_path_for_prompt(board: &std::path::Path) -> String {
    board
        .canonicalize()
        .unwrap_or_else(|_| board.to_path_buf())
        .to_string_lossy()
        .to_string()
}

/// Convert a Unix timestamp (seconds) to (year, month, day, hour, min, sec) in UTC.
/// No external crates; handles leap years.
pub(crate) fn unix_ts_to_ymd_hms(ts: u64) -> (u32, u32, u32, u32, u32, u32) {
    let sec = (ts % 60) as u32;
    let min = ((ts / 60) % 60) as u32;
    let hour = ((ts / 3600) % 24) as u32;
    let days = ts / 86400; // days since 1970-01-01

    // Compute year/month/day from days since epoch.
    let mut y: u32 = 1970;
    let mut d = days as u32;
    loop {
        let days_in_year = if is_leap(y) { 366 } else { 365 };
        if d < days_in_year {
            break;
        }
        d -= days_in_year;
        y += 1;
    }
    let month_days: &[u32] = if is_leap(y) {
        &[31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        &[31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut m: u32 = 1;
    for &md in month_days {
        if d < md {
            break;
        }
        d -= md;
        m += 1;
    }
    (y, m, d + 1, hour, min, sec)
}

pub(crate) fn is_leap(y: u32) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

pub(crate) fn successful_rpc_envelope(result: Result<Value, String>) -> Result<Value, String> {
    let response = result?;
    if rpc_response_failed(&response) {
        let detail = response
            .get("error")
            .and_then(|error| {
                error
                    .as_str()
                    .or_else(|| error.get("message").and_then(Value::as_str))
                    .or_else(|| error.get("code").and_then(Value::as_str))
            })
            .unwrap_or("request rejected");
        return Err(format!("RPC returned ok:false: {detail}"));
    }
    Ok(response)
}

/// Transport success is not command success. Both the app's v2 envelope and
/// standard JSON-RPC encode failures as ordinary JSON values.
pub(crate) fn rpc_response_failed(response: &Value) -> bool {
    response.get("ok").and_then(Value::as_bool) == Some(false)
        || response.get("error").is_some_and(|error| !error.is_null())
}

/// A usable `send` requires both the text write and its companion Return.
/// This remains a transport-level acknowledgement; it does not claim that the
/// agent consumed the instruction or produced a reply.
pub(crate) fn send_delivery_response(mut response: Value, return_submitted: bool) -> Value {
    let text_delivered = response["result"]["text_delivered"]
        .as_bool()
        .unwrap_or(false);
    let sent = text_delivered && return_submitted;
    let delivery_state = if !text_delivered {
        "paste_failed"
    } else if !return_submitted {
        "return_failed"
    } else {
        "submitted"
    };
    if !response["result"].is_object() {
        response["result"] = json!({});
    }
    response["result"]["sent"] = json!(sent);
    response["result"]["text_delivered"] = json!(text_delivered);
    response["result"]["return_submitted"] = json!(return_submitted);
    response["result"]["delivery_state"] = json!(delivery_state);
    response["ok"] = json!(sent);
    if sent {
        if let Some(object) = response.as_object_mut() {
            object.remove("error");
        }
    } else {
        response["error"] = json!({
            "code": "delivery_failed",
            "message": if text_delivered {
                "Instruction text was delivered but Return submission failed"
            } else {
                "Instruction text was not delivered"
            }
        });
    }
    response
}

pub(crate) fn headless_send_delivery_response(mut response: Value) -> Value {
    if !response["result"].is_object() {
        response["result"] = json!({});
    }
    response["result"]["text_delivered"] = json!(true);
    send_delivery_response(response, true)
}

pub(crate) fn attach_delivery_metadata(mut response: Value, delivery: &Value) -> Value {
    if !response["result"].is_object() {
        response["result"] = json!({});
    }
    for key in [
        "sent",
        "text_delivered",
        "return_submitted",
        "delivery_state",
    ] {
        response["result"][key] = delivery["result"][key].clone();
    }
    response
}

pub(crate) fn reply_failure_response(delivery: &Value, message: &str) -> Value {
    let code = if message.contains("timed out") {
        "reply_timeout"
    } else {
        "reply_failed"
    };
    attach_delivery_metadata(
        json!({
            "ok": false,
            "result": { "reply_received": false },
            "error": { "code": code, "message": message },
        }),
        delivery,
    )
}

pub(crate) fn print_result(result: Result<Value, String>) {
    match result {
        Ok(resp) => {
            println!("{}", pretty(&resp));
            if rpc_response_failed(&resp) {
                eprint_version_skew();
                process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("Error: {e}");
            eprint_version_skew();
            process::exit(1);
        }
    }
}

pub(crate) fn run_best_effort_rpc_with_retry<F>(label: &str, mut call: F)
where
    F: FnMut() -> Result<Value, String>,
{
    for attempt in 0..2 {
        match successful_rpc_envelope(call()) {
            Ok(response) => {
                println!("{}", pretty(&response));
                return;
            }
            Err(error) if attempt == 0 => {
                eprintln!("  Warning: {label} failed: {error}, retrying...");
            }
            Err(error) => eprintln!("  Warning: {label} retry failed: {error}"),
        }
    }
}

pub(crate) fn validate_reply_correlation_id(id: &str) -> Result<(), String> {
    if id.len() < 24
        || id.len() > 128
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err("invalid --reply-to correlation id".to_string());
    }
    Ok(())
}

pub(crate) fn validate_correlation_identity_component(value: &str) -> Result<(), String> {
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err("invalid correlated reply identity".to_string());
    }
    Ok(())
}

pub(crate) fn new_correlation_token() -> Result<String, String> {
    let mut bytes = [0_u8; 32];
    fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .map_err(|error| format!("failed to generate correlation token: {error}"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

pub(crate) fn correlated_reply_params(
    team: &str,
    sender: &str,
    id: &str,
    instance_id: &str,
    body: &str,
) -> Result<Value, String> {
    validate_reply_correlation_id(id)?;
    validate_correlation_identity_component(instance_id)?;
    if body.trim().is_empty() {
        return Err("correlated reply body must not be empty".to_string());
    }
    Ok(json!({
        "team_name": team,
        "from": sender,
        "to": "leader",
        "type": "note",
        "agent_instance_id": instance_id,
        "correlation_token": id,
        "content": body,
    }))
}

pub(crate) fn validate_correlated_reply_overrides(
    has_sender_override: bool,
    has_task_override: bool,
    has_instance_override: bool,
) -> Result<(), String> {
    if has_sender_override || has_task_override || has_instance_override {
        return Err(
            "--reply-to cannot be combined with --from, --task-id, or --agent-instance-id"
                .to_string(),
        );
    }
    Ok(())
}

pub(crate) fn append_correlated_reply_instruction(
    text: &str,
    id: &str,
    instance_id: &str,
) -> Result<String, String> {
    validate_reply_correlation_id(id)?;
    validate_correlation_identity_component(instance_id)?;
    Ok(format!(
        "{text}\n\n[REQUIRED CORRELATED REPLY for instance {instance_id}]\nWhen finished, run this literal heredoc command exactly once, replacing only the response body:\ntm-agent reply --reply-to {id} <<'TERMMESH_REPLY_EOF'\n<response body>\nTERMMESH_REPLY_EOF"
    ))
}

pub(crate) fn register_correlation_mailbox(
    sock: &PathBuf,
    team: &str,
    token: &str,
    expected_agent: &str,
    expected_instance_id: &str,
    expires_in_seconds: u64,
    timeout: Duration,
) -> Result<Value, String> {
    validate_reply_correlation_id(token)?;
    if timeout.is_zero() {
        return Err("correlation registration deadline expired".to_string());
    }
    successful_rpc_envelope(rpc_call_timeout_duration(
        sock,
        "team.correlation.register",
        json!({
            "team_name": team,
            "correlation_token": token,
            "expected_agent_name": expected_agent,
            "expected_agent_instance_id": expected_instance_id,
            "expires_in_seconds": expires_in_seconds,
        }),
        timeout,
    ))
}

pub(crate) fn cancel_correlation_mailbox(sock: &PathBuf, team: &str, token: &str) {
    let _ = successful_rpc_envelope(rpc_call_timeout_duration(
        sock,
        "team.correlation.cancel",
        json!({
            "team_name": team,
            "correlation_token": token,
        }),
        Duration::from_millis(500),
    ));
}

pub(crate) fn correlated_reply_from_mailbox(
    response: Value,
    expected_agent: &str,
    expected_instance_id: &str,
    correlation_id: &str,
) -> Result<Option<Value>, String> {
    validate_reply_correlation_id(correlation_id)?;
    let response = successful_rpc_envelope(Ok(response))?;
    let result = response
        .get("result")
        .ok_or_else(|| "PROTOCOL_ERROR: team.correlation.get has no result".to_string())?;
    if result.get("ready").and_then(Value::as_bool) != Some(true) {
        return Ok(None);
    }
    if result.get("agent_name").and_then(Value::as_str) != Some(expected_agent)
        || result.get("agent_instance_id").and_then(Value::as_str) != Some(expected_instance_id)
    {
        return Err(
            "PROTOCOL_ERROR: correlation mailbox returned a mismatched identity".to_string(),
        );
    }
    let body = result
        .get("content")
        .and_then(Value::as_str)
        .filter(|body| !body.trim().is_empty())
        .ok_or_else(|| "PROTOCOL_ERROR: correlation mailbox returned an empty reply".to_string())?;
    Ok(Some(json!({
        "ok": true,
        "result": {
            "agent": expected_agent,
            "agent_instance_id": expected_instance_id,
            "content": body,
            "message_id": result.get("message_id").cloned().unwrap_or(Value::Null),
        }
    })))
}

/// Poll cadence for a correlated reply. The early probes are quick because
/// the native fast path can land a reply tens of milliseconds after the
/// send; the cadence settles at the historical 100 ms so a long wait costs
/// no more RPCs than it used to. The extra polls all fit in the first
/// quarter second, against a local unix socket.
pub(crate) fn correlation_poll_delay(attempt: usize) -> Duration {
    const LADDER_MS: [u64; 5] = [10, 20, 40, 80, 100];
    Duration::from_millis(LADDER_MS[attempt.min(LADDER_MS.len() - 1)])
}

pub(crate) fn wait_for_correlated_reply_with<P>(
    expected_agent: &str,
    expected_instance_id: &str,
    correlation_id: &str,
    timeout: Duration,
    mut poll: P,
) -> Result<Value, String>
where
    P: FnMut(Duration) -> Result<Value, String>,
{
    let deadline = Instant::now() + timeout;
    let mut attempt = 0usize;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(format!(
                "timed out waiting for correlated reply from {expected_agent}"
            ));
        }
        let response = poll(remaining)?;
        if let Some(reply) = correlated_reply_from_mailbox(
            response,
            expected_agent,
            expected_instance_id,
            correlation_id,
        )? {
            return Ok(reply);
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(format!(
                "timed out waiting for correlated reply from {expected_agent}"
            ));
        }
        thread::sleep(remaining.min(correlation_poll_delay(attempt)));
        attempt += 1;
    }
}

pub(crate) fn wait_for_correlated_reply(
    sock: &PathBuf,
    team: &str,
    expected_agent: &str,
    expected_instance_id: &str,
    correlation_id: &str,
    timeout: Duration,
) -> Result<Value, String> {
    wait_for_correlated_reply_with(
        expected_agent,
        expected_instance_id,
        correlation_id,
        timeout,
        |remaining| {
            rpc_call_timeout_duration(
                sock,
                "team.correlation.get",
                json!({
                    "team_name": team,
                    "correlation_token": correlation_id,
                    "consume": true,
                }),
                remaining,
            )
        },
    )
}

/// The bare `tm-agent reply` contract: nothing about resolving *who* replied may
/// stop the reply from being recorded. The daemon injects the bare form in
/// `REQUIRED_FINAL_STEP_BLOCK`, `REPORT_SUFFIX`, `BROADCAST_SUFFIX` and
/// `agent_init_prompt`, so that form has to survive a duplicated agent name and
/// an instance it cannot resolve.
#[cfg(test)]
mod reply_completion_regression_169_tests {
    use super::*;

    #[test]
    fn reply_requires_at_least_one_durable_copy() {
        let full_reply = "x".repeat(1601);
        assert_ne!(truncate_summary(&full_reply, 1500), full_reply);
        for fault in [
            AtomicWriteFault::Write,
            AtomicWriteFault::Sync,
            AtomicWriteFault::Rename,
        ] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("reply.md");
            let error = atomic_write_file_with_fault(&path, &full_reply, Some(fault))
                .expect_err("injected durable write must fail");
            assert!(
                !path.exists(),
                "a failed write must not publish a partial reply"
            );
            assert!(
                require_durable_reply(Err(error.clone()), Some(Err(error))).is_err(),
                "two failed durable writes must prevent reply completion"
            );
        }
    }

    #[test]
    fn one_durable_copy_is_enough_to_continue() {
        let durable = PathBuf::from("/tmp/task.md");
        let (alias, task, errors) =
            require_durable_reply(Err("alias failed".to_string()), Some(Ok(durable.clone())))
                .expect("the canonical task copy is durable");
        assert_eq!(alias, None);
        assert_eq!(task, Some(durable));
        assert_eq!(errors, vec!["alias failed"]);
    }

    #[test]
    fn bare_reply_closes_only_the_current_duplicate_name_instance_task() {
        let agents = vec![
            json!({
                "name": "executor",
                "panel_id": "panel-a",
                "workspace_id": "workspace-a",
                "agent_instance_id": "instance-a",
            }),
            json!({
                "name": "executor",
                "panel_id": "panel-b",
                "workspace_id": "workspace-b",
                "agent_instance_id": "instance-b",
            }),
        ];
        let tasks = vec![
            json!({
                "id": "task-a", "status": "in_progress",
                "agent_instance_id": "instance-a", "created_at": "2026-07-30T01:00:00Z",
            }),
            json!({
                "id": "task-b", "status": "in_progress",
                "agent_instance_id": "instance-b", "created_at": "2026-07-30T02:00:00Z",
            }),
        ];

        let current_instance = instance_id_from_current_pane(
            &agents,
            "executor",
            Some("panel-a"),
            Some("workspace-a"),
        );
        assert_eq!(current_instance.as_deref(), Some("instance-a"));
        let (selected, candidates) =
            select_reply_task_from_tasks(&tasks, current_instance.as_deref());
        assert_eq!(candidates, vec!["task-a"]);
        let (task_id, withheld) = reply_task_decision(selected, &candidates);
        assert_eq!(task_id.as_deref(), Some("task-a"));
        assert_eq!(withheld, None);
    }

    #[test]
    fn unresolved_current_instance_preserves_duplicate_task_ambiguity() {
        let tasks = vec![
            json!({"id": "task-a", "status": "in_progress", "agent_instance_id": "instance-a"}),
            json!({"id": "task-b", "status": "in_progress", "agent_instance_id": "instance-b"}),
        ];
        let (selected, candidates) = select_reply_task_from_tasks(&tasks, None);
        let (task_id, withheld) = reply_task_decision(selected, &candidates);
        assert_eq!(task_id, None);
        assert!(withheld.expect("ambiguity reason").contains("--task-id"));
    }

    /// One live task closes normally even when the sender's name is duplicated:
    /// the task row itself names the instance that was given the work.
    #[test]
    fn a_single_live_task_still_closes() {
        let candidates = vec!["task-a".to_string()];
        let (task_id, withheld) = reply_task_decision(Some("task-a".to_string()), &candidates);
        assert_eq!(task_id.as_deref(), Some("task-a"));
        assert_eq!(withheld, None);
    }

    /// Two live tasks withhold the transition and say why — but they return a
    /// reason instead of ending the process, so the caller still writes the
    /// durable copies and posts the report.
    #[test]
    fn ambiguity_withholds_the_transition_instead_of_aborting() {
        let candidates = vec!["task-a".to_string(), "task-b".to_string()];
        let (task_id, withheld) = reply_task_decision(Some("task-a".to_string()), &candidates);
        assert_eq!(task_id, None, "no task may be closed on a guess");
        let reason = withheld.expect("a withheld transition must explain itself");
        assert!(reason.contains("--task-id"), "{reason}");
        assert!(
            reason.contains("task-a") && reason.contains("task-b"),
            "{reason}"
        );
    }

    /// No live task at all is not ambiguous; it falls through to whatever the
    /// board selected (`None` here), which the command reports as
    /// `no_active_task` after writing the alias.
    #[test]
    fn no_candidates_is_not_ambiguous() {
        let (task_id, withheld) = reply_task_decision(None, &[]);
        assert_eq!(task_id, None);
        assert_eq!(withheld, None);
    }

    /// An unresolved instance degrades the alias, it does not lose the reply.
    /// Both filenames stay inside the results directory, so either one is a
    /// legitimate durable copy for the leader to read.
    #[test]
    fn an_unresolved_instance_falls_back_to_a_name_scoped_alias() {
        assert_eq!(
            reply_alias_filename("executor", Some("inst-2")),
            "executor-inst-2-reply.md"
        );
        assert_eq!(reply_alias_filename("executor", None), "executor-reply.md");
        // Empty is the same answer as absent: an instance id nobody could
        // resolve must not produce an `executor--reply.md`.
        assert_eq!(
            reply_alias_filename("executor", Some("")),
            "executor-reply.md"
        );

        let names = task_result_candidates("team-a", "task-a", "executor", None)
            .iter()
            .filter_map(|path| {
                path.file_name()
                    .and_then(|name| name.to_str().map(str::to_owned))
            })
            .collect::<Vec<_>>();
        assert_eq!(names, vec!["task-a.md", "executor-reply.md"]);
    }
}
