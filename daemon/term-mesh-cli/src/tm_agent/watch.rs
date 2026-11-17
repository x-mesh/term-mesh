use super::*;

// ── watch doctor: phantom watcher diagnose + repair ─────────────────
//
// Design: ~/.term-mesh/results/term-mesh/ai-watch-doctor-design.md
// Captures the liveness-probe + phantom-repair procedure (previously hand-run
// prose in watch.md) as one deterministic primitive. All team.* RPCs ride the
// *app* (Swift) socket; no new RPCs are introduced — only existing team.read /
// team.status / team.detach / team.attach / team.add_agent are reused.

/// Liveness verdict for a watcher pane, used by `run_watch_doctor`.
pub(crate) enum WatcherProbe {
    /// Pane is live and readable, and present in team.status with a `panel_id`.
    Live,
    /// No live pane — `team.read` returned `not_found`, the agent is missing from
    /// status, or its `panel_id` is absent. The phantom condition.
    Phantom,
    /// Could not determine — RPC/socket failure (transient during grace loops).
    RpcError(String),
}

/// Probe whether a watcher has a live pane via app-socket RPCs.
///
/// Phantom triggers (design requirement 1): `team.read` → `not_found`, the agent
/// is absent from `team.status`, or the status agent's `panel_id` is null/absent.
/// A null `heartbeat_age_seconds` alone is NOT a trigger (idle live panes report
/// null too), so it is intentionally ignored.
pub(crate) fn probe_watcher(app_sock: &PathBuf, team: &str, watcher: &str) -> WatcherProbe {
    match rpc_call(
        app_sock,
        "team.read",
        json!({ "team_name": team, "agent_name": watcher, "lines": 1 }),
    ) {
        Err(e) => return WatcherProbe::RpcError(format!("team.read: {e}")),
        Ok(r) => {
            if !r["ok"].as_bool().unwrap_or(false) {
                let code = r["error"]["code"].as_str().unwrap_or("");
                if code == "not_found" {
                    return WatcherProbe::Phantom;
                }
                let msg = r["error"]["message"].as_str().unwrap_or("team.read failed");
                return WatcherProbe::RpcError(format!("team.read [{code}]: {msg}"));
            }
        }
    }
    // team.read succeeded → pane is reachable. Cross-check status for panel_id.
    match rpc_call(app_sock, "team.status", json!({ "team_name": team })) {
        Err(e) => WatcherProbe::RpcError(format!("team.status: {e}")),
        Ok(st) => {
            if !st["ok"].as_bool().unwrap_or(false) {
                let code = st["error"]["code"].as_str().unwrap_or("");
                let msg = st["error"]["message"]
                    .as_str()
                    .unwrap_or("team.status failed");
                return WatcherProbe::RpcError(format!("team.status [{code}]: {msg}"));
            }
            let agent = st["result"]["agents"]
                .as_array()
                .and_then(|arr| arr.iter().find(|a| a["name"].as_str() == Some(watcher)));
            match agent {
                None => WatcherProbe::Phantom,
                Some(a) => {
                    // Hard-proof of a live pane requires BOTH a panel_id and a
                    // workspace_id; a status row that loses either is a phantom.
                    let panel_present = a["panel_id"]
                        .as_str()
                        .map(|s| !s.is_empty())
                        .unwrap_or(false);
                    let workspace_present = a["workspace_id"]
                        .as_str()
                        .map(|s| !s.is_empty())
                        .unwrap_or(false);
                    if panel_present && workspace_present {
                        WatcherProbe::Live
                    } else {
                        WatcherProbe::Phantom
                    }
                }
            }
        }
    }
}

/// Read a watcher's configured `cli`/`model` from `team.status` (best-effort).
/// Lets a repair inherit the watcher's original CLI/model so the recreated pane
/// matches the one that went phantom.
pub(crate) fn read_watcher_cli_model(
    app_sock: &PathBuf,
    team: &str,
    watcher: &str,
) -> (Option<String>, Option<String>) {
    match rpc_call(app_sock, "team.status", json!({ "team_name": team })) {
        Ok(st) => st["result"]["agents"]
            .as_array()
            .and_then(|arr| arr.iter().find(|a| a["name"].as_str() == Some(watcher)))
            .map(|a| {
                (
                    a["cli"]
                        .as_str()
                        .filter(|s| !s.is_empty())
                        .map(String::from),
                    a["model"]
                        .as_str()
                        .filter(|s| !s.is_empty())
                        .map(String::from),
                )
            })
            .unwrap_or((None, None)),
        Err(_) => (None, None),
    }
}

/// Print the doctor verdict JSON and exit. Diverging so callers don't fall
/// through after a terminal verdict.
pub(crate) fn doctor_emit(out: &Value, code: i32) -> ! {
    println!("{}", pretty(out));
    process::exit(code);
}

/// `tm-agent watch doctor <team> [watcher]` — diagnose and repair a phantom watcher.
///
/// `_daemon_sock` is unused by the core path (no `watch.*` RPCs); the app (Swift)
/// socket is resolved internally for every team.* call.
///
/// Exit codes: 0 healthy or repaired-alive · 2 phantom confirmed + `--no-repair`
/// · 3 repair attempted but still dead (fail-loud) · 4 H7 routing risk · 1 RPC /
/// context error.
pub(crate) fn run_watch_doctor(
    _daemon_sock: &PathBuf,
    team: &str,
    watcher: Option<&str>,
    no_repair: bool,
    probe_timeout: Option<u64>,
    cli: Option<&str>,
) {
    let watcher = watcher.unwrap_or("watcher");
    let probe_timeout = probe_timeout.unwrap_or(5);
    let team_type = if team.starts_with("ws-") {
        "ws"
    } else {
        "create"
    };

    let mut out = json!({
        "watcher": watcher,
        "team_type": team_type,
        "was_phantom": false,
        "action": "none",
        "repaired": false,
        "alive": false,
        "error": Value::Null,
        "h7_risk": false,
    });

    // ── Resolve the app (Swift) socket — all team.* RPCs ride it. ──────────
    let app_sock = match resolve_app_socket(None) {
        Some(s) => PathBuf::from(s),
        None => {
            // H7 heuristic (requirement 6, heuristic-only this pass): the app
            // socket is unresolved. If env signals we're inside a GUI pane, the
            // daemon watch tick may misroute to a headless one-shot → routing risk
            // (exit 4). Pure-headless callers (no GUI signal) simply cannot probe
            // (exit 1). No new RPC field is consulted.
            //
            // A socket env var only counts as a GUI signal when it points at a
            // *live app* socket — a daemon socket (term-meshd*.sock) passed via
            // TERMMESH_SOCKET is a normal headless/CLI path, not H7.
            let is_live_app_env = |key: &str| {
                env::var(key)
                    .ok()
                    .filter(|v| !v.is_empty())
                    .map(PathBuf::from)
                    .map(|p| is_app_socket_path(&p) && is_socket_alive(&p))
                    .unwrap_or(false)
            };
            let gui_signal = env::var("TERMMESH_WORKSPACE_ID")
                .map(|v| !v.is_empty())
                .unwrap_or(false)
                || is_live_app_env("TERMMESH_SOCKET")
                || is_live_app_env("TERMMESH_SOCKET_PATH");
            if gui_signal {
                out["h7_risk"] = json!(true);
                out["error"] = json!(
                    "app_socket unresolved despite GUI context \u{2192} watch tick may misroute to headless one-shot (H7)"
                );
                doctor_emit(&out, 4);
            } else {
                out["error"] = json!(
                    "app_socket unresolved (headless context) \u{2014} cannot probe watcher liveness"
                );
                doctor_emit(&out, 1);
            }
        }
    };

    // ── 1. Initial liveness probe (requirement 1) ─────────────────────────
    match probe_watcher(&app_sock, team, watcher) {
        WatcherProbe::RpcError(e) => {
            out["error"] = json!(e);
            doctor_emit(&out, 1);
        }
        WatcherProbe::Live => {
            out["alive"] = json!(true);
            doctor_emit(&out, 0);
        }
        WatcherProbe::Phantom => {}
    }
    out["was_phantom"] = json!(true);

    // ── 2. Fresh-spawn race guard (requirement 2) ─────────────────────────
    // A just-spawned pane can momentarily read not_found; poll before judging.
    let grace_deadline = std::time::Instant::now() + Duration::from_secs(probe_timeout);
    while std::time::Instant::now() < grace_deadline {
        thread::sleep(Duration::from_secs(1));
        match probe_watcher(&app_sock, team, watcher) {
            WatcherProbe::Live => {
                out["alive"] = json!(true);
                out["action"] = json!("settled_during_grace");
                doctor_emit(&out, 0);
            }
            WatcherProbe::Phantom | WatcherProbe::RpcError(_) => {}
        }
    }

    // Still phantom after grace → confirmed phantom.
    if no_repair {
        out["action"] = json!("diagnose_only");
        out["error"] = json!("phantom confirmed; repair skipped (--no-repair)");
        doctor_emit(&out, 2);
    }

    // ── 3. Team-type-symmetric repair (requirement 3) ─────────────────────
    // Inherit the watcher's configured cli/model from status when present so the
    // recreated pane matches; fall back to the flag, then to defaults.
    let (status_cli, status_model) = read_watcher_cli_model(&app_sock, team, watcher);
    let repair_cli = cli
        .map(|s| s.to_string())
        .or(status_cli)
        .unwrap_or_else(|| "claude".to_string());
    let repair_model = status_model.unwrap_or_else(|| "sonnet".to_string());

    if team_type == "ws" {
        // Workspace-local: needs the caller pane's workspace/panel to re-split.
        // detach+attach (not team.restart): a phantom has no pane, so a hard
        // restart fails immediately with workspace_missing — recovery must re-run
        // the creation path.
        let (workspace_id, panel_id, window_id) = match require_termmesh_context() {
            Ok(t) => t,
            Err(e) => {
                out["error"] = json!(format!("ws-* repair needs caller pane context: {e}"));
                doctor_emit(&out, 1);
            }
        };
        // detach the dead registry entry (mirror run_detach)
        let mut detach_params = json!({
            "agent_name": watcher,
            "team_name": team,
            "workspace_id": workspace_id,
        });
        if let Some(ref wid) = window_id {
            detach_params["window_id"] = json!(wid);
        }
        out["action"] = json!("detach+attach");
        // A hidden detach failure must fail loud, not be masked by a follow-on
        // attach error. A missing entry (not_found) is benign — proceed.
        match rpc_call_timeout(&app_sock, "team.detach", detach_params, 10) {
            Ok(r) if r["ok"].as_bool().unwrap_or(false) => {}
            Ok(r) => {
                let code = r["error"]["code"].as_str().unwrap_or("unknown");
                if !matches!(code, "not_found" | "agent_not_found") {
                    let msg = r["error"]["message"].as_str().unwrap_or("detach failed");
                    out["error"] = json!(format!("detach failed [{code}]: {msg}"));
                    doctor_emit(&out, 3);
                }
            }
            Err(e) => {
                out["error"] = json!(format!("detach RPC error: {e}"));
                doctor_emit(&out, 3);
            }
        }
        // re-attach a fresh pane (mirror run_attach)
        let mut attach_params = json!({
            "agent_type": "watcher",
            "agent_name": watcher,
            "agent_cli": repair_cli,
            "agent_model": repair_model,
            "workspace_id": workspace_id,
            "surface_id": panel_id,
        });
        if let Some(ref wid) = window_id {
            attach_params["window_id"] = json!(wid);
        }
        match rpc_call_timeout(&app_sock, "team.attach", attach_params, 10) {
            Ok(r) if !r["ok"].as_bool().unwrap_or(false) => {
                let code = r["error"]["code"].as_str().unwrap_or("unknown");
                let msg = r["error"]["message"].as_str().unwrap_or("attach failed");
                out["error"] = json!(format!("re-attach failed [{code}]: {msg}"));
                doctor_emit(&out, 3);
            }
            Err(e) => {
                out["error"] = json!(format!("re-attach RPC error: {e}"));
                doctor_emit(&out, 3);
            }
            Ok(_) => {}
        }
    } else {
        // create-based: team-name-scoped remove + add (mirror run_remove_gui/run_add_gui)
        out["action"] = json!("remove+add");
        // Fail loud on a hidden remove failure; a missing entry is benign.
        // keep_team_if_empty:true preserves the (workspaceId+leader) team record
        // when the watcher is the last agent, so the following add_agent rebuilds
        // the pane instead of hitting team_not_found. No-op when other agents
        // remain, so it is passed unconditionally (no count branch needed).
        match rpc_call_timeout(
            &app_sock,
            "team.detach",
            json!({ "team_name": team, "agent_name": watcher, "force": true, "keep_team_if_empty": true }),
            10,
        ) {
            Ok(r) if r["ok"].as_bool().unwrap_or(false) => {}
            Ok(r) => {
                let code = r["error"]["code"].as_str().unwrap_or("unknown");
                if !matches!(code, "not_found" | "agent_not_found") {
                    let msg = r["error"]["message"].as_str().unwrap_or("remove failed");
                    out["error"] = json!(format!("remove failed [{code}]: {msg}"));
                    doctor_emit(&out, 3);
                }
            }
            Err(e) => {
                out["error"] = json!(format!("remove RPC error: {e}"));
                doctor_emit(&out, 3);
            }
        }
        match rpc_call_timeout(
            &app_sock,
            "team.add_agent",
            json!({
                "team_name": team,
                "agent_type": "watcher",
                "name": watcher,
                "model": repair_model,
                "cli": repair_cli,
            }),
            10,
        ) {
            Ok(r) if !r["ok"].as_bool().unwrap_or(false) => {
                let code = r["error"]["code"].as_str().unwrap_or("unknown");
                let msg = r["error"]["message"].as_str().unwrap_or("add_agent failed");
                out["error"] = json!(format!("re-add failed [{code}]: {msg}"));
                doctor_emit(&out, 3);
            }
            Err(e) => {
                out["error"] = json!(format!("re-add RPC error: {e}"));
                doctor_emit(&out, 3);
            }
            Ok(_) => {}
        }
    }
    out["repaired"] = json!(true);

    // ── 4. Infinite-loop guard: re-verify once, then fail loud (requirement 4) ──
    let verify_deadline = std::time::Instant::now() + Duration::from_secs(probe_timeout);
    while std::time::Instant::now() < verify_deadline {
        thread::sleep(Duration::from_secs(1));
        if let WatcherProbe::Live = probe_watcher(&app_sock, team, watcher) {
            out["alive"] = json!(true);
            doctor_emit(&out, 0);
        }
    }
    out["error"] = json!(format!(
        "repair attempted but watcher still not live after {probe_timeout}s"
    ));
    doctor_emit(&out, 3); // fail-loud, NO second repair
}

/// Connect to the daemon's `events.subscribe` streaming endpoint and print
/// each received JSONL event to stdout until timeout or Ctrl+C.
pub(crate) fn run_watch(
    sock: &PathBuf,
    timeout_secs: u32,
    on_event: Option<&str>,
    leader_session: Option<&str>,
) {
    let kinds: Vec<&str> = on_event
        .unwrap_or("task_done,reply,heartbeat_stale")
        .split(',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();

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

    // Read timeout must outlast the daemon's keepalive interval (30 s) with margin.
    // When a user-specified timeout is active, the daemon closes the connection,
    // so the client's read will return EOF naturally.
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

    eprintln!(
        "[watch] subscribed (kinds: {}, timeout: {}s)",
        kinds.join(","),
        timeout_secs
    );

    let mut reader = BufReader::new(&stream);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break, // EOF — daemon closed the connection (timeout or shutdown)
            Ok(_) => {
                let trimmed = line.trim_end_matches('\n').trim_end_matches('\r');
                if !trimmed.is_empty() {
                    println!("{trimmed}");
                }
            }
            Err(e) => {
                use std::io::ErrorKind;
                match e.kind() {
                    ErrorKind::WouldBlock | ErrorKind::TimedOut => {
                        // No data within read timeout — daemon may be quiet.
                        // Continue waiting unless a hard timeout has been set.
                        if timeout_secs > 0 {
                            eprintln!("[watch] read timeout; exiting");
                            break;
                        }
                        continue;
                    }
                    _ => {
                        eprintln!("[watch] stream error: {e}");
                        break;
                    }
                }
            }
        }
    }
}

/// Dispatch `tm-agent watch <on|off|status>` to the daemon `watch.*` RPCs.
pub(crate) fn run_watch_command(sock: &PathBuf, action: &WatchAction) {
    match action {
        WatchAction::On {
            team,
            every,
            target,
            stance,
            cli,
            model,
            spec,
            ratio,
            working_dir,
            app_socket,
        } => {
            // The daemon persists config keyed by working_directory; default to cwd.
            let wd = working_dir.clone().unwrap_or_else(|| {
                env::current_dir()
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_default()
            });
            let mut params = json!({
                "team_id": team,
                "cli": cli,
                "model": model,
                "stance": stance,
                "working_directory": wd,
            });
            if let Some(e) = every {
                params["interval_secs"] = json!(e);
            }
            if let Some(t) = target {
                params["target"] = json!(t);
            }
            // Pass `spec` verbatim (incl. any `@path` sentinel — resolved later by
            // the watcher each cycle), per ADR-P6.
            if let Some(s) = spec {
                params["spec"] = json!(s);
            }
            if let Some(r) = ratio {
                params["exec_to_dir_ratio"] = json!(r);
            }
            // P14/§4: store the app socket on the WatchState. A GUI team's watched
            // pane lives in the Swift app (not the daemon's headless manager), so
            // the spawned watcher needs it to self-collect the target delta
            // (`tm-agent read <target>`), the WatchController needs it to post to
            // the leader inbox, and §4's GUI execution path needs it to drive
            // recycle/send/read on the watcher pane. resolve_app_socket covers an
            // adopted leader pane that lacks TERMMESH_SOCKET (explicit flag >
            // TERMMESH_SOCKET > detection). Headless callers resolve to None →
            // daemon-side pre-fetch (P13) / headless one-shot covers them.
            if let Some(app_sock) = resolve_app_socket(app_socket.as_deref()) {
                params["app_socket_path"] = json!(app_sock);
            }
            print_result(rpc_call(sock, "watch.on", params));
        }
        WatchAction::Off { team } => {
            print_result(rpc_call(sock, "watch.off", json!({ "team_id": team })));
        }
        WatchAction::Status { team } => {
            // Send cwd as working_directory so the daemon can merge config.json
            // as a fallback for teams not yet in the in-memory registry.
            let wd = env::current_dir()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            let mut params = json!({ "working_directory": wd });
            if let Some(t) = team {
                params["team_id"] = json!(t);
            }
            match rpc_call(sock, "watch.status", params) {
                Ok(resp) => print_watch_status(&resp),
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            }
        }
        WatchAction::Trigger { team } => {
            match rpc_call(sock, "watch.trigger_now", json!({ "team_id": team })) {
                Ok(resp) => print_watch_trigger(&resp),
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            }
        }
        WatchAction::Doctor {
            team,
            watcher,
            no_repair,
            probe_timeout,
            cli,
            json: _json,
        } => {
            // `sock` here is the daemon socket; doctor resolves the app (Swift)
            // socket internally for its team.* RPCs (no new daemon RPCs needed).
            run_watch_doctor(
                sock,
                team,
                watcher.as_deref(),
                *no_repair,
                *probe_timeout,
                cli.as_deref(),
            );
        }
    }
}

/// Render `watch.trigger_now` as a compact one-line summary. The daemon fires the
/// check in the background (tokio::spawn), so this confirms the fire was accepted;
/// the verdict itself lands in `.xm/watch/board.jsonl` and the next `watch status`
/// `last_error`/`check_count`. `/watch test` polls status after this to surface it.
pub(crate) fn print_watch_trigger(resp: &Value) {
    let resp = resp.get("result").unwrap_or(resp);
    let triggered = resp
        .get("triggered")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    if triggered {
        let team = resp.get("team_id").and_then(|v| v.as_str()).unwrap_or("?");
        let count = resp
            .get("check_count")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        println!("TRIGGERED: true  TEAM: {team}  CHECK_COUNT: {count}");
    } else {
        let reason = resp
            .get("reason")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown");
        println!("TRIGGERED: false  REASON: {reason}");
    }
}

/// Render `watch.status` as a human-readable summary (P12 #6) instead of raw JSON.
pub(crate) fn print_watch_status(resp: &Value) {
    // `rpc_call` returns the full JSON-RPC envelope (`{id, result, ...}`); the
    // watch payload lives under `result`. Unwrap it (fall back to the raw value
    // so an already-unwrapped payload still works). Without this the lookups
    // below always missed and every status printed "No watches configured"
    // even though the daemon registry held a live watch.
    let resp = resp.get("result").unwrap_or(resp);
    // The handler returns either `{watch: {..}|null}` (single team) or
    // `{watches: [..]}` (all teams).
    let states: Vec<&Value> = if let Some(one) = resp.get("watch") {
        if one.is_null() {
            Vec::new()
        } else {
            vec![one]
        }
    } else if let Some(arr) = resp.get("watches").and_then(Value::as_array) {
        arr.iter().collect()
    } else {
        Vec::new()
    };

    if states.is_empty() {
        println!("No watches configured.");
        return;
    }

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    for st in states {
        let team = st.get("team_id").and_then(Value::as_str).unwrap_or("?");
        let enabled = st.get("enabled").and_then(Value::as_bool).unwrap_or(false);
        let running = st.get("running").and_then(Value::as_bool).unwrap_or(false);
        let target = st
            .get("target")
            .and_then(Value::as_str)
            .unwrap_or("all (workers)");
        let interval = st.get("interval_secs").and_then(Value::as_u64).unwrap_or(0);
        let stance = st.get("stance").and_then(Value::as_str).unwrap_or("?");
        let cli = st.get("cli").and_then(Value::as_str).unwrap_or("?");
        let model = st.get("model").and_then(Value::as_str).unwrap_or("?");
        let drift = st.get("drift_count").and_then(Value::as_u64).unwrap_or(0);
        // healthy defaults to true when the field is absent (older daemon) so a
        // back-compat status never shows a spurious failure.
        let healthy = st.get("healthy").and_then(Value::as_bool).unwrap_or(true);
        let failures = st
            .get("consecutive_failures")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let last_error = st
            .get("last_error")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty());

        // health makes a 100%-failing watch obvious instead of hiding behind a
        // progressing next_tick: ok when no failure streak, FAILING with the
        // consecutive-failure count otherwise.
        let health = if healthy {
            "ok".to_string()
        } else if failures > 0 {
            format!("FAILING ({failures} consecutive)")
        } else {
            "FAILING".to_string()
        };

        println!("watch: {team}");
        println!("  enabled:   {}", if enabled { "yes" } else { "no" });
        println!("  running:   {}", if running { "yes" } else { "no" });
        println!("  health:    {health}");
        println!("  target:    {target}");
        println!("  interval:  {interval}s");
        println!("  stance:    {stance} ({cli}/{model})");
        // last_ok is the last *successful* check; last_try is the last attempt
        // (success or failure). They diverge precisely when the watch is failing.
        println!("  last_ok:   {}", fmt_tick(st.get("last_tick"), now, false));
        println!(
            "  last_try:  {}",
            fmt_tick(st.get("last_attempt"), now, false)
        );
        println!("  next_tick: {}", fmt_tick(st.get("next_tick"), now, true));
        println!("  drifts:    {drift}");
        if let Some(err) = last_error {
            println!("  error:     {err}");
        }
    }
}

/// Format an epoch-seconds tick value with a relative hint. `future` picks the
/// "in Ns" vs "Ns ago" phrasing; null/0 renders as "never"/"pending".
pub(crate) fn fmt_tick(v: Option<&Value>, now: u64, future: bool) -> String {
    let ts = match v.and_then(Value::as_u64) {
        Some(t) if t > 0 => t,
        _ => {
            return if future {
                "pending".into()
            } else {
                "never".into()
            }
        }
    };
    let rel = if future {
        if ts > now {
            format!("in {}", fmt_dur(ts - now))
        } else {
            "due now".into()
        }
    } else if now >= ts {
        format!("{} ago", fmt_dur(now - ts))
    } else {
        "just now".into()
    };
    format!("{ts} ({rel})")
}

/// Compact duration: seconds → `Ns` / `Nm` / `Nh`.
pub(crate) fn fmt_dur(secs: u64) -> String {
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        format!("{}m", secs / 60)
    } else {
        format!("{}h", secs / 3600)
    }
}
