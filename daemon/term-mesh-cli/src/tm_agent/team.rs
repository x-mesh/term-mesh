use super::*;

pub(crate) fn run_recycle(sock: &PathBuf, team: &str, target: &str, force: bool) {
    let status = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };

    let agents = status["result"]["agents"]
        .as_array()
        .ok_or_else(|| "team.status response missing result.agents".to_string())
        .unwrap_or_else(|e| {
            eprintln!("Error: {e}");
            process::exit(1);
        });
    let matches: Vec<&Value> = agents
        .iter()
        .filter(|agent| agent["name"].as_str() == Some(target))
        .collect();

    if matches.is_empty() {
        eprintln!("Error: agent not found: {target}");
        process::exit(1);
    }
    if matches.len() > 1 {
        eprintln!(
            "Error: multiple agents named {target}; recycle requires a unique agent name. Use `tm-agent restart {target} --hard` only if you accept first-match behavior."
        );
        process::exit(1);
    }

    let agent = matches[0];
    let active_task_id = agent["active_task_id"].as_str();
    let active_task_status = agent["active_task_status"].as_str().unwrap_or("");
    let terminal_checkpoint_status =
        matches!(active_task_status, "blocked" | "review_ready" | "completed");
    if active_task_id.is_some() && !terminal_checkpoint_status && !force {
        eprintln!(
            "Error: refusing to recycle {target}; active task {} is {active_task_status}. Checkpoint or finish the task first, or pass --force.",
            active_task_id.unwrap_or("<unknown>")
        );
        process::exit(1);
    }

    if active_task_id.is_some() && force {
        eprintln!(
            "recycle --force: discarding pane transcript for {target}; ensure task state was checkpointed in the task board or result files."
        );
    } else {
        eprintln!(
            "recycle: hard-restarting {target} to drop accumulated context; durable state remains in the task board/results."
        );
    }

    let result = rpc_call(
        sock,
        "team.restart",
        json!({
            "team_name": team,
            "agent_name": target,
            "mode": "hard",
        }),
    );
    print_result(result);
}

/// Check if an agent is headless by querying the daemon's headless.resolve RPC.
pub(crate) fn is_headless_agent(
    daemon_sock: &PathBuf,
    team: &str,
    agent_name: &str,
) -> Option<String> {
    if let Ok(resp) = rpc_call(
        daemon_sock,
        "headless.resolve",
        json!({
            "team_name": team,
            "agent_name": agent_name,
        }),
    ) {
        if resp["result"]["headless"].as_bool().unwrap_or(false) {
            return resp["result"]["agent_id"].as_str().map(String::from);
        }
    }
    None
}

pub(crate) fn run_create_headless(
    app_sock: &PathBuf,
    team: &str,
    count: u32,
    model: &str,
    effort: Option<&str>,
    leader_effort: Option<&str>,
    roles: Option<&str>,
    watcher_spec: Option<&str>,
    no_auto_watch: bool,
    auto_recycle: Option<u32>,
) {
    let daemon_sock = match detect_daemon_socket() {
        Some(s) => s,
        None => {
            eprintln!("Error: daemon socket not found (is term-meshd running?)");
            process::exit(1);
        }
    };

    // Build agent list from roles or defaults
    let mut agent_specs: Vec<Value> = if let Some(roles_str) = roles {
        roles_str
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .enumerate()
            .map(|(_i, name)| {
                let mut spec =
                    json!({ "name": name, "agent_type": name, "cli": "claude", "model": model });
                if let Some(n) = auto_recycle {
                    spec["auto_recycle_every"] = json!(n);
                }
                spec
            })
            .collect()
    } else {
        (0..count as usize)
            .map(|i| {
                let name = if i < DEFAULT_AGENT_NAMES.len() {
                    DEFAULT_AGENT_NAMES[i].to_string()
                } else {
                    format!("agent-{i}")
                };
                let mut spec =
                    json!({ "name": name, "agent_type": name, "cli": "claude", "model": model });
                if let Some(n) = auto_recycle {
                    spec["auto_recycle_every"] = json!(n);
                }
                spec
            })
            .collect()
    };

    // Attach watcher spec (if any) to watcher agents only (R7: watcher-only).
    apply_watcher_spec(&mut agent_specs, watcher_spec);
    if let Some(effort) = effort {
        for agent in &mut agent_specs {
            agent["effort"] = json!(effort);
        }
    }

    let workdir = env::current_dir()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| ".".to_string());

    // Destroy existing headless team first
    let _ = rpc_call_timeout(
        &daemon_sock,
        "headless.destroy_team",
        json!({ "team_name": team }),
        3,
    );

    let agent_count = agent_specs.len();
    eprintln!("Creating headless team '{team}' with {agent_count} agent(s) on daemon...");
    eprintln!("Daemon socket: {}", daemon_sock.display());

    let mut create_params = json!({
        "team_name": team,
        "working_directory": workdir,
        "leader_session_id": format!("leader-{}", process::id()),
        "agents": agent_specs,
        "app_socket_path": app_sock.to_string_lossy(),
    });
    if let Some(effort) = leader_effort {
        create_params["leader_effort"] = json!(effort);
    }

    match rpc_call_timeout(&daemon_sock, "headless.create_team", create_params, 30) {
        Ok(resp) => {
            if let Some(err) = resp.get("error") {
                eprintln!("Error: {}", err["message"].as_str().unwrap_or("unknown"));
                process::exit(1);
            }
            println!("{}", pretty(&resp));

            // Send init prompts to all agents
            eprintln!("\nSending init prompts to headless agents...");
            let app_sock_str = app_sock.to_string_lossy();
            for spec in &agent_specs {
                let name = spec["name"].as_str().unwrap_or("");
                let role = spec["agent_type"].as_str().unwrap_or(name);
                let agent_id = format!("{name}@{team}");
                // Watcher --spec is delivered via the daemon as --append-system-prompt
                // (custom_instructions folded into the persisted instructions at
                // create_team time), so no init-prompt injection is needed here.
                let init_text = agent_init_prompt(name, role, team, &workdir, &app_sock_str);
                match rpc_call_timeout(
                    &daemon_sock,
                    "headless.send",
                    json!({
                        "agent_id": agent_id,
                        "text": init_text,
                    }),
                    5,
                ) {
                    Ok(_) => eprintln!("  \u{2713} {name}: init prompt sent"),
                    Err(e) => eprintln!("  \u{2717} {name}: init prompt FAILED: {e}"),
                }
            }
        }
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    }

    println!();
    println!("Commands:");
    println!("  tm-agent send <agent> 'your message'");
    println!("  tm-agent read <agent> --lines 50");
    println!("  tm-agent status");
    println!("  tm-agent destroy");

    // Auto-watch hook: use agent_specs directly (daemon roster, no app_sock)
    let wd = env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
    maybe_auto_watch_after_headless_create(&agent_specs, team, no_auto_watch, &wd);
}

pub(crate) fn run_add_headless(
    app_sock: &PathBuf,
    daemon_sock: &PathBuf,
    team: &str,
    agent_name: &str,
    agent_type: &str,
    model: &str,
    cli: &str,
    effort: Option<&str>,
    no_auto_watch: bool,
    auto_recycle: Option<u32>,
) {
    eprintln!("Adding agent '{agent_name}' (type={agent_type}, cli={cli}, model={model}) to headless team '{team}'...");

    let app_sock_str = app_sock.to_string_lossy().to_string();

    let mut add_params = json!({
        "team_name": team,
        "name": agent_name,
        "agent_type": agent_type,
        "cli": cli,
        "model": model,
        "app_socket_path": app_sock_str,
    });
    if let Some(n) = auto_recycle {
        add_params["auto_recycle_every"] = json!(n);
    }
    if let Some(effort) = effort {
        add_params["effort"] = json!(effort);
    }

    match rpc_call_timeout(daemon_sock, "headless.add_agent", add_params, 15) {
        Ok(resp) => {
            if let Some(err) = resp.get("error") {
                eprintln!("Error: {}", err["message"].as_str().unwrap_or("unknown"));
                process::exit(1);
            }

            println!("{}", pretty(&resp));

            // Send init prompt to the new agent
            let workdir = env::current_dir()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|_| ".".to_string());
            let agent_id = format!("{agent_name}@{team}");
            let init_text =
                agent_init_prompt(agent_name, agent_type, team, &workdir, &app_sock_str);

            match rpc_call_timeout(
                daemon_sock,
                "headless.send",
                json!({
                    "agent_id": agent_id,
                    "text": init_text,
                }),
                5,
            ) {
                Ok(_) => eprintln!("  \u{2713} {agent_name}: init prompt sent"),
                Err(e) => eprintln!("  \u{2717} {agent_name}: init prompt FAILED: {e}"),
            }

            // Register the agent with the Swift app's team data store
            // Use agent_type (role) separately from agent_name (display name)
            match rpc_call(
                app_sock,
                "team.register_agent",
                json!({
                    "team_name": team,
                    "agent_name": agent_name,
                    "agent_type": agent_type,
                    "model": model,
                    "cli": cli,
                }),
            ) {
                Ok(_) => {}
                Err(e) => {
                    eprintln!("  Warning: failed to register agent with app: {e}");
                    eprintln!(
                        "  (agent process is running on daemon but may not appear in app UI)"
                    );
                }
            }

            eprintln!("\nAgent '{agent_name}' added to team '{team}'.");

            // Fire unconditionally — helper checks (watcher==1 + worker>=1) internally.
            let wd = env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
            maybe_auto_watch_after_headless_add(
                daemon_sock,
                team,
                no_auto_watch,
                &wd,
                agent_name,
                agent_type,
                cli,
                model,
            );
        }
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    }
}

#[cfg(test)]
mod watcher_spec_tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn resolve_watcher_spec_absent_and_empty_return_none() {
        assert_eq!(resolve_watcher_spec(None).unwrap(), None);
        assert_eq!(resolve_watcher_spec(Some("")).unwrap(), None);
    }

    #[test]
    fn resolve_watcher_spec_literal_passthrough() {
        assert_eq!(
            resolve_watcher_spec(Some("watch the diff scope")).unwrap(),
            Some("watch the diff scope".to_string())
        );
    }

    #[test]
    fn resolve_watcher_spec_at_path_reads_file() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = env::temp_dir().join(format!("tm-spec-{nanos}.txt"));
        fs::write(&path, "SPEC: do not drift from the plan").unwrap();
        let arg = format!("@{}", path.display());
        let resolved = resolve_watcher_spec(Some(&arg)).unwrap();
        assert_eq!(
            resolved,
            Some("SPEC: do not drift from the plan".to_string())
        );
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn resolve_watcher_spec_at_missing_file_errors() {
        assert!(resolve_watcher_spec(Some("@/nonexistent/tm-spec-xyz.txt")).is_err());
        assert!(resolve_watcher_spec(Some("@")).is_err());
    }

    #[test]
    fn apply_watcher_spec_attaches_to_watcher_only() {
        // R7 invariant: spec lands on watcher, never on other roles.
        let mut agents = vec![
            json!({ "name": "watcher", "agent_type": "watcher", "cli": "claude", "model": "sonnet" }),
            json!({ "name": "executor", "agent_type": "executor", "cli": "claude", "model": "sonnet" }),
        ];
        apply_watcher_spec(&mut agents, Some("oversight spec"));
        assert_eq!(
            agents[0]["custom_instructions"].as_str(),
            Some("oversight spec")
        );
        assert!(agents[1].get("custom_instructions").is_none());
    }

    #[test]
    fn apply_watcher_spec_uses_name_when_agent_type_missing() {
        let mut agents = vec![json!({ "name": "watcher", "cli": "claude", "model": "sonnet" })];
        apply_watcher_spec(&mut agents, Some("spec via name"));
        assert_eq!(
            agents[0]["custom_instructions"].as_str(),
            Some("spec via name")
        );
    }

    #[test]
    fn apply_watcher_spec_none_is_noop() {
        let mut agents =
            vec![json!({ "name": "watcher", "agent_type": "watcher", "cli": "claude" })];
        apply_watcher_spec(&mut agents, None);
        assert!(agents[0].get("custom_instructions").is_none());
    }

    // ── P15: watch daemon-socket routing ──────────────────────────────────
    #[test]
    fn is_app_socket_path_classifies_app_vs_daemon() {
        // App sockets (no trailing `d`) and cmux are app sockets.
        assert!(is_app_socket_path(Path::new("/tmp/term-mesh.sock")));
        assert!(is_app_socket_path(Path::new("/tmp/term-mesh-debug.sock")));
        assert!(is_app_socket_path(Path::new(
            "/tmp/term-mesh-debug-watcher-p2.sock"
        )));
        assert!(is_app_socket_path(Path::new("/tmp/cmux.sock")));
        // Daemon sockets are NOT app sockets.
        assert!(!is_app_socket_path(Path::new("/tmp/term-meshd.sock")));
        assert!(!is_app_socket_path(Path::new(
            "/Users/x/Library/Application Support/term-mesh/term-meshd-dev-watcher-p2.sock"
        )));
    }

    #[test]
    fn derive_daemon_socket_maps_tagged_app_to_app_support() {
        let _env = SocketDiscoveryEnv::isolated();
        std::env::set_var("HOME", "/Users/tester");
        let derived =
            derive_daemon_socket_from_app(Path::new("/tmp/term-mesh-debug-watcher-p2.sock"));
        assert_eq!(
            derived,
            Some(PathBuf::from(
                "/Users/tester/Library/Application Support/term-mesh/term-meshd-dev-watcher-p2.sock"
            ))
        );
    }

    #[test]
    fn derive_daemon_socket_skips_live_and_untagged() {
        let _env = SocketDiscoveryEnv::isolated();
        std::env::set_var("HOME", "/Users/tester");
        // Live/release app socket → no derivation (falls through to default daemon).
        assert_eq!(
            derive_daemon_socket_from_app(Path::new("/tmp/term-mesh.sock")),
            None
        );
        // Untagged debug app socket → no derivation (uses default daemon).
        assert_eq!(
            derive_daemon_socket_from_app(Path::new("/tmp/term-mesh-debug.sock")),
            None
        );
        // A daemon socket is never an "app" socket to derive from.
        assert_eq!(
            derive_daemon_socket_from_app(Path::new("/tmp/term-meshd.sock")),
            None
        );
    }

    // ── Linux control-socket discovery ────────────────────────────────────

    /// Guards the regression this list exists for: a Linux host binds its
    /// control socket under the runtime dir or the installer's service
    /// directory, and before these entries existed `tm-agent` looked only in
    /// `/tmp` and answered DAEMON_UNAVAILABLE on a host whose daemon was up.
    /// Both socket-discovery tests clear and set the same five process-global
    /// environment variables, so running them concurrently lets one observe
    /// the other's cleared state. Observed once as
    /// `daemon_socket_candidates_cover_both_linux_install_scopes` failing in a
    /// full-suite run that passed on the next four. Serialize them; a flake
    /// that rare is worse than one that always fails. The guard is the
    /// suite-wide one because these tests also clear `HOME`, which the leader
    /// turn tests read.
    const SOCKET_ENV_KEYS: [&str; 6] = [
        "TERMMESH_DAEMON_SOCKET",
        "TERMMESH_DAEMON_UNIX_PATH",
        "XDG_RUNTIME_DIR",
        "TMPDIR",
        "HOME",
        "SUDO_UID",
    ];
    struct SocketDiscoveryEnv {
        saved: Vec<(&'static str, Option<OsString>)>,
        _guard: ProcessEnvGuard,
    }
    impl SocketDiscoveryEnv {
        fn isolated() -> Self {
            let guard = ProcessEnvGuard::acquire();
            let saved = SOCKET_ENV_KEYS
                .iter()
                .map(|&key| {
                    let value = env::var_os(key);
                    env::remove_var(key);
                    (key, value)
                })
                .collect();
            Self {
                saved,
                _guard: guard,
            }
        }
    }
    impl Drop for SocketDiscoveryEnv {
        fn drop(&mut self) {
            for (key, value) in &self.saved {
                match value {
                    Some(value) => env::set_var(key, value),
                    None => env::remove_var(key),
                }
            }
        }
    }

    #[test]
    fn daemon_socket_candidates_cover_both_linux_install_scopes() {
        let _env = SocketDiscoveryEnv::isolated();
        // An empty HOME would make the user peer.env path `/.config/...`.
        std::env::set_var("HOME", "/nonexistent-home-for-tests");
        std::env::set_var("XDG_RUNTIME_DIR", "/run/user/4242");

        let candidates = daemon_socket_candidates();

        // User-scope service (installer default for a non-root install).
        assert!(candidates.contains(&PathBuf::from("/run/user/4242/term-meshd.sock")));
        // System-scope service (root installer default, and what peer.env pins).
        assert!(candidates.contains(&PathBuf::from("/run/term-mesh/term-meshd.sock")));
        // The historical default stays last so macOS behaviour is unchanged.
        assert_eq!(
            candidates.last(),
            Some(&PathBuf::from("/tmp/term-meshd.sock"))
        );
    }

    /// An explicitly exported socket must still win over every default, and
    /// the list must not offer the same path twice — a duplicate would make
    /// the caller probe a dead pathname a second time before moving on.
    #[test]
    fn daemon_socket_candidates_rank_env_first_and_deduplicate() {
        let _env = SocketDiscoveryEnv::isolated();
        std::env::set_var("HOME", "/nonexistent-home-for-tests");
        // Both variables name the same socket, as a daemon-spawned pane sees it.
        std::env::set_var("TERMMESH_DAEMON_SOCKET", "/run/term-mesh/term-meshd.sock");
        std::env::set_var(
            "TERMMESH_DAEMON_UNIX_PATH",
            "/run/term-mesh/term-meshd.sock",
        );

        let candidates = daemon_socket_candidates();

        assert_eq!(
            candidates.first(),
            Some(&PathBuf::from("/run/term-mesh/term-meshd.sock"))
        );
        assert_eq!(
            candidates
                .iter()
                .filter(|path| *path == &PathBuf::from("/run/term-mesh/term-meshd.sock"))
                .count(),
            1,
            "the same socket must be probed once, however many names point at it"
        );
    }

    /// The value systemd reads from `peer.env` is invisible to a login shell,
    /// so the resolver reads the file itself rather than requiring every
    /// operator to re-export what the installer already wrote.
    #[test]
    fn peer_env_daemon_socket_reads_the_installer_written_value() {
        let _env = SocketDiscoveryEnv::isolated();
        let dir = tempfile::tempdir().unwrap();
        let user = dir.path().join("user.env");
        let system = dir.path().join("system.env");
        std::fs::write(
            &user,
            "TERMMESH_DAEMON_UNIX_PATH=\"/run/user/0/term-meshd.sock\"\n",
        )
        .unwrap();
        std::fs::write(
            &system,
            "TERMMESH_DAEMON_UNIX_PATH='/run/term-mesh/term-meshd.sock'\n",
        )
        .unwrap();
        assert_eq!(
            peer_env_daemon_sockets_from_paths(&[user, system]),
            vec![
                PathBuf::from("/run/term-mesh/term-meshd.sock"),
                PathBuf::from("/run/user/0/term-meshd.sock"),
            ]
        );
    }

    #[test]
    fn socket_environment_is_restored_when_a_test_panics() {
        let before = env::var_os("SUDO_UID");
        let _ = std::panic::catch_unwind(|| {
            let _env = SocketDiscoveryEnv::isolated();
            env::set_var("SUDO_UID", OsString::from("4242"));
            panic!("exercise Drop");
        });
        assert_eq!(env::var_os("SUDO_UID"), before);
    }

    #[test]
    fn doctor_uid_and_mixed_outcome_helpers_are_deterministic() {
        assert!(uid_is_trusted(501, 501));
        assert!(uid_is_trusted(0, 501));
        assert!(!uid_is_trusted(502, 501));
        assert_eq!(doctor_expected_uid_from(0, Some(501)), 501);
        let outcomes = vec![
            (
                PathBuf::from("/old.sock"),
                DoctorSocketOutcome::Unsupported("unknown method".into()),
            ),
            (
                PathBuf::from("/new.sock"),
                DoctorSocketOutcome::Report(vec![]),
            ),
            (
                PathBuf::from("/failed.sock"),
                DoctorSocketOutcome::RpcFailed("timeout".into()),
            ),
        ];
        let findings = aggregate_doctor_findings(&outcomes);
        assert!(findings
            .iter()
            .any(|finding| finding["code"] == "multiple_daemon_owners"));
        assert!(findings.iter().any(|f| f["code"] == "doctor_unsupported"));
        assert!(findings.iter().any(|f| f["code"] == "doctor_rpc_failed"));
        assert_eq!(doctor_exit_code(&outcomes, &findings), 1);
        let incomplete = vec![
            (
                PathBuf::from("/old.sock"),
                DoctorSocketOutcome::Unsupported("unknown method".into()),
            ),
            (
                PathBuf::from("/failed.sock"),
                DoctorSocketOutcome::RpcFailed("timeout".into()),
            ),
        ];
        let incomplete_findings = aggregate_doctor_findings(&incomplete);
        assert_eq!(doctor_exit_code(&incomplete, &incomplete_findings), 1);
        let healthy = vec![(
            PathBuf::from("/healthy.sock"),
            DoctorSocketOutcome::Report(vec![]),
        )];
        assert_eq!(doctor_exit_code(&healthy, &[]), 0);
        let report_and_unsupported = vec![
            (
                PathBuf::from("/healthy.sock"),
                DoctorSocketOutcome::Report(vec![]),
            ),
            (
                PathBuf::from("/old.sock"),
                DoctorSocketOutcome::Unsupported("unknown method".into()),
            ),
        ];
        assert_eq!(
            doctor_exit_code(
                &report_and_unsupported,
                &aggregate_doctor_findings(&report_and_unsupported)
            ),
            1
        );
        let report_and_failure = vec![
            (
                PathBuf::from("/healthy.sock"),
                DoctorSocketOutcome::Report(vec![]),
            ),
            (
                PathBuf::from("/failed.sock"),
                DoctorSocketOutcome::RpcFailed("timeout".into()),
            ),
        ];
        assert_eq!(
            doctor_exit_code(
                &report_and_failure,
                &aggregate_doctor_findings(&report_and_failure)
            ),
            1
        );
        let report_and_untrusted = vec![
            (
                PathBuf::from("/healthy.sock"),
                DoctorSocketOutcome::Report(vec![]),
            ),
            (
                PathBuf::from("/untrusted.sock"),
                DoctorSocketOutcome::Untrusted("foreign uid".into()),
            ),
        ];
        assert_eq!(
            doctor_exit_code(
                &report_and_untrusted,
                &aggregate_doctor_findings(&report_and_untrusted)
            ),
            2
        );
    }

    #[test]
    fn doctor_result_parser_rejects_malformed_or_inconsistent_reports() {
        assert_eq!(
            parse_doctor_result(json!({"healthy": true, "findings": []})).unwrap(),
            Vec::<Value>::new()
        );
        assert!(parse_doctor_result(json!({"healthy": true})).is_err());
        assert!(parse_doctor_result(json!({"healthy": "yes", "findings": []})).is_err());
        assert!(parse_doctor_result(json!({
            "healthy": true,
            "findings": [{"code": "surface_missing"}]
        }))
        .is_err());
        assert!(parse_doctor_result(json!({
            "healthy": false,
            "findings": []
        }))
        .is_err());
    }

    #[test]
    fn multiple_daemons_withhold_applied_repairs() {
        let applied = json!({
            "code": "surface_missing",
            "severity": "error",
            "detail": "missing",
            "remedy": "dangerous",
            "repair_argv": ["tm-agent", "daemon", "project-presentations", "prune",
                "--project-id", "team:x", "--apply"],
        });
        let outcomes = vec![
            (
                PathBuf::from("/one.sock"),
                DoctorSocketOutcome::Report(vec![applied.clone()]),
            ),
            (
                PathBuf::from("/two.sock"),
                DoctorSocketOutcome::Report(vec![applied]),
            ),
        ];
        let findings = aggregate_doctor_findings(&outcomes);
        let reported = findings
            .iter()
            .filter(|finding| finding["code"] == "surface_missing")
            .collect::<Vec<_>>();
        assert_eq!(reported.len(), 2);
        for finding in reported {
            assert_eq!(
                finding["repair_argv"],
                json!(["tm-agent", "daemon", "project-presentations", "list"])
            );
            assert_eq!(
                finding["remedy"],
                "'tm-agent' 'daemon' 'project-presentations' 'list'"
            );
            assert!(finding["detail"]
                .as_str()
                .unwrap()
                .contains("applied repair is withheld"));
        }

        let legacy = with_multiple_daemon_repair_withheld(json!({
            "code": "legacy_surface_missing",
            "severity": "error",
            "detail": "legacy missing",
            "remedy": "tm-agent daemon project-presentations prune --project-id team:x --apply"
        }));
        assert_eq!(
            legacy["repair_argv"],
            json!(["tm-agent", "daemon", "project-presentations", "list"])
        );
        assert_eq!(
            legacy["remedy"],
            "'tm-agent' 'daemon' 'project-presentations' 'list'"
        );

        let structured_inspect = json!({
            "code": "surface_predates_record",
            "severity": "warning",
            "detail": "inspect",
            "remedy": "'tm-agent' 'daemon' 'project-presentations' 'list'",
            "repair_argv": ["tm-agent", "daemon", "project-presentations", "list"]
        });
        assert_eq!(
            with_multiple_daemon_repair_withheld(structured_inspect.clone()),
            structured_inspect
        );
    }

    #[test]
    fn untrusted_connected_socket_withholds_applied_repair() {
        let outcomes = vec![
            (
                PathBuf::from("/untrusted.sock"),
                DoctorSocketOutcome::Untrusted("foreign uid".into()),
            ),
            (
                PathBuf::from("/trusted.sock"),
                DoctorSocketOutcome::Report(vec![json!({
                    "code": "surface_missing",
                    "severity": "error",
                    "detail": "missing",
                    "remedy": "dangerous",
                    "repair_argv": ["tm-agent", "daemon", "project-presentations",
                        "prune", "--project-id", "team:x", "--apply"],
                })]),
            ),
        ];

        let findings = aggregate_doctor_findings(&outcomes);
        let repair = findings
            .iter()
            .find(|finding| finding["code"] == "surface_missing")
            .expect("surface finding");
        assert_eq!(
            repair["repair_argv"],
            json!(["tm-agent", "daemon", "project-presentations", "list"])
        );
        assert_eq!(
            repair["remedy"],
            "'tm-agent' 'daemon' 'project-presentations' 'list'"
        );
        assert!(!repair["repair_argv"]
            .as_array()
            .unwrap()
            .iter()
            .any(|argument| argument == "--apply"));
        assert!(findings
            .iter()
            .any(|finding| finding["code"] == "untrusted_socket_owner"));
        assert!(!findings
            .iter()
            .any(|finding| finding["code"] == "multiple_daemon_owners"));
        assert_eq!(doctor_exit_code(&outcomes, &findings), 2);
    }

    #[test]
    fn human_remedy_suppresses_control_characters() {
        let finding = json!({
            "remedy": "dangerous",
            "repair_argv": ["tm-agent", "bad\nproject"],
        });
        assert_eq!(
            human_remedy(&finding),
            "unavailable in human output; inspect --json"
        );
        let blank = json!({"remedy": "", "repair_argv": []});
        assert_eq!(human_remedy_line(&blank), None);
    }

    #[test]
    fn terminal_safe_escapes_terminal_controls() {
        let raw = format!(
            "project{}]8;;bad{}{}done",
            char::from(27),
            char::from(7),
            char::from(133)
        );
        let rendered = terminal_safe(&raw);
        assert_eq!(rendered, "project\\u{001B}]8;;bad\\u{0007}\\u{0085}done");
        assert!(!rendered.chars().any(char::is_control));
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn extracts_uid_from_a_connected_unix_peer() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("doctor.sock");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let client = UnixStream::connect(&path).unwrap();
        let (server, _) = listener.accept().unwrap();
        assert_eq!(
            doctor_peer_identity(&client).map(|identity| identity.uid),
            Some(unsafe { libc::getuid() })
        );
        assert_eq!(
            doctor_peer_identity(&server).map(|identity| identity.uid),
            Some(unsafe { libc::getuid() })
        );
    }

    #[test]
    fn doctor_collapses_a_symlink_alias_to_one_listener() {
        use std::os::unix::fs::symlink;

        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("daemon.sock");
        let alias = dir.path().join("daemon-alias.sock");
        let listener = std::os::unix::net::UnixListener::bind(&target).unwrap();
        symlink(&target, &alias).unwrap();

        let target_stream = UnixStream::connect(&target).unwrap();
        let alias_stream = UnixStream::connect(&alias).unwrap();
        let target_identity = doctor_peer_identity(&target_stream).unwrap();
        let alias_identity = doctor_peer_identity(&alias_stream).unwrap();
        assert_eq!(target_identity, alias_identity);
        assert_ne!(
            target_identity,
            DoctorPeerIdentity {
                uid: target_identity.uid,
                pid: target_identity.pid.saturating_add(1),
            }
        );

        let mut identities = std::collections::HashSet::new();
        let mut outcomes = Vec::new();
        for (path, identity) in [(&target, target_identity), (&alias, alias_identity)] {
            if identities.insert(identity) {
                outcomes.push((
                    path.to_path_buf(),
                    DoctorSocketOutcome::Report(vec![json!({
                        "code": "one_report",
                        "severity": "warning",
                    })]),
                ));
            }
        }
        let findings = aggregate_doctor_findings(&outcomes);
        assert_eq!(outcomes.len(), 1);
        assert_eq!(findings.len(), 1);
        assert_eq!(findings[0]["code"], "one_report");
        assert!(!findings
            .iter()
            .any(|finding| finding["code"] == "multiple_daemon_owners"));

        drop(listener);
    }
}

#[cfg(test)]
mod auto_watch_tests {
    use super::*;

    #[test]
    fn auto_watch_env_disabled_by_zero() {
        std::env::set_var("TERMMESH_AUTO_WATCH", "0");
        assert!(is_auto_watch_disabled_by_env());
        std::env::remove_var("TERMMESH_AUTO_WATCH");
    }

    fn make_agent(name: &str, agent_type: &str) -> AutoWatchAgent {
        AutoWatchAgent {
            name: name.to_string(),
            agent_type: agent_type.to_string(),
            cli: "claude".to_string(),
            model: "sonnet".to_string(),
        }
    }

    // ── pure auto_watch_decision tests ────────────────────────────────

    #[test]
    fn decision_no_watcher_returns_skip_no_watcher() {
        let agents = vec![
            make_agent("executor", "executor"),
            make_agent("reviewer", "reviewer"),
        ];
        assert_eq!(
            auto_watch_decision(&agents, true),
            AutoWatchDecision::SkipNoWatcher
        );
    }

    #[test]
    fn decision_no_worker_returns_skip_no_worker() {
        let agents = vec![make_agent("watcher", "watcher")];
        assert_eq!(
            auto_watch_decision(&agents, true),
            AutoWatchDecision::SkipNoWorker
        );
    }

    #[test]
    fn decision_multi_worker_returns_skip_multi_worker() {
        let agents = vec![
            make_agent("watcher", "watcher"),
            make_agent("executor", "executor"),
            make_agent("reviewer", "reviewer"),
        ];
        assert_eq!(
            auto_watch_decision(&agents, true),
            AutoWatchDecision::SkipMultiWorker(2)
        );
    }

    #[test]
    fn decision_spec_missing_returns_skip_missing_spec() {
        let agents = vec![
            make_agent("watcher", "watcher"),
            make_agent("executor", "executor"),
        ];
        assert_eq!(
            auto_watch_decision(&agents, false),
            AutoWatchDecision::SkipMissingSpec
        );
    }

    #[test]
    fn decision_single_worker_spec_present_returns_enable() {
        let agents = vec![
            make_agent("watcher", "watcher"),
            make_agent("executor", "executor"),
        ];
        let result = auto_watch_decision(&agents, true);
        assert_eq!(
            result,
            AutoWatchDecision::Enable {
                target: "executor".to_string(),
                watcher_cli: "claude".to_string(),
                watcher_model: "sonnet".to_string(),
            }
        );
    }

    // ── env var tests (inline logic, no process env mutation) ─────────

    #[test]
    fn auto_watch_env_disabled_values() {
        for val in &["0", "false", "no", "off", "FALSE", "OFF"] {
            assert!(
                matches!(
                    val.to_ascii_lowercase().as_str(),
                    "0" | "false" | "no" | "off"
                ),
                "expected {val} to be disabled"
            );
        }
    }

    #[test]
    fn auto_watch_env_enabled_values() {
        for val in &["1", "true", "yes", "on"] {
            assert!(
                !matches!(
                    val.to_ascii_lowercase().as_str(),
                    "0" | "false" | "no" | "off"
                ),
                "expected {val} to be enabled"
            );
        }
    }

    // ── P1: watch.on envelope parsing ────────────────────────────────────

    #[test]
    fn watch_on_success_envelope_returns_enabled() {
        let r = json!({"result": {"enabled": true, "status": "ok"}});
        assert!(matches!(
            parse_watch_on_response(&r),
            WatchOnOutcome::Enabled
        ));
    }

    #[test]
    fn watch_on_error_envelope_returns_failed_with_message() {
        let r = json!({"error": {"code": -32601, "message": "unknown method"}, "result": null});
        match parse_watch_on_response(&r) {
            WatchOnOutcome::Failed(msg) => assert_eq!(msg, "unknown method"),
            other => panic!("expected Failed, got {other:?}"),
        }
    }

    #[test]
    fn watch_on_malformed_envelope_returns_unexpected() {
        let r = json!({"id": 1});
        assert!(matches!(
            parse_watch_on_response(&r),
            WatchOnOutcome::Unexpected(_)
        ));
    }

    #[test]
    fn watch_on_success_with_enabled_false_returns_unexpected() {
        let r = json!({"result": {"enabled": false}});
        assert!(matches!(
            parse_watch_on_response(&r),
            WatchOnOutcome::Unexpected(_)
        ));
    }

    // ── P2: roster patch for headless add with custom watcher name ────────

    fn patch_roster_for_added_agent(
        mut roster: Vec<AutoWatchAgent>,
        agent_name: &str,
        agent_type: &str,
        cli: &str,
        model: &str,
    ) -> Vec<AutoWatchAgent> {
        if let Some(existing) = roster.iter_mut().find(|a| a.name == agent_name) {
            existing.agent_type = agent_type.to_string();
        } else {
            roster.push(AutoWatchAgent {
                name: agent_name.to_string(),
                agent_type: agent_type.to_string(),
                cli: cli.to_string(),
                model: model.to_string(),
            });
        }
        roster
    }

    #[test]
    fn roster_patch_adds_watcher_when_absent() {
        let roster = vec![make_agent("executor", "executor")];
        let patched = patch_roster_for_added_agent(roster, "drift", "watcher", "claude", "sonnet");
        assert_eq!(patched.len(), 2);
        let w = patched.iter().find(|a| a.name == "drift").unwrap();
        assert_eq!(w.agent_type, "watcher");
        let decision = auto_watch_decision(&patched, true);
        assert_eq!(
            decision,
            AutoWatchDecision::Enable {
                target: "executor".to_string(),
                watcher_cli: "claude".to_string(),
                watcher_model: "sonnet".to_string(),
            }
        );
    }

    #[test]
    fn roster_patch_overrides_fallback_name_as_watcher_type() {
        // headless.list fallback sets agent_type=name="drift" → worker
        let roster = vec![
            make_agent("executor", "executor"),
            make_agent("drift", "drift"),
        ];
        let patched = patch_roster_for_added_agent(roster, "drift", "watcher", "claude", "sonnet");
        let drift = patched.iter().find(|a| a.name == "drift").unwrap();
        assert_eq!(drift.agent_type, "watcher");
        // Now decision should Enable (1 watcher + 1 worker)
        let decision = auto_watch_decision(&patched, true);
        assert_eq!(
            decision,
            AutoWatchDecision::Enable {
                target: "executor".to_string(),
                watcher_cli: "claude".to_string(),
                watcher_model: "sonnet".to_string(),
            }
        );
    }

    #[test]
    fn remote_leader_route_allows_scoped_add_but_not_other_lifecycle_methods() {
        for method in [
            "team.send",
            "team.delegate",
            "team.result.status",
            "team.result.collect",
            "team.task.create",
            "team.task.update",
            "team.task.done",
            "team.task.block",
            "team.task.review",
            "team.task.unblock",
            "team.task.approve",
            "team.task.list",
            "team.task.metrics",
            "team.task.diff",
            // These come from peer-proto's SCOPED_METHODS, not from the
            // match arm above; asserting them here proves the delegation.
            "team.add_agent",
            "team.send_key",
            "team.leader.request.list",
            "team.leader.request.take",
            "team.leader.request.complete",
            "team.delegation.configure",
        ] {
            assert!(remote_leader_method_allowed(method), "{method}");
        }
        for method in [
            "team.create",
            "team.destroy",
            "team.list",
            "team.attach",
            "team.restart",
            "team.task.reassign",
            "surface.send_key",
        ] {
            assert!(!remote_leader_method_allowed(method), "{method}");
        }
    }

    #[test]
    fn remote_leader_list_wraps_only_its_scoped_status() {
        let wrapped = scoped_team_list_from_status(json!({
            "ok": true,
            "result": {
                "team_name": "term-mesh",
                "team_uuid": "owned-team",
                "agent_count": 4,
            },
            "remote_leader_proxy": true,
        }));

        let teams = wrapped["result"].as_array().unwrap();
        assert_eq!(teams.len(), 1);
        assert_eq!(teams[0]["team_uuid"], "owned-team");
        assert_eq!(wrapped["remote_leader_proxy"], true);
    }

    #[test]
    fn remote_leader_team_lifecycle_fails_closed_instead_of_using_peer_local_app() {
        assert_eq!(
            remote_leader_rpc_policy(true, "team.status"),
            RemoteLeaderRpcPolicy::Proxy
        );
        for method in [
            "team.create",
            "team.destroy",
            "team.preset.resolve",
            "team.list",
        ] {
            assert_eq!(
                remote_leader_rpc_policy(true, method),
                RemoteLeaderRpcPolicy::RejectTeam,
                "{method}"
            );
        }
        assert_eq!(
            remote_leader_rpc_policy(true, "system.info"),
            RemoteLeaderRpcPolicy::Local
        );
        assert_eq!(
            remote_leader_rpc_policy(false, "team.create"),
            RemoteLeaderRpcPolicy::Local
        );
    }

    #[test]
    fn remote_leader_batch_and_wait_methods_are_proxied() {
        for method in [
            "team.status",
            "team.task.list",
            "team.send",
            "team.broadcast",
            "team.inbox",
            "team.task.get",
        ] {
            assert_eq!(
                remote_leader_rpc_policy(true, method),
                RemoteLeaderRpcPolicy::Proxy,
                "{method}"
            );
            assert_eq!(
                remote_leader_rpc_policy(false, method),
                RemoteLeaderRpcPolicy::Local,
                "{method}"
            );
        }
    }

    #[test]
    fn remote_leader_batch_per_call_preserves_order_and_errors() {
        let payloads = [
            json!({"jsonrpc": "2.0", "id": 1, "method": "team.status", "params": {"team_name": "t"}})
                .to_string(),
            json!({"jsonrpc": "2.0", "id": 2, "method": "team.create", "params": {"name": "x"}})
                .to_string(),
            json!({"jsonrpc": "2.0", "id": 3, "method": "team.task.list"}).to_string(),
        ];
        let mut calls: Vec<(String, Value)> = Vec::new();
        let results = rpc_batch_per_call(&payloads, |method, params| {
            calls.push((method.to_string(), params.clone()));
            if method == "team.create" {
                Err("rejected".to_string())
            } else {
                Ok(json!({ "ok": true, "result": { "method": method } }))
            }
        })
        .expect("valid payloads");

        assert_eq!(
            calls,
            vec![
                ("team.status".to_string(), json!({"team_name": "t"})),
                ("team.create".to_string(), json!({"name": "x"})),
                ("team.task.list".to_string(), json!({})),
            ]
        );
        assert_eq!(results.len(), payloads.len());
        assert_eq!(results[0]["result"]["method"], "team.status");
        assert_eq!(results[1], json!({ "error": "rejected" }));
        assert_eq!(results[2]["result"]["method"], "team.task.list");

        let mut invalid_calls = 0;
        let invalid = rpc_batch_per_call(
            &[
                json!({"method": "team.status"}).to_string(),
                "{not json".to_string(),
            ],
            |_, _| {
                invalid_calls += 1;
                Ok(json!({}))
            },
        );
        assert!(invalid.is_err());
        assert_eq!(invalid_calls, 0, "no call before every payload validates");

        let mut methodless_calls = 0;
        let methodless = rpc_batch_per_call(&[json!({"params": {}}).to_string()], |_, _| {
            methodless_calls += 1;
            Ok(json!({}))
        });
        assert!(methodless.is_err());
        assert_eq!(methodless_calls, 0);
    }

    #[test]
    fn remote_leader_request_ids_are_opaque_fixed_width_and_unique() {
        let first = remote_leader_request_id_hex();
        let second = remote_leader_request_id_hex();
        assert_eq!(first.len(), 32);
        assert_eq!(second.len(), 32);
        assert_ne!(first, second);
        assert!(first.bytes().all(|byte| byte.is_ascii_hexdigit()));
    }

    #[test]
    fn remote_leader_delegate_proxy_submits_return_and_retry_reuses_request_id() {
        let route = RemoteLeaderRoute {
            grant_id_hex: "ab".repeat(32),
            project_id: "name:demo".to_string(),
            team_uuid: "team-uuid".to_string(),
            expires_at_unix_secs: u64::MAX,
            target_peer_id_hex: "cd".repeat(16),
        };
        let request_id = "41".repeat(16);
        let original = json!({
            "agent_name": "executor",
            "text": "inspect relay",
            "submit_return": false,
        });

        let first =
            remote_leader_proxy_params(&route, "team.delegate", original.clone(), &request_id)
                .expect("first proxy payload");
        let retry = remote_leader_proxy_params(&route, "team.delegate", original, &request_id)
            .expect("retry proxy payload");

        assert_eq!(first, retry, "retry must reuse the entire scoped request");
        assert_eq!(first["request_id_hex"], request_id);
        assert_eq!(first["target_peer_id_hex"], "cd".repeat(16));
        assert_eq!(first["method"], "team.delegate");
        let inner: Value = serde_json::from_str(first["params_json"].as_str().unwrap()).unwrap();
        assert_eq!(inner["text"], "inspect relay");
        assert_eq!(
            inner["submit_return"], true,
            "remote delegate must commit text + one Return inside the deduped request"
        );
    }

    #[test]
    fn remote_leader_delegate_ack_suppresses_legacy_followup_return() {
        assert!(delegate_return_already_submitted(&json!({
            "remote_leader_proxy": true,
            "result": { "return_submitted": false },
        })));
        assert!(delegate_return_already_submitted(&json!({
            "result": { "return_submitted": true },
        })));
        assert!(!delegate_return_already_submitted(&json!({
            "result": { "return_submitted": false },
        })));
    }

    #[test]
    fn remote_leader_proxy_preserves_nested_error_code_and_message() {
        let error = remote_leader_proxy_result(json!({
            "ok": false,
            "result": {
                "error_code": "expired_grant",
                "error_message": "leader grant expired before dispatch",
            },
        }))
        .unwrap_err();

        assert_eq!(
            error,
            "remote leader proxy [expired_grant]: leader grant expired before dispatch; \
             reconnect or restart the remote leader pane from its owning project window"
        );
    }

    #[test]
    fn unknown_remote_leader_grant_has_an_actionable_recovery_hint() {
        let error = remote_leader_proxy_result(json!({
            "ok": false,
            "result": {
                "error_code": "unknown_grant",
                "error_message": "remote leader command rejected",
            },
        }))
        .unwrap_err();

        assert!(error.contains("[unknown_grant]"), "{error}");
        assert!(
            error.contains("reconnect or restart the remote leader pane"),
            "{error}"
        );
    }

    #[test]
    fn viewer_route_retry_requires_an_explicit_error_and_uses_the_latest_route() {
        let current = RemoteLeaderRoute {
            grant_id_hex: "ab".repeat(32),
            project_id: "name:demo".into(),
            team_uuid: "team-uuid".into(),
            expires_at_unix_secs: 100,
            target_peer_id_hex: "11".repeat(16),
        };
        let mut refreshed = current.clone();
        refreshed.grant_id_hex = "cd".repeat(32);
        refreshed.target_peer_id_hex = "22".repeat(16);
        let unavailable = json!({
            "ok": false,
            "error": {"message": "authorized peer viewer is unavailable"},
        });

        assert_eq!(
            remote_leader_route_retry_candidate(&current, &unavailable, Some(refreshed.clone()),),
            Some(refreshed),
        );
        assert_eq!(
            remote_leader_route_retry_candidate(&current, &unavailable, None),
            Some(current.clone()),
            "a same-route transport reconnect still retries the stable request id"
        );
        assert!(remote_leader_route_retry_candidate(
            &current,
            &json!({"ok": false, "error": {"message": "unknown_grant"}}),
            Some(current.clone()),
        )
        .is_none());
        for message in [
            "authorized peer viewer is not connected",
            "authorized peer viewer did not reconnect",
        ] {
            assert!(remote_leader_viewer_unavailable(&json!({
                "ok": false, "error": {"message": message}
            })));
        }
    }

    #[test]
    fn viewer_route_refresh_reuses_request_id_with_the_replacement_audience() {
        let current = RemoteLeaderRoute {
            grant_id_hex: "ab".repeat(32),
            project_id: "name:demo".into(),
            team_uuid: "team-uuid".into(),
            expires_at_unix_secs: 100,
            target_peer_id_hex: "11".repeat(16),
        };
        let mut refreshed = current.clone();
        refreshed.grant_id_hex = "cd".repeat(32);
        refreshed.target_peer_id_hex = "22".repeat(16);
        let request_id = "41".repeat(16);
        let original = remote_leader_proxy_params(
            &current,
            "team.delegate",
            json!({"agent_name": "reviewer"}),
            &request_id,
        )
        .unwrap();
        let replacement = remote_leader_proxy_params(
            &refreshed,
            "team.delegate",
            json!({"agent_name": "reviewer"}),
            &request_id,
        )
        .unwrap();

        assert_eq!(original["request_id_hex"], replacement["request_id_hex"]);
        assert_eq!(replacement["target_peer_id_hex"], "22".repeat(16));
        assert_eq!(replacement["grant_id_hex"], "cd".repeat(32));
        assert_eq!(original["params_json"], replacement["params_json"]);
    }

    #[test]
    fn remote_leader_proxy_without_nested_error_details_keeps_generic_fallback() {
        let error = remote_leader_proxy_result(json!({
            "ok": false,
            "result": {},
        }))
        .unwrap_err();

        assert_eq!(error, "remote leader proxy returned non-ok");
    }

    #[test]
    fn retry_after_response_timeout_reuses_same_request_id() {
        let params = json!({"request_id": "delegate-stable-1"});
        let mut seen_request_ids = Vec::new();
        let mut calls = 0;
        let outcome = resolve_unified_delegate(&params, "delegate-stable-1", |attempt| {
            calls += 1;
            seen_request_ids.push(attempt["request_id"].as_str().unwrap().to_string());
            if calls == 1 {
                Err("read: timed out".into())
            } else {
                Ok(json!({"ok": true, "result": {"task": {"id": "task-1"}}}))
            }
        })
        .unwrap();

        assert!(matches!(outcome, UnifiedDelegateOutcome::Response(_)));
        assert_eq!(seen_request_ids, ["delegate-stable-1", "delegate-stable-1"]);
    }

    #[test]
    fn transport_error_does_not_enter_legacy_fallback() {
        let params = json!({"request_id": "delegate-unknown-1"});
        for retry in [
            Err("read: timed out".to_string()),
            Ok(json!({
                "ok": false,
                "error": {"code": -32601, "message": "method not found"},
            })),
        ] {
            let mut unified_calls = 0;
            let mut legacy_task_create_calls = 0;
            let result = resolve_unified_delegate(&params, "delegate-unknown-1", |_| {
                unified_calls += 1;
                if unified_calls == 1 {
                    Err("read: timed out".into())
                } else {
                    retry.clone()
                }
            });
            if matches!(result, Ok(UnifiedDelegateOutcome::LegacyFallback)) {
                legacy_task_create_calls += 1;
            }

            let error = result.unwrap_err();
            assert_eq!(unified_calls, 2);
            assert_eq!(legacy_task_create_calls, 0);
            assert!(error.contains("request_id=delegate-unknown-1"));
            assert!(error.contains("--request-id delegate-unknown-1"));
        }
    }

    #[test]
    fn method_not_found_still_falls_back_to_legacy() {
        let params = json!({"request_id": "delegate-legacy-1"});
        let mut unified_calls = 0;
        let mut legacy_task_create_calls = 0;
        let outcome = resolve_unified_delegate(&params, "delegate-legacy-1", |_| {
            unified_calls += 1;
            Ok(json!({
                "ok": false,
                "error": {"code": -32601, "message": "method not found"},
            }))
        })
        .unwrap();
        if matches!(outcome, UnifiedDelegateOutcome::LegacyFallback) {
            legacy_task_create_calls += 1;
        }

        assert_eq!(unified_calls, 1);
        assert_eq!(legacy_task_create_calls, 1);
    }

    #[test]
    fn agent_busy_delegate_error_has_actionable_hint() {
        let response_error = resolve_unified_delegate(&json!({}), "delegate-busy-1", |_| {
            Ok(json!({
                "ok": false,
                "error": {"code": "agent_busy", "message": "agent has an active task"},
            }))
        })
        .unwrap_err();
        let proxy_error = resolve_unified_delegate(&json!({}), "delegate-busy-2", |_| {
            Err("remote leader proxy [agent_busy]: agent has an active task".into())
        })
        .unwrap_err();

        for error in [response_error, proxy_error] {
            assert!(error.contains("agent_busy"));
            assert!(error.contains("finish/block it first"));
            assert!(error.contains("another idle agent"));
        }
    }
}

// ── Session picker ──────────────────────────────────────────────────

/// A Claude Code session entry parsed from the project session directory.
pub(crate) struct SessionEntry {
    id: String,
    modified: std::time::SystemTime,
    first_message: String,
    last_message: String,
}

/// Discover the Claude Code sessions directory for the current working directory.
pub(crate) fn claude_sessions_dir() -> Option<PathBuf> {
    let home = env::var("HOME").ok()?;
    let cwd = env::current_dir().ok()?;
    // Claude Code encodes the project path as dash-separated: /Users/foo/bar → -Users-foo-bar
    let encoded = cwd.to_string_lossy().replace('/', "-");
    let dir = PathBuf::from(format!("{home}/.claude/projects/{encoded}"));
    if dir.is_dir() {
        Some(dir)
    } else {
        None
    }
}

/// List recent sessions from the Claude Code sessions directory.
pub(crate) fn list_recent_sessions(limit: usize) -> Vec<SessionEntry> {
    let dir = match claude_sessions_dir() {
        Some(d) => d,
        None => return vec![],
    };

    let mut entries: Vec<SessionEntry> = vec![];
    if let Ok(read_dir) = std::fs::read_dir(&dir) {
        for entry in read_dir.flatten() {
            let path = entry.path();
            let name = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) => n.to_string(),
                None => continue,
            };
            // Only .jsonl session files with UUID names
            if !name.ends_with(".jsonl") {
                continue;
            }
            let id = name.trim_end_matches(".jsonl");
            // Quick UUID format check (8-4-4-4-12)
            if id.len() != 36 || id.chars().filter(|c| *c == '-').count() != 4 {
                continue;
            }

            let modified = match entry.metadata().and_then(|m| m.modified()) {
                Ok(t) => t,
                Err(_) => continue,
            };

            // Extract first user message and last assistant message
            let (first_message, last_message) = extract_messages(&path);

            entries.push(SessionEntry {
                id: id.to_string(),
                modified,
                first_message,
                last_message,
            });
        }
    }

    // Sort by modification time, newest first
    entries.sort_by(|a, b| b.modified.cmp(&a.modified));
    entries.truncate(limit);
    entries
}

/// Extract text content from a session JSONL entry.
/// User messages: `message.content` is a string.
/// Assistant messages: `message.content` is `[{"type":"text","text":"..."}]`.
pub(crate) fn extract_text_from_entry(val: &Value) -> String {
    // Try message.content first (current format)
    let msg = &val["message"]["content"];
    if let Some(s) = msg.as_str() {
        return s.to_string();
    }
    if let Some(arr) = msg.as_array() {
        let texts: Vec<&str> = arr
            .iter()
            .filter(|b| b["type"].as_str() == Some("text"))
            .filter_map(|b| b["text"].as_str())
            .collect();
        if !texts.is_empty() {
            return texts.join(" ");
        }
    }
    // Fallback: top-level content (older format)
    val["content"].as_str().unwrap_or("").to_string()
}

/// Extract the first user message and last assistant message from a session JSONL file.
pub(crate) fn extract_messages(path: &PathBuf) -> (String, String) {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return (String::new(), String::new()),
    };

    // First message: read first ~16KB
    let mut head_buf = vec![0u8; 16384];
    let head_n = file.read(&mut head_buf).unwrap_or(0);
    head_buf.truncate(head_n);
    let head_text = String::from_utf8_lossy(&head_buf);

    let mut first_message = String::new();
    for line in head_text.lines().take(50) {
        if let Ok(val) = serde_json::from_str::<Value>(line) {
            if val["type"].as_str() != Some("user") {
                continue;
            }
            let text = extract_text_from_entry(&val);
            if text.contains("<system-reminder>")
                || text.contains("<command-name>")
                || text.contains("<local-command")
            {
                continue;
            }
            let trimmed = text.trim();
            if trimmed.is_empty() {
                continue;
            }
            // Label commit generator sessions clearly
            if trimmed.starts_with("You are a commit message generator") {
                first_message = "[commit message]".to_string();
                break;
            }
            let display: String = trimmed.chars().take(80).collect();
            first_message = if trimmed.chars().count() > 80 {
                format!("{display}...")
            } else {
                display
            };
            break;
        }
    }

    // Last message: read last ~32KB
    let file_len = file.metadata().map(|m| m.len()).unwrap_or(0);
    let tail_offset = if file_len > 32768 {
        file_len - 32768
    } else {
        0
    };
    let _ = file.seek(SeekFrom::Start(tail_offset));
    let mut tail_buf = Vec::new();
    let _ = file.read_to_end(&mut tail_buf);
    let tail_text = String::from_utf8_lossy(&tail_buf);

    let mut last_message = String::new();
    for line in tail_text.lines().rev() {
        if let Ok(val) = serde_json::from_str::<Value>(line) {
            if val["type"].as_str() != Some("assistant") {
                continue;
            }
            let text = extract_text_from_entry(&val);
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                let display: String = trimmed.chars().take(80).collect();
                last_message = if trimmed.chars().count() > 80 {
                    format!("{display}...")
                } else {
                    display
                };
                break;
            }
        }
    }

    (first_message, last_message)
}

/// Format a SystemTime as a relative time string (e.g. "2h ago", "3d ago").
pub(crate) fn format_relative_time(time: std::time::SystemTime) -> String {
    let elapsed = time.elapsed().unwrap_or_default();
    let secs = elapsed.as_secs();
    if secs < 60 {
        return "just now".to_string();
    }
    if secs < 3600 {
        return format!("{}m ago", secs / 60);
    }
    if secs < 86400 {
        return format!("{}h ago", secs / 3600);
    }
    format!("{}d ago", secs / 86400)
}

/// Interactive session picker. Returns a session ID or exits.
pub(crate) fn pick_session() -> String {
    let sessions = list_recent_sessions(15);
    if sessions.is_empty() {
        eprintln!("No recent sessions found for this project.");
        eprintln!("Hint: enter a session ID directly with --resume-session=<uuid>");
        process::exit(1);
    }

    eprintln!("\n  Recent sessions:\n");
    for (i, s) in sessions.iter().enumerate() {
        let time_str = format_relative_time(s.modified);
        let preview = if s.first_message.is_empty() {
            s.id[..8].to_string()
        } else {
            s.first_message.clone()
        };
        eprintln!("  {:>2}) {:<10} Q: {}", i + 1, time_str, preview);
        if !s.last_message.is_empty() {
            eprintln!("      {:<10} A: {}", "", s.last_message);
        }
    }
    eprintln!();
    eprint!("  Select [1-{}] or paste session ID: ", sessions.len());
    std::io::stderr().flush().ok();

    let mut input = String::new();
    if std::io::stdin().read_line(&mut input).is_err() || input.trim().is_empty() {
        eprintln!("No selection made.");
        process::exit(1);
    }
    let input = input.trim();

    // Try as number first
    if let Ok(num) = input.parse::<usize>() {
        if num >= 1 && num <= sessions.len() {
            return sessions[num - 1].id.clone();
        }
        eprintln!("Invalid selection: {num}");
        process::exit(1);
    }

    // Otherwise treat as session ID
    input.to_string()
}

/// Resolve --resume-session: None means not requested, Some(None) means interactive picker,
/// Some(Some(id)) means specific session ID.
pub(crate) fn resolve_resume_session(flag: Option<Option<String>>) -> Option<String> {
    match flag {
        None => None,
        Some(None) => Some(pick_session()),
        Some(Some(id)) if id.is_empty() => Some(pick_session()),
        Some(Some(id)) => Some(id),
    }
}

/// Resolve --spec: literal text, or @path to read the spec from a file.
/// Returns Ok(None) when no spec was supplied. A leading `@` reads the file
/// at the remaining path (error if it cannot be read). Empty input is treated
/// as absent.
pub(crate) fn resolve_watcher_spec(spec: Option<&str>) -> Result<Option<String>, String> {
    let Some(raw) = spec else {
        return Ok(None);
    };
    if raw.is_empty() {
        return Ok(None);
    }
    if let Some(path) = raw.strip_prefix('@') {
        let path = path.trim();
        if path.is_empty() {
            return Err("--spec @<path> requires a file path after '@'".to_string());
        }
        let content = fs::read_to_string(path)
            .map_err(|e| format!("--spec: cannot read file '{path}': {e}"))?;
        if content.trim().is_empty() {
            return Err(format!("--spec: file '{path}' is empty"));
        }
        Ok(Some(content))
    } else {
        Ok(Some(raw.to_string()))
    }
}

/// Attach `watcher_spec` as `custom_instructions` to watcher agents only (R7:
/// watcher-only invariant). Warns when a spec is supplied but no watcher role
/// is present in the team. Mutates the agents JSON array in place.
pub(crate) fn apply_watcher_spec(agents: &mut [serde_json::Value], watcher_spec: Option<&str>) {
    let Some(spec) = watcher_spec else {
        return;
    };
    let mut attached = 0usize;
    for agent in agents.iter_mut() {
        let role = agent
            .get("agent_type")
            .and_then(|v| v.as_str())
            .or_else(|| agent.get("name").and_then(|v| v.as_str()))
            .unwrap_or("");
        if role == "watcher" {
            if let Some(obj) = agent.as_object_mut() {
                obj.insert(
                    "custom_instructions".to_string(),
                    serde_json::Value::String(spec.to_string()),
                );
                attached += 1;
            }
        }
    }
    if attached == 0 {
        eprintln!(
            "Warning: --spec was provided but no 'watcher' agent is in this team; spec ignored."
        );
    }
}

// ── Orchestration implementations ────────────────────────────────────

pub(crate) fn run_create(
    sock: &PathBuf,
    team: &str,
    count: u32,
    claude_leader: bool,
    model: &str,
    leader_model: Option<&str>,
    effort: Option<&str>,
    leader_effort: Option<&str>,
    kiro: &Option<String>,
    codex: &Option<String>,
    gemini: &Option<String>,
    adopt: bool,
    preset: Option<&str>,
    roles: Option<&str>,
    resume_session: Option<Option<String>>,
    watcher_spec: Option<&str>,
    no_auto_watch: bool,
    auto_recycle: Option<u32>,
    auto_recycle_per_agent: Option<&str>,
) {
    // Guard: --adopt and --claude-leader are mutually exclusive
    if adopt && claude_leader {
        eprintln!("Error: --adopt and --claude-leader cannot be used together. In --adopt mode the current terminal is already the leader.");
        process::exit(1);
    }
    // Guard: --roles and count together — roles wins, count is ignored
    if roles.is_some() && count != 2 {
        eprintln!("Warning: --roles is specified; --count ({count}) will be ignored.");
    }
    // Resolve resume session before team creation (may show interactive picker)
    let resume_session_id = resolve_resume_session(resume_session);
    if resume_session_id.is_some() && adopt {
        eprintln!("Error: --resume-session and --adopt cannot be used together.");
        process::exit(1);
    }

    cleanup_old_results(team);
    // --resume-session implies claude leader mode (need Claude CLI to pass --resume)
    let mut leader_mode = if adopt {
        "adopted".to_string()
    } else if claude_leader || resume_session_id.is_some() {
        "claude".to_string()
    } else {
        "repl".to_string()
    };
    let leader_model = leader_model.unwrap_or(model);
    let kiro_agents = parse_cli_flag(kiro);
    let codex_agents = parse_cli_flag(codex);
    let gemini_agents = parse_cli_flag(gemini);
    let mut preset_name: Option<String> = None;
    let mut workflow_task_templates: Vec<String> = Vec::new();
    let mut workflow_review_checkpoints: Vec<String> = Vec::new();

    // Resolve agents from preset or roles via RPC, or build from defaults
    let mut agents: Vec<serde_json::Value> = if let Some(preset_id) = preset {
        eprintln!("Resolving preset '{preset_id}'...");
        match rpc_call_timeout(
            sock,
            "team.preset.resolve",
            json!({
                "preset_id": preset_id,
                "model": model,
            }),
            3,
        ) {
            Ok(resp) if resp["ok"].as_bool().unwrap_or(false) => {
                let result = &resp["result"];
                preset_name = result["preset_name"].as_str().map(str::to_string);
                if !adopt && !claude_leader && resume_session_id.is_none() {
                    if let Some(resolved_leader) = result["leader_mode"].as_str() {
                        leader_mode = resolved_leader.to_string();
                    }
                }
                workflow_task_templates = result["task_templates"]
                    .as_array()
                    .map(|items| {
                        items
                            .iter()
                            .filter_map(|v| v.as_str().map(str::to_string))
                            .collect()
                    })
                    .unwrap_or_default();
                workflow_review_checkpoints = result["review_checkpoints"]
                    .as_array()
                    .map(|items| {
                        items
                            .iter()
                            .filter_map(|v| v.as_str().map(str::to_string))
                            .collect()
                    })
                    .unwrap_or_default();
                result["agents"].as_array().cloned().unwrap_or_default()
            }
            Ok(resp) => {
                eprintln!(
                    "Error: preset resolve failed: {}",
                    resp["error"]["message"].as_str().unwrap_or("unknown")
                );
                process::exit(1);
            }
            Err(e) => {
                eprintln!(
                    "Error: team.preset.resolve RPC failed (app may not support presets yet): {e}"
                );
                process::exit(1);
            }
        }
    } else if let Some(roles_str) = roles {
        eprintln!("Resolving roles '{roles_str}'...");
        // Split comma-separated roles into a JSON array (Swift expects [String], not String)
        let roles_vec: Vec<&str> = roles_str
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();
        match rpc_call_timeout(
            sock,
            "team.preset.resolve",
            json!({
                "roles": roles_vec,
                "model": model,
            }),
            3,
        ) {
            Ok(resp) if resp["ok"].as_bool().unwrap_or(false) => resp["result"]["agents"]
                .as_array()
                .cloned()
                .unwrap_or_default(),
            Ok(resp) => {
                eprintln!(
                    "Error: roles resolve failed: {}",
                    resp["error"]["message"].as_str().unwrap_or("unknown")
                );
                process::exit(1);
            }
            Err(e) => {
                eprintln!(
                    "Error: team.preset.resolve RPC failed (app may not support roles yet): {e}"
                );
                process::exit(1);
            }
        }
    } else {
        // Default: build from DEFAULT_AGENT_NAMES up to count
        let mut default_agents = Vec::new();
        for i in 0..count as usize {
            let name = if i < DEFAULT_AGENT_NAMES.len() {
                DEFAULT_AGENT_NAMES[i].to_string()
            } else {
                format!("agent-{i}")
            };
            let color = DEFAULT_AGENT_COLORS[i % DEFAULT_AGENT_COLORS.len()];
            let cli = if codex_agents.contains(&name) || codex_agents.contains("all") {
                "codex"
            } else if gemini_agents.contains(&name) || gemini_agents.contains("all") {
                "gemini"
            } else if kiro_agents.contains(&name) || kiro_agents.contains("all") {
                "kiro"
            } else {
                "claude"
            };
            default_agents.push(json!({
                "name": name, "cli": cli, "model": model,
                "agent_type": name, "color": color,
            }));
        }
        default_agents
    };

    // Attach watcher spec (if any) to watcher agents only (R7: watcher-only).
    apply_watcher_spec(&mut agents, watcher_spec);
    if let Some(effort) = effort {
        for agent in &mut agents {
            agent["effort"] = json!(effort);
        }
    }

    // Destroy existing team first, then poll until gone (max 10 × 50ms = 500ms)
    let _ = rpc_call_timeout(sock, "team.destroy", json!({ "team_name": team }), 2);
    for i in 0..10 {
        if rpc_call_timeout(sock, "team.status", json!({ "team_name": team }), 1).is_err() {
            break;
        }
        // team.status returns ok even if team exists but is being torn down;
        // check if the response indicates the team no longer exists
        if let Ok(r) = rpc_call_timeout(sock, "team.status", json!({ "team_name": team }), 1) {
            if !r["ok"].as_bool().unwrap_or(false) {
                break;
            }
        }
        if i == 9 {
            eprintln!("Warning: previous team may still be tearing down");
        }
        thread::sleep(Duration::from_millis(50));
    }

    let workdir = env::current_dir()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| ".".to_string());

    let agent_count = agents.len();
    if let Some(ref sid) = resume_session_id {
        eprintln!("Creating team '{team}' with {agent_count} agent(s) [leader: {leader_mode}, resume: {}]...", &sid[..8.min(sid.len())]);
    } else {
        eprintln!("Creating team '{team}' with {agent_count} agent(s) [leader: {leader_mode}]...");
    }
    eprintln!("Socket: {}", sock.display());

    // Pass caller's panel ID so the app can route team creation to the correct window
    let mut create_params = json!({
        "team_name": team,
        "working_directory": workdir,
        "leader_session_id": format!("leader-{}", process::id()),
        "leader_mode": leader_mode,
        "leader_model": leader_model,
        "agents": agents,
        "runbook_init_prompt": true,
    });
    if let Some(ref sid) = resume_session_id {
        create_params["resume_session_id"] = json!(sid);
    }
    if let Ok(panel_id) = env::var("TERMMESH_PANEL_ID") {
        create_params["surface_id"] = json!(panel_id);
    }
    if let Ok(window_id) = env::var("TERMMESH_WINDOW_ID") {
        create_params["window_id"] = json!(window_id);
    }
    if let Ok(workspace_id) = env::var("TERMMESH_WORKSPACE_ID") {
        create_params["workspace_id"] = json!(workspace_id);
    }
    // In --adopt mode, pass the adopted leader's CLI for stable detection
    if adopt {
        if let Ok(cli) = env::var("TERMMESH_CLI") {
            create_params["leader_cli"] = json!(cli);
        }
    }
    if let Some(n) = auto_recycle {
        create_params["default_auto_recycle_every"] = json!(n);
    }
    if let Some(effort) = leader_effort {
        create_params["leader_effort"] = json!(effort);
    }
    if let Some(per_agent_str) = auto_recycle_per_agent {
        let map: serde_json::Map<String, serde_json::Value> = per_agent_str
            .split(',')
            .filter_map(|s| {
                let mut parts = s.trim().splitn(2, ':');
                let name = parts.next()?.trim().to_string();
                let count: u32 = parts.next()?.trim().parse().ok()?;
                Some((name, json!(count)))
            })
            .collect();
        if !map.is_empty() {
            create_params["per_agent_auto_recycle"] = serde_json::Value::Object(map);
        }
    }
    let r = match rpc_call_timeout(sock, "team.create", create_params, 5) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };

    println!("{}", pretty(&r));
    println!();
    println!("Commands:");
    println!("  tm-agent send <agent> 'your message'");
    println!("  tm-agent broadcast 'message to all'");
    println!("  tm-agent status");
    println!("  tm-agent destroy");

    if r["ok"].as_bool().unwrap_or(false) {
        if !workflow_task_templates.is_empty() {
            let workflow_label = preset_name.as_deref().or(preset).unwrap_or("workflow");
            let checkpoint_note = if workflow_review_checkpoints.is_empty() {
                String::new()
            } else {
                format!(
                    "\nReview checkpoints: {}",
                    workflow_review_checkpoints.join(", ")
                )
            };
            eprintln!("\nCreating workflow task templates for '{workflow_label}'...");
            for (i, title) in workflow_task_templates.iter().enumerate() {
                let assignee = agents
                    .get(i % agents.len())
                    .and_then(|a| a["name"].as_str())
                    .unwrap_or("");
                let mut params = json!({
                    "team_name": team,
                    "title": title,
                    "description": format!(
                        "Created from workflow preset: {}{}",
                        workflow_label,
                        checkpoint_note
                    ),
                    "priority": 2,
                    "created_by": format!("workflow:{workflow_label}"),
                });
                if !assignee.is_empty() {
                    params["assignee"] = json!(assignee);
                }
                match rpc_call_timeout(sock, "team.task.create", params, 2) {
                    Ok(resp) if resp["ok"].as_bool().unwrap_or(false) => {
                        let suffix = if assignee.is_empty() {
                            String::new()
                        } else {
                            format!(" -> {assignee}")
                        };
                        eprintln!("  \u{2713} {title}{suffix}");
                    }
                    Ok(resp) => {
                        eprintln!(
                            "  \u{2717} {title}: {}",
                            resp["error"]["message"]
                                .as_str()
                                .unwrap_or("task create failed")
                        );
                    }
                    Err(e) => {
                        eprintln!("  \u{2717} {title}: {e}");
                    }
                }
            }
        }

        let created_agents = r["result"]["agents"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let non_kiro: Vec<(usize, &Value)> = agents
            .iter()
            .enumerate()
            .filter(|(_, a)| a["cli"].as_str().unwrap_or("claude") != "kiro")
            .collect();
        if !non_kiro.is_empty() {
            // Poll until all agent panels are spawned (max 60 × 100ms = 6s)
            eprintln!("\nWaiting for agent panels to spawn...");
            let expected = non_kiro.len();
            for i in 0..60 {
                if let Ok(st) =
                    rpc_call_timeout(sock, "team.status", json!({ "team_name": team }), 2)
                {
                    if let Some(agents_arr) = st["result"]["agents"].as_array() {
                        let with_panels = agents_arr
                            .iter()
                            .filter(|a| {
                                a["panel_id"]
                                    .as_str()
                                    .map(|s| !s.is_empty())
                                    .unwrap_or(false)
                            })
                            .count();
                        if with_panels >= expected {
                            eprintln!("  All {expected} agent panels ready ({} ms)", (i + 1) * 100);
                            break;
                        }
                        if i % 10 == 9 {
                            eprintln!("  ... {with_panels}/{expected} panels ready");
                        }
                    }
                }
                if i == 59 {
                    eprintln!("  Warning: timed out waiting for all panels (proceeding anyway)");
                }
                thread::sleep(Duration::from_millis(100));
            }

            eprintln!("Sending init prompts to non-kiro agents...");
            // Cold-start protection moved to Swift: the TerminalSurface gates
            // the first paste on each surface until ghostty's pty_data_callback
            // confirms the child has started outputting. No fixed warmup here.
            for (agent_index, a) in &non_kiro {
                let name = a["name"].as_str().unwrap_or("");
                let role = a["agent_type"].as_str().unwrap_or(name);
                let (agent_instance_id, panel_id) =
                    created_agent_selector(&created_agents, *agent_index);
                let init_text =
                    agent_init_prompt(name, role, team, &workdir, &sock.to_string_lossy());
                let mut pace_for_terminal = true;
                match rpc_call_timeout(
                    sock,
                    "team.send",
                    json!({
                        "team_name": team, "agent_name": name,
                        "agent_instance_id": agent_instance_id,
                        "panel_id": panel_id,
                        "text": format!("{init_text}\n"),
                        "send_sequence_aware": true,
                        // The role briefing must arrive as the user's own turn; a
                        // Claude inbox frames it as another session's message, and
                        // an agent can reject its own role as an injection.
                        "claude_inbox": false,
                    }),
                    3,
                ) {
                    Ok(ref r) => {
                        // team.send pastes text with withReturn=false; the trailing "\n"
                        // is stripped by sendTextToPanel, so the Enter must be delivered
                        // separately via team.send_key — same follow-up as `tm-agent send`
                        // and `tm-agent delegate`. Without this the init prompt sits
                        // unsubmitted in the freshly spawned agent pane (enter-swallow).
                        let text_delivered =
                            r["result"]["text_delivered"].as_bool().unwrap_or(false);
                        let return_required = send_response_return_required(r);
                        let _ = send_return_key_with_retry(
                            sock,
                            team,
                            name,
                            text_delivered,
                            "team.create.init",
                            panel_id,
                            agent_instance_id,
                            r["result"]["send_sequence_id"].as_str(),
                            return_required,
                        );
                        pace_for_terminal = return_required != Some(false);
                        eprintln!("  \u{2713} {name}: init prompt sent");
                    }
                    Err(e) => eprintln!("  \u{2717} {name}: init prompt FAILED: {e}"),
                }
                // Keep 1s delay between sends: this is NOT state synchronization but
                // main-thread congestion relief. The Swift app processes sendTextToPanel
                // on DispatchQueue.main — sending too fast causes Enter key events to be
                // dropped because the TUI (Claude Code) hasn't processed the previous
                // text input before the next arrives. DO NOT remove this delay.
                // A native acknowledgement (return_required=false) is exempt: its
                // turn went to stdin, with no main-thread paste or TUI to congest.
                if pace_for_terminal {
                    thread::sleep(Duration::from_secs(1));
                }
            }
        }
        let kiro_count = agents.len() - non_kiro.len();
        if kiro_count > 0 {
            eprintln!("\n  \u{2713} {kiro_count} kiro agent(s): prompt loaded via agent profile (no delay)");
        }

        // Auto-watch hook: trigger after successful team creation (best-effort)
        let wd = env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
        maybe_auto_watch_after_team_change(sock, team, no_auto_watch, &wd);
    }
}

pub(crate) fn is_auto_watch_disabled_by_env() -> bool {
    match env::var("TERMMESH_AUTO_WATCH") {
        Ok(val) => matches!(
            val.to_ascii_lowercase().as_str(),
            "0" | "false" | "no" | "off"
        ),
        Err(_) => false,
    }
}

/// Normalized agent descriptor used by the pure decision function.
#[derive(Debug, Clone)]
pub(crate) struct AutoWatchAgent {
    name: String,
    agent_type: String,
    cli: String,
    model: String,
}

/// Decision returned by `auto_watch_decision`.
#[derive(Debug, PartialEq)]
pub(crate) enum AutoWatchDecision {
    SkipNoWatcher,
    SkipNoWorker,
    SkipMultiWorker(usize),
    SkipMissingSpec,
    Enable {
        target: String,
        watcher_cli: String,
        watcher_model: String,
    },
}

/// Pure decision function — no I/O, fully unit-testable.
pub(crate) fn auto_watch_decision(
    agents: &[AutoWatchAgent],
    spec_exists: bool,
) -> AutoWatchDecision {
    let watchers: Vec<&AutoWatchAgent> = agents
        .iter()
        .filter(|a| a.agent_type == "watcher")
        .collect();
    let workers: Vec<&AutoWatchAgent> = agents
        .iter()
        .filter(|a| a.agent_type != "watcher")
        .collect();

    if watchers.is_empty() {
        return AutoWatchDecision::SkipNoWatcher;
    }
    if workers.is_empty() {
        return AutoWatchDecision::SkipNoWorker;
    }
    if workers.len() > 1 {
        return AutoWatchDecision::SkipMultiWorker(workers.len());
    }
    if !spec_exists {
        return AutoWatchDecision::SkipMissingSpec;
    }
    let w = &watchers[0];
    AutoWatchDecision::Enable {
        target: workers[0].name.clone(),
        watcher_cli: w.cli.clone(),
        watcher_model: w.model.clone(),
    }
}

/// Outcome of parsing a watch.on JSON-RPC response envelope.
#[derive(Debug)]
pub(crate) enum WatchOnOutcome {
    Enabled,
    Failed(String),
    Unexpected(String),
}

/// Classify a watch.on JSON-RPC response for unit testing without RPC mocking.
pub(crate) fn parse_watch_on_response(r: &serde_json::Value) -> WatchOnOutcome {
    if r.get("error").map_or(true, serde_json::Value::is_null)
        && r["result"]["enabled"].as_bool().unwrap_or(false)
    {
        WatchOnOutcome::Enabled
    } else if r.get("error").map_or(false, |e| !e.is_null()) {
        let msg = r["error"]["message"]
            .as_str()
            .unwrap_or("unknown")
            .to_string();
        WatchOnOutcome::Failed(msg)
    } else {
        WatchOnOutcome::Unexpected(r.to_string())
    }
}

/// Emit the user-facing message and call watch.on RPC (best-effort).
pub(crate) fn apply_auto_watch(
    team_name: &str,
    working_dir: &std::path::Path,
    decision: AutoWatchDecision,
) {
    match decision {
        AutoWatchDecision::SkipNoWatcher | AutoWatchDecision::SkipNoWorker => {}
        AutoWatchDecision::SkipMultiWorker(n) => {
            eprintln!(
                "ℹ️  auto-watch skipped: {n} non-watcher workers found; run \
                 `tm-agent watch on <team> --target <name>` manually"
            );
        }
        AutoWatchDecision::SkipMissingSpec => {
            eprintln!(
                "ℹ️  auto-watch skipped: .xm/watch/default-spec.md not present; \
                 create the file to enable auto drift watch"
            );
        }
        AutoWatchDecision::Enable {
            target,
            watcher_cli,
            watcher_model,
        } => {
            let wd_str = working_dir.to_string_lossy();
            let mut params = json!({
                "team_id": team_name,
                "target": &target,
                "interval_secs": 300u64,
                "stance": "critic",
                "cli": &watcher_cli,
                "model": &watcher_model,
                "spec": "@.xm/watch/default-spec.md",
                "working_directory": wd_str,
            });
            if let Some(app_sock) = resolve_app_socket(None) {
                params["app_socket_path"] = json!(app_sock);
            }
            let watch_sock = match detect_watch_socket() {
                Some(s) => s,
                None => {
                    eprintln!("⚠️  auto-watch failed: daemon socket not found; skipping");
                    return;
                }
            };
            match rpc_call(&watch_sock, "watch.on", params) {
                Ok(r) => match parse_watch_on_response(&r) {
                    WatchOnOutcome::Enabled => {
                        eprintln!(
                            "✓ auto-watch enabled: target={target} \
                             spec=@.xm/watch/default-spec.md every=300s"
                        );
                    }
                    WatchOnOutcome::Failed(msg) => {
                        eprintln!("⚠️  auto-watch failed: {msg}; skipping");
                    }
                    WatchOnOutcome::Unexpected(r) => {
                        eprintln!("⚠️  auto-watch failed: unexpected response {r}; skipping");
                    }
                },
                Err(e) => {
                    eprintln!("⚠️  auto-watch failed: {e}; skipping");
                }
            }
        }
    }
}

/// Build AutoWatchAgent roster from a JSON agents array (GUI team.status format).
pub(crate) fn roster_from_gui_status(agents: &[Value]) -> Vec<AutoWatchAgent> {
    agents
        .iter()
        .map(|a| {
            let name = a["name"].as_str().unwrap_or("").to_string();
            let agent_type = a["agent_type"].as_str().unwrap_or(&name).to_string();
            AutoWatchAgent {
                name: name.clone(),
                agent_type,
                cli: a["cli"].as_str().unwrap_or("claude").to_string(),
                model: a["model"].as_str().unwrap_or("sonnet").to_string(),
            }
        })
        .collect()
}

/// Build AutoWatchAgent roster from headless agent specs (Value array from create).
pub(crate) fn roster_from_headless_specs(specs: &[Value]) -> Vec<AutoWatchAgent> {
    specs
        .iter()
        .map(|a| {
            let name = a["name"].as_str().unwrap_or("").to_string();
            // headless specs use "name" as agent_type; watcher is detected by name
            let agent_type = a["agent_type"].as_str().unwrap_or(&name).to_string();
            AutoWatchAgent {
                name: name.clone(),
                agent_type,
                cli: a["cli"].as_str().unwrap_or("claude").to_string(),
                model: a["model"].as_str().unwrap_or("sonnet").to_string(),
            }
        })
        .collect()
}

/// Build AutoWatchAgent roster via headless.list on daemon socket (for add path).
pub(crate) fn roster_from_headless_daemon(
    daemon_sock: &PathBuf,
    team_name: &str,
) -> Vec<AutoWatchAgent> {
    let resp = match rpc_call_timeout(
        daemon_sock,
        "headless.list",
        json!({ "team_name": team_name }),
        3,
    ) {
        Ok(v) => v,
        Err(_) => return vec![],
    };
    // headless.list returns an array directly (not wrapped in result)
    let arr = if let Some(a) = resp.as_array() {
        a.as_slice().to_vec()
    } else if let Some(a) = resp["result"].as_array() {
        a.clone()
    } else {
        return vec![];
    };
    arr.iter()
        .map(|a| {
            let name = a["name"].as_str().unwrap_or("").to_string();
            // headless.list AgentInfo has no agent_type field; infer from name
            AutoWatchAgent {
                agent_type: name.clone(),
                name,
                cli: a["cli"].as_str().unwrap_or("claude").to_string(),
                model: a["model"].as_str().unwrap_or("sonnet").to_string(),
            }
        })
        .collect()
}

pub(crate) fn run_auto_watch_if_enabled(
    team_name: &str,
    no_auto_watch: bool,
    working_dir: &std::path::Path,
    roster: Vec<AutoWatchAgent>,
) {
    if no_auto_watch || is_auto_watch_disabled_by_env() {
        return;
    }
    let spec_exists = working_dir.join(".xm/watch/default-spec.md").exists();
    let decision = auto_watch_decision(&roster, spec_exists);
    apply_auto_watch(team_name, working_dir, decision);
}

/// Auto-watch hook for GUI team create/add — fetches roster via app socket.
pub(crate) fn maybe_auto_watch_after_team_change(
    app_sock: &PathBuf,
    team_name: &str,
    no_auto_watch: bool,
    working_dir: &std::path::Path,
) {
    // The watcher would run on this host for a team the owning host manages.
    if no_auto_watch || is_auto_watch_disabled_by_env() || remote_leader_route().is_some() {
        return;
    }
    let status = match rpc_call_timeout(
        app_sock,
        "team.status",
        json!({ "team_name": team_name }),
        3,
    ) {
        Ok(v) if v["ok"].as_bool().unwrap_or(false) => v,
        _ => return,
    };
    let agents = match status["result"]["agents"].as_array() {
        Some(a) => a.clone(),
        None => return,
    };
    let roster = roster_from_gui_status(&agents);
    let spec_exists = working_dir.join(".xm/watch/default-spec.md").exists();
    let decision = auto_watch_decision(&roster, spec_exists);
    apply_auto_watch(team_name, working_dir, decision);
}

/// Auto-watch hook for headless create — uses existing agent_specs (no RPC needed).
pub(crate) fn maybe_auto_watch_after_headless_create(
    agent_specs: &[Value],
    team_name: &str,
    no_auto_watch: bool,
    working_dir: &std::path::Path,
) {
    let roster = roster_from_headless_specs(agent_specs);
    run_auto_watch_if_enabled(team_name, no_auto_watch, working_dir, roster);
}

/// Auto-watch hook for headless add — fetches roster via daemon socket.
/// `added_agent_name` / `added_agent_type` are patched in because headless.list
/// AgentInfo has no agent_type field; fallback infers type=name so "drift" becomes worker.
pub(crate) fn maybe_auto_watch_after_headless_add(
    daemon_sock: &PathBuf,
    team_name: &str,
    no_auto_watch: bool,
    working_dir: &std::path::Path,
    added_agent_name: &str,
    added_agent_type: &str,
    added_cli: &str,
    added_model: &str,
) {
    let mut roster = roster_from_headless_daemon(daemon_sock, team_name);
    // Patch the just-added agent with the explicit type the caller knows.
    if let Some(existing) = roster.iter_mut().find(|a| a.name == added_agent_name) {
        existing.agent_type = added_agent_type.to_string();
    } else {
        roster.push(AutoWatchAgent {
            name: added_agent_name.to_string(),
            agent_type: added_agent_type.to_string(),
            cli: added_cli.to_string(),
            model: added_model.to_string(),
        });
    }
    run_auto_watch_if_enabled(team_name, no_auto_watch, working_dir, roster);
}

/// Validate agent name against the whitelist regex `^[a-zA-Z0-9_-]{1,32}$`.
///
/// Used by `attach` and `detach` subcommands to prevent env var injection and
/// filename escape via agent_name. Returns `Err(message)` if invalid.
/// Implemented as a manual char scan (no `regex` crate dep).
pub(crate) fn validate_agent_name(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("agent name must not be empty".to_string());
    }
    if name.len() > 32 {
        return Err(format!(
            "agent name '{}' is too long ({}>32 chars)",
            name,
            name.len()
        ));
    }
    for ch in name.chars() {
        let ok = ch.is_ascii_alphanumeric() || ch == '_' || ch == '-';
        if !ok {
            return Err(format!(
                "agent name '{}' contains invalid character '{}'; only [a-zA-Z0-9_-] allowed",
                name, ch
            ));
        }
    }
    Ok(())
}

/// Resolve the team name for workspace-local attach/detach operations.
///
/// Priority:
/// 1. `TERMMESH_TEAM` env var (explicit override)
/// 2. `ws-<first8hex>` derived from `TERMMESH_WORKSPACE_ID`
///
/// Returns `Err` if neither is available.
#[allow(dead_code)] // used by run_attach/run_detach (t8/t9)
/// Resolve the team name for agent-side RPCs (report/send/delegate/read/collect/
/// inbox/task.*). Every agent-side command shares this so a missing TERMMESH_TEAM
/// can no longer silently leak the whole command set to `live-team`. Priority:
/// 1. explicit `--team` flag — works from any context, including an adopted leader
///    pane that never had TERMMESH_TEAM injected,
/// 2. `$TERMMESH_TEAM` — set on GUI-spawned agent panes,
/// 3. `$TERMMESH_WORKSPACE_ID` → `ws-<hex>` — same derivation attach/detach use
///    via [`resolve_workspace_team_name`], so workspace-local teams resolve
///    symmetrically across all commands,
/// 4. `live-team` — create-based / legacy default.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TeamNameSource {
    Explicit,
    Environment,
    Workspace,
    LiveTeamFallback,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct TeamNameResolution {
    pub(crate) name: String,
    pub(crate) source: TeamNameSource,
}

pub(crate) const LIVE_TEAM_FALLBACK_WARNING: &str = "Warning: no --team, TERMMESH_TEAM, or usable TERMMESH_WORKSPACE_ID; falling back to live-team. Pass --team <name> to select a team explicitly.";

pub(crate) fn resolve_team_name_inputs(
    explicit: Option<&str>,
    environment: Option<&str>,
    workspace: Option<&str>,
) -> TeamNameResolution {
    if let Some(t) = explicit {
        if !t.is_empty() {
            return TeamNameResolution {
                name: t.to_string(),
                source: TeamNameSource::Explicit,
            };
        }
    }
    if let Some(t) = environment {
        if !t.is_empty() {
            return TeamNameResolution {
                name: t.to_string(),
                source: TeamNameSource::Environment,
            };
        }
    }
    match workspace {
        Some(name) if !name.is_empty() => TeamNameResolution {
            name: name.to_string(),
            source: TeamNameSource::Workspace,
        },
        _ => TeamNameResolution {
            name: "live-team".to_string(),
            source: TeamNameSource::LiveTeamFallback,
        },
    }
}

pub(crate) fn resolve_team_name_with_source(explicit: Option<&str>) -> TeamNameResolution {
    let environment = env::var("TERMMESH_TEAM").ok();
    // resolve_workspace_team_name re-checks TERMMESH_TEAM (already handled by
    // `resolve_team_name_inputs`) and otherwise derives ws-<hex>; errors are
    // intentionally reduced to absence so diagnostics never expose env values.
    let workspace = resolve_workspace_team_name().ok();
    resolve_team_name_inputs(explicit, environment.as_deref(), workspace.as_deref())
}

pub(crate) fn resolve_team_name(explicit: Option<&str>) -> String {
    let resolution = resolve_team_name_with_source(explicit);
    if resolution.source == TeamNameSource::LiveTeamFallback {
        eprintln!("{LIVE_TEAM_FALLBACK_WARNING}");
    }
    resolution.name
}

pub(crate) fn resolve_workspace_team_name() -> Result<String, String> {
    if let Ok(explicit) = env::var("TERMMESH_TEAM") {
        if !explicit.is_empty() {
            return Ok(explicit);
        }
    }
    let ws = env::var("TERMMESH_WORKSPACE_ID").map_err(|_| {
        "TERMMESH_WORKSPACE_ID env var not set. Not running inside a term-mesh workspace?"
            .to_string()
    })?;
    if ws.is_empty() {
        return Err("TERMMESH_WORKSPACE_ID is empty".to_string());
    }
    // Strip dashes, take first 8 hex chars, lowercase
    let hex: String = ws
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .take(8)
        .collect::<String>()
        .to_lowercase();
    if hex.len() < 8 {
        return Err(format!(
            "TERMMESH_WORKSPACE_ID '{}' does not contain 8 hex chars",
            ws
        ));
    }
    Ok(format!("ws-{}", hex))
}

/// Validate that the caller is running inside a term-mesh pane.
/// Returns the tuple of env vars needed for workspace-local attach/detach.
pub(crate) fn require_termmesh_context() -> Result<(String, String, Option<String>), String> {
    let workspace_id = env::var("TERMMESH_WORKSPACE_ID").map_err(|_| {
        "Not running inside a term-mesh workspace. Use tm-agent create instead.".to_string()
    })?;
    if workspace_id.is_empty() {
        return Err(
            "Not running inside a term-mesh workspace. Use tm-agent create instead.".to_string(),
        );
    }
    let panel_id = env::var("TERMMESH_PANEL_ID").map_err(|_| {
        "TERMMESH_PANEL_ID not set. Caller pane cannot be identified for attach.".to_string()
    })?;
    if panel_id.is_empty() {
        return Err(
            "TERMMESH_PANEL_ID is empty. Caller pane cannot be identified for attach.".to_string(),
        );
    }
    let window_id = env::var("TERMMESH_WINDOW_ID")
        .ok()
        .filter(|s| !s.is_empty());
    Ok((workspace_id, panel_id, window_id))
}

/// Attach a single agent pane to the caller's current workspace via `team.attach` RPC.
pub(crate) fn run_attach(
    sock: &PathBuf,
    agent_type: &str,
    agent_name: &str,
    model: &str,
    cli: &str,
) {
    let (workspace_id, panel_id, window_id) = match require_termmesh_context() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };
    let team_name = match resolve_workspace_team_name() {
        Ok(name) => name,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };

    eprintln!(
        "Attaching agent '{}' (type={}, cli={}, model={}) to team '{}' in current workspace...",
        agent_name, agent_type, cli, model, team_name
    );

    let mut params = json!({
        "agent_type": agent_type,
        "agent_name": agent_name,
        "agent_cli": cli,
        "agent_model": model,
        "workspace_id": workspace_id,
        "surface_id": panel_id,
    });
    if let Some(wid) = window_id {
        params["window_id"] = json!(wid);
    }

    let resp = match rpc_call_timeout(sock, "team.attach", params, 10) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };

    if resp["ok"].as_bool().unwrap_or(false) {
        println!("{}", pretty(&resp));
        if let Some(result) = resp["result"].as_object() {
            eprintln!();
            eprintln!(
                "  \u{2713} agent '{}' attached ({} total in team '{}')",
                result
                    .get("agent_name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(agent_name),
                result
                    .get("agent_count")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0),
                result
                    .get("team_name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&team_name),
            );
        }
    } else {
        let code = resp["error"]["code"].as_str().unwrap_or("unknown");
        let msg = resp["error"]["message"].as_str().unwrap_or("attach failed");
        eprintln!("Error [{}]: {}", code, msg);
        process::exit(1);
    }
}

/// Detach a single agent from the caller's workspace-local team via `team.detach` RPC.
pub(crate) fn run_detach(
    sock: &PathBuf,
    agent_name: &str,
    panel_id: Option<&str>,
    explicit_instance_id: Option<&str>,
) {
    let (workspace_id, _panel_id, window_id) = match require_termmesh_context() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };
    let team_name = match resolve_workspace_team_name() {
        Ok(name) => name,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };
    let agent_instance_id = match command_agent_instance_id(
        sock,
        &team_name,
        agent_name,
        panel_id,
        explicit_instance_id,
    ) {
        Ok(id) => id,
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };

    eprintln!(
        "Detaching agent '{}' from team '{}'...",
        agent_name, team_name
    );

    let mut params = json!({
        "agent_name": agent_name,
        "team_name": team_name,
        "workspace_id": workspace_id,
        "panel_id": panel_id,
        "agent_instance_id": agent_instance_id,
    });
    if let Some(wid) = window_id {
        params["window_id"] = json!(wid);
    }

    let resp = match rpc_call_timeout(sock, "team.detach", params, 10) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };

    if resp["ok"].as_bool().unwrap_or(false) {
        println!("{}", pretty(&resp));
        if let Some(result) = resp["result"].as_object() {
            let remaining = result
                .get("remaining_agents")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            let team_destroyed = result
                .get("team_destroyed")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            eprintln!();
            if team_destroyed {
                eprintln!(
                    "  \u{2713} agent '{}' detached. Team '{}' destroyed (leader pane preserved).",
                    agent_name, team_name
                );
            } else {
                eprintln!(
                    "  \u{2713} agent '{}' detached ({} remaining)",
                    agent_name, remaining
                );
            }
        }
    } else {
        let code = resp["error"]["code"].as_str().unwrap_or("unknown");
        let msg = resp["error"]["message"].as_str().unwrap_or("detach failed");
        eprintln!("Error [{}]: {}", code, msg);
        process::exit(1);
    }
}

/// Add a single agent pane to a named GUI team via `team.add_agent` RPC.
///
/// Team-name–scoped: does not require TERMMESH_WORKSPACE_ID or PANEL_ID.
pub(crate) fn run_add_gui(
    sock: &PathBuf,
    team_name: &str,
    agent_type: &str,
    agent_name: &str,
    model: &str,
    cli: &str,
    effort: Option<&str>,
    no_auto_watch: bool,
    auto_recycle: Option<u32>,
    host: Option<&str>,
    dir: Option<&str>,
) {
    match host {
        Some(h) => eprintln!(
            "Adding agent '{}' (type={}, cli={}, model={}) to GUI team '{}' on host '{}'...",
            agent_name, agent_type, cli, model, team_name, h
        ),
        None => eprintln!(
            "Adding agent '{}' (type={}, cli={}, model={}) to GUI team '{}'...",
            agent_name, agent_type, cli, model, team_name
        ),
    }

    let mut params = json!({
        "team_name": team_name,
        "agent_type": agent_type,
        "name": agent_name,
        "model": model,
        "cli": cli,
    });
    if let Some(n) = auto_recycle {
        params["auto_recycle_every"] = json!(n);
    }
    if let Some(effort) = effort {
        params["effort"] = json!(effort);
    }
    if let Some(h) = host {
        params["host"] = json!(h);
    }
    if let Some(d) = dir {
        params["directory"] = json!(d);
    }

    let resp = match rpc_call_timeout(sock, "team.add_agent", params, 10) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };

    if resp["ok"].as_bool().unwrap_or(false) {
        println!("{}", pretty(&resp));
        if let Some(result) = resp["result"].as_object() {
            eprintln!();
            eprintln!(
                "  \u{2713} agent '{}' added ({} total in team '{}')",
                result
                    .get("agent_name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(agent_name),
                result
                    .get("agent_count")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0),
                result
                    .get("team_name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(team_name),
            );
        }
        // Fire unconditionally — helper checks (watcher==1 + worker>=1) internally.
        let wd = env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
        maybe_auto_watch_after_team_change(sock, team_name, no_auto_watch, &wd);
    } else {
        let code = resp["error"]["code"].as_str().unwrap_or("unknown");
        let msg = resp["error"]["message"]
            .as_str()
            .unwrap_or("add_agent failed");
        let hint = match code {
            "duplicate_name" => format!(
                "\nHint: An agent named '{}' already exists in team '{}'. Use --name to pick a unique name.",
                agent_name, team_name
            ),
            "team_not_found" => format!(
                "\nHint: Team '{}' not found. Run 'tm-agent status' to see active teams.",
                team_name
            ),
            "workspace_gone" => "\nHint: The team's workspace is no longer open. Recreate the team with 'tm-agent create'.".to_string(),
            "cli_not_found" => "\nHint: CLI executable not found — check Settings → CLI Paths or the cliPath.<cli> UserDefaults key.".to_string(),
            "pane_creation_failed" => "\nHint: Pane creation failed — check term-mesh logs at /tmp/term-mesh-debug.log.".to_string(),
            _ => String::new(),
        };
        eprintln!("Error [{}]: {}{}", code, msg, hint);
        process::exit(1);
    }
}

/// Remove an agent from a named GUI team via `team.detach` RPC (team-name–scoped).
///
/// Unlike `run_detach` (workspace-local), this variant looks up the team by name
/// and does not require TERMMESH_WORKSPACE_ID or PANEL_ID.
pub(crate) fn run_remove_gui(
    sock: &PathBuf,
    team_name: &str,
    agent_name: &str,
    force: bool,
    panel_id: Option<&str>,
    explicit_instance_id: Option<&str>,
) {
    eprintln!(
        "Removing agent '{}' from GUI team '{}'...",
        agent_name, team_name
    );

    let agent_instance_id = match command_agent_instance_id(
        sock,
        team_name,
        agent_name,
        panel_id,
        explicit_instance_id,
    ) {
        Ok(id) => id,
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };
    let params = json!({
        "team_name": team_name,
        "agent_name": agent_name,
        "force": force,
        "panel_id": panel_id,
        "agent_instance_id": agent_instance_id,
    });

    let resp = match rpc_call_timeout(sock, "team.detach", params, 10) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {}", e);
            process::exit(1);
        }
    };

    if resp["ok"].as_bool().unwrap_or(false) {
        println!("{}", pretty(&resp));
        if let Some(result) = resp["result"].as_object() {
            let remaining = result
                .get("remaining_agents")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            let team_destroyed = result
                .get("team_destroyed")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            eprintln!();
            if team_destroyed {
                eprintln!(
                    "  \u{2713} agent '{}' removed. Team '{}' destroyed (leader pane preserved).",
                    agent_name, team_name
                );
            } else {
                eprintln!(
                    "  \u{2713} agent '{}' removed ({} remaining in team '{}')",
                    agent_name, remaining, team_name
                );
            }
        }
    } else {
        let code = resp["error"]["code"].as_str().unwrap_or("unknown");
        let msg = resp["error"]["message"].as_str().unwrap_or("remove failed");
        let hint = match code {
            "agent_busy" => "\nHint: Agent has an active task — pass --force to close anyway, or finish/block the task first.".to_string(),
            "ambiguous_agent" => "\nHint: Pass --panel <PANEL_ID> or --agent-instance-id <ID> to select the instance.".to_string(),
            _ => String::new(),
        };
        eprintln!("Error [{}]: {}{}", code, msg, hint);
        process::exit(1);
    }
}
