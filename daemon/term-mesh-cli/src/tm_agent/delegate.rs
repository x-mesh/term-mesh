use super::*;

// ── Research helpers ──────────────────────────────────────────────────────────

/// Lightweight info about one agent, extracted from `team.status` response.
#[derive(Debug, Clone)]
pub(crate) struct AgentInfo {
    pub(crate) name: String,
    #[allow(dead_code)] // Parsed from status, used for future model routing
    model: String,
    cli: String,
    agent_state: String,
    /// panel_id of this agent's pane (used for deterministic per-pane fan-out routing)
    #[allow(dead_code)]
    // Parsed from status; fan-out reads panel_id from raw status JSON directly
    panel_id: Option<String>,
}

impl AgentInfo {
    fn from_value(v: &Value) -> Option<Self> {
        let name = v["name"].as_str()?.to_string();
        let model = v["model"].as_str().unwrap_or("sonnet").to_string();
        let cli = v["cli"].as_str().unwrap_or("claude").to_string();
        let agent_state = v["agent_state"].as_str().unwrap_or("").to_string();
        let panel_id = v["panel_id"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(String::from);
        Some(Self {
            name,
            model,
            cli,
            agent_state,
            panel_id,
        })
    }
}

/// Query `team.status` and return agents that are currently idle,
/// optionally restricted to those running the given CLI (e.g. "claude").
pub(crate) fn detect_idle_agents(
    sock: &PathBuf,
    team: &str,
    model_filter: Option<&str>,
) -> Vec<AgentInfo> {
    let status = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error querying team status: {e}");
            return Vec::new();
        }
    };

    let agents = match status["result"]["agents"].as_array() {
        Some(a) => a.clone(),
        None => return Vec::new(),
    };

    agents
        .iter()
        .filter_map(AgentInfo::from_value)
        .filter(|a| a.agent_state == "idle")
        .filter(|a| {
            if let Some(filter) = model_filter {
                a.cli == filter
            } else {
                true
            }
        })
        .collect()
}

/// Choose which agents to assign from the idle pool.
///
/// Returns `(selected, warning)`:
/// - If no idle agents → returns empty vec and an error string (caller should exit).
/// - If fewer idle agents than `requested` → returns all idle with a warning.
/// - Otherwise → returns exactly `requested` agents (or all if `requested == 0`).
pub(crate) fn select_agents(
    idle: Vec<AgentInfo>,
    requested: u32,
) -> (Vec<AgentInfo>, Option<String>) {
    if idle.is_empty() {
        return (
            Vec::new(),
            Some("No idle agents. Create a team first: tm-agent create 3".to_string()),
        );
    }

    if requested == 0 || requested as usize >= idle.len() {
        // Use all idle agents; warn if we asked for more than available.
        let warn = if requested > 0 && (requested as usize) > idle.len() {
            Some(format!(
                "Warning: requested {requested} agents but only {} idle — using all {}.",
                idle.len(),
                idle.len()
            ))
        } else {
            None
        };
        (idle, warn)
    } else {
        (idle.into_iter().take(requested as usize).collect(), None)
    }
}

pub(crate) fn task_title_from_text(text: &str) -> String {
    let compact: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.is_empty() {
        "Untitled task".to_string()
    } else if compact.len() > 80 {
        // Find a valid char boundary at or before byte 80
        let mut end = 80;
        while end > 0 && !compact.is_char_boundary(end) {
            end -= 1;
        }
        compact[..end].to_string()
    } else {
        compact
    }
}

/// Format instruction for autonomous mode: task context + instruction only.
/// No lifecycle commands (task start/done/reply) since the detached monitor handles completion.
pub(crate) fn format_autonomous_instruction(
    task: &Value,
    instruction: &str,
    context: Option<&str>,
) -> String {
    let mut lines = vec![
        format!("[TASK_ID] {}", task["id"].as_str().unwrap_or("")),
        format!("[TASK_TITLE] {}", task["title"].as_str().unwrap_or("")),
    ];
    if let Some(ctx) = context {
        let truncated = truncate_summary(ctx, 3000);
        lines.push(String::new());
        lines.push("[PRIOR_CONTEXT]".to_string());
        lines.push(truncated);
        lines.push("[/PRIOR_CONTEXT]".to_string());
    }
    lines.push(String::new());
    lines.push(instruction.trim().to_string());
    lines.join("\n")
}

pub(crate) fn format_task_instruction(
    sock: &PathBuf,
    team: &str,
    task: &Value,
    instruction: &str,
    no_report: bool,
    context: Option<&str>,
    fix_budget: Option<u8>,
) -> String {
    let task_id = task["id"].as_str().unwrap_or("");
    // Mirror Swift formatDelegateInstruction: prepend the required final step
    // at the top so the model sees the literal shell command before the goal.
    let mut lines: Vec<String> = REQUIRED_FINAL_STEP_BLOCK
        .lines()
        .map(|s| s.to_string())
        .collect();
    lines.push(String::new());
    lines.extend(vec![
        "## Task Capsule".to_string(),
        format!("TASK_ID: {task_id}"),
        format!("TASK_TITLE: {}", task["title"].as_str().unwrap_or("")),
        format!(
            "TASK_STATUS: {}",
            task["status"].as_str().unwrap_or("assigned")
        ),
        "PROTOCOL: TM-PROTOCOL-v1".to_string(),
        "OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT header plus concise summary".to_string(),
    ]);
    if let Some(p) = task["priority"].as_u64() {
        lines.push(format!("TASK_PRIORITY: {p}"));
    }
    if let Some(path) = task["worktree_path"].as_str().filter(|s| !s.is_empty()) {
        lines.push(format!("WORKTREE_PATH: {path}"));
        if let Some(branch) = task["worktree_branch"].as_str().filter(|s| !s.is_empty()) {
            lines.push(format!("WORKTREE_BRANCH: {branch}"));
        }
        lines.push(format!(
            "WORKDIR_INSTRUCTION: Run commands from this worktree: cd {}",
            shell_quote(path)
        ));
        lines.push(format!(
            "NEXT_HINT: after reporting, the leader can run `tm-agent task finish-worktree {task_id} --to parent --cleanup`"
        ));
    }
    if let Some(ac) = task["acceptance_criteria"].as_array() {
        if !ac.is_empty() {
            lines.push("[ACCEPTANCE]".to_string());
            for item in ac {
                lines.push(format!("- {}", item.as_str().unwrap_or("")));
            }
        }
    }
    if let Some(deps) = task["depends_on"].as_array() {
        if !deps.is_empty() {
            let dep_strs: Vec<&str> = deps.iter().filter_map(|d| d.as_str()).collect();
            lines.push(format!("[DEPS] {}", dep_strs.join(", ")));
            // Inject dependency results for completed deps
            for dep_id in &dep_strs {
                if let Ok(dep_resp) = rpc_call(
                    sock,
                    "team.task.get",
                    json!({
                        "team_name": team, "task_id": dep_id,
                    }),
                ) {
                    let dep_task = &dep_resp["result"];
                    if dep_task["status"].as_str() == Some("completed") {
                        let content = if let Some(path) = dep_task["result_path"].as_str() {
                            std::fs::read_to_string(path).ok()
                        } else {
                            dep_task["result"].as_str().map(String::from)
                        };
                        if let Some(text) = content {
                            let dep_ref = write_result_file(
                                team,
                                &format!("{task_id}-dep-{dep_id}.md"),
                                &text,
                            )
                            .map(|p| p.to_string_lossy().to_string());
                            let truncated = truncate_summary(&text, 600);
                            if let Ok(path) = dep_ref.as_ref() {
                                lines.push(format!("DEP_REF: {dep_id} {path}"));
                            } else if let Err(err) = dep_ref.as_ref() {
                                eprintln!(
                                    "warning: failed to write dependency result ref for {dep_id}: {err}"
                                );
                            }
                            lines.push(format!("\n[DEP_RESULT: {dep_id}]"));
                            lines.push(truncated);
                            lines.push(format!("[/DEP_RESULT]"));
                        }
                    }
                }
            }
        }
    }
    if let Some(desc) = task["description"].as_str() {
        if !desc.is_empty() {
            lines.push(format!("[TASK_DESCRIPTION] {desc}"));
        }
    }
    if let Some(ctx) = context {
        let context_ref = write_result_file(team, &format!("{task_id}-context.md"), ctx)
            .map(|p| p.to_string_lossy().to_string());
        let truncated = truncate_summary(ctx, if context_ref.is_ok() { 500 } else { 3000 });
        lines.push(String::new());
        match context_ref {
            Ok(path) => lines.push(format!("CONTEXT_REF: {path}")),
            Err(err) => {
                eprintln!("warning: failed to write context ref for task {task_id}: {err}");
                lines.push(format!("CONTEXT_REF_ERROR: {err}"));
            }
        }
        lines.push("[CONTEXT_SUMMARY]".to_string());
        lines.push(truncated);
        lines.push("[/CONTEXT_SUMMARY]".to_string());
    }

    lines.push(String::new());
    lines.push("[GOAL]".to_string());
    lines.push(instruction.trim().to_string());
    lines.push("[/GOAL]".to_string());
    append_team_checkout_topology(sock, team, task, &mut lines);
    append_checkout_contract(&mut lines);

    // Inject Auto-Fix Budget rules when budget is set
    if let Some(budget) = fix_budget {
        lines.push(String::new());
        lines.push(format!("## Auto-Fix Budget: {budget} attempts"));
        lines.push(format!("BEFORE each build/test/error fix attempt, run:"));
        lines.push(format!("  tm-agent task fix-attempt {task_id}"));
        lines.push(format!(
            "If it prints BUDGET_EXHAUSTED, stop immediately — you are auto-blocked."
        ));
        lines.push(format!("Architecture decisions (new deps, API/schema changes) require immediate block regardless of budget."));
    }

    let body = lines.join("\n");
    append_report_suffix(body.trim(), no_report)
}

pub(crate) fn append_team_checkout_topology(
    sock: &PathBuf,
    team: &str,
    task: &Value,
    lines: &mut Vec<String>,
) {
    let Ok(status) = rpc_call(sock, "team.status", json!({ "team_name": team })) else {
        return;
    };
    let result = &status["result"];
    lines.extend(team_checkout_topology_lines(result, task));
}

pub(crate) fn team_checkout_topology_lines(result: &Value, task: &Value) -> Vec<String> {
    let Some(agents) = result["agents"].as_array() else {
        return Vec::new();
    };
    let target_instance = task["agent_instance_id"].as_str();
    // `checkout_mode` is what the leader was briefed with, already resolved
    // by the app — including a deliberate "unknown" for a peer team whose
    // layout nobody recorded. Only its ABSENCE means an older app, so only
    // absence falls back to `worktree_mode`, which says whether local git
    // worktrees were requested and is "off" for every all-peer team.
    let mode = result["checkout_mode"]
        .as_str()
        .map(str::trim)
        .filter(|mode| !mode.is_empty())
        .or_else(|| result["worktree_mode"].as_str())
        .unwrap_or("unknown");
    let leader_path = result["working_directory"].as_str().unwrap_or("unknown");
    let integration_target = result["integration_target_path"]
        .as_str()
        .unwrap_or(leader_path);
    let mut lines = vec![
        String::new(),
        "## Team Checkout Topology".to_string(),
        format!("TEAM_CHECKOUT_MODE: {mode}"),
        format!("LEADER_CHECKOUT_PATH: {leader_path}"),
        "LEADER_CHECKOUT_ROLE: integration-owner".to_string(),
        format!("INTEGRATION_TARGET_PATH: {integration_target}"),
    ];
    for agent in agents {
        if target_instance.is_some() && agent["agent_instance_id"].as_str() == target_instance {
            continue;
        }
        lines.push(format!(
            "PEER_CHECKOUT: name={} instance={} branch={} path={}",
            agent["name"].as_str().unwrap_or("unknown"),
            agent["agent_instance_id"].as_str().unwrap_or("unknown"),
            agent["worktree_branch"]
                .as_str()
                .unwrap_or("shared-or-unknown"),
            agent["worktree_path"]
                .as_str()
                .or_else(|| agent["working_directory"].as_str())
                .unwrap_or("unknown"),
        ));
    }
    lines.push(match mode {
        "isolated" => "TOPOLOGY_RULE: Isolated. Each worker writes in its own checkout, which satisfies ownership separation: owned and forbidden path lists are optional, and concurrent write tasks may touch the same paths. Give each task a goal, done criteria, and one verification command. If a task needs a shared-code change, make it there instead of duplicating code or deferring the connection to another worker. The leader merges each task branch serially with git merge and resolves conflicts inside that merge; never copy files out of a task branch instead of merging it.",
        "shared" => "TOPOLOGY_RULE: Workers share one checkout. Serialize writes unless the paths are proven disjoint.",
        "off" => "TOPOLOGY_RULE: No managed worktree isolation is active. Do not run concurrent writes without another verified isolation boundary.",
        _ => "TOPOLOGY_RULE: Checkout isolation is unknown. Query team.status before concurrent writes.",
    }.to_string());
    lines
}

pub(crate) fn append_checkout_contract(lines: &mut Vec<String>) {
    lines.extend([
        String::new(),
        "## Source Control Contract".to_string(),
        "CHECKOUT_CONTRACT_PRIORITY: This platform contract overrides goal text that requires the current branch name to equal the project target branch.".to_string(),
        "CHECKOUT_RULES:".to_string(),
        "- An agent/*, team/*, or other assigned worktree branch is expected and valid.".to_string(),
        "- Never block solely because the current branch name differs from the project target branch.".to_string(),
        "- Read-only work: fetch origin once if the required ref is missing or stale, then inspect explicit refs directly (for example, git diff <base>...<target>). Do not checkout, reset, merge, or rebase.".to_string(),
        "- Write work: stay on the assigned branch. If it does not contain the required target revision, report NEEDS_REVIEW and ask the leader for an explicit sync; do not take over a branch checked out elsewhere.".to_string(),
        "- Use BLOCKED only when required refs remain unavailable after one fetch, the repository is unreadable, or the requested evidence cannot be obtained.".to_string(),
    ]);
}

#[cfg(test)]
mod checkout_contract_tests {
    use super::*;

    #[test]
    fn contract_follows_goal_and_accepts_isolated_agent_branches() {
        let mut lines = vec![
            "[GOAL]".to_string(),
            "Require the current branch to be main.".to_string(),
            "[/GOAL]".to_string(),
        ];

        append_checkout_contract(&mut lines);
        let rendered = lines.join("\n");

        assert!(
            rendered.find("[/GOAL]").unwrap()
                < rendered.find("CHECKOUT_CONTRACT_PRIORITY").unwrap()
        );
        assert!(rendered.contains("agent/*, team/*"));
        assert!(rendered.contains("Never block solely"));
        assert!(rendered.contains("inspect explicit refs directly"));
        assert!(rendered.contains("Do not checkout, reset, merge, or rebase"));
    }

    #[test]
    fn task_topology_lists_isolated_peers_and_skips_self() {
        let status = json!({"worktree_mode":"isolated","working_directory":"/repo","integration_target_path":"/repo","agents": [
            {"name":"executor","agent_instance_id":"a","worktree_path":"/wt/a","worktree_branch":"team/a"},
            {"name":"reviewer","agent_instance_id":"b","worktree_path":"/wt/b","worktree_branch":"team/b"}
        ]});
        let rendered =
            team_checkout_topology_lines(&status, &json!({"agent_instance_id":"a"})).join("\n");
        assert!(rendered.contains("TEAM_CHECKOUT_MODE: isolated"));
        assert!(
            rendered.contains("PEER_CHECKOUT: name=reviewer instance=b branch=team/b path=/wt/b")
        );
        assert!(!rendered.contains("PEER_CHECKOUT: name=executor instance=a"));
    }

    #[test]
    fn topology_prefers_the_recorded_checkout_mode() {
        // `worktree_mode` is "off" for every all-peer team even when the
        // bootstrap isolated every member, so the worker brief would tell an
        // agent not to write where its leader had just sent it.
        let status = json!({"checkout_mode":"isolated","worktree_mode":"off","working_directory":"/repo","integration_target_path":"/repo","agents": [
            {"name":"executor","agent_instance_id":"a","worktree_path":"/wt/a","worktree_branch":"team/a"},
            {"name":"reviewer","agent_instance_id":"b","worktree_path":"/wt/b","worktree_branch":"team/b"}
        ]});
        let rendered =
            team_checkout_topology_lines(&status, &json!({"agent_instance_id":"a"})).join("\n");
        assert!(rendered.contains("TEAM_CHECKOUT_MODE: isolated"));
        assert!(rendered.contains("owned and forbidden path lists are optional"));
        assert!(rendered.contains("never copy files out of a task branch instead of merging it"));
    }

    #[test]
    fn topology_falls_back_only_when_the_key_is_absent() {
        // An older app does not send the key at all; then `worktree_mode` is
        // all there is.
        let status = json!({"worktree_mode":"isolated","working_directory":"/repo","integration_target_path":"/repo","agents": [
            {"name":"executor","agent_instance_id":"a","worktree_path":"/wt/a","worktree_branch":"team/a"}
        ]});
        let rendered =
            team_checkout_topology_lines(&status, &json!({"agent_instance_id":"b"})).join("\n");
        assert!(rendered.contains("TEAM_CHECKOUT_MODE: isolated"));
    }

    #[test]
    fn topology_keeps_a_published_unknown_as_the_hedge() {
        // The app resolves before publishing: "unknown" is its answer for a
        // peer team with nothing recorded. Re-resolving it here briefed the
        // worker "no isolation is active" while its leader was told to query
        // team.status.
        let status = json!({"checkout_mode":"unknown","worktree_mode":"off","working_directory":"/repo","integration_target_path":"/repo","agents": [
            {"name":"executor","agent_instance_id":"a"}
        ]});
        let rendered =
            team_checkout_topology_lines(&status, &json!({"agent_instance_id":"b"})).join("\n");
        assert!(rendered.contains("TEAM_CHECKOUT_MODE: unknown"));
        assert!(rendered.contains("Checkout isolation is unknown"));
    }

    #[test]
    fn legacy_topology_does_not_guess_isolation_from_stale_paths() {
        let status = json!({"agents": [
            {"name":"a","agent_instance_id":"a","worktree_path":"/old/a"},
            {"name":"b","agent_instance_id":"b","worktree_path":"/old/b"}
        ]});
        let rendered =
            team_checkout_topology_lines(&status, &json!({"agent_instance_id":"a"})).join("\n");
        assert!(rendered.contains("TEAM_CHECKOUT_MODE: unknown"));
        assert!(rendered.contains("Checkout isolation is unknown"));
    }
}

pub(crate) struct DelegateOptions<'a> {
    pub(crate) title: Option<String>,
    pub(crate) priority: Option<u32>,
    pub(crate) accept: &'a [String],
    pub(crate) deps: &'a [String],
    pub(crate) desc: Option<String>,
    pub(crate) no_report: bool,
    pub(crate) context: Option<&'a str>,
    pub(crate) fix_budget: Option<u8>,
    pub(crate) panel_id: Option<&'a str>,
    pub(crate) agent_instance_id: Option<&'a str>,
    pub(crate) worktree_policy: WorktreePolicyArg,
    pub(crate) from_ref: Option<&'a str>,
    pub(crate) request_id: Option<&'a str>,
    /// Measurement only, forwarded verbatim to the board. See `TeamTask.route`.
    pub(crate) route: Option<&'a str>,
    /// Measurement only, forwarded verbatim to the board. See `TeamTask.waveId`.
    pub(crate) wave_id: Option<&'a str>,
}

pub(crate) fn run_delegate_result(
    sock: &PathBuf,
    team: &str,
    target: &str,
    text: &str,
    options: DelegateOptions<'_>,
) -> Result<Value, String> {
    let DelegateOptions {
        title,
        priority,
        accept,
        deps,
        desc,
        no_report,
        context,
        fix_budget,
        panel_id,
        agent_instance_id,
        worktree_policy,
        from_ref,
        request_id,
        route,
        wave_id,
    } = options;
    let resolved_title = title.unwrap_or_else(|| task_title_from_text(text));
    let resolved_priority = priority.unwrap_or(2);
    // Resolve the pane once, before either task creation path. An explicit
    // panel must never degrade into name-only routing on status failure.
    let selected_target =
        selected_delegate_target(sock, team, target, panel_id, agent_instance_id)?;
    let selected_instance_id = selected_target.agent_instance_id.as_deref();
    let request_id = request_id
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(local_request_id);

    if should_acquire_worktree(
        worktree_policy,
        target,
        text,
        &resolved_title,
        desc.as_deref(),
    ) {
        return run_delegate_result_with_worktree(
            sock,
            team,
            target,
            text,
            resolved_title,
            resolved_priority,
            accept,
            deps,
            desc,
            no_report,
            context,
            fix_budget,
            panel_id,
            selected_instance_id,
            selected_target.working_directory.as_deref(),
            worktree_policy,
            from_ref,
            &request_id,
            route,
            wave_id,
        );
    }

    // Retry an unknown transport outcome once with the exact same idempotency key.
    let delegate_params = delegate_rpc_params(
        team,
        target,
        text,
        &resolved_title,
        resolved_priority,
        accept,
        deps,
        desc.as_deref(),
        context,
        fix_budget,
        panel_id,
        selected_instance_id,
        &request_id,
        route,
        wave_id,
    );
    let unified = resolve_unified_delegate(&delegate_params, &request_id, |params| {
        rpc_call(sock, "team.delegate", params.clone())
    })?;
    if let UnifiedDelegateOutcome::Response(v) = unified {
        // Check if text was actually delivered to the agent's terminal
        let mut text_delivered = v["result"]["text_delivered"].as_bool().unwrap_or(true);
        if !text_delivered {
            eprintln!("text.delivered.false reason=team.delegate_ack agent={target}");
            let task_ref = &v["result"]["task"];
            let instruction =
                format_task_instruction(sock, team, task_ref, text, no_report, context, fix_budget);

            // Headless agent path: route via daemon socket if available
            if let Some(daemon_sock) = team_headless_daemon_socket() {
                if let Some(agent_id) = is_headless_agent(&daemon_sock, team, target) {
                    let headless_ok = match rpc_call(
                        &daemon_sock,
                        "headless.send",
                        json!({
                            "agent_id": agent_id,
                            "text": format!("{instruction}\n"),
                        }),
                    ) {
                        Ok(ref hr) => !hr["result"].is_null(),
                        Err(_) => false,
                    };
                    if !headless_ok {
                        eprintln!("  Warning: headless.send failed for {target}");
                        let task_id = v["result"]["task"]["id"]
                            .as_str()
                            .unwrap_or("?")
                            .to_string();
                        let reason = format!("headless paste delivery failed: headless.send RPC returned null (agent={target})");
                        let _ = rpc_call(
                            sock,
                            "team.task.update",
                            json!({
                                "team_name": team,
                                "task_id": &task_id,
                                "status": "blocked",
                                "blocked_reason": &reason,
                            }),
                        );
                        return Err(format!(
                            "delivery failed; task blocked: {reason} (task_id={task_id})"
                        ));
                    }
                    return Ok(v);
                }
            }

            // In-app panel retry: agent is not headless, retry via team.send.
            // The server-side already retried twice (150ms + 400ms). Give one final
            // CLI-side attempt after a short pause for late panel init.
            eprintln!(
                "  Warning: text not delivered to agent '{target}', retrying via team.send..."
            );
            std::thread::sleep(std::time::Duration::from_millis(300));
            let retry = rpc_call(
                sock,
                "team.send",
                json!({
                    "team_name": team, "agent_name": target,
                    "text": format!("{instruction}\n"),
                    "panel_id": panel_id,
                    "agent_instance_id": selected_instance_id,
                    "send_sequence_aware": true,
                }),
            );
            match &retry {
                Ok(rv) if rv["ok"].as_bool().unwrap_or(false) => {
                    // team.send succeeded — text was delivered. Update the response.
                    let mut patched = v.clone();
                    patched["result"]["text_delivered"] = json!(true);
                    text_delivered = true;
                    if !delegate_return_already_submitted(&v) {
                        let _ = send_return_key_with_retry(
                            sock,
                            team,
                            target,
                            text_delivered,
                            "team.delegate.retry",
                            panel_id,
                            selected_instance_id.as_deref(),
                            rv["result"]["send_sequence_id"].as_str(),
                            send_response_return_required(rv),
                        );
                    }
                    return Ok(patched);
                }
                _ => {
                    eprintln!("  Warning: retry also failed — task created but text may not have been delivered.");
                    if let Some(task_id) = v["result"]["task"]["id"].as_str() {
                        let reason = format!("paste delivery failed: surface-nil 4-retry + team.send fallback exhausted (agent={target})");
                        let _ = rpc_call(
                            sock,
                            "team.task.update",
                            json!({
                                "team_name": team,
                                "task_id": task_id,
                                "status": "blocked",
                                "blocked_reason": reason,
                            }),
                        );
                    }
                }
            }
        }

        // If text still not delivered after all retries, return failure so callers
        // get a nonzero exit code (task was already blocked above).
        if !text_delivered {
            let task_id = v["result"]["task"]["id"]
                .as_str()
                .unwrap_or("?")
                .to_string();
            let reason = format!("paste delivery failed: surface-nil 4-retry + team.send fallback exhausted (agent={target})");
            return Err(format!(
                "delivery failed; task blocked: {reason} (task_id={task_id})"
            ));
        }

        // Remote leader proxy asked the authoritative dispatcher to
        // commit paste + Return inside the same deduplicated request.
        // Sending another key here would submit the prompt twice.
        if delegate_return_already_submitted(&v) {
            return Ok(v);
        }

        // Send Return key separately via team.send_key RPC.
        // delegateToAgent sends text WITHOUT Return (paste only). Return is sent
        // through the reliable sendNamedKey path (same as surface.send_key RPC).
        // Swift ack-based completion is the primary ordering guarantee;
        // this sleep is a minimal safety margin only.
        let _ = send_return_key_with_retry(
            sock,
            team,
            target,
            text_delivered,
            "team.delegate",
            panel_id,
            selected_instance_id.as_deref(),
            v["result"]["send_sequence_id"].as_str(),
            send_response_return_required(&v),
        );

        return Ok(v);
    }

    if remote_leader_route().is_some() {
        return Err("owner does not support team.delegate; \
             legacy fallback is disabled for a scoped remote leader"
            .to_string());
    }

    // Fallback: 2-RPC path (server may not support team.delegate yet).
    // Reuse a single UnixStream connection for task.create → team.send to avoid
    // two separate connect() calls. task_id from create is needed for the send
    // instruction, so requests remain sequential but share one connection.
    let mut params = json!({
        "team_name": team,
        "title": resolved_title,
                "assignee": target,
        "priority": resolved_priority,
        "agent_instance_id": selected_instance_id,
        "request_id": request_id,
    });
    if let Some(d) = desc {
        params["description"] = json!(d);
    }
    if !accept.is_empty() {
        params["acceptance_criteria"] = json!(accept);
    }
    if !deps.is_empty() {
        params["depends_on"] = json!(deps);
    }
    if let Some(fb) = fix_budget {
        params["fix_budget"] = json!(fb);
    }

    // Open one connection for both task.create and team.send.
    let fallback_stream = UnixStream::connect(sock).map_err(|e| format!("connect: {e}"))?;
    fallback_stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .ok();
    fallback_stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .ok();

    // Use one shared BufReader for both sequential RPC calls so its internal
    // read-ahead buffer is preserved between calls.  Creating a new BufReader
    // per call (as rpc_call_on_stream does) risks losing bytes that the first
    // BufReader pre-fetched from the OS socket buffer when it is dropped.
    let mut fallback_reader = BufReader::new(&fallback_stream);

    let created = rpc_call_with_reader(
        &fallback_stream,
        &mut fallback_reader,
        "team.task.create",
        params,
    )
    .map_err(|e| format!("task.create: {e}"))?;

    let task = &created["result"];
    let task_id = task["id"].as_str().unwrap_or("");
    if !created["ok"].as_bool().unwrap_or(false) || task_id.is_empty() {
        return Err(format!("task.create failed: {}", pretty(&created)));
    }

    let instruction =
        format_task_instruction(sock, team, task, text, no_report, context, fix_budget);
    let send_text = format!("{instruction}\n");

    // Headless agent path: route via daemon socket for 2-RPC fallback too
    if let Some(daemon_sock) = team_headless_daemon_socket() {
        if let Some(agent_id) = is_headless_agent(&daemon_sock, team, target) {
            let sent_ok = match rpc_call(
                &daemon_sock,
                "headless.send",
                json!({
                    "agent_id": agent_id,
                    "text": &send_text,
                }),
            ) {
                Ok(ref hr) => !hr["result"].is_null(),
                Err(_) => false,
            };
            if !sent_ok {
                eprintln!("  Warning: headless.send failed in 2-RPC fallback");
                let reason = format!(
                    "legacy delegate fallback failed: headless.send returned null (agent={target})"
                );
                let _ = rpc_call(
                    sock,
                    "team.task.update",
                    json!({
                        "team_name": team,
                        "task_id": task_id,
                        "status": "blocked",
                        "blocked_reason": &reason,
                    }),
                );
                return Err(format!(
                    "delivery failed; task blocked: {reason} (task_id={task_id})"
                ));
            }
            return Ok(json!({ "task": task, "send": { "ok": sent_ok } }));
        }
    }

    // In-app panel path: reuse the same connection and BufReader for team.send.
    let sent = rpc_call_with_reader(
        &fallback_stream,
        &mut fallback_reader,
        "team.send",
        json!({
            "team_name": team, "agent_name": target,
            "text": &send_text,
            "panel_id": panel_id,
            "agent_instance_id": selected_instance_id,
            "send_sequence_aware": true,
        }),
    )
    .map_err(|e| format!("team.send: {e}"))?;

    if !sent["ok"].as_bool().unwrap_or(false) {
        // Retry once after 300ms — task is already created, so we must not abandon it.
        // Server-side team.send already retries internally (150ms + 400ms).
        eprintln!("  Warning: team.send failed for '{target}', retrying in 300ms...");
        std::thread::sleep(std::time::Duration::from_millis(300));
        let retry = rpc_call(
            sock,
            "team.send",
            json!({
                "team_name": team, "agent_name": target,
                "text": &send_text,
                "panel_id": panel_id,
                "agent_instance_id": selected_instance_id,
                "send_sequence_aware": true,
            }),
        );
        match retry {
            Ok(ref rv) if rv["ok"].as_bool().unwrap_or(false) => {
                eprintln!("  Retry succeeded.");
                return Ok(json!({ "task": task, "send": rv }));
            }
            _ => {
                let reason = format!(
                    "legacy delegate fallback failed: team.send error after retry (agent={target})"
                );
                let _ = rpc_call(
                    sock,
                    "team.task.update",
                    json!({
                        "team_name": team,
                        "task_id": task_id,
                        "status": "blocked",
                        "blocked_reason": reason,
                    }),
                );
                return Err(format!("team.send failed after retry: {}", pretty(&sent)));
            }
        }
    }

    Ok(json!({ "task": task, "send": sent }))
}

pub(crate) fn delegate_rpc_params(
    team: &str,
    target: &str,
    text: &str,
    title: &str,
    priority: u32,
    accept: &[String],
    deps: &[String],
    desc: Option<&str>,
    context: Option<&str>,
    fix_budget: Option<u8>,
    panel_id: Option<&str>,
    agent_instance_id: Option<&str>,
    request_id: &str,
    route: Option<&str>,
    wave_id: Option<&str>,
) -> Value {
    let mut params = json!({
        "team": team,
        "agent": target,
        "text": text,
        "task_title": title,
        "priority": priority,
        "agent_instance_id": agent_instance_id,
        "request_id": request_id,
    });
    if !accept.is_empty() {
        params["acceptance_criteria"] = json!(accept);
    }
    if !deps.is_empty() {
        params["depends_on"] = json!(deps);
    }
    if let Some(description) = desc {
        params["description"] = json!(description);
    }
    if let Some(ctx) = context {
        params["context"] = json!(ctx);
    }
    if let Some(fb) = fix_budget {
        params["fix_budget"] = json!(fb);
    }
    if let Some(pid) = panel_id {
        params["panel_id"] = json!(pid);
    }
    // Omitted rather than sent as null when unstated: absent reads as "the
    // leader did not classify this", which is what nil means on the board.
    if let Some(r) = route.filter(|v| !v.trim().is_empty()) {
        params["route"] = json!(r);
    }
    if let Some(w) = wave_id.filter(|v| !v.trim().is_empty()) {
        params["wave_id"] = json!(w);
    }
    params
}

#[derive(Debug)]
pub(crate) enum UnifiedDelegateOutcome {
    Response(Value),
    LegacyFallback,
}

pub(crate) fn delegate_response_is_explicitly_unsupported(response: &Value) -> bool {
    if response["error"]["code"].as_i64() == Some(-32601) {
        return true;
    }
    [
        response["error"]["code"].as_str(),
        response["error_code"].as_str(),
        response["result"]["error_code"].as_str(),
    ]
    .into_iter()
    .flatten()
    .any(|code| {
        matches!(
            code.to_ascii_lowercase().as_str(),
            "method_not_found"
                | "method-not-found"
                | "unknown_method"
                | "unsupported"
                | "unsupported_method"
                | "not_supported"
        )
    })
}

pub(crate) fn delegate_error_is_explicitly_unsupported(error: &str) -> bool {
    let lower = error.to_ascii_lowercase();
    [
        "[method_not_found]",
        "[method-not-found]",
        "[unknown_method]",
        "[unsupported]",
        "[unsupported_method]",
        "[not_supported]",
    ]
    .iter()
    .any(|code| lower.contains(code))
}

pub(crate) const DELEGATE_AGENT_BUSY_HINT: &str =
    "\nHint: Agent has an active task — finish/block it first, or delegate to another idle agent.";

pub(crate) fn delegate_response_error_code(response: &Value) -> Option<&str> {
    response["error"]["code"]
        .as_str()
        .or_else(|| response["result"]["error_code"].as_str())
}

pub(crate) fn delegate_error_with_agent_busy_hint(error: String) -> String {
    if error.contains("[agent_busy]") && !error.contains(DELEGATE_AGENT_BUSY_HINT) {
        format!("{error}{DELEGATE_AGENT_BUSY_HINT}")
    } else {
        error
    }
}

pub(crate) fn resolve_unified_delegate<F>(
    params: &Value,
    request_id: &str,
    mut call: F,
) -> Result<UnifiedDelegateOutcome, String>
where
    F: FnMut(&Value) -> Result<Value, String>,
{
    let first_error = match call(params) {
        Ok(response) if response["ok"].as_bool().unwrap_or(false) => {
            return Ok(UnifiedDelegateOutcome::Response(response));
        }
        Ok(response) if delegate_response_is_explicitly_unsupported(&response) => {
            return Ok(UnifiedDelegateOutcome::LegacyFallback);
        }
        Ok(response) => {
            let hint = if delegate_response_error_code(&response) == Some("agent_busy") {
                DELEGATE_AGENT_BUSY_HINT
            } else {
                ""
            };
            return Err(format!(
                "team.delegate returned non-ok (request_id={request_id}): {}",
                format!("{}{hint}", pretty(&response))
            ));
        }
        Err(error) if delegate_error_is_explicitly_unsupported(&error) => {
            return Ok(UnifiedDelegateOutcome::LegacyFallback);
        }
        Err(error) => delegate_error_with_agent_busy_hint(error),
    };

    match call(params) {
        Ok(response) if response["ok"].as_bool().unwrap_or(false) => {
            Ok(UnifiedDelegateOutcome::Response(response))
        }
        Ok(response) => {
            let hint = if delegate_response_error_code(&response) == Some("agent_busy") {
                DELEGATE_AGENT_BUSY_HINT
            } else {
                ""
            };
            Err(format!(
                "team.delegate outcome unknown after transport retry; request_id={request_id}; \
                 retry with --request-id {request_id}; first={first_error}; retry={}{hint}",
                pretty(&response)
            ))
        }
        Err(retry_error) => Err(delegate_error_with_agent_busy_hint(format!(
            "team.delegate outcome unknown after transport retry; request_id={request_id}; \
             retry with --request-id {request_id}; first={first_error}; retry={retry_error}"
        ))),
    }
}

#[derive(Debug, Clone)]
pub(crate) struct GkWorktreeMeta {
    pub(crate) path: String,
    branch: String,
    parent: Option<String>,
    created: Option<bool>,
    reused: Option<bool>,
    init: Option<String>,
}

pub(crate) fn should_acquire_worktree(
    policy: WorktreePolicyArg,
    target: &str,
    text: &str,
    title: &str,
    desc: Option<&str>,
) -> bool {
    match policy {
        WorktreePolicyArg::Off => false,
        WorktreePolicyArg::Always => true,
        WorktreePolicyArg::Auto => {
            let target_l = target.to_lowercase();
            let hay = format!("{}\n{}\n{}", title, text, desc.unwrap_or_default()).to_lowercase();
            let mutating_role = target_l.contains("executor")
                || target_l.contains("frontend")
                || target_l.contains("backend");
            let mutating_word = [
                "implement",
                "fix",
                "refactor",
                "update",
                "edit",
                "add",
                "remove",
                "change",
                "build",
                "code",
                "patch",
                "구현",
                "수정",
                "리팩터",
                "변경",
                "추가",
                "삭제",
            ]
            .iter()
            .any(|w| hay.contains(w));
            let read_only_word = [
                "review",
                "research",
                "inspect",
                "analyze",
                "plan",
                "audit",
                "read-only",
                "리뷰",
                "조사",
                "분석",
                "계획",
            ]
            .iter()
            .any(|w| hay.contains(w));
            (mutating_role || mutating_word) && !read_only_word
        }
    }
}

pub(crate) fn sanitize_branch_component(raw: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for c in raw.chars() {
        let mapped = if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
            c.to_ascii_lowercase()
        } else {
            '-'
        };
        if mapped == '-' {
            if !last_dash {
                out.push(mapped);
                last_dash = true;
            }
        } else {
            out.push(mapped);
            last_dash = false;
        }
    }
    out.trim_matches('-').chars().take(48).collect()
}

pub(crate) fn xmb_project_from_text(text: &str) -> Option<String> {
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("XMB_TASK:") {
            let rest = rest.trim();
            if let Some((project, task_id)) = rest.split_once('/') {
                if !project.is_empty() && !task_id.is_empty() {
                    return Some(sanitize_branch_component(project));
                }
            }
        }
    }
    None
}

pub(crate) fn worktree_branch_for_task(team: &str, task: &Value, text: &str) -> String {
    let task_id = task["id"].as_str().unwrap_or("task");
    let task_short = sanitize_branch_component(task_id);
    if let Some(project) = xmb_project_from_text(text) {
        format!("xmb/{project}/{task_short}")
    } else {
        format!("tm/{}/{}", sanitize_branch_component(team), task_short)
    }
}

pub(crate) fn run_gk_json(args: &[String], cwd: Option<&str>) -> Result<Value, String> {
    let mut cmd = process::Command::new("git-kit");
    cmd.args(args).env("GK_AGENT", "1").env("NO_COLOR", "1");
    if let Some(cwd) = cwd {
        cmd.current_dir(cwd);
    }
    let output = cmd.output().map_err(|e| {
        // Distinguish "the tool is not installed here" from "the tool ran and
        // objected". Only the first is safe to shrug off: a peer is a machine
        // term-mesh was pointed at, not one it provisioned, so git-kit being
        // absent says nothing about the repository. A git-kit that exists and
        // refuses is telling us something, and callers must keep failing on it.
        if e.kind() == std::io::ErrorKind::NotFound {
            GIT_KIT_MISSING.to_string()
        } else {
            format!("failed to run git-kit: {e}")
        }
    })?;
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if !stdout.is_empty() {
        if let Ok(value) = serde_json::from_str::<Value>(&stdout) {
            return Ok(value);
        }
    }
    if !output.status.success() {
        return Err(format!(
            "git-kit exited with {}: {}{}{}",
            output.status,
            stdout,
            if stderr.is_empty() { "" } else { "\n" },
            stderr
        ));
    }
    serde_json::from_str::<Value>(&stdout).map_err(|e| {
        format!(
            "git-kit did not return JSON for `{}`; upgrade git-kit for `wt acquire/finish` support ({e})",
            args.join(" ")
        )
    })
}

pub(crate) fn epoch_ms_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

pub(crate) struct TaskWorktreeLock {
    path: PathBuf,
}

impl Drop for TaskWorktreeLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

pub(crate) fn acquire_task_worktree_lock(
    team: &str,
    task_id: &str,
) -> Result<TaskWorktreeLock, String> {
    let dir = env::temp_dir().join("term-mesh-worktree-locks");
    fs::create_dir_all(&dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    let team = sanitize_branch_component(team);
    let task = sanitize_branch_component(task_id);
    let path = dir.join(format!("{team}-{task}.lock"));
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
    {
        Ok(mut file) => {
            let _ = writeln!(file, "pid={}", process::id());
            Ok(TaskWorktreeLock { path })
        }
        Err(e) if e.kind() == ErrorKind::AlreadyExists => Err(format!(
            "another worktree finish is already running for task {task_id}; lock={}",
            path.display()
        )),
        Err(e) => Err(format!("create lock {}: {e}", path.display())),
    }
}

pub(crate) fn gk_wt_acquire(
    branch: &str,
    from_ref: Option<&str>,
    working_directory: Option<&str>,
) -> Result<GkWorktreeMeta, String> {
    gk_wt_acquire_with(branch, from_ref, working_directory, run_gk_json)
}

pub(crate) fn gk_wt_acquire_with<F>(
    branch: &str,
    from_ref: Option<&str>,
    working_directory: Option<&str>,
    mut run: F,
) -> Result<GkWorktreeMeta, String>
where
    F: FnMut(&[String], Option<&str>) -> Result<Value, String>,
{
    let mut args = vec![
        "wt".to_string(),
        "acquire".to_string(),
        branch.to_string(),
        "--json".to_string(),
    ];
    if let Some(base) = from_ref.filter(|s| !s.trim().is_empty()) {
        args.push("--from".to_string());
        args.push(base.to_string());
    }
    let value = run(&args, working_directory)?;
    if !value["ok"].as_bool().unwrap_or(false) {
        return Err(format!("git-kit wt acquire failed: {}", pretty(&value)));
    }
    let result = &value["result"];
    let path = result["path"]
        .as_str()
        .ok_or_else(|| format!("git-kit wt acquire missing result.path: {}", pretty(&value)))?;
    let branch = result["branch"].as_str().unwrap_or(branch);
    Ok(GkWorktreeMeta {
        path: path.to_string(),
        branch: branch.to_string(),
        parent: result["parent"].as_str().map(String::from),
        created: result["created"].as_bool(),
        reused: result["reused"].as_bool(),
        init: result["init"].as_str().map(String::from),
    })
}

pub(crate) fn update_task_with_worktree(
    sock: &PathBuf,
    team: &str,
    task_id: &str,
    meta: &GkWorktreeMeta,
    policy: WorktreePolicyArg,
) -> Result<Value, String> {
    let mut params = json!({
        "team_name": team,
        "task_id": task_id,
        "worktree_policy": worktree_policy_name(policy),
        "worktree_path": meta.path,
        "worktree_branch": meta.branch,
    });
    if let Some(parent) = &meta.parent {
        params["worktree_parent"] = json!(parent);
    }
    if let Some(created) = meta.created {
        params["worktree_created"] = json!(created);
    }
    if let Some(reused) = meta.reused {
        params["worktree_reused"] = json!(reused);
    }
    if let Some(init) = &meta.init {
        params["worktree_init"] = json!(init);
    }
    rpc_call(sock, "team.task.update", params)
}

/// Record on the task that isolation was asked for and could not be had.
///
/// `auto` selects a worktree because the work mutates, so the case where this
/// fires is exactly the case isolation exists for. Leaving it on stderr only
/// meant the board showed a task indistinguishable from an isolated one, while
/// the repository contract requires same-checkout concurrent writes to have
/// explicit disjoint ownership or isolation.
///
/// Written into `worktree_policy` rather than a new column: the value is
/// already carried, displayed and queried, and adding a field would mean a
/// schema migration for something a distinct value says just as plainly.
///
/// NOTE: this makes the state visible; it does not make it safe. Refusing a
/// second concurrent write to the same checkout needs the working directory on
/// the task, which the schema does not carry today.
pub(crate) fn mark_task_isolation_degraded(
    sock: &PathBuf,
    team: &str,
    task_id: &str,
    reason: &str,
) {
    let _ = rpc_call(
        sock,
        "team.task.update",
        json!({
            "team_name": team,
            "task_id": task_id,
            "worktree_policy": WORKTREE_POLICY_DEGRADED,
            "worktree_init": reason,
        }),
    );
}

pub(crate) fn block_task_for_worktree_error(
    sock: &PathBuf,
    team: &str,
    task_id: &str,
    reason: &str,
) {
    let _ = rpc_call(
        sock,
        "team.task.update",
        json!({
            "team_name": team,
            "task_id": task_id,
            "status": "blocked",
            "blocked_reason": reason,
        }),
    );
}

pub(crate) fn run_task_finish_worktree(
    sock: &PathBuf,
    team: &str,
    task_id: &str,
    to: &str,
    cleanup: bool,
    push: bool,
) -> Result<Value, String> {
    let _lock = acquire_task_worktree_lock(team, task_id)?;
    let task_resp = rpc_call(
        sock,
        "team.task.get",
        json!({
            "team_name": team,
            "task_id": task_id,
        }),
    )
    .map_err(|e| format!("task.get: {e}"))?;
    let task = &task_resp["result"];
    let path = task["worktree_path"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            format!(
                "task {task_id} has no worktree_path; delegate with --worktree always/auto first"
            )
        })?;

    let mut args = vec![
        "wt".to_string(),
        "finish".to_string(),
        "--to".to_string(),
        to.to_string(),
        "--json".to_string(),
    ];
    if cleanup {
        args.push("--cleanup".to_string());
    }
    if push {
        args.push("--push".to_string());
    }
    let finish = run_gk_json(&args, Some(path))?;
    if !finish["ok"].as_bool().unwrap_or(false) {
        let state = finish["state"].as_str().unwrap_or("error");
        let reason = format!(
            "git-kit wt finish ended with state={state}: {}",
            pretty(&finish)
        );
        block_task_for_worktree_error(sock, team, task_id, &reason);
        return Err(reason);
    }

    let result = &finish["result"];
    let mut params = json!({
        "team_name": team,
        "task_id": task_id,
        "worktree_finished_at": iso8601_utc_now(),
        "worktree_finished_at_ms": epoch_ms_now(),
    });
    if let Some(mode) = result["mode"].as_str() {
        params["worktree_finish_mode"] = json!(mode);
    }
    if let Some(removed) = result["removed"].as_bool() {
        params["worktree_removed"] = json!(removed);
    }
    let updated = rpc_call(sock, "team.task.update", params)
        .map_err(|e| format!("task.update worktree finish metadata: {e}"))?;
    Ok(json!({
        "finish": finish,
        "task": updated["result"].clone(),
    }))
}

pub(crate) fn worktree_task_create_params(
    team: &str,
    target: &str,
    resolved_title: &str,
    resolved_priority: u32,
    accept: &[String],
    deps: &[String],
    desc: Option<&str>,
    fix_budget: Option<u8>,
    agent_instance_id: Option<&str>,
    worktree_policy: WorktreePolicyArg,
    request_id: &str,
    route: Option<&str>,
    wave_id: Option<&str>,
) -> Value {
    let mut params = json!({
        "team_name": team,
        "title": resolved_title,
        "assignee": target,
        "priority": resolved_priority,
        "worktree_policy": worktree_policy_name(worktree_policy),
        "request_id": request_id,
        "agent_instance_id": agent_instance_id,
    });
    if let Some(d) = desc {
        params["description"] = json!(d);
    }
    if !accept.is_empty() {
        params["acceptance_criteria"] = json!(accept);
    }
    if !deps.is_empty() {
        params["depends_on"] = json!(deps);
    }
    if let Some(fb) = fix_budget {
        params["fix_budget"] = json!(fb);
    }
    if let Some(r) = route.filter(|v| !v.trim().is_empty()) {
        params["route"] = json!(r);
    }
    if let Some(w) = wave_id.filter(|v| !v.trim().is_empty()) {
        params["wave_id"] = json!(w);
    }
    params
}

pub(crate) fn run_delegate_result_with_worktree(
    sock: &PathBuf,
    team: &str,
    target: &str,
    text: &str,
    resolved_title: String,
    resolved_priority: u32,
    accept: &[String],
    deps: &[String],
    desc: Option<String>,
    no_report: bool,
    context: Option<&str>,
    fix_budget: Option<u8>,
    panel_id: Option<&str>,
    agent_instance_id: Option<&str>,
    working_directory: Option<&str>,
    worktree_policy: WorktreePolicyArg,
    from_ref: Option<&str>,
    request_id: &str,
    route: Option<&str>,
    wave_id: Option<&str>,
) -> Result<Value, String> {
    let params = worktree_task_create_params(
        team,
        target,
        &resolved_title,
        resolved_priority,
        accept,
        deps,
        desc.as_deref(),
        fix_budget,
        agent_instance_id,
        worktree_policy,
        request_id,
        route,
        wave_id,
    );

    let created = rpc_call(sock, "team.task.create", params)
        .map_err(|e| format!("task.create before worktree acquire failed: {e}"))?;
    let mut task = created["result"].clone();
    let task_id = task["id"]
        .as_str()
        .ok_or_else(|| format!("task.create missing task id: {}", pretty(&created)))?
        .to_string();

    let branch = worktree_branch_for_task(team, &task, text);
    // `null` when isolation was unavailable and the policy allowed proceeding,
    // so the caller can tell "isolated at this path" from "shared checkout"
    // instead of inferring it from a field's absence.
    let mut worktree_path = Value::Null;
    match gk_wt_acquire(&branch, from_ref, working_directory) {
        Ok(meta) => {
            worktree_path = Value::String(meta.path.clone());
            let updated = update_task_with_worktree(sock, team, &task_id, &meta, worktree_policy)
                .map_err(|e| format!("task.update worktree metadata failed: {e}"))?;
            task = updated["result"].clone();
        }
        Err(e) if !worktree_failure_is_fatal(worktree_policy, &e) => {
            // Record it on the task, not only on stderr. `auto` asked for
            // isolation because the work mutates, so a run without it is a
            // different concurrency story than the board would otherwise
            // show -- and stderr is gone by the time anyone reads the board.
            mark_task_isolation_degraded(sock, team, &task_id, &e);
            eprintln!(
                "note: {e}; running {task_id} in the shared checkout without worktree isolation"
            );
        }
        Err(e) => {
            let reason = format!("worktree acquire failed: {e}");
            block_task_for_worktree_error(sock, team, &task_id, &reason);
            return Err(format!("{reason} (task_id={task_id})"));
        }
    }

    let instruction =
        format_task_instruction(sock, team, &task, text, no_report, context, fix_budget);
    let send_text = format!("{instruction}\n");

    if let Some(daemon_sock) = team_headless_daemon_socket() {
        if let Some(agent_id) = is_headless_agent(&daemon_sock, team, target) {
            let sent_ok = match rpc_call(
                &daemon_sock,
                "headless.send",
                json!({
                    "agent_id": agent_id,
                    "text": &send_text,
                }),
            ) {
                Ok(ref hr) => !hr["result"].is_null(),
                Err(_) => false,
            };
            if !sent_ok {
                let reason = format!(
                    "worktree delegate failed: headless.send returned null (agent={target})"
                );
                block_task_for_worktree_error(sock, team, &task_id, &reason);
                return Err(format!(
                    "delivery failed; task blocked: {reason} (task_id={task_id})"
                ));
            }
            return Ok(
                json!({ "task": task, "send": { "ok": sent_ok }, "worktree": worktree_path }),
            );
        }
    }

    let sent = rpc_call(
        sock,
        "team.send",
        json!({
            "team_name": team,
            "agent_name": target,
            "text": &send_text,
            "panel_id": panel_id,
            "agent_instance_id": agent_instance_id,
            "send_sequence_aware": true,
        }),
    )
    .map_err(|e| format!("team.send: {e}"))?;
    if !sent["ok"].as_bool().unwrap_or(false) {
        let reason =
            format!("worktree delegate failed: team.send returned non-ok (agent={target})");
        block_task_for_worktree_error(sock, team, &task_id, &reason);
        return Err(format!(
            "delivery failed; task blocked: {reason} (task_id={task_id})"
        ));
    }

    let _ = send_return_key_with_retry(
        sock,
        team,
        target,
        true,
        "team.delegate.worktree",
        panel_id,
        agent_instance_id,
        sent["result"]["send_sequence_id"].as_str(),
        send_response_return_required(&sent),
    );
    Ok(json!({ "task": task, "send": sent, "worktree": worktree_path }))
}

pub(crate) fn run_delegate(
    sock: &PathBuf,
    team: &str,
    target: &str,
    text: &str,
    options: DelegateOptions<'_>,
) {
    match run_delegate_result(sock, team, target, text, options) {
        Ok(v) => println!("{}", pretty(&v)),
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    }
}

/// Delegate a task in autonomous mode: spawn a temporary Claude subprocess
/// directly from the CLI (no daemon required). The subprocess runs without
/// team flags (--agent-id etc.), so no leader approval is needed for edits.
/// It uses `claude -p` (print mode) for single-shot execution.
pub(crate) fn run_delegate_autonomous(
    sock: &PathBuf,
    team: &str,
    target: &str,
    text: &str,
    title: Option<String>,
    priority: Option<u32>,
    _no_report: bool,
    context: Option<&str>,
    _fix_budget: Option<u8>,
) {
    let resolved_title = title.unwrap_or_else(|| task_title_from_text(text));
    let resolved_priority = priority.unwrap_or(2);

    // Step 1: Create the task (same as normal delegate)
    let task_params = json!({
        "team_name": team,
        "title": resolved_title,
        "assignee": target,
        "priority": resolved_priority,
    });
    let task = match rpc_call(sock, "team.task.create", task_params) {
        Ok(v) if v["ok"].as_bool().unwrap_or(false) => v["result"].clone(),
        Ok(v) => {
            eprintln!("Error creating task: {}", pretty(&v));
            process::exit(1);
        }
        Err(e) => {
            eprintln!("Error creating task: {e}");
            process::exit(1);
        }
    };
    let task_id = task["id"].as_str().unwrap_or("").to_string();
    let task_agent_instance_id = task["agent_instance_id"].as_str().map(str::to_string);

    // Step 2: Format instruction for autonomous mode (no lifecycle commands, no report suffix).
    // The monitor process handles task completion and result reporting.
    let instruction = format_autonomous_instruction(&task, text, context);

    // Step 3: Get agent model from team status
    let model = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(v) => v["result"]["agents"]
            .as_array()
            .and_then(|arr| arr.iter().find(|a| a["name"].as_str() == Some(target)))
            .and_then(|a| a["model"].as_str())
            .unwrap_or("sonnet")
            .to_string(),
        Err(_) => "sonnet".to_string(),
    };

    // Step 4: Resolve claude binary path
    let claude_path = env::var("CLAUDE_PATH")
        .ok()
        .or_else(|| {
            // Check versioned installs
            let versions_dir = format!(
                "{}/.local/share/claude/versions",
                env::var("HOME").unwrap_or_default()
            );
            if let Ok(entries) = std::fs::read_dir(&versions_dir) {
                let mut paths: Vec<_> = entries
                    .filter_map(|e| e.ok())
                    .filter(|e| e.path().join("claude").exists())
                    .collect();
                paths.sort_by_key(|e| e.path());
                paths
                    .last()
                    .map(|e| e.path().join("claude").to_string_lossy().to_string())
            } else {
                None
            }
        })
        .unwrap_or_else(|| "claude".to_string());

    // Step 5: Spawn claude subprocess directly (no team flags → no leader approval)
    // stdout goes to a temp file so a detached monitor process can read it after tm-agent exits.
    let app_socket = env::var("TERMMESH_SOCKET").unwrap_or_default();
    let working_dir = env::current_dir().unwrap_or_default();

    eprintln!(
        "  Autonomous mode: spawning claude subprocess for task {}",
        &task_id[..8.min(task_id.len())]
    );

    // Create temp file for capturing stdout
    let results_dir = format!(
        "{}/.term-mesh/results/{}",
        env::var("HOME").unwrap_or_default(),
        team
    );
    let _ = std::fs::create_dir_all(&results_dir);
    let stdout_file_path = format!(
        "{}/autonomous-{}.stdout",
        results_dir,
        &task_id[..8.min(task_id.len())]
    );
    let stdout_file = match std::fs::File::create(&stdout_file_path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("Error creating stdout file: {e}");
            process::exit(1);
        }
    };

    let child = std::process::Command::new(&claude_path)
        .arg("-p") // print mode: single-shot execution
        .arg("--dangerously-skip-permissions")
        .arg("--model")
        .arg(&model)
        .arg(&instruction)
        .env("TERMMESH_SOCKET", &app_socket)
        .env("TERMMESH_TEAM", team)
        .env("TERMMESH_AGENT_NAME", target)
        .env("TERMMESH_AGENT_ID", format!("{target}@{team}"))
        .env_remove("CLAUDECODE")
        .env_remove("CLAUDE_CODE_ENTRYPOINT")
        .current_dir(&working_dir)
        .stdout(stdout_file)
        .stderr(std::process::Stdio::null())
        .spawn();

    let child = match child {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: failed to spawn claude: {e}");
            eprintln!("  Tried path: {claude_path}");
            let _ = std::fs::remove_file(&stdout_file_path);
            process::exit(1);
        }
    };

    let child_pid = child.id();

    // Output task info immediately (don't wait for subprocess to finish)
    println!(
        "{}",
        pretty(&json!({
            "ok": true,
            "result": {
                "task": task,
                "sent": true,
                "text_delivered": true,
                "autonomous": true,
                "pid": child_pid,
            }
        }))
    );

    // Step 6: Wait for claude subprocess in a background thread, then auto-complete the task.
    // The thread runs inside this tm-agent process (which is a descendant of term-mesh),
    // so RPC calls pass the socket's isDescendant() access check.
    // The caller should invoke `tm-agent delegate --autonomous &` to avoid blocking.
    let sock_path = sock.clone();
    let team_str = team.to_string();
    let target_str = target.to_string();
    let task_id_clone = task_id.clone();
    let task_agent_instance_id_clone = task_agent_instance_id.clone();
    let stdout_path_clone = stdout_file_path.clone();

    let handle = std::thread::spawn(move || {
        // Wait for the claude subprocess to finish
        let mut child_inner = child;
        let status = child_inner.wait();
        let exit_code = status
            .as_ref()
            .map(|s| s.code().unwrap_or(-1))
            .unwrap_or(-1);

        // Copy stdout file to result files
        let stdout_content = std::fs::read_to_string(&stdout_path_clone).unwrap_or_default();
        if !stdout_content.trim().is_empty() {
            let _ = write_result_file(&team_str, &format!("{task_id_clone}.md"), &stdout_content);
            let alias_name =
                reply_alias_filename(&target_str, task_agent_instance_id_clone.as_deref());
            let _ = write_result_file(&team_str, &alias_name, &stdout_content);
        }
        let _ = std::fs::remove_file(&stdout_path_clone);

        // Auto-complete the task via RPC
        let completion_msg = format!(
            "autonomous task {} completed (exit={})",
            task_id_clone, exit_code
        );
        let _ = rpc_call(
            &sock_path,
            "team.report",
            json!({
                "team_name": team_str,
                "agent_name": target_str,
                "content": &completion_msg,
            }),
        );
        let _ = rpc_call(
            &sock_path,
            "team.task.update",
            json!({
                "team_name": team_str,
                "task_id": task_id_clone,
                "status": "completed",
                "result": &completion_msg,
            }),
        );

        eprintln!(
            "  Autonomous task {} completed (exit={})",
            &task_id_clone[..8.min(task_id_clone.len())],
            exit_code
        );
    });

    // Wait for the background thread to finish.
    // This means tm-agent stays alive until claude -p exits.
    // The caller should use `tm-agent delegate --autonomous &` to avoid blocking.
    let _ = handle.join();
}

pub(crate) fn run_fan_out(
    sock: &PathBuf,
    team: &str,
    text: &str,
    title: Option<String>,
    priority: Option<u32>,
    no_report: bool,
    agents_flag: &Option<String>,
    context: Option<&str>,
    fix_budget: Option<u8>,
    worktree_policy: WorktreePolicyArg,
    from_ref: Option<&str>,
) {
    // Get all agents from team status as (name, panel_id) pairs. team.status lists
    // EVERY pane separately, so duplicate-named agents already carry DISTINCT
    // panel_ids — pair them 1:1 (do NOT dedup by name) so each fan-out thread can
    // deterministically address its own pane instead of relying on round-robin.
    let all_agents: Vec<(String, Option<String>)> =
        match rpc_call(sock, "team.status", json!({ "team_name": team })) {
            Ok(r) => r["result"]["agents"]
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .filter_map(|a| {
                            a["name"].as_str().map(|n| {
                                (
                                    n.to_string(),
                                    a["panel_id"]
                                        .as_str()
                                        .filter(|s| !s.is_empty())
                                        .map(String::from),
                                )
                            })
                        })
                        .collect()
                })
                .unwrap_or_default(),
            Err(e) => {
                eprintln!("Error: {e}");
                process::exit(1);
            }
        };

    // Filter agents if --agents flag provided (filter by NAME, keep distinct panes)
    let filter = parse_cli_flag(agents_flag);
    let targets: Vec<(&str, Option<&str>)> = if filter.is_empty() {
        all_agents
            .iter()
            .map(|(n, p)| (n.as_str(), p.as_deref()))
            .collect()
    } else {
        all_agents
            .iter()
            .filter(|(n, _)| filter.contains(n.as_str()))
            .map(|(n, p)| (n.as_str(), p.as_deref()))
            .collect()
    };

    if targets.is_empty() {
        eprintln!("Error: no matching agents found");
        process::exit(1);
    }

    eprintln!(
        "Fan-out: delegating to {} agents in parallel: {}",
        targets.len(),
        targets
            .iter()
            .map(|(n, _)| *n)
            .collect::<Vec<_>>()
            .join(", ")
    );

    // L2: compute task title once outside the thread scope to avoid repeated calls per thread.
    let base_title = title.unwrap_or_else(|| task_title_from_text(text));

    // Run all delegate calls in parallel using scoped threads.
    // rpc_call_timeout() opens a new UnixStream per call, so threads don't share connections.
    let results: Vec<(&str, Result<Value, String>)> = thread::scope(|s| {
        let handles: Vec<_> = targets
            .iter()
            .map(|(target, panel_id)| {
                let t = base_title.clone();
                let panel_id = *panel_id;
                s.spawn(move || {
                    let result = run_delegate_result(
                        sock,
                        team,
                        target,
                        text,
                        DelegateOptions {
                            title: Some(t),
                            priority,
                            accept: &[],
                            deps: &[],
                            desc: None,
                            no_report,
                            context,
                            fix_budget,
                            panel_id,
                            agent_instance_id: None,
                            worktree_policy,
                            from_ref,
                            request_id: None,
                            route: None,
                            wave_id: None,
                        },
                    );
                    (*target, result)
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().expect("thread panicked"))
            .collect()
    });

    let mut succeeded: Vec<String> = Vec::new();
    let mut failed: Vec<String> = Vec::new();
    for (agent, result) in &results {
        match result {
            Ok(v) => {
                println!("{}", pretty(v));
                succeeded.push(agent.to_string());
            }
            Err(e) => {
                eprintln!("Error delegating to {agent}: {e}");
                failed.push(agent.to_string());
            }
        }
    }

    eprintln!(
        "Fan-out complete: {} succeeded, {} failed.",
        succeeded.len(),
        failed.len()
    );
    println!(
        "{}",
        pretty(&json!({
            "fan_out": {
                "team_name": team,
                "agents": succeeded,
                "count": succeeded.len(),
                "failed": failed,
            }
        }))
    );

    // M1: exit with error if all delegates failed.
    if succeeded.is_empty() && !failed.is_empty() {
        process::exit(1);
    }
}

#[cfg(test)]
mod worktree_availability_tests {
    use super::*;

    /// The failure that started this: a leader on one peer delegating to an
    /// agent on another died on `worktree acquire failed: failed to run
    /// git-kit: No such file or directory`. Neither machine had git-kit, and
    /// neither had any reason to — term-mesh was pointed at them, it did not
    /// provision them.
    #[test]
    fn a_missing_tool_is_not_fatal_under_auto() {
        let missing = GIT_KIT_MISSING.to_string();
        assert!(worktree_isolation_unavailable(&missing));
        assert!(!worktree_failure_is_fatal(
            WorktreePolicyArg::Auto,
            &missing
        ));
    }

    /// `always` is the caller demanding isolation. An unavailable tool is then
    /// a real failure, and silently dropping isolation would hand two writers
    /// the same checkout while the task board claimed otherwise.
    #[test]
    fn a_missing_tool_is_still_fatal_under_always() {
        assert!(worktree_failure_is_fatal(
            WorktreePolicyArg::Always,
            GIT_KIT_MISSING
        ));
    }

    /// A git-kit that ran and objected is saying something about the
    /// repository. Only absence is shrugged off.
    #[test]
    fn a_tool_that_ran_and_refused_is_fatal_even_under_auto() {
        let refused = "gk wt acquire: branch is checked out elsewhere";
        assert!(!worktree_isolation_unavailable(refused));
        assert!(worktree_failure_is_fatal(WorktreePolicyArg::Auto, refused));
    }

    /// "off" is a caller who never wanted isolation; this is one who wanted it
    /// and could not have it. A board that shows them the same cannot tell a
    /// deliberate shared-checkout run from a silently degraded one.
    #[test]
    fn a_degraded_run_is_not_recorded_as_isolation_off() {
        assert_ne!(
            WORKTREE_POLICY_DEGRADED,
            worktree_policy_name(WorktreePolicyArg::Off)
        );
        assert_ne!(
            WORKTREE_POLICY_DEGRADED,
            worktree_policy_name(WorktreePolicyArg::Auto)
        );
        assert_ne!(
            WORKTREE_POLICY_DEGRADED,
            worktree_policy_name(WorktreePolicyArg::Always)
        );
    }

    /// The value is written into an existing column, so it has to round-trip
    /// through the same parser the policy field uses without being mistaken
    /// for one of the real policies.
    #[test]
    fn the_degraded_marker_does_not_parse_back_as_a_policy() {
        assert_eq!(
            parse_worktree_policy_name(Some(WORKTREE_POLICY_DEGRADED)),
            WorktreePolicyArg::Auto,
            "unknown values fall back to auto; the marker must not read as off or always"
        );
    }

    /// The marker has to survive being wrapped by the callers that prefix it.
    #[test]
    fn the_marker_survives_the_wrapping_callers_add() {
        let wrapped = format!("worktree acquire failed: {GIT_KIT_MISSING}");
        assert!(worktree_isolation_unavailable(&wrapped));
        assert!(!worktree_failure_is_fatal(
            WorktreePolicyArg::Auto,
            &wrapped
        ));
    }
}
