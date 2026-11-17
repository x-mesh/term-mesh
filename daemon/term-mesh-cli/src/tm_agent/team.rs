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
