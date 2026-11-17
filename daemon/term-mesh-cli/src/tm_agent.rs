#![allow(
    clippy::implicit_saturating_sub,
    clippy::manual_is_multiple_of,
    clippy::print_literal,
    clippy::ptr_arg,
    clippy::too_many_arguments,
    clippy::unused_enumerate_index,
    clippy::useless_concat,
    clippy::useless_format
)]

//! tm-agent: Unified Rust CLI for term-mesh team operations.
//!
//! Replaces both tm-rpc (agent-side) and team.py (leader-side).
//! ~1-3ms per call for all commands.

#[path = "tm_agent/bridge.rs"]
mod bridge;
mod claude_question;
#[path = "tm_agent/leader_turn.rs"]
mod leader_turn;
mod orchestrator;
mod peer;
mod prompts;
#[path = "../../question_store.rs"]
mod question_store;
#[path = "tm_agent/remote_leader.rs"]
mod remote_leader;
#[path = "tm_agent/reply.rs"]
mod reply;
#[path = "tm_agent/runbook.rs"]
mod runbook;
#[path = "tm_agent/socket_rpc.rs"]
mod socket_rpc;
#[path = "tm_agent/wait.rs"]
mod wait;

use bridge::*;
use clap::{Parser, Subcommand, ValueEnum};
use leader_turn::*;
use remote_leader::*;
use reply::*;
use runbook::*;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use socket_rpc::*;
#[cfg(test)]
use std::ffi::OsString;
use std::fs;
use std::io::{BufRead, BufReader, ErrorKind, IsTerminal, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::{env, process, thread};
use wait::*;

// ── Constants ────────────────────────────────────────────────────────

const DEFAULT_AGENT_NAMES: &[&str] = &[
    "explorer", "executor", "reviewer", "debugger", "writer", "tester",
];
const DEFAULT_AGENT_COLORS: &[&str] = &["green", "blue", "yellow", "magenta", "cyan", "red"];

fn default_model_for_cli(cli: &str) -> &'static str {
    match cli {
        "codex" => "gpt-5.6-sol",
        "gemini" => "gemini-3.1-pro-preview",
        "kiro" => "sonnet",
        _ => "sonnet",
    }
}

/// Marker for "git-kit is not on this machine", so a caller can tell an
/// absent tool from a tool that ran and said no. Matched by
/// `worktree_isolation_unavailable`, never by eyeballing a message.
const GIT_KIT_MISSING: &str = "git-kit is not installed on this machine";

/// `worktree_policy` for a task that asked for isolation and ran without it.
/// Distinct from "off", which is a caller who never wanted any.
const WORKTREE_POLICY_DEGRADED: &str = "auto-degraded";

/// Whether a worktree failure means isolation is simply unavailable here.
fn worktree_isolation_unavailable(error: &str) -> bool {
    error.contains(GIT_KIT_MISSING)
}

/// Whether a failed worktree acquire should stop the delegation.
///
/// `always` is the caller demanding isolation, so an unavailable tool is a
/// real failure. `auto` is a heuristic — "isolate mutating executor work" —
/// and a heuristic that cannot run should step aside, not block the task. It
/// used to block: a peer leader delegating anything mutating died on
/// `worktree acquire failed: failed to run git-kit: No such file or directory`,
/// naming a tool the user never asked term-mesh to use, on a machine that had
/// no reason to have it. Neither peer in a two-machine project had git-kit.
fn worktree_failure_is_fatal(policy: WorktreePolicyArg, error: &str) -> bool {
    match policy {
        WorktreePolicyArg::Off => true,
        WorktreePolicyArg::Always => true,
        WorktreePolicyArg::Auto => !worktree_isolation_unavailable(error),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
enum WorktreePolicyArg {
    Auto,
    Always,
    Off,
}

#[cfg(test)]
mod project_sync_cli_tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn add_parses_single_call_warmup_and_cli_native_model_default() {
        let parsed = Cli::try_parse_from([
            "tm-agent",
            "add",
            "reviewer",
            "--name",
            "codex-reviewer",
            "--cli",
            "codex",
            "--warmup",
            "--warmup-timeout",
            "45",
        ])
        .unwrap();
        let Commands::Add {
            model,
            warmup,
            warmup_timeout,
            cli,
            ..
        } = parsed.command
        else {
            panic!("expected add command");
        };
        assert!(model.is_none());
        assert!(warmup);
        assert_eq!(warmup_timeout, 45);
        assert_eq!(default_model_for_cli(&cli), "gpt-5.6-sol");
    }

    #[test]
    fn add_rejects_warmup_timeout_without_warmup() {
        assert!(
            Cli::try_parse_from(["tm-agent", "add", "reviewer", "--warmup-timeout", "45",])
                .is_err()
        );
    }

    #[test]
    fn warmup_requires_a_success_state_and_a_pong_word() {
        assert!(warmup_task_succeeded("completed", "pong"));
        assert!(warmup_task_succeeded(
            "review_ready",
            "STATUS: DONE\n\npong"
        ));
        assert!(!warmup_task_succeeded("blocked", "pong"));
        assert!(!warmup_task_succeeded("completed", "no response"));
        assert!(!warmup_task_succeeded("completed", "ping-ponging"));
    }

    #[test]
    fn wait_help_explains_tracked_any_and_uncorrelated_messages() {
        let mut command = Cli::command();
        let wait = command
            .find_subcommand_mut("wait")
            .expect("wait subcommand");
        let help = wait.render_long_help().to_string();
        assert!(help.contains("any requires a tracked task"));
        assert!(help.contains("use msg for uncorrelated messages"));
    }

    #[test]
    fn parses_project_and_conflict_command_groups() {
        let project =
            Cli::try_parse_from(["tm-agent", "project", "scan", "00", "--request-id", "r1"])
                .unwrap();
        assert!(matches!(project.command, Commands::Project(_)));

        let conflict =
            Cli::try_parse_from(["tm-agent", "conflict", "resolve", "00", "c1", "local"]).unwrap();
        assert!(matches!(conflict.command, Commands::Conflict(_)));
    }

    #[test]
    fn parses_orchestrator_command_group_without_team_socket_flags() {
        let parsed = Cli::try_parse_from([
            "tm-agent",
            "orchestrator",
            "--json",
            "task",
            "create",
            "--request-id",
            "req-1",
            "--project-id",
            "prj_abc",
            "Implement slice",
            "--body",
            "details",
        ])
        .unwrap();
        assert!(matches!(parsed.command, Commands::Orchestrator(_)));

        let subscribe =
            Cli::try_parse_from(["tm-agent", "orchestrator", "events", "subscribe"]).unwrap();
        assert!(matches!(subscribe.command, Commands::Orchestrator(_)));

        let suspect = Cli::try_parse_from([
            "tm-agent",
            "orchestrator",
            "task",
            "suspect",
            "--request-id",
            "suspect-1",
            "tsk_abc",
            "--reason",
            "heartbeat stale",
        ])
        .unwrap();
        assert!(matches!(suspect.command, Commands::Orchestrator(_)));

        let quarantine = Cli::try_parse_from([
            "tm-agent",
            "orchestrator",
            "task",
            "quarantine",
            "--request-id",
            "quarantine-1",
            "tsk_abc",
        ])
        .unwrap();
        assert!(matches!(quarantine.command, Commands::Orchestrator(_)));
    }

    /// The short forms are aliases and positional spellings of the long
    /// commands, so both must parse to the same request.
    #[test]
    fn daemon_short_forms_match_the_long_ones() {
        // clap panics at runtime on a duplicate alias; catch it here instead.
        Cli::command().debug_assert();

        for argv in [
            ["tm-agent", "daemon", "project-presentations", "list"],
            ["tm-agent", "d", "pp", "ls"],
        ] {
            let DaemonCommand::ProjectPresentations(pp) = daemon_command(argv) else {
                panic!("expected project-presentations");
            };
            assert!(matches!(pp.command, ProjectPresentationsCommand::List));
        }

        let long = daemon_command(["tm-agent", "daemon", "replay-capacity", "--set", "2mb"]);
        let short = daemon_command(["tm-agent", "d", "replay", "2mb"]);
        for parsed in [long, short] {
            let DaemonCommand::ReplayCapacity { capacity, set } = parsed else {
                panic!("expected replay-capacity");
            };
            assert_eq!(capacity.or(set).as_deref(), Some("2mb"));
        }

        let long = daemon_command(["tm-agent", "daemon", "reset", "--scope", "projects"]);
        let short = daemon_command(["tm-agent", "d", "reset", "projects"]);
        for parsed in [long, short] {
            let DaemonCommand::Reset {
                scope_arg, scope, ..
            } = parsed
            else {
                panic!("expected reset");
            };
            assert_eq!(scope_arg.or(scope).as_deref(), Some("projects"));
        }

        // No scope on either side still means the documented default.
        let DaemonCommand::Reset {
            scope_arg, scope, ..
        } = daemon_command(["tm-agent", "d", "reset"])
        else {
            panic!("expected reset");
        };
        assert!(scope_arg.is_none() && scope.is_none());
    }

    /// A positional value and its long flag name the same thing, so passing
    /// both is a mistake rather than a merge — except for prune, where the
    /// ids of both forms are one set.
    #[test]
    fn daemon_positional_and_flag_forms_do_not_silently_merge() {
        assert!(Cli::try_parse_from(["tm-agent", "d", "replay", "2mb", "--set", "4mb"]).is_err());
        assert!(
            Cli::try_parse_from(["tm-agent", "d", "reset", "projects", "--scope", "all"]).is_err()
        );

        let DaemonCommand::ProjectPresentations(pp) = daemon_command([
            "tm-agent",
            "d",
            "pp",
            "prune",
            "team:a",
            "--project-id",
            "team:b",
        ]) else {
            panic!("expected project-presentations");
        };
        let ProjectPresentationsCommand::Prune {
            project_id_args,
            project_ids,
            ..
        } = pp.command
        else {
            panic!("expected prune");
        };
        assert_eq!(project_id_args, vec!["team:a".to_string()]);
        assert_eq!(project_ids, vec!["team:b".to_string()]);
    }

    fn daemon_command<const N: usize>(argv: [&str; N]) -> DaemonCommand {
        daemon_group(argv)
            .command
            .expect("expected a daemon subcommand")
    }

    #[test]
    fn forced_project_prune_still_requires_explicit_apply() {
        for apply in [false, true] {
            let mut args = vec!["tm-agent", "daemon", "pp", "prune", "--force", "team:one"];
            if apply {
                args.push("--apply");
            }
            let parsed = Cli::try_parse_from(args).expect("force prune parses");
            let Commands::Daemon(group) = parsed.command else {
                panic!("daemon");
            };
            let Some(DaemonCommand::ProjectPresentations(pp)) = group.command else {
                panic!("pp");
            };
            let ProjectPresentationsCommand::Prune {
                force,
                apply: actual,
                project_id_args,
                ..
            } = pp.command
            else {
                panic!("prune");
            };
            assert!(force);
            assert_eq!(actual, apply);
            assert_eq!(project_id_args, vec!["team:one"]);
        }
    }

    #[test]
    fn daemon_interactive_is_opt_in_and_leaves_bare_daemon_alone() {
        // Bare `daemon` parses with no subcommand; the dispatcher prints help.
        let bare = daemon_group(["tm-agent", "d"]);
        assert!(!bare.interactive && bare.command.is_none());

        let group = daemon_group(["tm-agent", "d", "-i"]);
        assert!(group.interactive && group.command.is_none());

        let DaemonCommand::Doctor { json, interactive } =
            daemon_command(["tm-agent", "d", "doctor", "-i"])
        else {
            panic!("expected doctor");
        };
        assert!(interactive && !json);

        // The picker prints a report, so it cannot also be raw JSON.
        assert!(Cli::try_parse_from(["tm-agent", "d", "doctor", "-i", "--json"]).is_err());

        // A subcommand still parses next to the group flag; the dispatcher
        // rejects that pair, which keeps the message specific.
        let mixed = daemon_group(["tm-agent", "d", "-i", "doctor"]);
        assert!(mixed.interactive && mixed.command.is_some());
    }

    /// The daemon composes `repair_argv`, so the picker runs only the
    /// `daemon` repairs it knows and prints anything else for the operator.
    #[test]
    fn daemon_repair_argv_runs_only_daemon_repairs() {
        let prune = json!({ "repair_argv": [
            "tm-agent", "daemon", "project-presentations", "prune",
            "--project-id", "team:a", "--apply"
        ]});
        let argv = daemon_repair_argv(&prune).expect("prune is runnable");
        assert!(daemon_repair_runs(&argv).1.is_some());

        let inspect = json!({ "repair_argv": [
            "tm-agent", "daemon", "project-presentations", "list"
        ]});
        let argv = daemon_repair_argv(&inspect).expect("list is runnable");
        assert!(daemon_repair_runs(&argv).1.is_none());

        let reset = json!({ "repair_argv": [
            "tm-agent", "daemon", "reset", "--scope", "projects", "--apply"
        ]});
        assert!(daemon_repair_argv(&reset).is_some());

        for refused in [
            json!({ "repair_argv": [] }),
            json!({ "repair_argv": ["sh", "-c", "rm -rf /"] }),
            json!({ "repair_argv": ["tm-agent", "peer", "status", "--host", "h"] }),
            json!({ "repair_argv": ["tm-agent", "daemon", "replay-capacity", "--set", "1mb"] }),
            json!({ "repair_argv": ["tm-agent", "daemon", 7] }),
            json!({ "remedy": "start term-meshd" }),
        ] {
            assert!(
                daemon_repair_argv(&refused).is_none(),
                "must not run {refused}"
            );
        }
    }

    /// The picker shows the dry run, then repeats exactly that command with
    /// `--apply`. Both halves come from one argv so they cannot drift.
    #[test]
    fn daemon_repair_runs_splits_the_dry_run_from_the_applied_one() {
        let argv: Vec<String> = [
            "tm-agent",
            "daemon",
            "project-presentations",
            "prune",
            "--apply",
            "--project-id",
            "team:a",
        ]
        .iter()
        .map(|arg| arg.to_string())
        .collect();
        let (dry_run, applied) = daemon_repair_runs(&argv);
        // `--apply` goes wherever the daemon put it; every other argument
        // keeps its place, so the two runs address the same record.
        assert_eq!(
            dry_run,
            vec![
                "tm-agent",
                "daemon",
                "project-presentations",
                "prune",
                "--project-id",
                "team:a"
            ]
        );
        assert_eq!(applied.as_deref(), Some(argv.as_slice()));

        let inspect: Vec<String> = ["tm-agent", "daemon", "project-presentations", "list"]
            .iter()
            .map(|arg| arg.to_string())
            .collect();
        let (dry_run, applied) = daemon_repair_runs(&inspect);
        assert_eq!(dry_run, inspect);
        assert!(applied.is_none());
    }

    fn daemon_group<const N: usize>(argv: [&str; N]) -> DaemonCommands {
        let parsed = Cli::try_parse_from(argv).unwrap();
        let Commands::Daemon(daemon) = parsed.command else {
            panic!("expected daemon command");
        };
        daemon
    }

    #[test]
    fn daemon_errors_preserve_stable_machine_code() {
        let error = decode_daemon_response(json!({
            "error": { "code": -32601, "message": "USER_PRESENCE_REQUIRED: approve locally" }
        }))
        .unwrap_err();
        assert_eq!(error, "USER_PRESENCE_REQUIRED: approve locally");
    }

    #[test]
    fn peer_ensure_requires_all_identity_and_policy_flags() {
        let parsed = Cli::try_parse_from([
            "tm-agent",
            "peer",
            "ensure",
            "--host",
            "root@jw-server",
            "--key",
            "runner-smoke",
            "--cwd",
            "/app/runner",
            "--executable",
            "/bin/sh",
            "--arg=-lc",
            "--arg",
            "exec sleep 60",
            "--policy",
            "on-daemon-restart",
        ])
        .unwrap();
        assert!(matches!(parsed.command, Commands::Peer(_)));

        let missing_policy = Cli::try_parse_from([
            "tm-agent",
            "peer",
            "ensure",
            "--host",
            "root@jw-server",
            "--key",
            "runner-smoke",
            "--cwd",
            "/app/runner",
            "--executable",
            "/bin/sh",
        ]);
        assert!(missing_policy.is_err());
    }

    #[test]
    fn peer_attach_accepts_exact_surface_id_with_host() {
        let parsed = Cli::try_parse_from([
            "tm-agent",
            "peer",
            "attach",
            "--host",
            "root@jw-server",
            "--surface-id",
            "00112233445566778899aabbccddeeff",
        ])
        .unwrap();
        assert!(matches!(parsed.command, Commands::Peer(_)));
    }

    #[test]
    fn peer_terminate_requires_host_and_exact_surface_flag() {
        let parsed = Cli::try_parse_from([
            "tm-agent",
            "peer",
            "terminate",
            "--host",
            "root@jw-server",
            "--surface-id",
            "00112233445566778899aabbccddeeff",
            "--remote-socket",
            "/run/user/0/tm-peer.sock",
        ])
        .unwrap();
        assert!(matches!(parsed.command, Commands::Peer(_)));
        assert!(Cli::try_parse_from(
            ["tm-agent", "peer", "terminate", "--host", "root@jw-server",]
        )
        .is_err());
    }

    #[test]
    fn peer_help_names_the_implemented_contract() {
        let mut command = Cli::command();
        let peer = command
            .find_subcommand_mut("peer")
            .unwrap()
            .find_subcommand_mut("ensure")
            .unwrap();
        let mut help = Vec::new();
        peer.write_long_help(&mut help).unwrap();
        let help = String::from_utf8(help).unwrap();
        for flag in [
            "--host",
            "--key",
            "--cwd",
            "--executable",
            "--arg",
            "--policy",
        ] {
            assert!(help.contains(flag), "missing {flag} from help: {help}");
        }

        let terminate = command
            .find_subcommand_mut("peer")
            .unwrap()
            .find_subcommand_mut("terminate")
            .unwrap();
        let mut help = Vec::new();
        terminate.write_long_help(&mut help).unwrap();
        let help = String::from_utf8(help).unwrap();
        for flag in ["--host", "--surface-id", "--remote-socket"] {
            assert!(help.contains(flag), "missing {flag} from help: {help}");
        }
    }

    #[test]
    fn delegate_parses_deps_after_panel_and_forwards_them_to_unified_rpc() {
        let parsed = Cli::try_parse_from([
            "tm-agent",
            "delegate",
            "builder",
            "--panel",
            "panel-2",
            "--deps",
            "337a5e71",
            "--title",
            "Build after review",
            "run the build",
        ])
        .unwrap();
        let Commands::Delegate {
            agent,
            text,
            title,
            deps,
            panel,
            ..
        } = parsed.command
        else {
            panic!("expected delegate command");
        };
        assert_eq!(agent, "builder");
        assert_eq!(text, "run the build");
        assert_eq!(title.as_deref(), Some("Build after review"));
        assert_eq!(deps, vec!["337a5e71"]);
        assert_eq!(panel.as_deref(), Some("panel-2"));

        let params = delegate_rpc_params(
            "team-a",
            &agent,
            &text,
            title.as_deref().unwrap(),
            1,
            &[],
            &deps,
            None,
            None,
            None,
            panel.as_deref(),
            Some("instance-2"),
            "delegate-test-request",
            None,
            None,
        );
        assert_eq!(params["depends_on"], json!(["337a5e71"]));
        assert_eq!(params["panel_id"], "panel-2");
        assert_eq!(params["agent_instance_id"], "instance-2");
        // Unstated route/wave are omitted, not sent as null: absence is what
        // "the leader did not classify this" looks like on the board.
        assert!(params.get("route").is_none());
        assert!(params.get("wave_id").is_none());
    }

    /// Measurement-only fields. They must reach the board verbatim when stated
    /// and stay absent when not — a blank flag value must not create an empty
    /// route that later reads as a real classification.
    #[test]
    fn delegate_params_carry_stated_route_and_wave_and_omit_blank_ones() {
        let stated = delegate_rpc_params(
            "team-a",
            "executor",
            "own the parser lane",
            "Parser lane",
            2,
            &[],
            &[],
            None,
            None,
            None,
            None,
            None,
            "request-route",
            Some("parallel"),
            Some("wave-7"),
        );
        assert_eq!(stated["route"], "parallel");
        assert_eq!(stated["wave_id"], "wave-7");

        let blank = delegate_rpc_params(
            "team-a",
            "executor",
            "own the parser lane",
            "Parser lane",
            2,
            &[],
            &[],
            None,
            None,
            None,
            None,
            None,
            "request-route",
            Some("   "),
            Some(""),
        );
        assert!(blank.get("route").is_none());
        assert!(blank.get("wave_id").is_none());

        let worktree = worktree_task_create_params(
            "team-a",
            "executor",
            "Parser lane",
            2,
            &[],
            &[],
            None,
            None,
            None,
            WorktreePolicyArg::Auto,
            "request-route",
            Some("parallel"),
            Some("wave-7"),
        );
        assert_eq!(worktree["route"], "parallel");
        assert_eq!(worktree["wave_id"], "wave-7");
    }

    #[test]
    fn instance_scoped_commands_parse_supported_selectors() {
        let send = Cli::try_parse_from([
            "tm-agent", "send", "--panel", "panel-2", "reviewer", "message",
        ])
        .unwrap();
        assert!(matches!(
            send.command,
            Commands::Send {
                panel: Some(ref panel),
                agent_instance_id: None,
                ..
            } if panel == "panel-2"
        ));

        let expect_reply = Cli::try_parse_from([
            "tm-agent",
            "send",
            "reviewer",
            "message",
            "--expect-reply",
            "--reply-timeout",
            "45",
        ])
        .unwrap();
        assert!(matches!(
            expect_reply.command,
            Commands::Send {
                expect_reply: true,
                reply_timeout: 45,
                no_report: false,
                ..
            }
        ));
        assert!(Cli::try_parse_from([
            "tm-agent",
            "send",
            "reviewer",
            "check this",
            "--expect-reply",
            "--no-report",
        ])
        .is_err());

        let remove = Cli::try_parse_from([
            "tm-agent",
            "remove",
            "builder",
            "--agent-instance-id",
            "instance-2",
        ])
        .unwrap();
        assert!(matches!(
            remove.command,
            Commands::Remove {
                panel: None,
                agent_instance_id: Some(ref id),
                ..
            } if id == "instance-2"
        ));

        let delegate = Cli::try_parse_from([
            "tm-agent",
            "delegate",
            "reviewer",
            "inspect",
            "--agent-instance-id",
            "instance-2",
        ])
        .unwrap();
        assert!(matches!(
            delegate.command,
            Commands::Delegate {
                panel: None,
                agent_instance_id: Some(ref id),
                ..
            } if id == "instance-2"
        ));

        let detach =
            Cli::try_parse_from(["tm-agent", "detach", "builder", "--panel", "panel-2"]).unwrap();
        assert!(matches!(
            detach.command,
            Commands::Detach {
                panel: Some(ref panel),
                agent_instance_id: None,
                ..
            } if panel == "panel-2"
        ));

        assert!(Cli::try_parse_from([
            "tm-agent",
            "send",
            "reviewer",
            "message",
            "--panel",
            "panel-2",
            "--agent-instance-id",
            "instance-2",
        ])
        .is_err());
        assert!(Cli::try_parse_from([
            "tm-agent",
            "send",
            "reviewer",
            "check this",
            "--expect-reply",
            "--reply-timeout",
            "0",
        ])
        .is_err());
    }

    #[test]
    fn send_task_flag_parses_and_rejects_conflicting_or_empty_values() {
        Cli::try_parse_from(["tm-agent", "send", "worker", "retry", "--task", "2bbc7758"])
            .expect("--task binds a send to an existing task");
        Cli::try_parse_from([
            "tm-agent",
            "send",
            "worker",
            "retry",
            "--task",
            "2bbc7758",
            "--no-report",
            "--agent-instance-id",
            "instance-2",
        ])
        .expect("--task combines with the instance selector and --no-report");
        Cli::try_parse_from(["tm-agent", "send", "worker", "retry"])
            .expect("a send without --task stays an independent turn");

        let conflict = Cli::try_parse_from([
            "tm-agent",
            "send",
            "worker",
            "retry",
            "--task",
            "2bbc7758",
            "--expect-reply",
        ])
        .err()
        .expect("--task and --expect-reply are two different completion contracts");
        assert_eq!(conflict.kind(), clap::error::ErrorKind::ArgumentConflict);

        let empty = Cli::try_parse_from(["tm-agent", "send", "worker", "retry", "--task", ""])
            .err()
            .expect("an empty task id names no task");
        assert_eq!(empty.kind(), clap::error::ErrorKind::InvalidValue);
    }

    fn followup_task(status: &str, assignee: &str, instance: Option<&str>) -> Value {
        json!({
            "id": "2bbc7758",
            "title": "long suite",
            "status": status,
            "assignee": assignee,
            "agent_instance_id": instance,
            "worktree_path": "/tmp/wt/2bbc7758",
            "worktree_branch": "agent/2bbc7758",
        })
    }

    #[test]
    fn followup_routes_an_open_task_to_its_durable_instance() {
        for status in ["assigned", "in_progress", "blocked", "review_ready"] {
            let task = followup_task(status, "worker", Some("inst-1"));
            assert_eq!(
                validate_followup_task(&task, "2bbc7758", "worker", None),
                Ok(Some("inst-1".to_string())),
                "{status} must be routable without a selector"
            );
            assert_eq!(
                validate_followup_task(&task, "2bbc7758", "worker", Some("inst-1")),
                Ok(Some("inst-1".to_string())),
                "{status} must accept the matching selector"
            );
        }
        let legacy = followup_task("blocked", "worker", None);
        assert_eq!(
            validate_followup_task(&legacy, "2bbc7758", "worker", Some("inst-9")),
            Ok(Some("inst-9".to_string()))
        );
        assert_eq!(
            validate_followup_task(&legacy, "2bbc7758", "worker", None),
            Ok(None)
        );
    }

    #[test]
    fn followup_never_reaches_the_wrong_task_owner_or_a_finished_task() {
        let missing = validate_followup_task(&Value::Null, "2bbc7758", "worker", None)
            .expect_err("a task that does not exist");
        assert!(missing.contains("not found"), "{missing}");

        let other = followup_task("blocked", "reviewer", Some("inst-1"));
        let wrong_owner = validate_followup_task(&other, "2bbc7758", "worker", None)
            .expect_err("a task assigned to somebody else");
        assert!(
            wrong_owner.contains("not assigned to worker"),
            "{wrong_owner}"
        );

        let owned = followup_task("blocked", "worker", Some("inst-1"));
        let wrong_instance = validate_followup_task(&owned, "2bbc7758", "worker", Some("inst-2"))
            .expect_err("a same-named agent that is not the task's instance");
        assert!(
            wrong_instance.contains("agent_instance_id"),
            "{wrong_instance}"
        );

        for status in [
            "completed",
            "failed",
            "abandoned",
            "cancelled",
            "superseded",
        ] {
            let done = followup_task(status, "worker", Some("inst-1"));
            let error = validate_followup_task(&done, "2bbc7758", "worker", None)
                .expect_err("a terminal task must not be reopened by a message");
            assert!(error.contains("terminal"), "{status}: {error}");
        }
    }

    #[test]
    fn followup_rejects_a_lookup_that_answers_with_a_different_task() {
        let mut task = followup_task("blocked", "worker", Some("inst-1"));
        task["id"] = json!("deadbeef");
        let error = validate_followup_task(&task, "2bbc7758", "worker", None)
            .expect_err("the board answered for another task");
        assert!(error.contains("deadbeef"), "{error}");
    }

    #[test]
    fn a_bound_send_never_falls_back_to_the_name_only_headless_route() {
        assert_eq!(
            headless_probe_for_send(false, false, None),
            HeadlessProbe::Allow,
            "a plain send keeps the headless route"
        );
        assert_eq!(
            headless_probe_for_send(true, false, None),
            HeadlessProbe::Skip,
            "an explicit pane or instance names a GUI pane"
        );
        assert_eq!(
            headless_probe_for_send(false, true, Some("inst-1")),
            HeadlessProbe::Skip,
            "headless.send addresses by name and cannot honour the task's instance"
        );
        assert_eq!(
            headless_probe_for_send(false, true, None),
            HeadlessProbe::RejectIfHeadless,
            "a task with no recorded instance cannot be verified against a headless agent"
        );
    }

    fn serve_followup_rpc(
        listener: std::os::unix::net::UnixListener,
        task: Value,
        stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    ) -> std::thread::JoinHandle<Vec<String>> {
        listener.set_nonblocking(true).expect("nonblocking");
        std::thread::spawn(move || {
            let mut methods = Vec::new();
            while !stop.load(std::sync::atomic::Ordering::SeqCst) {
                let Ok((stream, _)) = listener.accept() else {
                    std::thread::sleep(Duration::from_millis(5));
                    continue;
                };
                stream.set_nonblocking(false).expect("blocking stream");
                let mut line = String::new();
                BufReader::new(&stream)
                    .read_line(&mut line)
                    .expect("read request");
                let method = serde_json::from_str::<Value>(&line).expect("request json")["method"]
                    .as_str()
                    .unwrap_or_default()
                    .to_string();
                let result = match method.as_str() {
                    "team.task.get" => task.clone(),
                    "team.status" => json!({
                        "agents": [
                            {"name": "worker", "agent_instance_id": "inst-1", "panel_id": "p1"},
                            {"name": "worker", "agent_instance_id": "inst-2", "panel_id": "p2"},
                        ]
                    }),
                    _ => json!({}),
                };
                (&stream)
                    .write_all(
                        format!("{}\n", json!({"id": 1, "ok": true, "result": result})).as_bytes(),
                    )
                    .expect("write response");
                methods.push(method);
            }
            methods
        })
    }

    fn followup_against_a_duplicated_name(
        panel: Option<&str>,
    ) -> (Result<(String, Option<String>), String>, Vec<String>) {
        let _env = ProcessEnvGuard::acquire();
        let _route = RouteDerivationEnv::isolated();
        let leader_keys = [
            "TERMMESH_LEADER_GRANT_ID",
            "TERMMESH_LEADER_PROJECT_ID",
            "TERMMESH_LEADER_TEAM_UUID",
            "TERMMESH_LEADER_EXPIRES_AT",
            "TERMMESH_LEADER_PEER_ID",
            REMOTE_LEADER_ROUTE_FILE_ENV,
        ];
        let saved: Vec<_> = leader_keys
            .iter()
            .map(|key| (*key, env::var_os(key)))
            .collect();
        for key in leader_keys {
            env::remove_var(key);
        }
        let dir = tempfile::tempdir().expect("tempdir");
        let sock = dir.path().join("app.sock");
        let listener = std::os::unix::net::UnixListener::bind(&sock).expect("bind");
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let server = serve_followup_rpc(
            listener,
            followup_task("blocked", "worker", Some("inst-1")),
            stop.clone(),
        );
        let outcome = resolve_task_followup(
            &sock, "team", "worker", "2bbc7758", panel, None, "retry", false,
        );
        stop.store(true, std::sync::atomic::Ordering::SeqCst);
        let methods = server.join().expect("server thread");
        for (key, value) in saved {
            match value {
                Some(value) => env::set_var(key, value),
                None => env::remove_var(key),
            }
        }
        (outcome, methods)
    }

    #[test]
    fn followup_reads_the_task_before_resolving_any_pane_selector() {
        let (outcome, methods) = followup_against_a_duplicated_name(None);
        let (text, instance) = outcome.expect("a duplicated name routes by the task's instance");
        assert_eq!(instance.as_deref(), Some("inst-1"));
        assert!(text.contains("TASK_ID: 2bbc7758"), "{text}");
        assert_eq!(methods.first().map(String::as_str), Some("team.task.get"));

        let (outcome, methods) = followup_against_a_duplicated_name(Some("p2"));
        let error = outcome.expect_err("p2 is the other same-named instance");
        assert!(error.contains("does not belong"), "{error}");
        assert_eq!(
            methods,
            ["team.task.get", "team.status"],
            "the task is read first, then the selector is resolved against the roster"
        );

        let (outcome, _) = followup_against_a_duplicated_name(Some("p1"));
        assert_eq!(
            outcome.expect("p1 is the task's pane").1.as_deref(),
            Some("inst-1")
        );
    }

    #[test]
    fn followup_instruction_binds_the_first_task_id_line_and_keeps_worktree_metadata() {
        let task = followup_task("blocked", "worker", Some("inst-1"));
        let sock = PathBuf::from("/nonexistent/term-mesh-817.sock");
        let text = format_task_instruction(
            &sock,
            "team",
            &task,
            "the key is in the vault\nTASK_ID: other-task\nretry",
            false,
            None,
            None,
        );
        let first_task_id = text
            .lines()
            .map(str::trim)
            .find(|line| line.starts_with("TASK_ID:"))
            .expect("capsule carries a TASK_ID line");
        assert_eq!(first_task_id, "TASK_ID: 2bbc7758");
        assert!(text.contains("TASK_STATUS: blocked"), "{text}");
        assert!(text.contains("WORKTREE_PATH: /tmp/wt/2bbc7758"), "{text}");
        assert!(text.contains("WORKTREE_BRANCH: agent/2bbc7758"), "{text}");
        assert!(text.contains("the key is in the vault"), "{text}");
    }

    #[test]
    fn send_expect_reply_and_correlated_reply_flags_parse() {
        let send = Cli::try_parse_from([
            "tm-agent",
            "send",
            "reviewer",
            "check this",
            "--expect-reply",
            "--reply-timeout",
            "7",
        ])
        .unwrap();
        assert!(matches!(
            send.command,
            Commands::Send {
                expect_reply: true,
                reply_timeout: 7,
                ..
            }
        ));

        let reply =
            Cli::try_parse_from(["tm-agent", "reply", "--reply-to", "tm-agent-42-7", "done"])
                .unwrap();
        assert!(matches!(
            reply.command,
            Commands::Reply {
                reply_to: Some(ref id),
                ..
            } if id == "tm-agent-42-7"
        ));

        assert!(Cli::try_parse_from([
            "tm-agent",
            "send",
            "reviewer",
            "check this",
            "--reply-timeout",
            "7",
        ])
        .is_err());
    }

    #[test]
    fn ok_false_is_a_cli_failure_even_when_transport_succeeded() {
        let failure = successful_rpc_envelope(Ok(json!({
            "ok": false,
            "error": { "code": "not_found", "message": "agent missing" }
        })))
        .unwrap_err();
        assert!(failure.contains("ok:false"));
        assert!(failure.contains("agent missing"));

        let success = successful_rpc_envelope(Ok(json!({
            "ok": true,
            "result": { "delivered": true }
        })))
        .unwrap();
        assert_eq!(success["result"]["delivered"], true);
    }

    #[test]
    fn send_success_requires_both_text_and_return_delivery() {
        let success = send_delivery_response(
            json!({"ok": true, "result": {
                "sent": true,
                "text_delivered": true,
                "delivery_scope": "transport_write"
            }}),
            true,
        );
        assert_eq!(success["result"]["sent"], true);
        assert_eq!(success["result"]["return_submitted"], true);
        assert_eq!(success["result"]["delivery_state"], "submitted");
        assert_eq!(success["result"]["delivery_scope"], "transport_write");

        let paste_failure = send_delivery_response(
            json!({"ok": true, "result": {
                "sent": false, "text_delivered": false
            }}),
            false,
        );
        assert_eq!(paste_failure["ok"], false);
        assert_eq!(paste_failure["result"]["sent"], false);
        assert_eq!(paste_failure["result"]["delivery_state"], "paste_failed");
        assert_eq!(paste_failure["error"]["code"], "delivery_failed");

        let return_failure = send_delivery_response(
            json!({"ok": true, "result": {
                "sent": true, "text_delivered": true
            }}),
            false,
        );
        assert_eq!(return_failure["ok"], false);
        assert_eq!(return_failure["result"]["sent"], false);
        assert_eq!(return_failure["result"]["delivery_state"], "return_failed");
        assert!(return_failure["error"]["message"]
            .as_str()
            .unwrap()
            .contains("Return submission failed"));

        let reply_timeout = reply_failure_response(&success, "timed out waiting for reply");
        assert_eq!(reply_timeout["ok"], false);
        assert_eq!(reply_timeout["error"]["code"], "reply_timeout");
        assert_eq!(reply_timeout["result"]["sent"], true);
        assert_eq!(reply_timeout["result"]["return_submitted"], true);
    }

    #[test]
    fn batch_team_send_opts_into_sequence_gate_contract() {
        let payloads = parse_batch_commands("send reviewer:check", "team-a").unwrap();
        let request: Value = serde_json::from_str(&payloads[0]).unwrap();
        assert_eq!(request["method"], "team.send");
        assert_eq!(request["params"]["send_sequence_aware"], true);
    }

    #[test]
    fn live_team_fallback_has_fixed_value_free_diagnostic() {
        let resolution = resolve_team_name_inputs(None, None, None);
        assert_eq!(resolution.name, "live-team");
        assert_eq!(resolution.source, TeamNameSource::LiveTeamFallback);
        assert!(LIVE_TEAM_FALLBACK_WARNING.contains("--team <name>"));
        assert!(LIVE_TEAM_FALLBACK_WARNING.contains("falling back to live-team"));

        let explicit =
            resolve_team_name_inputs(Some("chosen"), Some("secret-env-team"), Some("ws-secret"));
        assert_eq!(explicit.name, "chosen");
        assert_eq!(explicit.source, TeamNameSource::Explicit);
        assert!(!LIVE_TEAM_FALLBACK_WARNING.contains("secret-env-team"));
        assert!(!LIVE_TEAM_FALLBACK_WARNING.contains("ws-secret"));
    }

    #[test]
    fn correlated_reply_mailbox_is_typed_identity_bound_and_deadline_aware() {
        let token = std::iter::repeat_n('a', 64).collect::<String>();
        let params =
            correlated_reply_params("team-a", "reviewer", &token, "instance-7", "finished")
                .unwrap();
        assert_eq!(params["to"], "leader");
        assert_eq!(params["type"], "note");
        assert_eq!(params["agent_instance_id"], "instance-7");
        assert_eq!(params["correlation_token"], token);
        assert_eq!(params["content"], "finished");
        let instruction =
            append_correlated_reply_instruction("check", &token, "instance-7").unwrap();
        assert!(instruction.contains("<<'TERMMESH_REPLY_EOF'"));
        assert!(!instruction.contains("'<response>'"));

        let response = json!({
            "ok": true,
            "result": {
                "ready": true,
                "message_id": "matched",
                "agent_name": "reviewer",
                "agent_instance_id": "instance-7",
                "content": "finished"
            }
        });
        let reply = correlated_reply_from_mailbox(response, "reviewer", "instance-7", &token)
            .unwrap()
            .unwrap();
        assert_eq!(reply["result"]["content"], "finished");
        assert_eq!(reply["result"]["message_id"], "matched");

        let pending = json!({ "ok": true, "result": { "ready": false } });
        let mut polled = false;
        let timeout = wait_for_correlated_reply_with(
            "reviewer",
            "instance-7",
            &token,
            Duration::ZERO,
            |_| {
                polled = true;
                Ok(pending.clone())
            },
        )
        .unwrap_err();
        assert!(timeout.contains("timed out"));
        assert!(!polled, "an expired deadline must not start an RPC");

        let rpc_error = wait_for_correlated_reply_with(
            "reviewer",
            "instance-7",
            &token,
            Duration::from_secs(1),
            |_| Err("socket closed".to_string()),
        )
        .unwrap_err();
        assert_eq!(rpc_error, "socket closed");

        let rejected = wait_for_correlated_reply_with(
            "reviewer",
            "instance-7",
            &token,
            Duration::from_secs(1),
            |_| {
                Ok(json!({
                    "ok": false,
                    "error": { "code": "denied", "message": "mailbox denied" }
                }))
            },
        )
        .unwrap_err();
        assert!(rejected.contains("ok:false"));
        assert!(rejected.contains("mailbox denied"));

        let mismatch = correlated_reply_from_mailbox(
            json!({
                "ok": true,
                "result": {
                    "ready": true,
                    "message_id": "wrong",
                    "agent_name": "reviewer",
                    "agent_instance_id": "instance-6",
                    "content": "wrong pane"
                }
            }),
            "reviewer",
            "instance-7",
            &token,
        )
        .unwrap_err();
        assert!(mismatch.contains("mismatched identity"));

        let token_a = new_correlation_token().unwrap();
        let token_b = new_correlation_token().unwrap();
        assert_eq!(token_a.len(), 64);
        assert!(validate_reply_correlation_id(&token_a).is_ok());
        assert_ne!(token_a, token_b);

        assert!(validate_correlated_reply_overrides(true, false, false).is_err());
        assert!(validate_correlated_reply_overrides(false, true, false).is_err());
        assert!(validate_correlated_reply_overrides(false, false, true).is_err());
        assert!(validate_correlated_reply_overrides(false, false, false).is_ok());
    }

    #[test]
    fn correlation_poll_cadence_starts_fast_and_settles_at_the_legacy_pace() {
        let cadence: Vec<u64> = (0..7)
            .map(|attempt| correlation_poll_delay(attempt).as_millis() as u64)
            .collect();
        assert_eq!(cadence, vec![10, 20, 40, 80, 100, 100, 100]);
    }

    #[test]
    fn best_effort_rpc_retries_ok_false_without_exiting() {
        let mut calls = 0;
        run_best_effort_rpc_with_retry("test.post", || {
            calls += 1;
            Ok(json!({
                "ok": false,
                "error": { "code": "rejected", "message": "try again" }
            }))
        });
        assert_eq!(calls, 2);
    }

    #[test]
    fn panel_resolves_one_duplicate_name_to_its_durable_instance() {
        let agents = vec![
            json!({
                "name": "reviewer",
                "panel_id": "panel-1",
                "agent_instance_id": "instance-1",
            }),
            json!({
                "name": "reviewer",
                "panel_id": "panel-2",
                "agent_instance_id": "instance-2",
            }),
        ];

        assert_eq!(
            instance_id_from_agents(&agents, "reviewer", Some("panel-2")).unwrap(),
            Some("instance-2".to_string())
        );
        assert_eq!(
            instance_id_from_agents(&agents, "reviewer", None).unwrap(),
            None
        );
        let error = instance_id_from_agents(&agents, "reviewer", Some("missing")).unwrap_err();
        assert!(error.contains("--agent-instance-id"), "{error}");
    }

    #[test]
    fn explicit_instance_resolves_one_duplicate_name_without_a_panel() {
        let agents = vec![
            json!({"name": "reviewer", "agent_instance_id": "instance-1"}),
            json!({"name": "reviewer", "agent_instance_id": "instance-2"}),
        ];
        let target =
            delegate_target_from_agents(&agents, "reviewer", None, Some("instance-2")).unwrap();
        assert_eq!(target.agent_instance_id.as_deref(), Some("instance-2"));
        assert!(
            delegate_target_from_agents(&agents, "reviewer", None, Some("missing"))
                .unwrap_err()
                .contains("not registered")
        );
    }

    #[test]
    fn create_init_uses_the_created_instance_and_panel_by_slot() {
        let created = vec![
            json!({"name": "executor", "agent_instance_id": "instance-1", "panel_id": "panel-1"}),
            json!({"name": "executor", "agent_instance_id": "instance-2", "panel_id": "panel-2"}),
        ];
        assert_eq!(
            created_agent_selector(&created, 1),
            (Some("instance-2"), Some("panel-2"))
        );
        let params = send_return_key_params(
            "team-a",
            "executor",
            Some("panel-2"),
            Some("instance-2"),
            Some("seq-2"),
        );
        assert_eq!(params["agent_instance_id"], "instance-2");
        assert_eq!(params["panel_id"], "panel-2");
    }

    #[test]
    fn worktree_delegate_uses_panel_resolved_instance_for_task_owner() {
        let agents = vec![
            json!({
                "name": "executor",
                "panel_id": "panel-1",
                "agent_instance_id": "instance-1",
                "working_directory": "/repo/one",
            }),
            json!({
                "name": "executor",
                "panel_id": "panel-2",
                "agent_instance_id": "instance-2",
                "working_directory": "/repo/two",
            }),
        ];
        let target = delegate_target_from_agents(&agents, "executor", Some("panel-2"), None)
            .expect("panel-2 resolves");
        assert!(should_acquire_worktree(
            WorktreePolicyArg::Auto,
            "executor",
            "implement the fix",
            "Fix placement routing",
            None,
        ));

        let params = worktree_task_create_params(
            "team-a",
            "executor",
            "Fix placement routing",
            1,
            &[],
            &[],
            None,
            None,
            target.agent_instance_id.as_deref(),
            WorktreePolicyArg::Auto,
            "request-1",
            None,
            None,
        );
        assert_eq!(params["agent_instance_id"], "instance-2");
        assert_eq!(target.working_directory.as_deref(), Some("/repo/two"));
    }

    #[test]
    fn explicit_panel_resolution_fails_before_task_creation() {
        let agents = vec![json!({
            "name": "executor",
            "panel_id": "panel-1",
            "agent_instance_id": "instance-1",
        })];
        let mut task_create_calls = 0;
        let resolution = delegate_target_from_agents(&agents, "executor", Some("missing"), None);
        if resolution.is_ok() {
            task_create_calls += 1;
        }
        let error = resolution.unwrap_err();
        assert!(error.contains("no agent named executor matches panel missing"));
        assert_eq!(task_create_calls, 0);

        let dir = tempfile::tempdir().unwrap();
        let missing_socket = dir.path().join("missing.sock");
        let error =
            selected_delegate_target(&missing_socket, "team-a", "executor", Some("panel-2"), None)
                .unwrap_err();
        assert!(error.contains("cannot resolve delegate target before dispatch"));
    }

    #[test]
    fn worktree_acquire_runs_from_selected_placement() {
        let mut seen_cwd = None;
        let mut seen_args = Vec::new();
        let meta = gk_wt_acquire_with(
            "tm/team-a/task-1",
            Some("develop"),
            Some("/repo/selected-placement"),
            |args, cwd| {
                seen_args = args.to_vec();
                seen_cwd = cwd.map(str::to_string);
                Ok(json!({
                    "ok": true,
                    "result": {
                        "path": "/repo/worktree",
                        "branch": "tm/team-a/task-1",
                    },
                }))
            },
        )
        .expect("acquire result");

        assert_eq!(seen_cwd.as_deref(), Some("/repo/selected-placement"));
        assert_eq!(seen_args[0..3], ["wt", "acquire", "tm/team-a/task-1"]);
        assert_eq!(meta.path, "/repo/worktree");
    }
}

fn worktree_policy_name(policy: WorktreePolicyArg) -> &'static str {
    match policy {
        WorktreePolicyArg::Auto => "auto",
        WorktreePolicyArg::Always => "always",
        WorktreePolicyArg::Off => "off",
    }
}

fn parse_worktree_policy_name(value: Option<&str>) -> WorktreePolicyArg {
    match value.unwrap_or("auto").to_ascii_lowercase().as_str() {
        "always" => WorktreePolicyArg::Always,
        "off" | "false" | "none" => WorktreePolicyArg::Off,
        _ => WorktreePolicyArg::Auto,
    }
}

// Literal block agents must invoke as a shell command before stopping. TUI CLIs
// (Claude/Codex) frequently print this header in their response text but never
// actually run the shell command, which leaves the task stuck in "assigned" and
// causes `tm-agent wait` to time out. The strong wording + literal example here
// is the prompt-side mitigation; the scrollback auto-detector is the safety net.
const REQUIRED_FINAL_STEP_BLOCK: &str = concat!(
    "[REQUIRED FINAL STEP \u{2014} you MUST run this shell command before stopping]\n",
    "```\n",
    "tm-agent reply 'STATUS: DONE|BLOCKED|NEEDS_REVIEW\n",
    "FILES: <changed paths, space-separated, or none>\n",
    "VERIFY: <single shell command to verify, or n/a>\n",
    "NEXT: <one-line action for leader, or NONE>\n",
    "FULL_REPORT: <path to full result file, or n/a>\n",
    "\n",
    "<concise summary body>'\n",
    "```\n",
    "Without running this shell command the leader cannot detect completion \u{2014} the task hangs and wait times out. Printing the header text in your response is NOT enough; you must invoke the `tm-agent reply` shell command yourself.",
);

const REPORT_SUFFIX: &str = concat!(
    "\n\n",
    "[REQUIRED FINAL STEP \u{2014} you MUST run this shell command before stopping]\n",
    "```\n",
    "tm-agent reply 'STATUS: DONE|BLOCKED|NEEDS_REVIEW\n",
    "FILES: <changed paths or none>\n",
    "VERIFY: <single shell command or n/a>\n",
    "NEXT: <action or NONE>\n",
    "FULL_REPORT: <result file path or n/a>\n",
    "\n",
    "<concise summary body>'\n",
    "```\n",
    "Without running this shell command the leader cannot detect completion \u{2014} the task hangs and wait times out. Printing the header in your response is NOT enough; you must invoke `tm-agent reply` as a shell command.",
);

const BROADCAST_SUFFIX: &str = concat!(
    "\n\n",
    "[REQUIRED FINAL STEP \u{2014} every recipient MUST run this shell command before stopping]\n",
    "```\n",
    "tm-agent reply 'STATUS: DONE|BLOCKED|NEEDS_REVIEW\n",
    "FILES: <changed paths or none>\n",
    "VERIFY: <single shell command or n/a>\n",
    "NEXT: <action or NONE>\n",
    "FULL_REPORT: <result file path or n/a>\n",
    "\n",
    "<concise summary body>'\n",
    "```\n",
    "Without running this shell command the leader cannot detect completion. Printing the header in your response is NOT enough; you must invoke `tm-agent reply` as a shell command.",
);

fn agent_init_prompt(
    agent_name: &str,
    agent_role: &str,
    team_name: &str,
    workdir: &str,
    socket: &str,
) -> String {
    let root = Path::new(workdir);
    let runbook_mode = env::var("TERMMESH_RUNBOOK_MODE").unwrap_or_else(|_| "digest".to_string());
    let runbook_mode = runbook_mode.trim();
    let role = selected_runbook_roles(Some(agent_role))
        .ok()
        .and_then(|mut roles| roles.pop());
    let runbook_section = if runbook_mode.eq_ignore_ascii_case("full") {
        load_runbook_content_for_role(root, agent_role)
            .map(|content| format!("\n## Role Runbook\n\n{content}\n"))
            .unwrap_or_default()
    } else if let Some(role) = role {
        format!(
            "\n{}\n",
            runbook_digest_content(root, &role, agent_name, team_name)
        )
    } else {
        format!(
            "\n{}\n",
            runbook_digest_content_for_role_name(
                root,
                agent_role,
                load_runbook_content_for_role(root, agent_role).as_deref(),
                agent_name,
                team_name
            )
        )
    };
    let identity_line = if agent_name == agent_role {
        format!("You are a team agent named \"{agent_name}\" with role \"{agent_role}\" in a term-mesh multi-agent team.")
    } else {
        format!("You are a team agent named \"{agent_name}\" with role \"{agent_role}\" in a term-mesh multi-agent team. Your identity is \"{agent_name}\"; your behavior runbook is `.agent-runbooks/{agent_role}.md`.")
    };

    format!(
        "{identity_line} \
Use `tm-agent` (Rust, ~2ms) for ALL team operations. \
Fallback: `./scripts/tm-agent.sh` (bash, ~10ms). \
NEVER use `./scripts/team.py` \u{2014} it has been removed.\n\
\n\
Task lifecycle:\n\
1. Begin task: `tm-agent task start <task_id>`\n\
2. Progress heartbeat: `tm-agent heartbeat '<short summary>'`\n\
3. If blocked: `tm-agent task block <task_id> '<reason>'`\n\
4. If ready for review: `tm-agent task review <task_id> '<summary>'`\n\
5. When done: `tm-agent reply '<full result>'` \u{2014} this auto-reports and completes your active task. Do not run `tm-agent task done` separately.\n\
\n\
## Reply Protocol\n\
\n\
This session defines `TM-PROTOCOL-v1`:\n\
- Start assigned work with `tm-agent task start <task_id>`.\n\
- Send brief progress with `tm-agent heartbeat '<short summary>'`.\n\
- Use `tm-agent task block <task_id> '<reason>'` when blocked.\n\
- Use `tm-agent task review <task_id> '<summary>'` when ready for validation.\n\
- Finish with one `tm-agent reply '<5-line header plus concise result>'`; it auto-reports and completes your active task.\n\
\n\
Begin every `tm-agent reply` body with this 5-line header (use n/a / none / NONE when not applicable):\n\
\n\
```\n\
STATUS: DONE|BLOCKED|NEEDS_REVIEW\n\
FILES: <changed paths or \"none\">\n\
VERIFY: <single shell command or \"n/a\">\n\
NEXT: <action or \"NONE\">\n\
FULL_REPORT: <absolute result path or \"n/a\">\n\
```\n\
\n\
## Reply Truncation\n\
\n\
Replies are truncated to ~1500 chars over the socket. `tm-agent reply` preserves the submitted\n\
reply verbatim as `<task_id>.md` and `<agent>-<agent_instance_id>-reply.md`; those files are\n\
durable copies, not full-report generators. For long detail, first write a separate unique file\n\
(recommended `~/.term-mesh/results/<team>/<task_id>-full.md`, or the task-assigned path), then\n\
point FULL_REPORT at it. Never use a reply alias or `<task_id>.md` as FULL_REPORT; use `n/a` when\n\
there is no separate detail file.\n\
\n\
Communication:\n\
- `tm-agent reply` is the channel of record. Anything the leader must see belongs in\n\
  the reply body — it is delivered even when the calls below cannot reach the app.\n\
- Send message to leader: `tm-agent msg send '<text>'`\n\
- Send message to another agent: `tm-agent msg send '<text>' --to <agent_name>`\n\
- Check your inbox: `tm-agent inbox`\n\
- Check team status: `tm-agent status`\n\
- Check tasks: `tm-agent task list`\n\
\n\
If a message/inbox/task call fails (`no_app`, connection reset, non-zero exit), do NOT\n\
retry it and do NOT treat it as a blocker. An agent running on a peer host has no\n\
authorized route back to the app for these; only `reply` is guaranteed. Put the content\n\
in your reply body and continue.\n\
\n\
Environment:\n\
- Working directory: {workdir}\n\
- Socket: {socket}\n\
- Project: term-mesh (Swift/macOS terminal multiplexer)\n\
{runbook_section}\n\
CRITICAL: When tasks complete you MUST invoke `tm-agent reply '<5-line header plus result>'` \
as a shell command. Printing the header text in your response is NOT enough \u{2014} \
the leader cannot detect completion and the team stalls.\n\
Respond with \"Agent {agent_name} ready.\" to confirm.",
    )
}

// ── CLI definition ───────────────────────────────────────────────────

const GIT_SHA: &str = env!("TM_GIT_SHA");
const _BUILD_DATE: &str = env!("TM_BUILD_DATE");

#[derive(Parser)]
#[command(
    name = "tm-agent",
    about = "term-mesh team CLI — unified agent & leader tool",
    version
)]
struct Cli {
    /// Override the target team for this command. Without it the team is resolved
    /// from $TERMMESH_TEAM, then a $TERMMESH_WORKSPACE_ID-derived `ws-<hex>` name,
    /// then `live-team`. Pass `--team ws-<hex>` from an adopted leader pane that
    /// never had TERMMESH_TEAM injected (e.g. a workspace-local `ws-…` team) so
    /// read/collect/inbox/send reach the right team instead of leaking to
    /// `live-team`. Global: accepted on any subcommand.
    #[arg(long, global = true)]
    team: Option<String>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    #[command(hide = true)]
    ClaudeQuestion { action: String },
    // ── Agent-side ─────────────────────────────────────────────────
    /// Submit a result report
    Report { content: Option<String> },
    /// Send heartbeat (alias: ping)
    Ping {
        summary: Option<String>,
        /// Run heartbeat automatically every N seconds until parent process exits or Ctrl+C
        #[arg(long)]
        auto: bool,
        /// Interval in seconds for auto mode (default: 30)
        #[arg(long, default_value_t = 30)]
        interval: u64,
    },
    /// Send heartbeat
    Heartbeat {
        summary: Option<String>,
        /// Run heartbeat automatically every N seconds until parent process exits or Ctrl+C
        #[arg(long)]
        auto: bool,
        /// Interval in seconds for auto mode (default: 30)
        #[arg(long, default_value_t = 30)]
        interval: u64,
    },
    /// Show team status
    Status,
    /// Check agent inbox (pretty table by default on tty; pass --json for raw RPC output)
    Inbox {
        /// Force raw JSON output (otherwise pretty table when stdout is a tty)
        #[arg(long)]
        json: bool,
    },
    /// Execute multiple commands in a single socket roundtrip
    Batch {
        /// Commands separated by semicolons (e.g., "send a:msg1; send b:msg2; status")
        #[arg(required = true)]
        commands: String,
    },
    /// Send raw JSON-RPC payload
    Raw { payload: String },

    // ── Grouped subcommands ────────────────────────────────────────
    /// Task operations (create, start, done, block, review, list, ...)
    #[command(subcommand)]
    Task(TaskCommands),
    /// Message operations (send, list, clear)
    #[command(subcommand)]
    Msg(MsgCommands),
    /// Durable leader request operations
    #[command(subcommand)]
    Leader(LeaderCommands),
    /// Shared context store
    #[command(subcommand)]
    Context(ContextCommands),
    /// Task template operations (list, show)
    #[command(subcommand)]
    Template(TemplateCommands),
    /// Install per-agent runbooks into local agent tool configs
    #[command(subcommand)]
    Runbook(RunbookCommands),
    /// Project registry and local scan operations
    Project(ProjectCommands),
    /// Device pairing and recovery operations
    Pairing(PairingCommands),
    /// Project synchronization operations
    Sync(SyncCommands),
    /// Synchronization conflict operations
    Conflict(ConflictCommands),
    /// Project garbage-collection status
    Gc(GcCommands),

    // ── Simple RPC wrappers ────────────────────────────────────────
    /// Destroy the current team
    Destroy,
    /// List all teams
    List,
    /// List this host's own workspaces with pane/surface/busy counts
    Ls {
        /// Emit machine-readable JSON instead of a table
        #[arg(long)]
        json: bool,
        /// Also print each workspace's split/pane tree
        #[arg(long)]
        tree: bool,
    },
    /// Read an agent's terminal output
    Read {
        agent: String,
        /// Durable agent instance selector (required when the role name is duplicated)
        #[arg(long = "agent-instance-id")]
        agent_instance_id: Option<String>,
        #[arg(long, default_value_t = 50)]
        lines: u32,
    },
    /// Read all agents' terminal output
    Collect {
        #[arg(long, default_value_t = 50)]
        lines: u32,
        /// Print result headers only instead of terminal text
        #[arg(long)]
        headers: bool,
        /// Print result headers plus short summaries instead of terminal text
        #[arg(long)]
        summary: bool,
    },
    /// Get agent reports
    Reports {
        /// Print only STATUS/FILES/VERIFY/NEXT/FULL_REPORT headers
        #[arg(long)]
        headers: bool,
        /// Print headers plus short summaries
        #[arg(long)]
        summary: bool,
    },
    /// Check result completion status
    ResultStatus,
    /// Collect all results
    ResultCollect {
        /// Print only STATUS/FILES/VERIFY/NEXT/FULL_REPORT headers
        #[arg(long)]
        headers: bool,
        /// Print headers plus short summaries
        #[arg(long)]
        summary: bool,
    },

    // ── Orchestration ──────────────────────────────────────────────
    /// Create a new agent team
    Create {
        count: Option<u32>,
        #[arg(long)]
        claude_leader: bool,
        /// Set model for all agents (e.g. sonnet, opus, haiku)
        #[arg(long, default_value = "sonnet")]
        model: String,
        /// Set model for the leader (e.g. opus, sonnet, haiku)
        #[arg(long)]
        leader_model: Option<String>,
        /// Set reasoning effort for all agents (low, medium, high, xhigh, max)
        #[arg(long, value_parser = ["low", "medium", "high", "xhigh", "max"])]
        effort: Option<String>,
        /// Set reasoning effort for the leader (low, medium, high, xhigh, max)
        #[arg(long, value_parser = ["low", "medium", "high", "xhigh", "max"])]
        leader_effort: Option<String>,
        #[arg(long)]
        kiro: Option<String>,
        #[arg(long)]
        codex: Option<String>,
        #[arg(long)]
        gemini: Option<String>,
        /// Adopt current terminal as leader pane (skip leader pane creation)
        #[arg(long)]
        adopt: bool,
        /// Use a named smart or workflow preset (e.g. "standard", "bug-triage")
        #[arg(long)]
        preset: Option<String>,
        /// Comma-separated roles to create (e.g. "explorer,executor,reviewer")
        #[arg(long)]
        roles: Option<String>,
        /// Spawn headless agents (no GUI panes, daemon-managed subprocesses)
        #[arg(long)]
        headless: bool,
        /// Resume a previous Claude Code session for the leader.
        /// Without a value: shows interactive session picker.
        /// With a session ID: resumes that specific session.
        #[arg(long)]
        resume_session: Option<Option<String>>,
        /// Watcher spec, attached to the watcher agent only as custom instructions.
        /// Literal text, or @path to read the spec from a file.
        #[arg(long)]
        spec: Option<String>,
        /// Disable automatic /watch on after team creation (also: TERMMESH_AUTO_WATCH=0)
        #[arg(long)]
        no_auto_watch: bool,
        /// Auto-recycle all agents every N completed tasks (team default). 0 = disabled.
        #[arg(long)]
        auto_recycle: Option<u32>,
        /// Per-agent auto-recycle overrides as "name:N,name:N" (overrides --auto-recycle).
        #[arg(long)]
        auto_recycle_per_agent: Option<String>,
    },
    /// Add an agent to an existing team (GUI and headless teams both supported).
    ///
    /// For GUI teams: resolves the team name from TERMMESH_TEAM or the current
    /// workspace and routes to the Swift `team.add_agent` RPC.
    /// For headless teams: spawns a new daemon-managed subprocess as before.
    Add {
        /// Agent type/name (e.g. "security", "executor", "reviewer")
        agent_type: String,
        /// Custom agent name (defaults to agent_type)
        #[arg(long)]
        name: Option<String>,
        /// Model to use. Defaults to the selected CLI's native default.
        #[arg(long)]
        model: Option<String>,
        /// CLI to use (claude, codex, kiro, gemini)
        #[arg(long, default_value = "claude")]
        cli: String,
        /// Set reasoning effort (low, medium, high, xhigh, max)
        #[arg(long, value_parser = ["low", "medium", "high", "xhigh", "max"])]
        effort: Option<String>,
        /// Disable automatic /watch on after adding a watcher (also: TERMMESH_AUTO_WATCH=0)
        #[arg(long)]
        no_auto_watch: bool,
        /// Auto-recycle this agent every N completed tasks. 0 = disabled.
        #[arg(long)]
        auto_recycle: Option<u32>,
        /// Run this agent on a connected peer instead of here, named as the
        /// sidebar shows it ("jw-server") or as it is stored
        /// ("ssh:root@jw-server"). The pane still opens beside its team; only
        /// the shell behind it is remote.
        #[arg(long)]
        host: Option<String>,
        /// Working directory on that host. Needed when the host has not
        /// reported a project of its own; two machines rarely lay a checkout
        /// out the same way, so this is not guessed from the local path.
        #[arg(long, requires = "host")]
        dir: Option<String>,
        /// Send a ping task to the new agent and wait until it responds.
        #[arg(long)]
        warmup: bool,
        /// Warmup timeout in seconds (used only with --warmup).
        #[arg(long, default_value_t = 30, requires = "warmup")]
        warmup_timeout: u32,
    },
    /// Attach an agent pane to the current workspace's team.
    ///
    /// Unlike `create`, this does not spawn a new workspace — it adds the
    /// agent pane as a split inside the caller's existing workspace. The
    /// caller's pane is auto-adopted as the team's leader on first attach.
    /// The team is auto-named `ws-<first8hex>` based on the workspace UUID.
    /// Must be run inside a term-mesh pane (TERMMESH_WORKSPACE_ID env required).
    Attach {
        /// Agent type/name (e.g. "executor", "reviewer", "security")
        agent_type: String,
        /// Custom agent name (defaults to agent_type). Must match `^[a-zA-Z0-9_-]{1,32}$`.
        #[arg(long)]
        name: Option<String>,
        /// Model to use (e.g. sonnet, opus, haiku)
        #[arg(long, default_value = "sonnet")]
        model: String,
        /// CLI to use (claude, codex, kiro, gemini)
        #[arg(long, default_value = "claude")]
        cli: String,
    },
    /// Detach an agent from the current workspace's team.
    ///
    /// Closes the agent's pane and removes it from the team. The leader
    /// pane (the caller's original pane) is never touched. If the detached
    /// agent was the last one, the team is automatically destroyed while
    /// the leader pane is preserved.
    Detach {
        /// Agent name to detach
        agent_name: String,
        /// Target a specific pane when the agent name is duplicated
        #[arg(long, conflicts_with = "agent_instance_id")]
        panel: Option<String>,
        /// Durable agent instance selector (required for a duplicated name without --panel)
        #[arg(long = "agent-instance-id")]
        agent_instance_id: Option<String>,
    },
    /// Remove an agent from a named GUI team by team name.
    ///
    /// Team-name–scoped: does not require TERMMESH_WORKSPACE_ID/PANEL_ID.
    /// This is the counterpart of `add` for GUI teams — use this when you
    /// know the team name but may not be running inside the workspace.
    /// Unlike `detach` (workspace-local), `remove` operates on a named team.
    Remove {
        /// Agent name to remove from the team
        agent_name: String,
        /// Force removal even if the agent is busy (default: true)
        #[arg(long, default_value_t = true)]
        force: bool,
        /// Target a specific pane when the agent name is duplicated
        #[arg(long, conflicts_with = "agent_instance_id")]
        panel: Option<String>,
        /// Durable agent instance selector (required for a duplicated name without --panel)
        #[arg(long = "agent-instance-id")]
        agent_instance_id: Option<String>,
    },
    /// Preset operations (list)
    #[command(subcommand)]
    Preset(PresetCommands),
    /// Send instruction to an agent (with report suffix)
    Send {
        agent: String,
        text: String,
        #[arg(long, conflicts_with = "expect_reply")]
        no_report: bool,
        /// Wait for an exact reply posted with `tm-agent reply --reply-to <id>`.
        #[arg(long)]
        expect_reply: bool,
        /// Maximum seconds to wait for `--expect-reply`.
        #[arg(
            long,
            default_value_t = 60,
            requires = "expect_reply",
            value_parser = clap::value_parser!(u64).range(1..=86_400)
        )]
        reply_timeout: u64,
        /// Bind this message to an existing open task assigned to the agent: it is sent
        /// with that task's TASK_ID capsule so the reply settles the same task.
        #[arg(
            long,
            conflicts_with = "expect_reply",
            value_parser = clap::builder::NonEmptyStringValueParser::new()
        )]
        task: Option<String>,
        /// Target a specific pane by panel_id (deterministic; overrides name round-robin)
        #[arg(long, conflicts_with = "agent_instance_id")]
        panel: Option<String>,
        /// Durable agent instance selector (alternative to --panel for duplicated names)
        #[arg(long = "agent-instance-id")]
        agent_instance_id: Option<String>,
    },
    /// Broadcast instruction to all agents
    Broadcast {
        text: String,
        #[arg(long)]
        no_report: bool,
    },
    /// Create task and send instruction to agent
    Delegate {
        agent: String,
        text: String,
        /// Stable idempotency key. Reuse the value printed after an unknown outcome.
        #[arg(long)]
        request_id: Option<String>,
        #[arg(long)]
        title: Option<String>,
        #[arg(long)]
        priority: Option<u32>,
        #[arg(long, num_args = 1..)]
        accept: Vec<String>,
        /// Task IDs this task depends on; claimable only once all are completed.
        /// Accepts comma- or space-separated ids: --depends-on a,b  or  --deps a b
        #[arg(long, visible_alias = "depends-on", value_delimiter = ',', num_args = 1..)]
        deps: Vec<String>,
        #[arg(long)]
        desc: Option<String>,
        #[arg(long)]
        no_report: bool,
        /// Prior context (e.g. previous attempts, errors) to inject into agent instruction
        #[arg(long)]
        context: Option<String>,
        /// Auto-fix budget: max number of fix attempts before auto-blocking
        #[arg(long)]
        auto_fix_budget: Option<u8>,
        /// Run task in autonomous mode (headless subprocess, no leader approval needed for edits)
        #[arg(long)]
        autonomous: bool,
        /// Target a specific pane by panel_id (deterministic; overrides name round-robin). Task assignee stays the agent name.
        #[arg(long)]
        panel: Option<String>,
        /// Durable agent instance selector (required when the role name is duplicated)
        #[arg(long = "agent-instance-id", conflicts_with = "panel")]
        agent_instance_id: Option<String>,
        /// gk worktree policy for this task: auto isolates mutating executor work.
        #[arg(long, value_enum, default_value_t = WorktreePolicyArg::Auto)]
        worktree: WorktreePolicyArg,
        /// Base ref for `git-kit wt acquire --from <ref>` when a worktree is acquired.
        #[arg(long = "from")]
        from_ref: Option<String>,
        /// Measurement only: the leader's own route classification for the
        /// request that produced this task (`direct`, `probe`, `parallel`).
        /// Recorded verbatim on the board; nothing validates or acts on it.
        #[arg(long)]
        route: Option<String>,
        /// Measurement only: groups the tasks of one dispatch so wave size is a
        /// GROUP BY rather than a guess about clock gaps. Pass the same value
        /// to every delegate in the same wave.
        #[arg(long = "wave-id")]
        wave_id: Option<String>,
    },
    /// Stop (interrupt) agents by sending Ctrl+C to their terminals
    Stop {
        /// Agent name to interrupt, or omit for all agents
        agent: Option<String>,
        /// Interrupt all agents in the team
        #[arg(long)]
        all: bool,
    },
    /// Restart an agent CLI. Soft (default) sends Ctrl+C + retypes the launch
    /// command in-place. --hard closes the pane and respawns a fresh one in
    /// the same slot (scrollback lost; recovers stuck/IME-swallowed surfaces).
    Restart {
        /// Agent name to restart
        agent: String,
        /// Hard restart: close + respawn the pane (panelId changes; scrollback lost).
        #[arg(long, default_value_t = false)]
        hard: bool,
    },
    /// Safely recycle an idle/stopped agent pane to drop accumulated context.
    ///
    /// This is a guarded semantic wrapper around `restart <agent> --hard`.
    /// It rejects active non-terminal tasks by default so task state must be
    /// checkpointed into the board/results before the transcript is discarded.
    Recycle {
        /// Agent name to recycle
        agent: String,
        /// Bypass the active-task guard after manually checkpointing state.
        #[arg(long, default_value_t = false)]
        force: bool,
    },
    /// Wait for agent signals (report, msg, blocked, review_ready, idle, any).
    /// any requires a tracked task and ends once every tracked task has
    /// settled (completed, review_ready, blocked, failed, cancelled). Only
    /// without --tasks/--task does a message from every agent end it too;
    /// use msg for uncorrelated messages.
    Wait {
        #[arg(long, default_value_t = 120)]
        timeout: u32,
        #[arg(long, default_value_t = 3)]
        interval: u32,
        #[arg(long, default_value = "report")]
        mode: String,
        #[arg(long)]
        task: Option<String>,
        /// Comma-separated list of task IDs to wait for (overrides agent-based
        /// tracking). Cannot be combined with --task.
        #[arg(long)]
        tasks: Option<String>,
        /// Comma-separated list of agent names to wait for (default: all agents)
        #[arg(long)]
        agents: Option<String>,
    },
    /// Delegate a task to all agents (broadcast with task tracking)
    FanOut {
        text: String,
        #[arg(long)]
        title: Option<String>,
        #[arg(long)]
        priority: Option<u32>,
        #[arg(long)]
        no_report: bool,
        /// Comma-separated list of agents to target (default: all)
        #[arg(long)]
        agents: Option<String>,
        /// Prior context (e.g. previous attempts, errors) to inject into agent instruction
        #[arg(long)]
        context: Option<String>,
        /// Auto-fix budget: max number of fix attempts before auto-blocking
        #[arg(long)]
        auto_fix_budget: Option<u8>,
        /// gk worktree policy for each delegated task.
        #[arg(long, value_enum, default_value_t = WorktreePolicyArg::Auto)]
        worktree: WorktreePolicyArg,
        /// Base ref for `git-kit wt acquire --from <ref>` when worktrees are acquired.
        #[arg(long = "from")]
        from_ref: Option<String>,
    },
    /// Get concise agent status (status + task + messages + terminal)
    Brief {
        agent: String,
        #[arg(long, default_value_t = 30)]
        lines: u32,
    },
    /// Reply to leader with auto-report
    Reply {
        text: Vec<String>,
        #[arg(long)]
        from: Option<String>,
        /// Post a one-shot reply correlated to `send --expect-reply`.
        #[arg(long = "reply-to")]
        reply_to: Option<String>,
        /// Explicit task id to close (skips auto-selection when multiple active tasks exist)
        #[arg(long = "task-id")]
        task_id: Option<String>,
        /// Durable agent instance selector. Required for an implicit reply from a duplicated role.
        #[arg(long = "agent-instance-id")]
        agent_instance_id: Option<String>,
    },
    /// Stream daemon events (default), or control autonomous drift-watch via the
    /// `on`/`off`/`status` subcommands (watcher Phase 2, daemon `watch.*` RPC).
    Watch {
        /// Drift-watch control subcommand. Omit to stream daemon events instead.
        #[command(subcommand)]
        action: Option<WatchAction>,
        /// (stream) Comma-separated event kinds (default: task_done,reply,heartbeat_stale)
        #[arg(long, value_name = "KINDS")]
        on_event: Option<String>,
        /// (stream) Stop after N seconds (default: 0 = run until Ctrl+C)
        #[arg(long, default_value_t = 0)]
        timeout: u32,
        /// (stream) Filter to events belonging to a specific leader session
        #[arg(long, value_name = "SESSION_ID")]
        leader_session: Option<String>,
    },
    /// Bridge reply events with XMB_TASK headers into xm-build tasks.json updates
    /// (deprecated: superseded by xk-bridge, kept as a compatibility alias)
    XmbBridge {
        /// Stop after N seconds (default: 0 = run until Ctrl+C)
        #[arg(long, default_value_t = 0)]
        timeout: u32,
        /// Filter to events belonging to a specific leader session
        #[arg(long, value_name = "SESSION_ID")]
        leader_session: Option<String>,
    },
    /// Bridge reply/task_status events into x-kit .xm state: XK_TASK/XK_CORR
    /// headers (legacy XMB_TASK accepted) update x-build tasks.json, append
    /// agent_step entries to the active .xm trace, and record task_complete
    /// metrics. Contract: x-kit docs/term-mesh-integration.md.
    XkBridge {
        /// Stop after N seconds (default: 0 = run until Ctrl+C)
        #[arg(long, default_value_t = 0)]
        timeout: u32,
        /// Filter to events belonging to a specific leader session
        #[arg(long, value_name = "SESSION_ID")]
        leader_session: Option<String>,
    },
    /// Claim the next available pending task (work-stealing)
    Claim,
    /// Suggest the best agent for a task description based on capability mapping
    Suggest {
        /// Task description to match against agent capabilities
        task: Vec<String>,
    },
    /// Warm up agents (send pong task, wait for response, print latency)
    Warmup {
        /// Specific agent to warm up (default: all agents)
        agent: Option<String>,
        /// Timeout in seconds (default: 30)
        #[arg(long, default_value_t = 30)]
        timeout: u32,
    },
    /// Run a research task across idle agents
    Research {
        /// Topic to research
        topic: String,
        /// Number of agents to assign (0 = all idle)
        #[arg(long, default_value_t = 0)]
        agents: u32,
        /// Number of research rounds
        #[arg(long, default_value_t = 5)]
        budget: u32,
        /// Timeout in seconds
        #[arg(long, default_value_t = 600)]
        timeout: u64,
        /// Research depth (shallow|deep|exhaustive)
        #[arg(long, default_value = "deep")]
        depth: String,
        /// Allow web search
        #[arg(long)]
        web: bool,
        /// Focus hint for the research
        #[arg(long)]
        focus: Option<String>,
        /// Skip post-research discussion phase
        #[arg(long)]
        no_discuss: bool,
    },

    /// Solve a problem collaboratively via board stigmergy
    Solve {
        /// Problem description
        problem: String,
        /// Number of agents to assign (0 = all idle)
        #[arg(long, default_value_t = 0)]
        agents: u32,
        /// Number of solve rounds per agent
        #[arg(long, default_value_t = 5)]
        budget: u32,
        /// Timeout in seconds
        #[arg(long, default_value_t = 600)]
        timeout: u64,
        /// Verification command to check solution
        #[arg(long)]
        verify: Option<String>,
        /// Target file/directory to focus on
        #[arg(long)]
        target: Option<String>,
        /// Skip post-solve discussion phase
        #[arg(long)]
        no_discuss: bool,
    },

    /// Reach consensus on a question via board deliberation
    Consensus {
        /// Question to deliberate
        question: String,
        /// Number of agents to assign (0 = all idle)
        #[arg(long, default_value_t = 0)]
        agents: u32,
        /// Number of deliberation rounds per agent
        #[arg(long, default_value_t = 4)]
        budget: u32,
        /// Timeout in seconds
        #[arg(long, default_value_t = 600)]
        timeout: u64,
        /// Comma-separated perspectives for agents
        #[arg(long)]
        perspectives: Option<String>,
        /// Skip post-consensus discussion phase
        #[arg(long)]
        no_discuss: bool,
    },

    /// Execute emergent work via swarm task board
    Swarm {
        /// Goal to achieve
        goal: String,
        /// Number of agents to assign (0 = all idle)
        #[arg(long, default_value_t = 0)]
        agents: u32,
        /// Number of rounds per agent
        #[arg(long, default_value_t = 10)]
        budget: u32,
        /// Timeout in seconds
        #[arg(long, default_value_t = 900)]
        timeout: u64,
        /// Comma-separated seed tasks
        #[arg(long)]
        seed: Option<String>,
        /// Skip post-swarm discussion phase
        #[arg(long)]
        no_discuss: bool,
    },

    // ── Legacy hyphenated aliases (hidden) ───────────────────────────
    /// Alias: task-get → task get
    #[command(name = "task-get", hide = true)]
    TaskGet { id: String },
    /// Alias: task-start → task start
    #[command(name = "task-start", hide = true)]
    TaskStart { task_id: String },
    /// Alias: task-done → task done
    #[command(name = "task-done", hide = true)]
    TaskDone {
        task_id: String,
        result: Option<String>,
    },
    /// Alias: task-block → task block
    #[command(name = "task-block", hide = true)]
    TaskBlock {
        task_id: String,
        reason: Option<String>,
    },
    /// Alias: task-list → task list
    #[command(name = "task-list", hide = true)]
    TaskList,
    /// Alias: tasks → task list
    #[command(name = "tasks", hide = true)]
    Tasks,
    /// Alias: task-create → task create
    #[command(name = "task-create", hide = true)]
    TaskCreate2 {
        title: String,
        #[arg(long)]
        assign: Option<String>,
        #[arg(long)]
        desc: Option<String>,
        #[arg(long)]
        priority: Option<u32>,
        #[arg(long, num_args = 1..)]
        accept: Vec<String>,
        /// Task IDs this task depends on; claimable only once all are completed.
        /// Accepts comma- or space-separated ids: --depends-on a,b  or  --deps a b
        #[arg(long, visible_alias = "depends-on", value_delimiter = ',', num_args = 1..)]
        deps: Vec<String>,
        #[arg(long, value_enum, default_value_t = WorktreePolicyArg::Auto)]
        worktree: WorktreePolicyArg,
        #[arg(long = "from")]
        from_ref: Option<String>,
    },
    /// Alias: task-update → task update
    #[command(name = "task-update", hide = true)]
    TaskUpdate2 {
        id: String,
        status: String,
        result: Option<String>,
    },
    /// Alias: task-review → task review
    #[command(name = "task-review", hide = true)]
    TaskReview2 { id: String, summary: Option<String> },
    /// Alias: task-reassign → task reassign
    #[command(name = "task-reassign", hide = true)]
    TaskReassign2 { id: String, agent: String },
    /// Alias: task-unblock → task unblock
    #[command(name = "task-unblock", hide = true)]
    TaskUnblock2 {
        id: String,
        #[arg(long)]
        correction: Option<String>,
    },
    /// Alias: task-clear → task clear
    #[command(name = "task-clear", hide = true)]
    TaskClear2,

    /// Diagnose environment: sockets, daemons, teams, version mismatches
    Doctor {
        /// Show extra detail (process paths, full socket list)
        #[arg(long)]
        verbose: bool,
        /// Output as JSON instead of human-readable text
        #[arg(long)]
        json: bool,
    },

    /// Peer-federation operations (attach to a remote term-mesh host).
    Peer(PeerCommands),

    /// Daemon-local diagnostics/configuration (talks directly to the
    /// term-meshd socket — no team/app socket required).
    #[command(visible_alias = "d")]
    Daemon(DaemonCommands),

    /// Mobile remote control: expose this pane to the tailnet mobile page
    /// (`/rc` skill, docs/mobile-remote-control.md). Talks directly to the
    /// term-meshd socket like `daemon`.
    Remote(RemoteCommands),

    /// Distributed workspace coordinator control-plane operations.
    ///
    /// Talks directly to TERMMESH_COORDINATOR_UNIX_PATH or the default
    /// tm-coordinator.sock, never through the app/team socket.
    Orchestrator(orchestrator::OrchestratorCommands),
}

#[derive(clap::Args)]
struct PeerCommands {
    #[command(subcommand)]
    command: PeerCommand,
}

#[derive(clap::Args)]
struct DaemonCommands {
    /// Diagnose, then pick a repair from the findings instead of typing one.
    /// Takes no subcommand: bare `daemon` still prints help.
    #[arg(short = 'i', long)]
    interactive: bool,
    #[command(subcommand)]
    command: Option<DaemonCommand>,
}

#[derive(Subcommand)]
enum DaemonCommand {
    /// Get or set the peer PTY-surface replay buffer capacity — bytes of
    /// recent PTY output replayed to a newly attached relay
    /// (`peer.replay_capacity` RPC). Omit `--set` to just print the current
    /// value.
    #[command(visible_alias = "replay")]
    ReplayCapacity {
        /// New capacity as a positional value — the short form of `--set`.
        #[arg(value_name = "CAPACITY", conflicts_with = "set")]
        capacity: Option<String>,
        /// New capacity: plain byte count, or with a k/kb (KiB) or m/mb
        /// (MiB) suffix, e.g. `262144`, `256kb`, `2mb`. Omit to only read
        /// the current value.
        #[arg(long)]
        set: Option<String>,
    },
    /// Inspect or prune this host's durable Project manifests
    /// (`peer-project-presentations.json`). Records another installation
    /// owns cannot be deleted over the peer protocol; this is the
    /// host-side path for them.
    #[command(visible_alias = "pp")]
    ProjectPresentations(ProjectPresentationsCommands),
    /// Clear durable peer state so names a dead leader still holds stop
    /// blocking new Projects. Unlike `project-presentations prune` this does
    /// not require the record to be unresumable — a project folder does not
    /// vanish when its leader dies, so an ordinary prune skips it forever.
    ///
    /// Reports only unless --apply. Each file is backed up next to itself
    /// first. With the daemon up, live surfaces and the default workspace are
    /// refused and reported; with the daemon down there is nothing to ask
    /// about liveness, so the whole file goes.
    Reset {
        /// Scope as a positional value — the short form of `--scope`.
        #[arg(value_name = "SCOPE", conflicts_with = "scope",
              value_parser = ["projects", "workspaces", "all"])]
        scope_arg: Option<String>,
        /// projects = Project manifests, workspaces = named workspaces
        /// (removing one kills that workspace's shells), all = both.
        /// Defaults to `all`.
        #[arg(long, value_parser = ["projects", "workspaces", "all"])]
        scope: Option<String>,
        /// Perform the reset instead of previewing it.
        #[arg(long)]
        apply: bool,
    },
    /// Check this host for the state that makes a Project look healthy while
    /// being broken, and report a safe next step when one is available.
    ///
    /// Read-only: it changes nothing, so it is always safe to run first.
    ///
    /// Checks the daemon answers for (`peer.doctor`): manifests naming a
    /// surface nothing holds, and manifests naming a surface older than
    /// themselves. It also reports more than one trusted term-meshd process.
    Doctor {
        /// Print the raw report instead of the human summary.
        #[arg(long)]
        json: bool,
        /// Offer each finding's repair as a numbered choice. Same picker as
        /// `daemon -i`. Needs a terminal on stdin.
        #[arg(short = 'i', long, conflicts_with = "json")]
        interactive: bool,
    },
}

#[derive(clap::Args)]
struct ProjectPresentationsCommands {
    #[command(subcommand)]
    command: ProjectPresentationsCommand,
}

#[derive(Subcommand)]
enum ProjectPresentationsCommand {
    /// List every manifest with its referenced/live surface counts, owner
    /// and whether the recorded directory still exists.
    #[command(visible_alias = "ls")]
    List,
    /// Remove manifests nothing can resume. Without --project-id only
    /// records whose directory is gone and whose surfaces are all dead are
    /// candidates. --force also selects live records and existing directories. Reports
    /// only unless --apply is given; an applied prune writes a timestamped
    /// .bak copy next to the file first. Workspaces are never touched.
    Prune {
        /// Project IDs as positional values — the short form of
        /// `--project-id`. Combined with any `--project-id` given.
        #[arg(value_name = "PROJECT_ID")]
        project_id_args: Vec<String>,
        /// Restrict to these Project IDs (repeatable). Explicitly named
        /// records are removed even if their directory still exists.
        #[arg(long = "project-id")]
        project_ids: Vec<String>,
        /// Perform the removal instead of previewing it.
        #[arg(long)]
        apply: bool,
        /// Stop the selected projects, including live leaders and agents.
        /// Without Project IDs, select every manifest. Requires --apply to
        /// change anything. Keep project folders and surfaces shared by other projects.
        #[arg(long)]
        force: bool,
    },
}

#[derive(clap::Args)]
struct RemoteCommands {
    #[command(subcommand)]
    command: RemoteCommand,
}

#[derive(Subcommand)]
enum RemoteCommand {
    /// Expose this pane to the mobile page (`remote.on`). Running it again
    /// replaces the entry and restarts the TTL.
    On {
        /// Keys the page may send: `safe` (Enter/Esc/Tab/arrows/y/n/1-9/C-c)
        /// or `none`.
        #[arg(long, default_value = "safe", value_parser = ["safe", "none"])]
        keys: String,
        /// Lifetime such as `12h`, `30m`, `2d`, or plain seconds. Default 24h;
        /// the daemon clamps to 60s..7d.
        #[arg(long)]
        ttl: Option<String>,
        /// Surface id. Defaults to this pane's $TERMMESH_SURFACE_ID.
        #[arg(long)]
        surface: Option<String>,
        /// Register as the team leader: text from the page goes through the
        /// durable leader request board instead of being typed. Auto-detected
        /// for leader panes the app launched; adopted leaders pass it with
        /// `--team`.
        #[arg(long)]
        leader: bool,
        /// Expose a team agent's pane as a chat: the page shows its
        /// structured transcript and sends turns. NAME defaults to this
        /// pane's own $TERMMESH_AGENT_NAME, which is also what a bare
        /// `remote on` does inside a team agent pane; naming another agent
        /// needs the leader pane (or `--team`).
        #[arg(
            long,
            value_name = "AGENT",
            num_args = 0..=1,
            default_missing_value = "",
            conflicts_with = "leader"
        )]
        agent: Option<String>,
        /// Terminal mirror instead of chat: the page shows the screen and
        /// types into it. Alone it exposes this pane's surface; with
        /// `--agent NAME` it mirrors that agent's terminal pane.
        #[arg(long)]
        terminal: bool,
        /// App control socket that owns the surface. Defaults to this pane's
        /// $TERMMESH_SOCKET_PATH.
        #[arg(long)]
        app_socket: Option<String>,
        /// Agent CLI label for the page (claude, codex, ...). Auto-detected
        /// from the environment when omitted.
        #[arg(long)]
        cli: Option<String>,
        /// Title for the page. Defaults to the working directory name.
        #[arg(long)]
        title: Option<String>,
        /// Print the raw RPC result.
        #[arg(long)]
        json: bool,
    },
    /// Stop exposing this pane (`remote.off`).
    Off {
        /// Surface id. Defaults to this pane's $TERMMESH_SURFACE_ID.
        #[arg(long)]
        surface: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Show this pane's exposure, or every exposed surface with `--all`.
    Status {
        /// Surface id. Defaults to this pane's $TERMMESH_SURFACE_ID.
        #[arg(long)]
        surface: Option<String>,
        /// List every exposed surface on this daemon.
        #[arg(long)]
        all: bool,
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand)]
enum PeerCommand {
    /// Check that a remote term-meshd peer socket is reachable and authenticates.
    Status {
        /// Explicit SSH target, for example root@jw-server.
        #[arg(long)]
        host: String,
        /// Explicit remote peer socket; omit to auto-detect it.
        #[arg(long)]
        remote_socket: Option<String>,
    },
    /// Create or reuse one deterministic remote PTY surface.
    Ensure {
        /// Explicit SSH target, for example root@jw-server.
        #[arg(long)]
        host: String,
        /// Explicit remote peer socket; omit to auto-detect it.
        #[arg(long)]
        remote_socket: Option<String>,
        /// Caller-owned logical surface key.
        #[arg(long)]
        key: String,
        /// Absolute working directory on the remote host.
        #[arg(long)]
        cwd: PathBuf,
        /// Absolute executable path on the remote host.
        #[arg(long)]
        executable: PathBuf,
        /// One executable argument; repeat for multiple arguments.
        #[arg(long = "arg", visible_alias = "args", allow_hyphen_values = true)]
        args: Vec<String>,
        /// Lifecycle policy: never or on-daemon-restart.
        #[arg(long, value_enum)]
        policy: PeerRestartPolicyArg,
    },
    /// Terminate one exact ensured remote surface.
    Terminate {
        /// Explicit SSH target, for example root@jw-server.
        #[arg(long)]
        host: String,
        /// Exact full surface ID returned by `peer ensure`.
        #[arg(long)]
        surface_id: String,
        /// Explicit remote peer socket; omit to auto-detect it.
        #[arg(long)]
        remote_socket: Option<String>,
    },
    /// List the surfaces a peer-federation host exposes.
    ///
    /// Prints one surface per line: `<title>  <cols>x<rows>  <status>  <id>`
    /// where status is "live" or "dead". Exits after printing.
    List {
        /// Local peer-federation Unix socket (direct mode).
        #[arg(conflicts_with = "host")]
        socket: Option<PathBuf>,
        /// Explicit SSH target. Opens a temporary forwarded socket.
        #[arg(long, conflicts_with = "socket", required_unless_present = "socket")]
        host: Option<String>,
    },
    /// Attach to a surface exposed by a peer-federation host.
    ///
    /// Without `--name` or `--surface-id`, attaches to the first surface listed by the host.
    /// Stream PtyData from the host to stdout; relay stdin as Input.
    /// Ctrl-] detaches in interactive mode; stdin EOF detaches otherwise.
    Attach {
        /// Local peer-federation Unix socket (legacy direct mode).
        #[arg(conflicts_with = "host")]
        socket: Option<PathBuf>,
        /// Explicit SSH target. Opens a temporary forwarded socket.
        #[arg(long, conflicts_with = "socket", required_unless_present = "socket")]
        host: Option<String>,
        /// Title of the surface to attach to; defaults to the first listed.
        #[arg(long, conflicts_with = "surface_id")]
        name: Option<String>,
        /// Full surface ID returned by `peer ensure`; skips picker selection.
        #[arg(long, conflicts_with = "name")]
        surface_id: Option<String>,
        /// Strip ANSI/OSC escape sequences from the streamed output.
        #[arg(long)]
        plain: bool,
    },
    /// Send one or more keys to a surface, then detach.
    ///
    /// Keys are names (`Enter`, `Up`, `Down`, `Tab`, `Esc`, `C-c`, …) or
    /// literal tokens (`2`, `y`). Multiple keys are sent in order:
    /// `peer send-key --name shell Down Down Enter`.
    SendKey {
        /// Local peer-federation Unix socket (direct mode).
        #[arg(long, conflicts_with = "host")]
        socket: Option<PathBuf>,
        /// Explicit SSH target. Opens a temporary forwarded socket.
        #[arg(long, conflicts_with = "socket", required_unless_present = "socket")]
        host: Option<String>,
        /// Title of the surface; defaults to the first listed.
        #[arg(long, conflicts_with = "surface_id")]
        name: Option<String>,
        /// Full surface ID; skips picker selection.
        #[arg(long, conflicts_with = "name")]
        surface_id: Option<String>,
        /// Keys to send, in order.
        #[arg(required = true)]
        keys: Vec<String>,
    },
    /// Print a surface's current screen once, escapes stripped, then exit.
    ///
    /// Read-only: never sends input, so it won't disturb the surface. Useful
    /// for a bridge to sample "what's on screen right now" without scraping.
    Snapshot {
        /// Local peer-federation Unix socket (direct mode).
        #[arg(long, conflicts_with = "host")]
        socket: Option<PathBuf>,
        /// Explicit SSH target. Opens a temporary forwarded socket.
        #[arg(long, conflicts_with = "socket", required_unless_present = "socket")]
        host: Option<String>,
        /// Title of the surface; defaults to the first listed.
        #[arg(long, conflicts_with = "surface_id")]
        name: Option<String>,
        /// Full surface ID; skips picker selection.
        #[arg(long, conflicts_with = "name")]
        surface_id: Option<String>,
    },
    /// Benchmark peer-relay latency/throughput (P8 measurement harness).
    ///
    /// Point it at a forwarded `ssh -L` socket vs the host's real socket to
    /// isolate the SSH tunnel's contribution. Not interactive — prints
    /// metrics and exits. See docs/peer-p8-measurement.md.
    Bench {
        /// Path to the host's peer-federation unix socket.
        socket: PathBuf,
        /// Which measurements: rtt | wire | throughput | all.
        #[arg(long, default_value = "all")]
        mode: String,
        /// Samples per latency mode (after 3 warmup samples).
        #[arg(long, default_value_t = 30)]
        iterations: usize,
        /// Surface to attach to for rtt/throughput; defaults to the first.
        #[arg(long)]
        name: Option<String>,
        /// Emit a single JSON line instead of a human table.
        #[arg(long)]
        json: bool,
    },
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum PeerRestartPolicyArg {
    Never,
    OnDaemonRestart,
}

#[derive(clap::Args)]
struct ProjectCommands {
    #[command(subcommand)]
    command: ProjectCommand,
}

#[derive(Subcommand)]
enum ProjectCommand {
    Add {
        path: PathBuf,
        /// Explicit project id (64 hex) — register under a chosen id so a second
        /// machine can share it for cross-machine sync. Omitted → random.
        #[arg(long)]
        id: Option<String>,
    },
    List,
    Status {
        project: String,
    },
    Pause {
        project: String,
    },
    Resume {
        project: String,
    },
    Scan {
        project: String,
        #[arg(long)]
        request_id: Option<String>,
    },
}

#[derive(clap::Args)]
struct PairingCommands {
    #[command(subcommand)]
    command: PairingCommand,
}

#[derive(Subcommand)]
enum PairingCommand {
    List {
        project: String,
    },
    Approve {
        project: String,
        request: String,
    },
    Revoke {
        project: String,
        device: String,
    },
    #[command(name = "recovery-export")]
    RecoveryExport {
        project: String,
    },
    #[command(name = "recovery-import")]
    RecoveryImport {
        project: String,
    },
}

#[derive(clap::Args)]
struct SyncCommands {
    #[command(subcommand)]
    command: SyncCommand,
}

#[derive(Subcommand)]
enum SyncCommand {
    Start {
        project: String,
        #[arg(long)]
        peer: Option<String>,
        #[arg(long)]
        request_id: Option<String>,
    },
    Status {
        project: String,
        operation: String,
    },
    Cancel {
        project: String,
        operation: String,
    },
    /// Dev/test bootstrap — identity phase: ensure this daemon's TLS identity for
    /// a project and print its certificate hash (feeds the roster).
    BootstrapIdentity {
        #[arg(long)]
        project: String,
        #[arg(long)]
        device: String,
    },
    /// Dev/test bootstrap — apply phase: provision this daemon from a JSON
    /// descriptor (`{project_id, recovery, dek_key_id, dek_key, device_id, epoch,
    /// roster[], peers[]}`). Pass a file path, or `-` to read stdin.
    BootstrapTrust {
        #[arg(long)]
        descriptor: String,
    },
    /// Dev/test — responder: bind a listener for a provisioned project and serve
    /// incoming syncs. Prints the bound address for the initiator's address book.
    Serve {
        #[arg(long)]
        project: String,
        #[arg(long)]
        bind: String,
    },
}

#[derive(clap::Args)]
struct ConflictCommands {
    #[command(subcommand)]
    command: ConflictCommand,
}

#[derive(Subcommand)]
enum ConflictCommand {
    List {
        project: String,
    },
    Get {
        project: String,
        conflict: String,
    },
    Resolve {
        project: String,
        conflict: String,
        choice: String,
    },
}

#[derive(clap::Args)]
struct GcCommands {
    #[command(subcommand)]
    command: GcCommand,
}

#[derive(Subcommand)]
enum GcCommand {
    /// Summarize what term-mesh is holding on disk, by category
    Status {
        /// Optional project id — selects the legacy project-scoped response
        project: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// List every reclaim candidate with the reasons and the blockers
    Plan {
        /// Limit to a category (repeatable): daemon_worktrees, gitkit_worktrees,
        /// project_checkouts, team_results, team_boards, headless_archives,
        /// worktree_meta, logs, build_caches
        #[arg(long = "category", value_name = "ID")]
        categories: Vec<String>,
        /// Extra directory to search for agent project checkouts (repeatable)
        #[arg(long = "root", value_name = "PATH")]
        roots: Vec<String>,
        /// Also size the build caches — walks Xcode derived data, so it is slow
        #[arg(long)]
        deep: bool,
        #[arg(long)]
        json: bool,
    },
    /// Reclaim what the plan marks safe. Reports only unless --apply is given.
    Sweep {
        /// Actually delete. Without this the command only shows what it would do.
        #[arg(long)]
        apply: bool,
        /// Also reclaim worktrees git cannot open at all. Every other blocker
        /// (uncommitted changes, unmerged commits, an active session) still holds.
        #[arg(long)]
        force: bool,
        #[arg(long = "category", value_name = "ID")]
        categories: Vec<String>,
        #[arg(long = "root", value_name = "PATH")]
        roots: Vec<String>,
        /// Include regenerable build caches in the sweep plan
        #[arg(long)]
        deep: bool,
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand)]
enum TaskCommands {
    /// Create a task (use --template <name> to load from a template)
    Create {
        /// Task title (optional when --template is used)
        title: Option<String>,
        #[arg(long)]
        assign: Option<String>,
        #[arg(long)]
        desc: Option<String>,
        #[arg(long)]
        priority: Option<u32>,
        #[arg(long, num_args = 1..)]
        accept: Vec<String>,
        /// Task IDs this task depends on; claimable only once all are completed.
        /// Accepts comma- or space-separated ids: --depends-on a,b  or  --deps a b
        #[arg(long, visible_alias = "depends-on", value_delimiter = ',', num_args = 1..)]
        deps: Vec<String>,
        /// Load task from a template (builtin: analysis, review, implement)
        #[arg(long)]
        template: Option<String>,
        /// Template variable substitution: --var key=value (repeatable)
        #[arg(long, value_parser = parse_template_var)]
        var: Vec<(String, String)>,
        /// Store a worktree policy on the task for later delegate/claim handling.
        #[arg(long, value_enum, default_value_t = WorktreePolicyArg::Auto)]
        worktree: WorktreePolicyArg,
        /// Base ref hint for future worktree acquisition.
        #[arg(long = "from")]
        from_ref: Option<String>,
    },
    /// Mark task as in_progress
    Start { task_id: String },
    /// Mark task as done with optional result
    Done {
        task_id: String,
        result: Option<String>,
    },
    /// Mark task as blocked with reason
    Block {
        task_id: String,
        reason: Option<String>,
    },
    /// Submit task for review
    Review { id: String, summary: Option<String> },
    /// Get task details
    Get { id: String },
    /// List all tasks (pretty table by default on tty; pass --json for raw RPC output)
    List {
        /// Force raw JSON output (otherwise pretty table when stdout is a tty)
        #[arg(long)]
        json: bool,
        /// Filter by assignee
        #[arg(long)]
        assignee: Option<String>,
        /// Filter by status (e.g. in_progress, assigned, completed)
        #[arg(long)]
        status: Option<String>,
        /// Show only active tasks (assigned + in_progress, excluding stale)
        #[arg(long)]
        active: bool,
    },
    /// Compute coordination timings from durable board timestamps
    Metrics {
        /// Durable leader request id (defaults to the latest request)
        #[arg(long)]
        request_id: Option<String>,
    },
    /// Show this agent's current active task (one-line summary)
    Current {
        /// Force raw JSON output
        #[arg(long)]
        json: bool,
    },
    /// Update task status
    Update {
        id: String,
        status: String,
        result: Option<String>,
    },
    /// Reassign task to another agent
    Reassign { id: String, agent: String },
    /// Unblock a task
    Unblock {
        id: String,
        #[arg(long)]
        correction: Option<String>,
    },
    /// Split a task into subtasks
    Split {
        id: String,
        title: String,
        #[arg(long)]
        assign: Option<String>,
    },
    /// Record a fix attempt (increments fix counter, auto-blocks when budget exhausted)
    #[command(name = "fix-attempt")]
    FixAttempt { task_id: String },
    /// Clear all tasks
    Clear,
    /// Finish the gk worktree attached to a task.
    #[command(name = "finish-worktree")]
    FinishWorktree {
        task_id: String,
        #[arg(long, default_value = "parent")]
        to: String,
        #[arg(long)]
        cleanup: bool,
        #[arg(long)]
        push: bool,
    },
}

#[derive(Subcommand)]
enum MsgCommands {
    /// Send a message (to leader by default, --to for specific agent)
    Send {
        content: String,
        #[arg(long)]
        to: Option<String>,
    },
    /// List messages
    List {
        #[arg(long, name = "from")]
        from_agent: Option<String>,
        #[arg(long)]
        to: Option<String>,
        #[arg(long)]
        limit: Option<u32>,
    },
    /// Clear message queue
    Clear,
}

#[derive(Subcommand)]
enum LeaderCommands {
    /// Durable request queue
    #[command(subcommand)]
    Request(LeaderRequestCommands),
    /// Per-turn measurement records
    #[command(subcommand)]
    Turn(LeaderTurnCommands),
}

#[derive(Subcommand)]
enum LeaderTurnCommands {
    /// Record the route this turn took. Measurement only: appends one line to
    /// `~/.term-mesh/logs/turns.log`, so it works with no daemon running and
    /// costs a leader nothing on a plain direct-answer turn. The one socket
    /// read, a bounded `team.status` for an omitted `--checkout-mode`, is
    /// best-effort and never stops the line from being written.
    ///
    /// The count of these lines is only half the measurement. The harness hooks
    /// write `turn_start`/`turn_end` independently; the gap
    /// `count(turn_start) - count(turn_route)` is the number of turns where the
    /// leader never reported a route, which is the number this exists to expose.
    Route {
        /// Identifies the turn. Omit it and the id is read from the harness
        /// hook's per-surface state stack (`.turn-current-<surface>`), which is
        /// what makes the two independent record streams joinable: a value the
        /// leader invents would never match the `turn_start` the hook wrote.
        #[arg(long = "turn-id")]
        turn_id: Option<String>,
        /// The leader's own classification: `direct`, `probe`, or `parallel`.
        /// Stored verbatim — an unrecognized value is recorded, never rejected
        /// and never normalized, because rejecting one would drop exactly the
        /// anomalies worth seeing.
        #[arg(long)]
        route: String,
        /// How the request was classified before the route was chosen.
        #[arg(long = "task-shape")]
        task_shape: Option<String>,
        /// Authoritative worker-capacity snapshot for this turn. Omit it and
        /// the roster count is read from the participation control file when
        /// the app recorded one; unknown capacity always fails closed.
        #[arg(long = "available-workers")]
        available_workers: Option<u32>,
        /// A risk condition that applied to this turn. Repeatable; every
        /// occurrence collects into one `risk_reasons` array.
        #[arg(long = "risk-reason")]
        risk_reason: Vec<String>,
        /// Groups this turn with the dispatch wave it produced. Same value as
        /// the `--wave-id` passed to `delegate`.
        #[arg(long = "wave-id")]
        wave_id: Option<String>,
        /// Checkout mode used by the candidate worker worktrees. Omit it and
        /// the team's own `checkout_mode` is recorded when the app reports one.
        #[arg(long = "checkout-mode")]
        checkout_mode: Option<String>,
        /// Number of dependency-ready mutating slices.
        #[arg(long = "ready-mutating-slices")]
        ready_mutating_slices: Option<u32>,
        /// Confirms that worker ownership sets are disjoint.
        #[arg(long)]
        ownership_disjoint: bool,
        /// Confirms that the leader lane is disjoint from worker lanes.
        #[arg(long)]
        leader_lane_disjoint: bool,
        /// Number of concurrent write overlaps observed for this turn.
        #[arg(long = "concurrent-write-overlap")]
        concurrent_write_overlap: Option<u32>,
        /// Confirms that integration runs serially.
        #[arg(long)]
        serial_integration: bool,
        /// Resource health result for the execution host.
        #[arg(long = "resource-health")]
        resource_health: Option<String>,
        /// Why no eligible worker task exists in a delegated turn that
        /// dispatched nothing. Only a `direct` route with a non-blank reason
        /// exempts the turn from the Stop hook's one continuation.
        #[arg(long = "no-dispatch-reason")]
        no_dispatch_reason: Option<String>,
    },
    /// Read-only report of one Project's leader turn health, built from the
    /// same `leader_participation_health` gate the execution-host safety net
    /// uses (`apply_participation_health_scope`). Touches no socket and no
    /// daemon: it only reads `~/.term-mesh/logs/turns.log`, so it works when
    /// the Project is a peer's execution host with nothing else running.
    Health {
        /// Project whose turns.log rows to measure.
        #[arg(long)]
        project: String,
        /// Emit the report as JSON instead of one human-readable line.
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand)]
enum LeaderRequestCommands {
    /// List queued and claimed requests
    List {
        #[arg(long)]
        include_completed: bool,
    },
    /// Atomically claim and print one full request
    Take { request_id: String },
    /// Mark a request completed
    Complete { request_id: String },
    /// Change the Project's configured delegation level. Active work keeps its
    /// current snapshot; the next request receives the pending value.
    Configure { level: String },
}

#[derive(Subcommand)]
enum ContextCommands {
    /// Set a context key-value pair
    Set { key: String, value: String },
    /// Get a context value by key
    Get { key: String },
    /// List all context entries
    List,
}

#[derive(Subcommand)]
enum PresetCommands {
    /// List all available presets
    List,
}

#[derive(Subcommand)]
enum TemplateCommands {
    /// List available task templates (builtin + ~/.term-mesh/templates/)
    List,
    /// Show template details
    Show { name: String },
}

#[derive(Subcommand)]
enum RunbookCommands {
    /// Show runbook install status for this repo
    Status,
    /// Create .agent-runbooks/ source files only
    Init {
        /// Print planned changes without writing files
        #[arg(long)]
        dry_run: bool,
        /// Overwrite existing managed files
        #[arg(long)]
        force: bool,
    },
    /// Install runbooks for one tool or all supported tools
    Install {
        /// claude, codex, opencode, gemini, or all
        #[arg(long, default_value = "all")]
        tool: String,
        /// Install only one role runbook
        #[arg(long)]
        agent: Option<String>,
        /// Print planned changes without writing files
        #[arg(long)]
        dry_run: bool,
        /// Overwrite existing non-managed files
        #[arg(long)]
        force: bool,
    },
    /// Print compact runbook digest(s) for prompt-efficient agent init
    Digest {
        /// Show only one role digest
        #[arg(long)]
        agent: Option<String>,
    },
}

/// `tm-agent watch <on|off|status>` — daemon-side autonomous drift-watch control
/// (watcher Phase 2). Routes to the term-meshd `watch.*` RPCs.
#[derive(Subcommand)]
enum WatchAction {
    /// Enable autonomous drift-watch for a team
    On {
        /// Team id to watch
        team: String,
        /// Check interval in seconds (default: daemon default, 300s)
        #[arg(long)]
        every: Option<u64>,
        /// Watched agent name (default: all workers on the team)
        #[arg(long)]
        target: Option<String>,
        /// Watcher stance: critic | advisor | pair
        #[arg(long, default_value = "critic")]
        stance: String,
        /// Watcher CLI: claude | codex | gemini | kiro
        #[arg(long, default_value = "claude")]
        cli: String,
        /// Watcher model
        #[arg(long, default_value = "sonnet")]
        model: String,
        /// Oversight spec text, or @path to read live each cycle
        #[arg(long)]
        spec: Option<String>,
        /// Executions-per-direction ratio (default 5 → every 6th check is direction)
        #[arg(long)]
        ratio: Option<u32>,
        /// Working dir whose .xm/watch/config.json persists this (default: cwd)
        #[arg(long)]
        working_dir: Option<String>,
        /// App (Swift) socket the daemon uses to drive a GUI watcher pane (§4).
        /// Auto-resolved from TERMMESH_SOCKET / detection when omitted; pass it
        /// explicitly from an adopted leader pane that lacks TERMMESH_SOCKET.
        #[arg(long)]
        app_socket: Option<String>,
    },
    /// Disable autonomous drift-watch for a team (config persisted, disabled)
    Off {
        /// Team id to stop watching
        team: String,
    },
    /// Show watch status for one team, or all teams when omitted
    Status {
        /// Team id (optional — omit for all teams)
        team: Option<String>,
    },
    /// Force one drift check immediately, bypassing the cadence timer.
    ///
    /// Self-test surface for `/watch test`: lets the leader confirm the watch
    /// pipeline actually fires (watcher spawn → verdict → board append) without
    /// waiting a full `--every` interval. Rejected when the watch is disabled or
    /// a check is already in flight.
    Trigger {
        /// Team id to fire a check for (required by watch.trigger_now)
        team: String,
    },
    /// Diagnose (and optionally repair) a phantom watcher.
    ///
    /// A phantom watcher is listed in the team registry but has no live pane —
    /// `tm-agent status` shows it (often with `heartbeat_age_seconds: null`) yet
    /// no pane exists, so enabling watch makes every tick fail with
    /// `recycle failed: workspace_missing`. `doctor` probes liveness (team.read +
    /// status panel_id), guards a fresh-spawn race, and repairs by recreating the
    /// pane through the team's own creation path (detach+attach for `ws-*`
    /// workspace-local teams, remove+add for `create`-based teams). It repairs at
    /// most once, then fails loud — never loops.
    Doctor {
        /// Team id to check (e.g. `ws-1a2b3c4d` or a create-based team name)
        team: String,
        /// Watcher agent name (default: `watcher`)
        watcher: Option<String>,
        /// Diagnose only — never repair a confirmed phantom (dry-run)
        #[arg(long)]
        no_repair: bool,
        /// Fresh-spawn race guard: poll liveness up to N seconds at 1s intervals
        #[arg(long)]
        probe_timeout: Option<u64>,
        /// CLI to use when recreating the watcher pane (default: current watcher CLI)
        #[arg(long)]
        cli: Option<String>,
        /// Emit machine-readable JSON (always on — accepted for explicitness)
        #[arg(long)]
        json: bool,
    },
}

fn run_project_sync_command(sock: &PathBuf, command: &Commands) -> Result<Value, String> {
    let (method, params) = match command {
        Commands::Project(group) => match &group.command {
            ProjectCommand::Add { path, id } => (
                "project.add",
                json!({ "root_path": path.to_string_lossy(), "project_id": id }),
            ),
            ProjectCommand::List => ("project.list", json!({})),
            ProjectCommand::Status { project } => {
                ("project.status", json!({ "project_id": project }))
            }
            ProjectCommand::Pause { project } => {
                ("project.pause", json!({ "project_id": project }))
            }
            ProjectCommand::Resume { project } => {
                ("project.resume", json!({ "project_id": project }))
            }
            ProjectCommand::Scan {
                project,
                request_id,
            } => (
                "project.scan",
                json!({
                    "project_id": project,
                    "request_id": request_id.clone().unwrap_or_else(local_request_id),
                    "kind": "manifest_scan",
                }),
            ),
        },
        Commands::Pairing(group) => match &group.command {
            PairingCommand::List { project } => ("pairing.list", json!({ "project_id": project })),
            PairingCommand::Approve { project, request } => (
                "pairing.approve",
                json!({ "project_id": project, "request_id": request }),
            ),
            PairingCommand::Revoke { project, device } => (
                "pairing.revoke",
                json!({ "project_id": project, "device_id": device }),
            ),
            PairingCommand::RecoveryExport { project } => {
                ("pairing.recovery_export", json!({ "project_id": project }))
            }
            PairingCommand::RecoveryImport { project } => {
                ("pairing.recovery_import", json!({ "project_id": project }))
            }
        },
        Commands::Sync(group) => match &group.command {
            SyncCommand::Start {
                project,
                peer,
                request_id,
            } => (
                "sync.start",
                json!({
                    "project_id": project,
                    "peer_id": peer,
                    "request_id": request_id.clone().unwrap_or_else(local_request_id),
                    "kind": "manifest_scan",
                }),
            ),
            SyncCommand::Status { project, operation } => (
                "sync.status",
                json!({ "project_id": project, "operation_id": operation }),
            ),
            SyncCommand::Cancel { project, operation } => (
                "sync.cancel",
                json!({ "project_id": project, "operation_id": operation }),
            ),
            SyncCommand::BootstrapIdentity { project, device } => (
                "sync.bootstrap_identity",
                json!({ "project_id": project, "device_id": device }),
            ),
            SyncCommand::BootstrapTrust { descriptor } => {
                // The descriptor JSON matches the RPC params 1:1, so forward it
                // verbatim (file path, or `-` for stdin).
                let raw = if descriptor == "-" {
                    let mut buf = String::new();
                    std::io::Read::read_to_string(&mut std::io::stdin(), &mut buf).map_err(
                        |error| format!("failed to read descriptor from stdin: {error}"),
                    )?;
                    buf
                } else {
                    std::fs::read_to_string(descriptor).map_err(|error| {
                        format!("failed to read descriptor '{descriptor}': {error}")
                    })?
                };
                let params: Value = serde_json::from_str(&raw)
                    .map_err(|error| format!("descriptor is not valid JSON: {error}"))?;
                ("sync.bootstrap_trust", params)
            }
            SyncCommand::Serve { project, bind } => (
                "sync.serve",
                json!({ "project_id": project, "bind_addr": bind }),
            ),
        },
        Commands::Conflict(group) => match &group.command {
            ConflictCommand::List { project } => {
                ("conflict.list", json!({ "project_id": project }))
            }
            ConflictCommand::Get { project, conflict } => (
                "conflict.get",
                json!({ "project_id": project, "conflict_id": conflict }),
            ),
            ConflictCommand::Resolve {
                project,
                conflict,
                choice,
            } => (
                "conflict.resolve",
                json!({
                    "project_id": project,
                    "conflict_id": conflict,
                    "choice": choice,
                }),
            ),
        },
        // `Commands::Gc` is handled by `cmd_gc`, which renders a table instead
        // of dumping the raw envelope.
        _ => return Err("INTERNAL_ERROR: unsupported project sync command".to_string()),
    };
    daemon_result(sock, method, params)
}

fn pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

/// True when stdout is a terminal — used to default pretty output without
/// breaking pipes/scripts that parse raw JSON.
fn stdout_is_tty() -> bool {
    std::io::stdout().is_terminal()
}

/// Compact "12s" / "3m" / "2h" / "5d" age strings.
fn humanize_age_secs(secs: i64) -> String {
    if secs < 0 {
        return "0s".to_string();
    }
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        format!("{}m", secs / 60)
    } else if secs < 86400 {
        format!("{}h", secs / 3600)
    } else {
        format!("{}d", secs / 86400)
    }
}

/// Truncate to `n` chars (unicode-aware), append `…` when cut.
fn truncate_chars(s: &str, n: usize) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= n {
        s.to_string()
    } else {
        let mut out: String = chars.into_iter().take(n.saturating_sub(1)).collect();
        out.push('…');
        out
    }
}

/// Icon + status label for a task row.
fn task_status_glyph(
    status: &str,
    is_stale: bool,
    needs_attention: bool,
) -> (&'static str, &'static str) {
    match status {
        "in_progress" => ("★", "in_progress"),
        "assigned" if is_stale => ("⏳", "stale"),
        "assigned" => ("◯", "assigned"),
        "completed" => ("✓", "completed"),
        "blocked" => ("✗", "blocked"),
        "failed" => ("✗", "failed"),
        "cancelled" => ("✗", "cancelled"),
        "abandoned" => ("✗", "abandoned"),
        "review_ready" | "needs_review" => ("🔍", "review"),
        _ if needs_attention => ("⏳", status_or_unknown(status)),
        _ => ("·", status_or_unknown(status)),
    }
}

fn status_or_unknown(s: &str) -> &'static str {
    // Convert dynamic str into a small static set without leaking; fall back to "?".
    match s {
        "open" => "open",
        "queued" => "queued",
        "running" => "running",
        "pending" => "pending",
        _ => "?",
    }
}

/// Render `team.task.list` response as a compact table.
fn format_task_list_pretty(v: &Value) -> String {
    let tasks = match v["result"]["tasks"].as_array() {
        Some(t) => t,
        None => return "(no tasks)".to_string(),
    };
    if tasks.is_empty() {
        return "(no tasks)".to_string();
    }
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let mut lines: Vec<String> = Vec::with_capacity(tasks.len() + 1);
    lines.push(format!(
        "{:<2} {:<11} {:<8} {:<12} {:<5} {:>6}  {}",
        "", "status", "id", "assignee", "prio", "age", "title"
    ));
    for t in tasks {
        let status = t["status"].as_str().unwrap_or("?");
        let is_stale = t["is_stale"].as_bool().unwrap_or(false);
        let needs_attn = t["needs_attention"].as_bool().unwrap_or(false);
        let (icon, label) = task_status_glyph(status, is_stale, needs_attn);
        let id = t["id"].as_str().unwrap_or("");
        let id_short: String = id.chars().take(8).collect();
        let assignee = t["assignee"].as_str().unwrap_or("-");
        let prio = t["priority"].as_u64().unwrap_or(0);
        let age = task_age_seconds(t, now_secs);
        let title = t["title"].as_str().unwrap_or("");
        lines.push(format!(
            "{:<2} {:<11} {:<8} {:<12} P{:<4} {:>6}  {}",
            icon,
            label,
            id_short,
            truncate_chars(assignee, 12),
            prio,
            humanize_age_secs(age),
            truncate_chars(title, 60)
        ));
    }
    lines.join("\n")
}

/// One-line summary for a single task (used by `task current`).
fn format_task_oneline(t: &Value) -> String {
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let status = t["status"].as_str().unwrap_or("?");
    let is_stale = t["is_stale"].as_bool().unwrap_or(false);
    let needs_attn = t["needs_attention"].as_bool().unwrap_or(false);
    let (icon, label) = task_status_glyph(status, is_stale, needs_attn);
    let id = t["id"].as_str().unwrap_or("");
    let id_short: String = id.chars().take(8).collect();
    let prio = t["priority"].as_u64().unwrap_or(0);
    let age = task_age_seconds(t, now_secs);
    let title = t["title"].as_str().unwrap_or("");
    format!(
        "{} {} [P{}] {} {} — \"{}\"",
        icon,
        id_short,
        prio,
        label,
        humanize_age_secs(age),
        truncate_chars(title, 80)
    )
}

/// Best-effort age in seconds — prefers server-supplied `stale_seconds` or a
/// timestamp delta from `last_progress_at`/`updated_at`/`created_at`.
fn task_age_seconds(t: &Value, now_secs: i64) -> i64 {
    if let Some(s) = t["stale_seconds"].as_i64() {
        return s.max(0);
    }
    for field in ["last_progress_at", "updated_at", "created_at"] {
        if let Some(ts) = t[field].as_str() {
            if let Some(d) = parse_rfc3339_to_unix(ts) {
                return (now_secs - d).max(0);
            }
        }
    }
    0
}

/// Minimal ISO-8601/RFC3339 parser (`2026-05-18T02:07:14Z`) → unix seconds.
fn parse_rfc3339_to_unix(s: &str) -> Option<i64> {
    if s.len() < 20 || !s.ends_with('Z') {
        return None;
    }
    let year: i64 = s.get(0..4)?.parse().ok()?;
    let month: i64 = s.get(5..7)?.parse().ok()?;
    let day: i64 = s.get(8..10)?.parse().ok()?;
    let hour: i64 = s.get(11..13)?.parse().ok()?;
    let minute: i64 = s.get(14..16)?.parse().ok()?;
    let second: i64 = s.get(17..19)?.parse().ok()?;
    // Days from civil — Howard Hinnant's formula.
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as i64;
    let m = month as i64;
    let d = day as i64;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(days * 86400 + hour * 3600 + minute * 60 + second)
}

/// Render `team.inbox` response as a compact table.
fn format_inbox_pretty(v: &Value) -> String {
    let items = match v["result"]["items"].as_array() {
        Some(i) => i,
        None => return "(empty inbox)".to_string(),
    };
    if items.is_empty() {
        return "(empty inbox)".to_string();
    }
    let mut lines: Vec<String> = Vec::with_capacity(items.len() + 1);
    lines.push(format!(
        "{:<2} {:<8} {:<10} {:<12} {:<5} {:>6}  {}",
        "", "kind", "status", "from", "prio", "age", "summary/title"
    ));
    for it in items {
        let kind = it["kind"].as_str().unwrap_or("?");
        let status = it["status"].as_str().unwrap_or("-");
        let is_stale = it["is_stale"].as_bool().unwrap_or(false);
        let age = it["age_seconds"].as_i64().unwrap_or(0);
        let from = it["agent_name"].as_str().unwrap_or("-");
        let prio = it["priority"].as_u64().unwrap_or(0);
        let title = it["task_title"]
            .as_str()
            .or_else(|| it["summary"].as_str())
            .or_else(|| it["reason"].as_str())
            .unwrap_or("");
        let icon = match kind {
            _ if is_stale => "⏳",
            "task" => "★",
            "report" => "📄",
            "note" => "·",
            _ => "·",
        };
        lines.push(format!(
            "{:<2} {:<8} {:<10} {:<12} P{:<4} {:>6}  {}",
            icon,
            truncate_chars(kind, 8),
            truncate_chars(status, 10),
            truncate_chars(from, 12),
            prio,
            humanize_age_secs(age),
            truncate_chars(title, 60)
        ));
    }
    lines.join("\n")
}

/// Run heartbeat in a loop every `interval` seconds.
/// Stops when the parent process exits (detected via kill -0) or SIGINT/SIGTERM.
fn run_heartbeat_auto(
    sock: &PathBuf,
    team: &str,
    agent: &str,
    interval: u64,
    message: Option<&str>,
) -> Result<Value, String> {
    use std::sync::atomic::{AtomicBool, Ordering};

    static STOP: AtomicBool = AtomicBool::new(false);

    extern "C" fn handle_signal(_: libc::c_int) {
        STOP.store(true, Ordering::SeqCst);
    }
    unsafe {
        libc::signal(
            libc::SIGINT,
            handle_signal as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGTERM,
            handle_signal as *const () as libc::sighandler_t,
        );
    }

    let ppid = unsafe { libc::getppid() };
    let msg = message.unwrap_or("working...");

    eprintln!(
        "auto-heartbeat started (interval={}s, ppid={}, send SIGINT/SIGTERM to stop)",
        interval, ppid
    );

    loop {
        // Send heartbeat
        let _ = rpc_call(
            sock,
            "team.agent.heartbeat",
            json!({
                "team_name": team,
                "agent_name": agent,
                "summary": msg,
            }),
        );

        // Sleep in 100ms chunks to react to signals quickly
        let ticks = interval * 10;
        for _ in 0..ticks {
            if STOP.load(Ordering::SeqCst) {
                eprintln!("auto-heartbeat stopped (signal).");
                return Ok(json!({"ok": true, "stopped": "signal"}));
            }
            thread::sleep(Duration::from_millis(100));
        }

        // Check if parent process is still alive (kill -0)
        let alive = unsafe { libc::kill(ppid, 0) == 0 };
        if !alive {
            eprintln!("auto-heartbeat stopped (parent exited).");
            return Ok(json!({"ok": true, "stopped": "parent_exited"}));
        }
    }
}

// ── Helpers ──────────────────────────────────────────────────────────

fn append_report_suffix(text: &str, no_report: bool) -> String {
    if no_report {
        text.to_string()
    } else {
        format!("{text}{REPORT_SUFFIX}")
    }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn terminal_safe(value: &str) -> String {
    let mut safe = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '\n' => safe.push_str("\\n"),
            '\r' => safe.push_str("\\r"),
            '\t' => safe.push_str("\\t"),
            ch if ch.is_control() => safe.push_str(&format!("\\u{{{:04X}}}", ch as u32)),
            ch => safe.push(ch),
        }
    }
    safe
}

// ── Research helpers ──────────────────────────────────────────────────────────

/// Lightweight info about one agent, extracted from `team.status` response.
#[derive(Debug, Clone)]
struct AgentInfo {
    name: String,
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
fn detect_idle_agents(sock: &PathBuf, team: &str, model_filter: Option<&str>) -> Vec<AgentInfo> {
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
fn select_agents(idle: Vec<AgentInfo>, requested: u32) -> (Vec<AgentInfo>, Option<String>) {
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

fn task_title_from_text(text: &str) -> String {
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
fn format_autonomous_instruction(task: &Value, instruction: &str, context: Option<&str>) -> String {
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

fn format_task_instruction(
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

fn append_team_checkout_topology(
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

fn team_checkout_topology_lines(result: &Value, task: &Value) -> Vec<String> {
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

fn append_checkout_contract(lines: &mut Vec<String>) {
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

// ── Main ─────────────────────────────────────────────────────────────

fn main() {
    let cli = Cli::parse();
    if let Commands::ClaudeQuestion { action } = &cli.command {
        let _ = claude_question::run(action);
        return;
    }

    // `ls` queries the host's own peer socket, not the team control
    // socket — handle it before detect_socket() (same rationale as Peer).
    if let Commands::Ls { json, tree } = &cli.command {
        process::exit(peer::ls_local_cmd(*json, *tree));
    }

    // Peer commands carry their own socket path — handle them before
    // the daemon-socket detection that would otherwise fail when there
    // is no running term-mesh daemon in the environment.
    if let Commands::Peer(ref peer_cmd) = cli.command {
        match &peer_cmd.command {
            PeerCommand::Status {
                host,
                remote_socket,
            } => {
                process::exit(peer::status_cmd(host, remote_socket.as_deref()));
            }
            PeerCommand::Ensure {
                host,
                remote_socket,
                key,
                cwd,
                executable,
                args,
                policy,
            } => {
                let policy = match policy {
                    PeerRestartPolicyArg::Never => peer::RestartPolicy::Never,
                    PeerRestartPolicyArg::OnDaemonRestart => peer::RestartPolicy::OnDaemonRestart,
                };
                process::exit(peer::ensure_cmd(
                    host,
                    remote_socket.as_deref(),
                    key,
                    cwd,
                    executable,
                    args,
                    policy,
                ));
            }
            PeerCommand::Terminate {
                host,
                surface_id,
                remote_socket,
            } => {
                process::exit(peer::terminate_cmd(
                    host,
                    remote_socket.as_deref(),
                    surface_id,
                ));
            }
            PeerCommand::List { socket, host } => {
                let result = if let Some(host) = host {
                    peer::list_host_cmd(host)
                } else {
                    peer::list_cmd(socket.as_deref().expect("clap requires socket or host"))
                };
                if let Err(e) = result {
                    eprintln!("peer list failed: {e:#}");
                    process::exit(1);
                }
                return;
            }
            PeerCommand::Attach {
                socket,
                host,
                name,
                surface_id,
                plain,
            } => {
                let result = if let Some(host) = host {
                    peer::attach_host_cmd(host, name.as_deref(), surface_id.as_deref(), *plain)
                } else {
                    peer::attach_cmd(
                        socket.as_deref().expect("clap requires socket or host"),
                        name.as_deref(),
                        surface_id.as_deref(),
                        *plain,
                    )
                };
                if let Err(e) = result {
                    eprintln!("peer attach failed: {e:#}");
                    process::exit(1);
                }
                return;
            }
            PeerCommand::SendKey {
                socket,
                host,
                name,
                surface_id,
                keys,
            } => {
                let result = if let Some(host) = host {
                    peer::send_key_host_cmd(host, name.as_deref(), surface_id.as_deref(), keys)
                } else {
                    peer::send_key_cmd(
                        socket.as_deref().expect("clap requires socket or host"),
                        name.as_deref(),
                        surface_id.as_deref(),
                        keys,
                    )
                };
                if let Err(e) = result {
                    eprintln!("peer send-key failed: {e:#}");
                    process::exit(1);
                }
                return;
            }
            PeerCommand::Snapshot {
                socket,
                host,
                name,
                surface_id,
            } => {
                let result = if let Some(host) = host {
                    peer::snapshot_host_cmd(host, name.as_deref(), surface_id.as_deref())
                } else {
                    peer::snapshot_cmd(
                        socket.as_deref().expect("clap requires socket or host"),
                        name.as_deref(),
                        surface_id.as_deref(),
                    )
                };
                if let Err(e) = result {
                    eprintln!("peer snapshot failed: {e:#}");
                    process::exit(1);
                }
                return;
            }
            PeerCommand::Bench {
                socket,
                mode,
                iterations,
                name,
                json,
            } => {
                if let Err(e) = peer::bench_cmd(socket, mode, *iterations, name.as_deref(), *json) {
                    eprintln!("peer bench failed: {e:#}");
                    process::exit(1);
                }
                return;
            }
        }
    }

    // Runbook commands operate on the current repository, not the app socket.
    // They must work before term-mesh is running so onboarding can bootstrap itself.
    if let Commands::Runbook(ref runbook_cmd) = cli.command {
        print_result(run_runbook_command(runbook_cmd));
        return;
    }

    if let Commands::Orchestrator(ref orchestrator_cmd) = cli.command {
        process::exit(orchestrator::run(orchestrator_cmd));
    }

    if matches!(
        cli.command,
        Commands::Project(_) | Commands::Pairing(_) | Commands::Sync(_) | Commands::Conflict(_)
    ) {
        let sock = detect_watch_socket().unwrap_or_else(|| {
            eprintln!("Error: DAEMON_UNAVAILABLE: no term-meshd socket found");
            process::exit(1);
        });
        print_result(run_project_sync_command(&sock, &cli.command));
        return;
    }

    // Disk reclamation talks to the same daemon but renders a table, so it
    // does not go through the generic project-sync passthrough above.
    if let Commands::Gc(group) = &cli.command {
        let sock = detect_watch_socket().unwrap_or_else(|| {
            eprintln!("Error: DAEMON_UNAVAILABLE: no term-meshd socket found");
            process::exit(1);
        });
        cmd_gc(&sock, &group.command);
        return;
    }

    // Doctor runs without a socket (it probes all sockets itself).
    if let Commands::Doctor { verbose, json } = &cli.command {
        cmd_doctor(*verbose, *json);
        return;
    }

    if let Commands::XmbBridge {
        timeout,
        leader_session,
    } = &cli.command
    {
        let sock = detect_daemon_socket()
            .or_else(detect_socket)
            .unwrap_or_else(|| {
                eprintln!("Error: no daemon socket found");
                process::exit(1);
            });
        run_xmb_bridge(&sock, *timeout, leader_session.as_deref());
        return;
    }

    if let Commands::XkBridge {
        timeout,
        leader_session,
    } = &cli.command
    {
        let sock = detect_daemon_socket()
            .or_else(detect_socket)
            .unwrap_or_else(|| {
                eprintln!("Error: no daemon socket found");
                process::exit(1);
            });
        run_xk_bridge(&sock, *timeout, leader_session.as_deref());
        return;
    }

    // Daemon commands talk directly to term-meshd, bypassing team/app socket
    // resolution — same reasoning as XmbBridge/XkBridge above.
    if let Commands::Daemon(ref daemon_cmd) = cli.command {
        let Some(daemon_command) = &daemon_cmd.command else {
            if daemon_cmd.interactive {
                cmd_daemon_interactive();
            }
            // Bare `daemon` still prints help and exits 2, the way a required
            // subcommand did before `-i` made the subcommand optional.
            eprintln!("{}", daemon_help_text());
            process::exit(2);
        };
        if daemon_cmd.interactive {
            eprintln!(
                "Error: -i/--interactive takes no subcommand.\n       \
                 Run `tm-agent daemon -i`, or `tm-agent daemon doctor -i`."
            );
            process::exit(2);
        }
        match daemon_command {
            DaemonCommand::ReplayCapacity { capacity, set } => {
                let sock = detect_daemon_socket()
                    .or_else(detect_socket)
                    .unwrap_or_else(|| {
                        eprintln!("Error: no daemon socket found");
                        process::exit(1);
                    });
                // The positional form and `--set` are mutually exclusive at
                // parse time, so either one alone is the requested capacity.
                let requested = capacity.as_deref().or(set.as_deref());
                cmd_daemon_replay_capacity(&sock, requested);
                return;
            }
            DaemonCommand::Doctor { json, interactive } => {
                if *interactive {
                    cmd_daemon_interactive();
                }
                // Resolves its own sockets: finding the ones this CLI would
                // NOT have reached is half of what it checks.
                cmd_daemon_doctor(*json);
                return;
            }
            DaemonCommand::Reset {
                scope_arg,
                scope,
                apply,
            } => {
                let scope = scope_arg
                    .as_deref()
                    .or(scope.as_deref())
                    .unwrap_or("all")
                    .to_string();
                let scope = &scope;
                // With the daemon up, go through it: clearing the files alone
                // would be undone by its next save, which writes a full
                // in-memory snapshot. Without one, fall back to the files.
                let Some(sock) = detect_daemon_socket().or_else(detect_socket) else {
                    cmd_daemon_reset_offline(scope, *apply);
                };
                let result = match cmd_daemon_rpc(
                    &sock,
                    "peer.state.reset",
                    json!({ "scope": scope, "apply": apply }),
                ) {
                    Ok(result) => {
                        println!("{}", pretty(&result));
                        result
                    }
                    // A daemon older than this command answers this way. Say
                    // what to do instead of leaving a bare protocol error:
                    // clearing the files under a live daemon does nothing,
                    // because its next save writes the old snapshot back.
                    Err(msg) if msg.contains("unknown method") => {
                        eprintln!(
                            "Error: the running term-meshd does not know `peer.state.reset`.\n\
                             It predates this command, so upgrade and restart it — or stop it\n\
                             and run this again to clear the files directly."
                        );
                        process::exit(3);
                    }
                    Err(msg) => {
                        eprintln!("Error: {msg}");
                        process::exit(1);
                    }
                };
                if !apply {
                    let projects = result["projects"]["removed"]
                        .as_array()
                        .map(|r| r.len())
                        .unwrap_or(0);
                    let workspaces = result["workspaces_removed"]
                        .as_array()
                        .map(|r| r.len())
                        .unwrap_or(0);
                    if projects > 0 || workspaces > 0 {
                        println!(
                            "(dry-run — pass --apply to clear {projects} manifest(s) \
                             and {workspaces} workspace(s))"
                        );
                    }
                }
                return;
            }
            DaemonCommand::ProjectPresentations(cmd) => {
                let sock = detect_daemon_socket()
                    .or_else(detect_socket)
                    .unwrap_or_else(|| {
                        eprintln!("Error: no daemon socket found");
                        process::exit(1);
                    });
                match &cmd.command {
                    ProjectPresentationsCommand::List => {
                        cmd_daemon_rpc_print(&sock, "peer.project_presentations.list", json!({}));
                    }
                    ProjectPresentationsCommand::Prune {
                        project_id_args,
                        project_ids,
                        apply,
                        force,
                    } => {
                        // Positional ids and `--project-id` name the same set;
                        // both forms may appear in one invocation.
                        let mut ids = project_id_args.clone();
                        ids.extend(project_ids.iter().cloned());
                        let result = cmd_daemon_rpc_print(
                            &sock,
                            "peer.project_presentations.prune",
                            json!({ "project_ids": ids, "apply": apply, "force": force }),
                        );
                        if *force && result["forced"].as_bool() != Some(true) {
                            eprintln!("Error: the daemon does not support forced project pruning; update term-meshd");
                            process::exit(1);
                        }
                        if *force
                            && result["skipped"].as_array().is_some_and(|skipped| {
                                skipped.iter().any(|item| item["reason"] != "not_found")
                            })
                        {
                            eprintln!("Error: some projects could not be removed; inspect skipped and retry");
                            process::exit(1);
                        }
                        let removed = result["removed"].as_array().map(|r| r.len()).unwrap_or(0);
                        if !apply && removed > 0 {
                            println!("(dry-run — pass --apply to remove {removed} record(s))");
                        }
                    }
                }
                return;
            }
        }
    }

    // `remote <on|off|status>` mutates the daemon's mobile exposure registry
    // (`remote.*` RPCs), so it resolves the daemon socket the same way `watch`
    // does: the app-injected TERMMESH_DAEMON_UNIX_PATH first, a daemon-typed
    // TERMMESH_SOCKET (daemon-spawned panes) next.
    if let Commands::Remote(ref remote_cmd) = cli.command {
        let sock = detect_watch_socket().unwrap_or_else(|| {
            eprintln!(
                "Error: no term-meshd socket found (set TERMMESH_DAEMON_SOCKET, \
                 TERMMESH_DAEMON_UNIX_PATH, or TERMMESH_SOCKET to the daemon socket)"
            );
            process::exit(1);
        });
        run_remote_command(&sock, cli.team.as_deref(), &remote_cmd.command);
        return;
    }

    // `watch <on|off|status>` controls the term-meshd (daemon) drift-watch
    // scheduler via the `watch.*` RPCs, so resolve the daemon socket directly
    // (falling back to the app socket). Bare `watch` (no subcommand) is the event
    // stream, handled in the main match below.
    if let Commands::Watch {
        action: Some(ref action),
        ..
    } = cli.command
    {
        let sock = detect_watch_socket().unwrap_or_else(|| {
            eprintln!(
                "Error: no term-meshd socket found (set TERMMESH_DAEMON_SOCKET, \
                 TERMMESH_DAEMON_UNIX_PATH, or TERMMESH_SOCKET to the daemon socket)"
            );
            process::exit(1);
        });
        run_watch_command(&sock, action);
        return;
    }

    // `leader turn route` writes a local append-only record; its only socket read
    // is best-effort evidence. It returns before socket resolution on purpose: the measurement is worthless
    // if a leader skips the call whenever the daemon happens to be down, and the
    // gap it measures would then read as "the leader chose not to classify".
    if let Commands::Leader(LeaderCommands::Turn(LeaderTurnCommands::Route {
        turn_id,
        route,
        task_shape,
        available_workers,
        risk_reason,
        wave_id,
        checkout_mode,
        ready_mutating_slices,
        ownership_disjoint,
        leader_lane_disjoint,
        concurrent_write_overlap,
        serial_integration,
        resource_health,
        no_dispatch_reason,
    })) = &cli.command
    {
        // An omitted --turn-id is filled from the hook's state stack. Falling
        // back to "unstated" rather than erroring keeps the call cheap enough
        // that a leader still makes it when no hook is wired — a route record
        // that joins nothing is worth more than a turn with no record at all.
        let resolved_turn_id = turn_id
            .clone()
            .or_else(turn_id_from_hook_state)
            .unwrap_or_else(|| "unstated".to_string());
        print_result(run_leader_turn_route_with_evidence(
            &resolve_team_name_with_source(cli.team.as_deref()),
            &resolved_turn_id,
            route,
            task_shape.as_deref(),
            *available_workers,
            risk_reason,
            wave_id.as_deref(),
            checkout_mode.as_deref(),
            *ready_mutating_slices,
            *ownership_disjoint,
            *leader_lane_disjoint,
            *concurrent_write_overlap,
            *serial_integration,
            resource_health.as_deref(),
            no_dispatch_reason.as_deref(),
        ));
        return;
    }

    // `leader turn health` is a read-only local report built from
    // `leader_participation_health`; it returns before socket resolution for
    // the same reason `leader turn route` does above — a peer's execution
    // host may have no daemon running at all.
    if let Commands::Leader(LeaderCommands::Turn(LeaderTurnCommands::Health { project, json })) =
        &cli.command
    {
        let result = turn_log_path().map(|log_path| leader_turn_health_report(&log_path, project));
        match &result {
            Ok(report) if !*json => println!("{}", format_leader_turn_health_line(report)),
            _ => print_result(result),
        }
        return;
    }

    let sock = match detect_socket() {
        Some(s) => s,
        None => {
            eprintln!("Error: no socket found");
            process::exit(1);
        }
    };

    let team = resolve_team_name(cli.team.as_deref());
    let agent = env::var("TERMMESH_AGENT_NAME").unwrap_or_else(|_| "anonymous".into());

    if let Some(error) =
        remote_leader_lifecycle_rejection(remote_leader_route().is_some(), &cli.command)
    {
        eprintln!("Error: {error}");
        process::exit(1);
    }

    if reports_claude_inbox(&cli.command) {
        report_claude_inbox(&sock);
    }

    let result = match cli.command {
        Commands::ClaudeQuestion { .. } => unreachable!("handled before socket resolution"),
        // ── Agent-side commands ──────────────────────────────────
        Commands::Report { content } => {
            let report_content = content.as_deref().unwrap_or("done");
            let report_params = json!({
                "team_name": team,
                "agent_name": agent,
                "content": report_content,
            });
            // team.report — retry once on failure (wait hangs permanently if this is lost)
            let report_result = rpc_call(&sock, "team.report", report_params.clone());
            if let Err(ref e) = report_result {
                eprintln!("  Warning: team.report failed: {e}, retrying...");
                let _ = rpc_call(&sock, "team.report", report_params);
            }
            // Auto-complete the active task using team.task.list (data command,
            // no MainActor) instead of team.status (UI command) to avoid timeout.
            if report_result.is_ok() {
                if let Ok(task_resp) = rpc_call(
                    &sock,
                    "team.task.list",
                    json!({
                        "team_name": &team, "assignee": &agent
                    }),
                ) {
                    if let Some(tasks) = task_resp["result"]["tasks"].as_array() {
                        let summary = truncate_summary(report_content, 1500);
                        // Prefer in_progress task (the one actively being worked on),
                        // then fall back to any non-terminal task. This prevents
                        // completing a queued/blocked task when multiple tasks exist.
                        let target_task = tasks
                            .iter()
                            .find(|t| t["status"].as_str() == Some("in_progress"))
                            .or_else(|| {
                                tasks.iter().find(|t| {
                                    let st = t["status"].as_str().unwrap_or("");
                                    st != "completed" && st != "failed" && st != "abandoned"
                                })
                            });
                        if let Some(t) = target_task {
                            if let Some(tid) = t["id"].as_str() {
                                let update = json!({
                                    "team_name": &team, "task_id": tid,
                                    "status": "completed", "result": summary,
                                });
                                // task.update — retry once on failure (task stays in_progress forever if lost)
                                let update_result =
                                    rpc_call(&sock, "team.task.update", update.clone());
                                if let Err(ref e) = update_result {
                                    eprintln!("  Warning: task.update failed: {e}, retrying...");
                                    let _ = rpc_call(&sock, "team.task.update", update);
                                }
                            }
                        }
                    }
                }
            }
            report_result
        }
        Commands::Ping {
            summary,
            auto,
            interval,
        }
        | Commands::Heartbeat {
            summary,
            auto,
            interval,
        } => {
            if auto {
                run_heartbeat_auto(&sock, &team, &agent, interval, summary.as_deref())
            } else {
                rpc_call(
                    &sock,
                    "team.agent.heartbeat",
                    json!({
                        "team_name": team,
                        "agent_name": agent,
                        "summary": summary.as_deref().unwrap_or("alive"),
                    }),
                )
            }
        }
        Commands::Msg(sub) => match sub {
            MsgCommands::Send { content, to } => {
                let mut params = json!({
                    "team_name": team,
                    "from": agent,
                    "content": content,
                    "type": "note",
                });
                if let Some(target) = to {
                    params["to"] = json!(target);
                }
                rpc_call(&sock, "team.message.post", params)
            }
            MsgCommands::List {
                from_agent,
                to,
                limit,
            } => {
                let mut params = json!({ "team_name": team });
                if let Some(f) = from_agent {
                    params["from"] = json!(f);
                }
                if let Some(t) = to {
                    params["to"] = json!(t);
                }
                if let Some(l) = limit {
                    params["limit"] = json!(l);
                }
                rpc_call(&sock, "team.message.list", params)
            }
            MsgCommands::Clear => {
                rpc_call(&sock, "team.message.clear", json!({ "team_name": team }))
            }
        },
        Commands::Leader(sub) => match sub {
            LeaderCommands::Request(action) => match action {
                LeaderRequestCommands::List { include_completed } => rpc_call(
                    &sock,
                    "team.leader.request.list",
                    json!({
                        "team_name": team,
                        "include_completed": include_completed,
                        "leader_request_token": env::var("TERMMESH_LEADER_REQUEST_TOKEN").unwrap_or_default(),
                    }),
                ),
                LeaderRequestCommands::Take { request_id } => rpc_call(
                    &sock,
                    "team.leader.request.take",
                    json!({
                        "team_name": team,
                        "request_id": request_id,
                        "leader_request_token": env::var("TERMMESH_LEADER_REQUEST_TOKEN").unwrap_or_default(),
                    }),
                )
                .and_then(verify_leader_request_response),
                LeaderRequestCommands::Complete { request_id } => rpc_call(
                    &sock,
                    "team.leader.request.complete",
                    json!({
                        "team_name": team,
                        "request_id": request_id,
                        "leader_request_token": env::var("TERMMESH_LEADER_REQUEST_TOKEN").unwrap_or_default(),
                    }),
                ),
                LeaderRequestCommands::Configure { level } => rpc_call(
                    &sock,
                    "team.delegation.configure",
                    json!({
                        "team_name": team,
                        "level": level,
                        "leader_request_token": env::var("TERMMESH_LEADER_REQUEST_TOKEN").unwrap_or_default(),
                    }),
                ),
            },
            LeaderCommands::Turn(_) => {
                unreachable!("leader turn commands return before detect_socket()")
            }
        },
        Commands::Context(sub) => match sub {
            ContextCommands::Set { key, value } => {
                let agent = agent.clone();
                rpc_call(
                    &sock,
                    "team.context.set",
                    json!({
                        "team_name": team, "key": key, "value": value, "set_by": agent,
                    }),
                )
            }
            ContextCommands::Get { key } => rpc_call(
                &sock,
                "team.context.get",
                json!({ "team_name": team, "key": key }),
            ),
            ContextCommands::List => {
                rpc_call(&sock, "team.context.list", json!({ "team_name": team }))
            }
        },
        Commands::Template(sub) => match sub {
            TemplateCommands::List => {
                let templates = list_all_templates();
                if templates.is_empty() {
                    println!("No templates found.");
                } else {
                    println!("{:<20} {}", "NAME", "SOURCE");
                    println!("{}", "-".repeat(50));
                    for (name, source) in &templates {
                        println!("{:<20} {}", name, source);
                    }
                }
                return;
            }
            TemplateCommands::Show { name } => match load_template(&name) {
                Ok(t) => {
                    println!("name:     {}", t.name);
                    println!("title:    {}", t.title);
                    if let Some(d) = &t.description {
                        println!("desc:\n  {}", d.replace('\n', "\n  "));
                    }
                    if let Some(p) = t.priority {
                        println!("priority: {p}");
                    }
                    if let Some(a) = &t.assign {
                        println!("assign:   {a}");
                    }
                    return;
                }
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            },
        },
        Commands::Task(sub) => {
            match sub {
                TaskCommands::Start { task_id } => rpc_call(
                    &sock,
                    "team.task.update",
                    json!({
                        "team_name": team, "task_id": task_id, "status": "in_progress",
                    }),
                ),
                TaskCommands::Done { task_id, result } => {
                    let result_text = result.as_deref().unwrap_or("done");
                    // Write full result to file, send truncated summary via socket
                    let result_path =
                        write_result_file(&team, &format!("{task_id}.md"), result_text).ok();
                    let summary = truncate_summary(result_text, 1500);
                    let mut params = json!({
                        "team_name": team, "task_id": task_id,
                        "result": summary,
                    });
                    if let Some(ref path) = result_path {
                        params["result_path"] = json!(path.to_string_lossy());
                    }
                    rpc_call(&sock, "team.task.done", params)
                }
                TaskCommands::Block { task_id, reason } => rpc_call(
                    &sock,
                    "team.task.block",
                    json!({
                        "team_name": team, "task_id": task_id,
                        "blocked_reason": reason.as_deref().unwrap_or("blocked"),
                    }),
                ),
                TaskCommands::Create {
                    title,
                    assign,
                    desc,
                    priority,
                    accept,
                    deps,
                    template,
                    var,
                    worktree,
                    from_ref: _,
                } => {
                    // Resolve template (if provided), CLI args take precedence over template values
                    let (tmpl_title, tmpl_desc, tmpl_assign, tmpl_priority) =
                        if let Some(ref tname) = template {
                            match load_template(tname) {
                                Ok(t) => {
                                    let t = t.substitute(&var);
                                    (Some(t.title), t.description, t.assign, t.priority)
                                }
                                Err(e) => {
                                    eprintln!("Error loading template '{tname}': {e}");
                                    std::process::exit(1);
                                }
                            }
                        } else {
                            (None, None, None, None)
                        };

                    let final_title = title.or(tmpl_title).unwrap_or_else(|| {
                        eprintln!(
                            "Error: title required (provide as positional arg or via --template)"
                        );
                        std::process::exit(1);
                    });
                    let final_desc = desc.or(tmpl_desc);
                    let final_assign = assign.or(tmpl_assign);
                    let final_priority = priority.or(tmpl_priority);

                    let mut params = json!({ "team_name": team, "title": final_title });
                    params["worktree_policy"] = json!(worktree_policy_name(worktree));
                    if let Some(a) = final_assign {
                        params["assignee"] = json!(a);
                    }
                    if let Some(d) = final_desc {
                        params["description"] = json!(d);
                    }
                    if let Some(p) = final_priority {
                        params["priority"] = json!(p);
                    }
                    if !accept.is_empty() {
                        params["acceptance_criteria"] = json!(accept);
                    }
                    if !deps.is_empty() {
                        params["depends_on"] = json!(deps);
                    }
                    rpc_call(&sock, "team.task.create", params)
                }
                TaskCommands::Get { id } => rpc_call(
                    &sock,
                    "team.task.get",
                    json!({
                        "team_name": team, "task_id": id,
                    }),
                ).map(|value| { append_rcollect(&team, "task_get", &value); value }),
                TaskCommands::List {
                    json: as_json,
                    assignee,
                    status,
                    active,
                } => {
                    let mut params = json!({ "team_name": team });
                    if let Some(a) = assignee.as_ref() {
                        params["assignee"] = json!(a);
                    }
                    if let Some(s) = status.as_ref() {
                        params["status"] = json!(s);
                    }
                    let result = rpc_call(&sock, "team.task.list", params);
                    match result {
                        Ok(mut v) => {
                            if active {
                                if let Some(arr) = v["result"]["tasks"].as_array_mut() {
                                    arr.retain(|t| {
                                        let st = t["status"].as_str().unwrap_or("");
                                        let stale = t["is_stale"].as_bool().unwrap_or(false);
                                        !stale && (st == "assigned" || st == "in_progress")
                                    });
                                }
                            }
                            if as_json || !stdout_is_tty() {
                                println!("{}", pretty(&v));
                            } else {
                                println!("{}", format_task_list_pretty(&v));
                            }
                            return;
                        }
                        Err(e) => {
                            eprintln!("Error: {e}");
                            process::exit(1);
                        }
                    }
                }
                TaskCommands::Metrics { request_id } => {
                    // Reads the leader-request store, so it carries the same
                    // capability the leader-request commands do.
                    let mut params = json!({
                        "team_name": team,
                        "leader_request_token":
                            env::var("TERMMESH_LEADER_REQUEST_TOKEN").unwrap_or_default(),
                    });
                    if let Some(request_id) = request_id {
                        params["request_id"] = json!(request_id);
                    }
                    rpc_call(&sock, "team.task.metrics", params)
                }
                TaskCommands::Current { json: as_json } => {
                    let task_resp = rpc_call(
                        &sock,
                        "team.task.list",
                        json!({ "team_name": team, "assignee": &agent }),
                    );
                    match task_resp {
                        Ok(v) => {
                            let tasks =
                                v["result"]["tasks"].as_array().cloned().unwrap_or_default();
                            let mut candidates: Vec<&Value> = tasks
                                .iter()
                                .filter(|t| {
                                    matches!(
                                        t["status"].as_str().unwrap_or(""),
                                        "in_progress" | "assigned"
                                    )
                                })
                                .collect();
                            candidates.sort_by(|a, b| {
                                let sa = a["is_stale"].as_bool().unwrap_or(false);
                                let sb = b["is_stale"].as_bool().unwrap_or(false);
                                let ia = a["status"].as_str() == Some("in_progress");
                                let ib = b["status"].as_str() == Some("in_progress");
                                let ca = a["created_at"].as_str().unwrap_or("");
                                let cb = b["created_at"].as_str().unwrap_or("");
                                sa.cmp(&sb)
                                    .then_with(|| ib.cmp(&ia))
                                    .then_with(|| cb.cmp(ca))
                            });
                            match candidates.first() {
                                Some(t) => {
                                    if as_json {
                                        println!("{}", pretty(t));
                                    } else {
                                        println!("{}", format_task_oneline(t));
                                    }
                                    return;
                                }
                                None => {
                                    eprintln!("no active task");
                                    process::exit(1);
                                }
                            }
                        }
                        Err(e) => {
                            eprintln!("Error: {e}");
                            process::exit(1);
                        }
                    }
                }
                TaskCommands::Update { id, status, result } => {
                    let mut params = json!({
                        "team_name": team, "task_id": id, "status": status,
                    });
                    if let Some(r) = result {
                        params["result"] = json!(r);
                    }
                    rpc_call(&sock, "team.task.update", params)
                }
                TaskCommands::Review { id, summary } => rpc_call(
                    &sock,
                    "team.task.review",
                    json!({
                        "team_name": team, "task_id": id,
                        "summary": summary.as_deref().unwrap_or(""),
                    }),
                ),
                TaskCommands::Reassign {
                    id,
                    agent: ref target,
                } => rpc_call(
                    &sock,
                    "team.task.reassign",
                    json!({
                        "team_name": team, "task_id": id, "assignee": target,
                    }),
                ),
                TaskCommands::Unblock { id, correction } => rpc_call(
                    &sock,
                    "team.task.unblock",
                    task_unblock_params(&team, &id, correction.as_deref()),
                ),
                TaskCommands::FixAttempt { task_id } => {
                    match rpc_call(
                        &sock,
                        "team.task.fix_attempt",
                        json!({
                            "team_name": team, "task_id": task_id,
                        }),
                    ) {
                        Ok(ref v) => {
                            let result = &v["result"];
                            let count = result["fix_count"].as_u64().unwrap_or(0);
                            let budget = result["fix_budget"].as_u64().unwrap_or(0);
                            let blocked = result["blocked"].as_bool().unwrap_or(false);
                            if blocked {
                                eprintln!(
                                    "⚠️  Fix budget exhausted ({}/{}). Task auto-blocked.",
                                    count, budget
                                );
                            } else {
                                eprintln!("Fix attempt {}/{} recorded.", count, budget);
                            }
                            Ok(v.clone())
                        }
                        Err(e) => {
                            // If server doesn't support fix_attempt yet, warn but don't fail
                            eprintln!("Warning: fix_attempt RPC not available ({}). Continuing without budget tracking.", e);
                            Ok(
                                json!({"ok": true, "result": {"fix_count": 0, "fix_budget": 0, "blocked": false}}),
                            )
                        }
                    }
                }
                TaskCommands::Split { id, title, assign } => {
                    let mut params = json!({
                        "team_name": team, "task_id": id, "title": title,
                    });
                    if let Some(a) = assign {
                        params["assignee"] = json!(a);
                    }
                    rpc_call(&sock, "team.task.split", params)
                }
                TaskCommands::FinishWorktree {
                    task_id,
                    to,
                    cleanup,
                    push,
                } => run_task_finish_worktree(&sock, &team, &task_id, &to, cleanup, push),
                TaskCommands::Clear => {
                    rpc_call(&sock, "team.task.clear", json!({ "team_name": team }))
                }
            }
        }
        // ── Legacy hyphenated aliases ────────────────────────────────
        Commands::TaskGet { id } => rpc_call(
            &sock,
            "team.task.get",
            json!({
                "team_name": team, "task_id": id,
            }),
        ).map(|value| { append_rcollect(&team, "task_get", &value); value }),
        Commands::TaskStart { task_id } => rpc_call(
            &sock,
            "team.task.update",
            json!({
                "team_name": team, "task_id": task_id, "status": "in_progress",
            }),
        ),
        Commands::TaskDone { task_id, result } => rpc_call(
            &sock,
            "team.task.done",
            json!({
                "team_name": team, "task_id": task_id,
                "result": result.as_deref().unwrap_or("done"),
            }),
        ),
        Commands::TaskBlock { task_id, reason } => rpc_call(
            &sock,
            "team.task.block",
            json!({
                "team_name": team, "task_id": task_id,
                "blocked_reason": reason.as_deref().unwrap_or("blocked"),
            }),
        ),
        Commands::TaskList | Commands::Tasks => {
            rpc_call(&sock, "team.task.list", json!({ "team_name": team }))
        }
        Commands::TaskCreate2 {
            title,
            assign,
            desc,
            priority,
            accept,
            deps,
            worktree,
            from_ref: _,
        } => {
            let mut params = json!({ "team_name": team, "title": title });
            params["worktree_policy"] = json!(worktree_policy_name(worktree));
            if let Some(a) = assign {
                params["assignee"] = json!(a);
            }
            if let Some(d) = desc {
                params["description"] = json!(d);
            }
            if let Some(p) = priority {
                params["priority"] = json!(p);
            }
            if !accept.is_empty() {
                params["acceptance_criteria"] = json!(accept);
            }
            if !deps.is_empty() {
                params["depends_on"] = json!(deps);
            }
            rpc_call(&sock, "team.task.create", params)
        }
        Commands::TaskUpdate2 { id, status, result } => {
            let mut params = json!({
                "team_name": team, "task_id": id, "status": status,
            });
            if let Some(r) = result {
                params["result"] = json!(r);
            }
            rpc_call(&sock, "team.task.update", params)
        }
        Commands::TaskReview2 { id, summary } => rpc_call(
            &sock,
            "team.task.review",
            json!({
                "team_name": team, "task_id": id,
                "summary": summary.as_deref().unwrap_or(""),
            }),
        ),
        Commands::TaskReassign2 {
            id,
            agent: ref target,
        } => rpc_call(
            &sock,
            "team.task.reassign",
            json!({
                "team_name": team, "task_id": id, "assignee": target,
            }),
        ),
        Commands::TaskUnblock2 { id, correction } => rpc_call(
            &sock,
            "team.task.unblock",
            task_unblock_params(&team, &id, correction.as_deref()),
        ),
        Commands::TaskClear2 => rpc_call(&sock, "team.task.clear", json!({ "team_name": team })),
        Commands::Peer(_) => unreachable!("peer commands exit before detect_socket()"),
        Commands::Ls { .. } => unreachable!("ls exits before detect_socket()"),
        Commands::Runbook(_) => unreachable!("runbook commands exit before detect_socket()"),
        Commands::Doctor { .. } => unreachable!("doctor command exits before detect_socket()"),
        Commands::Daemon(_) => unreachable!("daemon command exits before detect_socket()"),
        Commands::Remote(_) => unreachable!("remote command exits before detect_socket()"),
        Commands::Status => {
            // Inject version info into the team.status response JSON
            let mut status = rpc_call(&sock, "team.status", json!({ "team_name": team }))
                .unwrap_or_else(|e| {
                    // If the error string is itself a JSON object (e.g. no_app structured error),
                    // use it directly as the "error" field to preserve code + message.
                    let err =
                        serde_json::from_str::<Value>(&e).unwrap_or_else(|_| json!({"message": e}));
                    json!({"ok": false, "error": err})
                });

            // Compact version check: "app_sha:cli_sha" + match flag
            let version_info = if let Ok(info) = rpc_call(&sock, "system.info", json!({})) {
                let app_sha = info["result"]["git_sha"].as_str().unwrap_or("?");
                let matched = if app_sha == "?" || app_sha.is_empty() {
                    Value::Null // app version unknown — can't determine match
                } else {
                    Value::Bool(app_sha == GIT_SHA)
                };
                json!({ "app": app_sha, "cli": GIT_SHA, "ok": matched })
            } else {
                json!({ "cli": GIT_SHA, "ok": null })
            };

            // Merge version into result (or top-level for error responses)
            if let Some(result) = status.get_mut("result") {
                result["version"] = version_info;
            } else {
                status["version"] = version_info;
            }
            Ok(status)
        }
        Commands::Inbox { json: as_json } => {
            let result = rpc_call(
                &sock,
                "team.inbox",
                json!({ "team_name": team, "agent_name": agent }),
            );
            match result {
                Ok(v) => {
                    if as_json || !stdout_is_tty() {
                        println!("{}", pretty(&v));
                    } else {
                        println!("{}", format_inbox_pretty(&v));
                    }
                    return;
                }
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            }
        }
        Commands::Batch { commands } => {
            let payloads = match parse_batch_commands(&commands, &team) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            };
            let results = if remote_leader_route().is_some() {
                rpc_batch_per_call(&payloads, |method, params| rpc_call(&sock, method, params))
            } else {
                rpc_batch(&sock, &payloads)
            };
            match results {
                Ok(results) => {
                    for r in &results {
                        println!("{}", serde_json::to_string(r).unwrap_or_default());
                    }
                    return;
                }
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            }
        }
        Commands::Raw { payload } => {
            if let Err(e) = serde_json::from_str::<Value>(&payload) {
                eprintln!("Invalid JSON: {e}");
                process::exit(1);
            }
            if remote_leader_route().is_some() {
                match run_raw_routed(&sock, &payload) {
                    Ok(value) => {
                        println!("{}", serde_json::to_string(&value).unwrap_or_default());
                        if rpc_response_failed(&value) {
                            process::exit(1);
                        }
                        return;
                    }
                    Err(e) => {
                        eprintln!("Error: {e}");
                        process::exit(1);
                    }
                }
            }
            let stream = UnixStream::connect(&sock).map_err(|e| format!("connect: {e}"));
            match stream {
                Ok(stream) => {
                    stream.set_read_timeout(Some(Duration::from_secs(2))).ok();
                    let mut writer = stream
                        .try_clone()
                        .map_err(|e| format!("clone: {e}"))
                        .unwrap_or_else(|e| {
                            eprintln!("Error: {e}");
                            process::exit(1);
                        });
                    if let Err(e) = writer
                        .write_all(payload.as_bytes())
                        .and_then(|_| writer.write_all(b"\n"))
                        .and_then(|_| writer.flush())
                    {
                        eprintln!("Error: write: {e}");
                        process::exit(1);
                    }
                    let mut reader = BufReader::new(&stream);
                    let mut line = String::new();
                    reader.read_line(&mut line).ok();
                    print!("{line}");
                    if serde_json::from_str::<Value>(&line)
                        .is_ok_and(|response| rpc_response_failed(&response))
                    {
                        process::exit(1);
                    }
                    return;
                }
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            }
        }

        // ── Simple RPC wrappers ─────────────────────────────────
        Commands::Destroy => {
            eprintln!("Destroying team '{team}'...");
            cleanup_old_results(&team);
            // Also destroy headless team if it exists
            if let Some(daemon_sock) = team_headless_daemon_socket() {
                let _ = rpc_call_timeout(
                    &daemon_sock,
                    "headless.destroy_team",
                    json!({ "team_name": team }),
                    5,
                );
            }
            rpc_call(&sock, "team.destroy", json!({ "team_name": team }))
        }
        Commands::List => {
            if remote_leader_route().is_some() {
                // `team.list` is deliberately forbidden by the scoped leader
                // protocol because it would reveal every team on the owning
                // machine. Give the leader useful list semantics by reading
                // its one granted team and wrapping that row as a one-item
                // roster instead of falling through to the peer host's local
                // app (which is what caused the split-brain incident).
                rpc_call(&sock, "team.status", json!({ "team_name": team }))
                    .map(scoped_team_list_from_status)
            } else {
                rpc_call(&sock, "team.list", json!({}))
            }
        }
        Commands::Read {
            agent: ref agent_name,
            agent_instance_id,
            lines,
        } => {
            // Check if agent is headless — route to daemon socket
            if let Some(daemon_sock) = team_headless_daemon_socket() {
                if let Some(agent_id) = is_headless_agent(&daemon_sock, &team, agent_name) {
                    print_result(rpc_call(
                        &daemon_sock,
                        "headless.read",
                        json!({
                            "agent_id": agent_id,
                            "lines": lines,
                        }),
                    ));
                    return;
                }
            }
            rpc_call(
                &sock,
                "team.read",
                json!({
                    "team_name": team, "agent_name": agent_name, "lines": lines,
                    "agent_instance_id": agent_instance_id,
                }),
            ).map(|value| { append_rcollect(&team, "read", &value); value })
        }
        Commands::Collect {
            lines,
            headers,
            summary,
        } => {
            if headers || summary {
                rpc_call(&sock, "team.result.collect", json!({ "team_name": team }))
                    .map(|resp| { append_rcollect(&team, "collect", &resp); compact_result_collect_response(resp, summary) })
            } else {
                rpc_call(
                    &sock,
                    "team.collect",
                    json!({
                        "team_name": team, "lines": lines,
                    }),
                ).map(|value| { append_rcollect(&team, "collect", &value); value })
            }
        }
        Commands::Reports { headers, summary } => {
            rpc_call(&sock, "team.result.collect", json!({ "team_name": team })).map(|resp| {
                append_rcollect(&team, "reports", &resp);
                if headers || summary {
                    compact_result_collect_response(resp, summary)
                } else {
                    resp
                }
            })
        }
        Commands::ResultStatus => {
            rpc_call(&sock, "team.result.status", json!({ "team_name": team }))
        }
        Commands::ResultCollect { headers, summary } => {
            rpc_call(&sock, "team.result.collect", json!({ "team_name": team })).map(|resp| {
                if headers || summary {
                    compact_result_collect_response(resp, summary)
                } else {
                    resp
                }
            })
        }
        // ── Orchestration commands ──────────────────────────────
        Commands::Create {
            count,
            claude_leader,
            model,
            leader_model,
            effort,
            leader_effort,
            kiro,
            codex,
            gemini,
            adopt,
            preset,
            roles,
            headless,
            resume_session,
            spec,
            no_auto_watch,
            auto_recycle,
            auto_recycle_per_agent,
        } => {
            // Resolve --spec (literal text or @path) once for both paths.
            let watcher_spec = match resolve_watcher_spec(spec.as_deref()) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            };
            if headless {
                run_create_headless(
                    &sock,
                    &team,
                    count.unwrap_or(2),
                    &model,
                    effort.as_deref(),
                    leader_effort.as_deref(),
                    roles.as_deref(),
                    watcher_spec.as_deref(),
                    no_auto_watch,
                    auto_recycle,
                );
            } else {
                run_create(
                    &sock,
                    &team,
                    count.unwrap_or(2),
                    claude_leader,
                    &model,
                    leader_model.as_deref(),
                    effort.as_deref(),
                    leader_effort.as_deref(),
                    &kiro,
                    &codex,
                    &gemini,
                    adopt,
                    preset.as_deref(),
                    roles.as_deref(),
                    resume_session,
                    watcher_spec.as_deref(),
                    no_auto_watch,
                    auto_recycle,
                    auto_recycle_per_agent.as_deref(),
                );
            }
            return;
        }
        Commands::Add {
            agent_type,
            name,
            model,
            cli,
            effort,
            no_auto_watch,
            auto_recycle,
            host,
            dir,
            warmup,
            warmup_timeout,
        } => {
            let agent_name = name.unwrap_or_else(|| agent_type.clone());
            let model = model.unwrap_or_else(|| default_model_for_cli(&cli).to_string());

            // Try headless path first
            if let Some(daemon_sock) = team_headless_daemon_socket() {
                // Check if the team exists as a headless team
                if let Ok(resp) = rpc_call(&daemon_sock, "headless.list_teams", json!({})) {
                    let is_headless = resp["result"]
                        .as_array()
                        .map(|teams| teams.iter().any(|t| t["name"].as_str() == Some(&team)))
                        .unwrap_or(false);
                    if is_headless {
                        run_add_headless(
                            &sock,
                            &daemon_sock,
                            &team,
                            &agent_name,
                            &agent_type,
                            &model,
                            &cli,
                            effort.as_deref(),
                            no_auto_watch,
                            auto_recycle,
                        );
                        if warmup {
                            run_warmup(&sock, &team, Some(&agent_name), warmup_timeout);
                        }
                        return;
                    }
                }
            }

            // GUI team: route to team.add_agent RPC
            let gui_team = resolve_workspace_team_name().unwrap_or_else(|_| team.clone());
            run_add_gui(
                &sock,
                &gui_team,
                &agent_type,
                &agent_name,
                &model,
                &cli,
                effort.as_deref(),
                no_auto_watch,
                auto_recycle,
                host.as_deref(),
                dir.as_deref(),
            );
            if warmup {
                run_warmup(&sock, &gui_team, Some(&agent_name), warmup_timeout);
            }
            return;
        }
        Commands::Attach {
            agent_type,
            name,
            model,
            cli,
        } => {
            let agent_name = name.unwrap_or_else(|| agent_type.clone());
            if let Err(e) = validate_agent_name(&agent_name) {
                eprintln!("Error: {}", e);
                process::exit(1);
            }
            run_attach(&sock, &agent_type, &agent_name, &model, &cli);
            return;
        }
        Commands::Detach {
            agent_name,
            panel,
            agent_instance_id,
        } => {
            if let Err(e) = validate_agent_name(&agent_name) {
                eprintln!("Error: {}", e);
                process::exit(1);
            }
            run_detach(
                &sock,
                &agent_name,
                panel.as_deref(),
                agent_instance_id.as_deref(),
            );
            return;
        }
        Commands::Remove {
            agent_name,
            force,
            panel,
            agent_instance_id,
        } => {
            if let Err(e) = validate_agent_name(&agent_name) {
                eprintln!("Error: {}", e);
                process::exit(1);
            }
            let gui_team = resolve_workspace_team_name().unwrap_or_else(|_| team.clone());
            run_remove_gui(
                &sock,
                &gui_team,
                &agent_name,
                force,
                panel.as_deref(),
                agent_instance_id.as_deref(),
            );
            return;
        }
        Commands::Preset(sub) => match sub {
            PresetCommands::List => {
                match rpc_call(&sock, "team.preset.list", json!({})) {
                    Ok(resp) => {
                        if let Some(presets) = resp["result"]["presets"].as_array() {
                            println!(
                                "{:<18} {:<10} {:<24} {:<8} {}",
                                "ID", "Kind", "Name", "Agents", "Description"
                            );
                            println!("{}", "-".repeat(92));
                            for p in presets {
                                let id = p["id"].as_str().unwrap_or("");
                                let kind = p["type"].as_str().unwrap_or("smart");
                                let name = p["name"].as_str().unwrap_or("");
                                let desc = p["description"].as_str().unwrap_or("");
                                let agent_count =
                                    p["agents"].as_array().map(|a| a.len()).unwrap_or(0);
                                println!(
                                    "{:<18} {:<10} {:<24} {:<8} {}",
                                    id, kind, name, agent_count, desc
                                );
                            }
                        } else {
                            println!("{}", pretty(&resp));
                        }
                    }
                    Err(e) => {
                        eprintln!("Error: {e}");
                        process::exit(1);
                    }
                }
                return;
            }
        },
        Commands::Stop { agent, all } => {
            if all || agent.is_none() {
                // Interrupt all agents in the team
                print_result(rpc_call(
                    &sock,
                    "team.interrupt_all",
                    json!({
                        "team_name": team,
                    }),
                ));
            } else if let Some(ref target) = agent {
                // Interrupt a specific agent
                print_result(rpc_call(
                    &sock,
                    "team.interrupt",
                    json!({
                        "team_name": team, "agent_name": target,
                    }),
                ));
            }
            return;
        }
        Commands::Restart {
            agent: ref target,
            hard,
        } => {
            if hard {
                eprintln!(
                    "hard restart: closing pane and respawning. scrollback will be lost; panelId changes."
                );
            } else {
                eprintln!(
                    "soft restart: types the launch command after Ctrl-C. Stuck CLIs are NOT recovered. Use --hard for true panel respawn."
                );
            }
            let result = rpc_call(
                &sock,
                "team.restart",
                json!({
                    "team_name": team,
                    "agent_name": target,
                    "mode": if hard { "hard" } else { "soft" },
                }),
            );
            if let Ok(ref r) = result {
                if r["ok"].as_bool().unwrap_or(false) {
                    eprintln!("restart issued for {target}");
                }
            }
            print_result(result);
            return;
        }
        Commands::Recycle {
            agent: ref target,
            force,
        } => {
            run_recycle(&sock, &team, target, force);
            return;
        }
        Commands::Send {
            agent: ref target,
            text,
            no_report,
            expect_reply,
            reply_timeout,
            task,
            panel,
            agent_instance_id,
        } => {
            if expect_reply && reply_timeout == 0 {
                print_result(Err("--reply-timeout must be at least 1 second".to_string()));
                return;
            }
            let (followup_text, followup_instance_id) = match task.as_deref() {
                Some(task_id) => match resolve_task_followup(
                    &sock,
                    &team,
                    target,
                    task_id,
                    panel.as_deref(),
                    agent_instance_id.as_deref(),
                    &text,
                    no_report,
                ) {
                    Ok((followup_text, instance_id)) => (Some(followup_text), instance_id),
                    Err(error) => {
                        print_result(Err(error));
                        return;
                    }
                },
                None => (None, None),
            };
            let reply_instance_id = if expect_reply {
                match exact_command_agent_instance_id(
                    &sock,
                    &team,
                    target,
                    panel.as_deref(),
                    agent_instance_id.as_deref(),
                ) {
                    Ok(instance_id) => Some(instance_id),
                    Err(error) => {
                        print_result(Err(error));
                        return;
                    }
                }
            } else {
                None
            };
            let reply_deadline =
                expect_reply.then(|| Instant::now() + Duration::from_secs(reply_timeout));
            let reply_correlation = if expect_reply {
                match new_correlation_token() {
                    Ok(token) => Some(token),
                    Err(error) => {
                        print_result(Err(error));
                        return;
                    }
                }
            } else {
                None
            };
            let text = if let Some(correlation_id) = reply_correlation.as_deref() {
                match append_correlated_reply_instruction(
                    &text,
                    correlation_id,
                    reply_instance_id
                        .as_deref()
                        .expect("expect-reply resolves an instance"),
                ) {
                    Ok(text) => text,
                    Err(error) => {
                        print_result(Err(error));
                        return;
                    }
                }
            } else if let Some(followup_text) = followup_text {
                followup_text
            } else {
                append_report_suffix(&text, no_report)
            };
            if let (Some(correlation_id), Some(instance_id)) =
                (reply_correlation.as_deref(), reply_instance_id.as_deref())
            {
                if let Err(error) = register_correlation_mailbox(
                    &sock,
                    &team,
                    correlation_id,
                    target,
                    instance_id,
                    reply_timeout,
                    reply_deadline
                        .expect("expect-reply establishes a deadline")
                        .saturating_duration_since(Instant::now()),
                ) {
                    print_result(Err(error));
                    return;
                }
                if reply_deadline
                    .expect("expect-reply establishes a deadline")
                    .saturating_duration_since(Instant::now())
                    .is_zero()
                {
                    cancel_correlation_mailbox(&sock, &team, correlation_id);
                    print_result(Err(format!(
                        "timed out before sending correlated request to {target}"
                    )));
                    return;
                }
            }
            // Check if agent is headless — route to daemon socket. An
            // explicit --panel/--agent-instance-id names a GUI pane, so it
            // must reach the GUI resolution path below rather than being
            // silently dropped by the headless route.
            let headless_probe = headless_probe_for_send(
                panel.is_some() || agent_instance_id.is_some(),
                task.is_some(),
                followup_instance_id.as_deref(),
            );
            if headless_probe != HeadlessProbe::Skip {
                if let Some(daemon_sock) = team_headless_daemon_socket() {
                    if let Some(agent_id) = is_headless_agent(&daemon_sock, &team, target) {
                        if headless_probe == HeadlessProbe::RejectIfHeadless {
                            print_result(Err(format!(
                                "--task cannot be verified against headless agent {target}: headless.send addresses by name and the task records no instance"
                            )));
                            return;
                        }
                        let delivery = successful_rpc_envelope(rpc_call(
                            &daemon_sock,
                            "headless.send",
                            json!({
                                "agent_id": agent_id,
                                "text": format!("{text}\n"),
                            }),
                        ))
                        .map(headless_send_delivery_response);
                        if let Err(error) = delivery {
                            if let Some(correlation_id) = reply_correlation.as_deref() {
                                cancel_correlation_mailbox(&sock, &team, correlation_id);
                            }
                            print_result(Err(error));
                            return;
                        }
                        if let Some(correlation_id) = reply_correlation.as_deref() {
                            let reply = wait_for_correlated_reply(
                                &sock,
                                &team,
                                target,
                                reply_instance_id
                                    .as_deref()
                                    .expect("expect-reply resolves an instance"),
                                correlation_id,
                                reply_deadline
                                    .expect("expect-reply establishes a deadline")
                                    .saturating_duration_since(Instant::now()),
                            );
                            if reply.is_err() {
                                cancel_correlation_mailbox(&sock, &team, correlation_id);
                            }
                            let delivery = delivery.as_ref().unwrap();
                            print_result(
                                reply
                                    .map(|response| attach_delivery_metadata(response, delivery))
                                    .or_else(|error| Ok(reply_failure_response(delivery, &error))),
                            );
                        } else {
                            print_result(delivery);
                        }
                        return;
                    }
                }
            }
            let selected_instance_id = if let Some(instance_id) = reply_instance_id.clone() {
                Some(instance_id)
            } else if followup_instance_id.is_some() {
                followup_instance_id
            } else {
                match command_agent_instance_id(
                    &sock,
                    &team,
                    target,
                    panel.as_deref(),
                    agent_instance_id.as_deref(),
                ) {
                    Ok(id) => id,
                    Err(e) => {
                        eprintln!("Error: {e}");
                        process::exit(1);
                    }
                }
            };
            let send_result = successful_rpc_envelope(rpc_call(
                &sock,
                "team.send",
                json!({
                    "team_name": team, "agent_name": target,
                    "text": format!("{text}\n"),
                    "panel_id": panel,
                    "agent_instance_id": selected_instance_id,
                    "send_sequence_aware": true,
                }),
            ));
            if let Err(error) = &send_result {
                if let Some(correlation_id) = reply_correlation.as_deref() {
                    cancel_correlation_mailbox(&sock, &team, correlation_id);
                }
                print_result(Err(error.clone()));
                return;
            }
            // Send Return key via team.send_key (reliable sendNamedKey path).
            // The Return MUST carry the SAME panel_id as the paste so both land on
            // the same pane (otherwise text lands on pane X, Return on name-match Y).
            let delivery_result = if let Ok(ref r) = send_result {
                let text_delivered = r["result"]["text_delivered"].as_bool().unwrap_or(false);
                if !text_delivered {
                    eprintln!("text.delivered.false reason=team.send_ack agent={target}");
                }
                let return_submitted = text_delivered
                    && send_return_key_with_retry(
                        &sock,
                        &team,
                        target,
                        true,
                        "team.send",
                        panel.as_deref(),
                        selected_instance_id.as_deref(),
                        r["result"]["send_sequence_id"].as_str(),
                        send_response_return_required(r),
                    );
                send_result.map(|response| send_delivery_response(response, return_submitted))
            } else {
                send_result
            };
            let delivery_failed = match delivery_result.as_ref() {
                Ok(response) => rpc_response_failed(response),
                Err(_) => true,
            };
            if delivery_failed {
                if let Some(correlation_id) = reply_correlation.as_deref() {
                    cancel_correlation_mailbox(&sock, &team, correlation_id);
                }
                print_result(delivery_result);
                return;
            }
            if let Some(correlation_id) = reply_correlation.as_deref() {
                let reply = wait_for_correlated_reply(
                    &sock,
                    &team,
                    target,
                    reply_instance_id
                        .as_deref()
                        .expect("expect-reply resolves an instance"),
                    correlation_id,
                    reply_deadline
                        .expect("expect-reply establishes a deadline")
                        .saturating_duration_since(Instant::now()),
                );
                if reply.is_err() {
                    cancel_correlation_mailbox(&sock, &team, correlation_id);
                }
                print_result(
                    reply
                        .map(|response| {
                            attach_delivery_metadata(response, delivery_result.as_ref().unwrap())
                        })
                        .or_else(|error| {
                            Ok(reply_failure_response(
                                delivery_result.as_ref().unwrap(),
                                &error,
                            ))
                        }),
                );
            } else {
                print_result(delivery_result);
            }
            return;
        }
        Commands::Broadcast { text, no_report } => {
            let text = if no_report {
                text
            } else {
                format!("{text}{BROADCAST_SUFFIX}")
            };
            print_result(rpc_call(
                &sock,
                "team.broadcast",
                json!({
                    "team_name": team, "text": format!("{text}\n"),
                }),
            ));
            return;
        }
        Commands::Delegate {
            agent: ref target,
            text,
            request_id,
            title,
            priority,
            accept,
            deps,
            desc,
            no_report,
            context,
            auto_fix_budget,
            autonomous,
            panel,
            agent_instance_id,
            worktree,
            from_ref,
            route,
            wave_id,
        } => {
            if agent_instance_id.is_some() && (target.contains(',') || autonomous) {
                eprintln!(
                    "Error: --agent-instance-id targets one pane and cannot be combined with comma fan-out or --autonomous"
                );
                process::exit(2);
            }
            // Auto-detect comma-separated agents and route to parallel fan-out.
            // Fan-out resolves its OWN per-thread panel_ids from team.status, so the
            // single CLI --panel is intentionally NOT forwarded here.
            if target.contains(',') {
                run_fan_out(
                    &sock,
                    &team,
                    &text,
                    title,
                    priority,
                    no_report,
                    &Some(target.to_string()),
                    context.as_deref(),
                    auto_fix_budget,
                    worktree,
                    from_ref.as_deref(),
                );
            } else if autonomous {
                // Autonomous mode spawns a headless subprocess; --panel does not apply.
                run_delegate_autonomous(
                    &sock,
                    &team,
                    target,
                    &text,
                    title,
                    priority,
                    no_report,
                    context.as_deref(),
                    auto_fix_budget,
                );
            } else {
                run_delegate(
                    &sock,
                    &team,
                    target,
                    &text,
                    DelegateOptions {
                        title,
                        priority,
                        accept: &accept,
                        deps: &deps,
                        desc,
                        no_report,
                        context: context.as_deref(),
                        fix_budget: auto_fix_budget,
                        panel_id: panel.as_deref(),
                        agent_instance_id: agent_instance_id.as_deref(),
                        worktree_policy: worktree,
                        from_ref: from_ref.as_deref(),
                        request_id: request_id.as_deref(),
                        route: route.as_deref(),
                        wave_id: wave_id.as_deref(),
                    },
                );
            }
            return;
        }
        Commands::FanOut {
            text,
            title,
            priority,
            no_report,
            agents,
            context,
            auto_fix_budget,
            worktree,
            from_ref,
        } => {
            run_fan_out(
                &sock,
                &team,
                &text,
                title,
                priority,
                no_report,
                &agents,
                context.as_deref(),
                auto_fix_budget,
                worktree,
                from_ref.as_deref(),
            );
            return;
        }
        Commands::Wait {
            timeout,
            interval,
            mode,
            task,
            tasks,
            agents,
        } => {
            let filter = parse_cli_flag(&agents);
            let task_ids = match parse_wait_task_arguments(tasks.as_deref(), task.as_deref()) {
                Ok(ids) => ids,
                Err(message) => {
                    eprintln!("wait: {message}");
                    process::exit(2);
                }
            };
            run_wait(
                &sock,
                &team,
                timeout,
                interval,
                &mode,
                task.as_deref(),
                &filter,
                task_ids.as_ref(),
            );
            return;
        }
        Commands::Watch {
            // `Some(action)` is handled by the early daemon-socket dispatch above;
            // reaching here means the bare event-stream form (action == None).
            action: _,
            on_event,
            timeout,
            leader_session,
        } => {
            run_watch(
                &sock,
                timeout,
                on_event.as_deref(),
                leader_session.as_deref(),
            );
            return;
        }
        Commands::XmbBridge {
            timeout,
            leader_session,
        } => {
            let bridge_sock = detect_daemon_socket().unwrap_or_else(|| sock.clone());
            run_xmb_bridge(&bridge_sock, timeout, leader_session.as_deref());
            return;
        }
        Commands::XkBridge {
            timeout,
            leader_session,
        } => {
            let bridge_sock = detect_daemon_socket().unwrap_or_else(|| sock.clone());
            run_xk_bridge(&bridge_sock, timeout, leader_session.as_deref());
            return;
        }
        Commands::Claim => {
            run_claim(&sock, &team, &agent);
            return;
        }
        Commands::Suggest { task } => {
            let description = task.join(" ");
            run_suggest(&sock, &team, &description);
            return;
        }
        Commands::Warmup {
            agent: ref target,
            timeout,
        } => {
            run_warmup(&sock, &team, target.as_deref(), timeout);
            return;
        }
        Commands::Research {
            topic,
            agents,
            budget,
            timeout,
            depth,
            web,
            focus,
            no_discuss,
        } => {
            run_autonomous(
                &sock,
                &team,
                "research",
                &topic,
                agents,
                budget,
                timeout,
                &depth,
                web,
                focus.as_deref(),
                no_discuss,
                None,
                None,
                None,
            );
            return;
        }
        Commands::Solve {
            problem,
            agents,
            budget,
            timeout,
            verify,
            target,
            no_discuss,
        } => {
            run_autonomous(
                &sock,
                &team,
                "solve",
                &problem,
                agents,
                budget,
                timeout,
                "deep",
                false,
                None,
                no_discuss,
                verify.as_deref(),
                target.as_deref(),
                None,
            );
            return;
        }
        Commands::Consensus {
            question,
            agents,
            budget,
            timeout,
            perspectives,
            no_discuss,
        } => {
            run_autonomous(
                &sock,
                &team,
                "consensus",
                &question,
                agents,
                budget,
                timeout,
                "deep",
                false,
                None,
                no_discuss,
                None,
                None,
                perspectives.as_deref(),
            );
            return;
        }
        Commands::Swarm {
            goal,
            agents,
            budget,
            timeout,
            seed,
            no_discuss,
        } => {
            run_autonomous(
                &sock,
                &team,
                "swarm",
                &goal,
                agents,
                budget,
                timeout,
                "deep",
                false,
                None,
                no_discuss,
                None,
                None,
                seed.as_deref(),
            );
            return;
        }
        Commands::Brief {
            agent: ref target,
            lines,
        } => {
            run_brief(&sock, &team, target, lines);
            return;
        }
        Commands::Reply {
            text,
            from,
            reply_to,
            task_id: explicit_task_id,
            agent_instance_id: explicit_agent_instance_id,
        } => {
            let has_sender_override = from.is_some();
            let sender = from.unwrap_or_else(|| agent.clone());
            let mut content = text.join(" ");
            // stdin fallback: agents frequently submit the body via a heredoc
            // (`tm-agent reply <<'EOF' ... EOF`) or pipe. The body is a positional
            // arg, so without this the piped text is silently dropped and STATUS
            // parses as n/a (the verdict never reaches the leader). Read stdin only
            // when no positional body was given AND stdin is not a TTY (a pipe or
            // heredoc is attached), so interactive use is unaffected.
            if content.trim().is_empty() && !std::io::stdin().is_terminal() {
                use std::io::Read as _;
                let mut piped = String::new();
                if std::io::stdin().read_to_string(&mut piped).is_ok() && !piped.trim().is_empty() {
                    content = piped;
                }
            }
            if let Some(correlation_id) = reply_to.as_deref() {
                if let Err(error) = validate_correlated_reply_overrides(
                    has_sender_override,
                    explicit_task_id.is_some(),
                    explicit_agent_instance_id.is_some(),
                ) {
                    print_result(Err(error));
                    return;
                }
                let identity_sender = match env::var("TERMMESH_AGENT_NAME") {
                    Ok(name) if !name.is_empty() => name,
                    _ => {
                        print_result(Err(
                            "--reply-to requires TERMMESH_AGENT_NAME identity".to_string()
                        ));
                        return;
                    }
                };
                let env_instance = env::var("TERMMESH_AGENT_INSTANCE_ID")
                    .ok()
                    .filter(|id| !id.is_empty());
                let identity_instance = match reply_agent_instance_id(
                    &sock,
                    &team,
                    &identity_sender,
                    env_instance.as_deref(),
                    None,
                ) {
                    Ok(Some(instance_id)) => instance_id,
                    Ok(None) => {
                        print_result(Err(
                            "--reply-to requires a durable agent instance identity".to_string()
                        ));
                        return;
                    }
                    Err(error) => {
                        print_result(Err(format!(
                            "could not verify correlated reply identity: {error}"
                        )));
                        return;
                    }
                };
                let params = match correlated_reply_params(
                    &team,
                    &identity_sender,
                    correlation_id,
                    &identity_instance,
                    &content,
                ) {
                    Ok(params) => params,
                    Err(error) => {
                        print_result(Err(error));
                        return;
                    }
                };
                print_result(rpc_call(&sock, "team.message.post", params));
                return;
            }
            // STATUS enforce (C1) — map protocol STATUS to task state before any I/O
            let (reply_headers, body_summary) = reply_header_and_summary(&content, 1500);
            let protocol_status = reply_headers["status"].as_str().unwrap_or("n/a");
            let task_status = match protocol_status_to_task_state(protocol_status) {
                Some(s) => s,
                None => {
                    eprintln!("STATUS field is required: DONE|BLOCKED|NEEDS_REVIEW (got: {protocol_status})");
                    eprintln!("Reply header must start with: STATUS: <DONE|BLOCKED|NEEDS_REVIEW>");
                    std::process::exit(2);
                }
            };
            // Write the canonical task result when possible, plus the legacy
            // per-agent alias for compatibility with older readers.
            // The watcher role is stateless and per-tick: `/watch` never assigns it
            // a task (watch_controller writes board.jsonl + leader inbox only), and
            // the GUI watch path polls the `<watcher>-reply.md` alias file, not a
            // task result. Skip auto-select for it so a verdict reply never closes
            // an unrelated task lingering on a recycled watcher pane. An explicit
            // --task-id still wins for the rare case the leader assigned one.
            let is_stateless_watcher = sender == "watcher" || sender.starts_with("watcher");
            // Instance resolution is best-effort. The pane environment supplies
            // a durable instance directly when available; older panes resolve
            // their panel/workspace through the roster. It used to run fatally:
            // a duplicated agent name or a `team.status` timeout exited before
            // anything was written
            // — no result file, no report, no task.update, and a leader waiting
            // on a reply that no longer existed. Every instruction the daemon
            // injects (REQUIRED_FINAL_STEP_BLOCK, REPORT_SUFFIX,
            // BROADCAST_SUFFIX, agent_init_prompt) tells the agent to run the
            // bare form, so the bare form has to survive both.
            let default_reply_instance_id = explicit_agent_instance_id
                .clone()
                .or_else(|| current_reply_instance_id(&sock, &team, &sender));
            let (selected, candidates) = if explicit_task_id.is_some() || is_stateless_watcher {
                (None, Vec::new())
            } else {
                select_reply_task(&sock, &team, &sender, default_reply_instance_id.as_deref())
            };
            // Ambiguity withholds the task transition, never the record of the
            // reply. Closing the wrong agent's task is destructive and stays
            // refused; losing the verdict is not a safer outcome, it is the
            // worse one, so the files and the report are written either way.
            let mut withheld_task: Option<String> = None;
            let mut reply_task_id = if let Some(tid) = explicit_task_id {
                Some(tid)
            } else if is_stateless_watcher {
                None
            } else {
                let (task_id, withheld) = reply_task_decision(selected, &candidates);
                withheld_task = withheld;
                task_id
            };
            // A task row is authoritative attribution — it names the instance
            // that was given the work — so one live task resolves a duplicated
            // role without asking `team.status` who the siblings are. When it
            // cannot be resolved, a name-scoped alias is the fallback: a reply
            // filed under a slightly less precise name still reaches the leader.
            let mut reply_instance_id = default_reply_instance_id;
            if let Some(tid) = reply_task_id.clone() {
                match reply_agent_instance_id(
                    &sock,
                    &team,
                    &sender,
                    explicit_agent_instance_id.as_deref(),
                    Some(&tid),
                ) {
                    Ok(instance) => reply_instance_id = instance,
                    // An explicit selector the task contradicts is a false claim
                    // about whose work this is, so the transition is withheld
                    // rather than applied under the wrong instance — the same
                    // treatment ambiguity gets, and for the same reason.
                    Err(message) if explicit_agent_instance_id.is_some() => {
                        withheld_task = Some(message);
                        reply_task_id = None;
                    }
                    // Nothing was claimed and the task is already scoped to this
                    // sender by assignee, so only the instance label is missing.
                    // A name-scoped alias plus a closed task beats a lost reply.
                    Err(message) => {
                        eprintln!(
                            "  Warning: could not resolve the instance for {sender} ({message}); \
                             writing a name-scoped reply alias"
                        );
                    }
                }
            }
            let alias_name = reply_alias_filename(&sender, reply_instance_id.as_deref());
            let mut durable_copy_paths = vec![result_file_path(&team, &alias_name)];
            if let Some(tid) = reply_task_id.as_deref() {
                durable_copy_paths.push(result_file_path(&team, &format!("{tid}.md")));
            }
            let (normalized_content, rejected_full_report) =
                normalize_self_referential_full_report(&content, &durable_copy_paths);
            if let Some(path) = rejected_full_report {
                eprintln!(
                    "Warning: FULL_REPORT points to this reply's durable copy ({path}); normalized to n/a. Write detail to a separate unique file first."
                );
            }
            content = normalized_content;
            let alias_write = write_result_file(&team, &alias_name, &content);
            let task_write = reply_task_id
                .as_deref()
                .map(|tid| write_result_file(&team, &format!("{tid}.md"), &content));
            let (alias_result_path, task_result_path, write_errors) =
                match require_durable_reply(alias_write, task_write) {
                    Ok(paths) => paths,
                    Err(error) => {
                        eprintln!("{error}");
                        process::exit(1);
                    }
                };
            for error in write_errors {
                eprintln!("  Warning: one durable reply copy failed: {error}");
            }
            let result_path = task_result_path.as_ref().or(alias_result_path.as_ref());
            let summary = truncate_summary(&content, 1500);
            let mut msg_params = json!({
                "team_name": team, "from": sender, "content": summary,
                "to": "leader", "type": "report",
            });
            if let Some(path) = result_path {
                msg_params["result_path"] = json!(path.to_string_lossy());
            }
            // team.message.post — retry once on failure, but never exit: the
            // verdict was durably recorded in at least one alias/task result
            // file and
            // the task is completed afterward, so a transient inbox-post failure
            // must not abort the reply (which would skip task completion and hang
            // the leader's wait). Mirrors the team.report handling just below.
            run_best_effort_rpc_with_retry("team.message.post", || {
                rpc_call(&sock, "team.message.post", msg_params.clone())
            });
            // Auto-submit report for wait detection (with result_path)
            let mut report_params = json!({
                "team_name": team, "agent_name": sender, "content": summary,
                "task_id": reply_task_id,
                "agent_instance_id": reply_instance_id,
            });
            if let Some(path) = result_path {
                report_params["result_path"] = json!(path.to_string_lossy());
            }
            // team.report — retry once on failure (wait hangs permanently if this is lost)
            let report_result = rpc_call(&sock, "team.report", report_params.clone());
            if let Err(ref e) = report_result {
                eprintln!("  Warning: team.report failed: {e}, retrying...");
                let _ = rpc_call(&sock, "team.report", report_params);
            }
            // Auto-complete the active task for this agent.
            // Use team.task.list (data command, no MainActor) instead of team.status
            // (UI command, MainActor) to avoid timeout when main thread is busy —
            // a timeout here silently skips task completion, causing the leader's
            // `wait` to hang indefinitely.
            if let Some(tid) = reply_task_id.as_deref() {
                let mut update = json!({
                    "team_name": &team, "task_id": tid,
                    "status": task_status, "result": &summary,
                    "agent_instance_id": reply_instance_id,
                });
                // P2: use body-only text for detail fields, not the full header+body summary
                let detail: &str = if body_summary.trim().is_empty() {
                    match task_status {
                        "blocked" => "Blocked",
                        "review_ready" => "Ready for review",
                        _ => "",
                    }
                } else {
                    body_summary.as_str()
                };
                if task_status == "blocked" {
                    update["blocked_reason"] = json!(detail);
                } else if task_status == "review_ready" {
                    update["review_summary"] = json!(detail);
                }
                if let Some(path) = result_path {
                    update["result_path"] = json!(path.to_string_lossy());
                }
                // task.update — retry once on failure (task stays in_progress forever if lost)
                let update_result = rpc_call(&sock, "team.task.update", update.clone());
                if let Err(ref e) = update_result {
                    eprintln!("  Warning: task.update failed: {e}, retrying...");
                    let _ = rpc_call(&sock, "team.task.update", update);
                }
                eprintln!("closed task {tid} for {sender}");
            } else if is_stateless_watcher {
                // The stateless watcher delivered its verdict via the alias reply
                // file (the GUI watch path polls it); there is no task to close, so
                // this is success — not the exit-2 path non-watcher roles take when
                // a task they were expected to own is missing.
                eprintln!("watcher reply recorded (no task to close)");
            } else if let Some(message) = withheld_task {
                // The reply is on disk and in the leader's inbox by now; only the
                // transition was withheld, and the flag that resolves it is named
                // in `message`. Still exit 2 so a leader-side parser and the
                // agent both see that no task was closed.
                let err = json!({
                    "ok": false,
                    "error": {
                        "code": "ambiguous_active_task",
                        "message": format!("{message}; recorded the reply without closing a task"),
                        "sender": sender,
                    }
                });
                eprintln!("{}", pretty(&err));
                eprintln!("  Warning: reply for {sender} is {message}");
                process::exit(2);
            } else {
                // Emit a structured JSON error so leader-side parsers can
                // recognize the condition (and exit 2 to distinguish from
                // RPC/transport failures which already exit 1).
                let err = json!({
                    "ok": false,
                    "error": {
                        "code": "no_active_task",
                        "message": format!("no active task found for {sender}; wrote reply alias only"),
                        "sender": sender,
                    }
                });
                eprintln!("{}", pretty(&err));
                eprintln!("  Warning: no active task found for {sender}; wrote reply alias only");
                process::exit(2);
            }
            return;
        }
        Commands::Project(_)
        | Commands::Pairing(_)
        | Commands::Sync(_)
        | Commands::Conflict(_)
        | Commands::Gc(_) => unreachable!("project sync commands return before app socket routing"),
        Commands::Orchestrator(_) => {
            unreachable!("orchestrator commands return before app socket routing")
        }
    };

    print_result(result);
}

// ---------------------------------------------------------------------------
// gc — disk reclamation
// ---------------------------------------------------------------------------

/// Scanning walks whole worktrees, so the default 6s RPC budget is far too
/// tight for anything but `status` on a small machine.
const GC_TIMEOUT_SECS: u64 = 120;

fn gc_call(sock: &PathBuf, method: &str, params: Value) -> Result<Value, String> {
    decode_daemon_response(rpc_call_timeout(sock, method, params, GC_TIMEOUT_SECS)?)
}

fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "K", "M", "G", "T"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes}{}", UNITS[0])
    } else {
        format!("{value:.1}{}", UNITS[unit])
    }
}

fn gc_scope_params(categories: &[String], roots: &[String], deep: bool) -> Value {
    let mut params = json!({});
    if !categories.is_empty() {
        params["categories"] = json!(categories);
    }
    if !roots.is_empty() {
        params["roots"] = json!(roots);
    }
    if deep {
        params["deep"] = json!(true);
    }
    params
}

fn cmd_gc(sock: &PathBuf, command: &GcCommand) {
    let result = match command {
        GcCommand::Status { project, json: raw } => {
            let params = match project {
                Some(id) => json!({ "project_id": id }),
                None => json!({}),
            };
            gc_call(sock, "gc.status", params).map(|value| {
                if *raw {
                    println!("{}", pretty(&value));
                } else {
                    render_gc_status(&value);
                }
            })
        }
        GcCommand::Plan {
            categories,
            roots,
            deep,
            json: raw,
        } => gc_call(sock, "gc.plan", gc_scope_params(categories, roots, *deep)).map(|value| {
            if *raw {
                println!("{}", pretty(&value));
            } else {
                render_gc_plan(&value);
            }
        }),
        GcCommand::Sweep {
            apply,
            force,
            categories,
            roots,
            deep,
            json: raw,
        } => {
            let mut params = gc_scope_params(categories, roots, *deep);
            params["apply"] = json!(*apply);
            params["force"] = json!(*force);
            gc_call(sock, "gc.sweep", params).map(|value| {
                if *raw {
                    println!("{}", pretty(&value));
                } else {
                    render_gc_sweep(&value, *apply);
                }
            })
        }
    };

    if let Err(error) = result {
        eprintln!("Error: {error}");
        process::exit(1);
    }
}

fn render_gc_status(value: &Value) {
    let categories = value
        .get("categories")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    println!(
        "{:<20} {:>7} {:>10} {:>10} {:>11}  {}",
        "CATEGORY", "ENTRIES", "SIZE", "RECLAIM", "CANDIDATES", "SWEPT"
    );
    for category in &categories {
        let name = category
            .get("category")
            .and_then(Value::as_str)
            .unwrap_or("?");
        let entries = category
            .get("entry_count")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let total = category
            .get("total_bytes")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let reclaim = category
            .get("reclaimable_bytes")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let candidates = category
            .get("candidate_count")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let auto = category
            .get("auto")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        println!(
            "{:<20} {:>7} {:>10} {:>10} {:>11}  {}",
            name,
            entries,
            human_bytes(total),
            human_bytes(reclaim),
            candidates,
            if auto { "auto" } else { "manual" }
        );
    }

    let total = value
        .get("total_bytes")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let reclaim = value
        .get("reclaimable_bytes")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    println!();
    println!(
        "total {}  reclaimable {}",
        human_bytes(total),
        human_bytes(reclaim)
    );

    match value.get("last_sweep") {
        Some(sweep) if !sweep.is_null() => {
            println!(
                "last sweep: {} — removed {}, reclaimed {}",
                sweep.get("mode").and_then(Value::as_str).unwrap_or("?"),
                sweep.get("removed").and_then(Value::as_u64).unwrap_or(0),
                human_bytes(
                    sweep
                        .get("reclaimed_bytes")
                        .and_then(Value::as_u64)
                        .unwrap_or(0)
                )
            );
        }
        _ => println!("last sweep: never"),
    }
    println!("run `tm-agent gc plan` for the candidate list");
}

fn render_gc_plan(value: &Value) {
    let categories = value
        .get("categories")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    for category in &categories {
        let candidates = category
            .get("candidates")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if candidates.is_empty() {
            continue;
        }
        let name = category
            .get("category")
            .and_then(Value::as_str)
            .unwrap_or("?");
        println!("── {name}");
        if let Some(note) = category.get("note").and_then(Value::as_str) {
            println!("   ({note})");
        }
        for candidate in &candidates {
            let path = candidate.get("path").and_then(Value::as_str).unwrap_or("?");
            let bytes = candidate.get("bytes").and_then(Value::as_u64).unwrap_or(0);
            let blockers = candidate
                .get("blockers")
                .and_then(Value::as_array)
                .map(|list| {
                    list.iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(",")
                })
                .unwrap_or_default();
            let marker = if blockers.is_empty() { "✓" } else { "✗" };
            let detail = if blockers.is_empty() {
                candidate
                    .get("reasons")
                    .and_then(Value::as_array)
                    .map(|list| {
                        list.iter()
                            .filter_map(Value::as_str)
                            .collect::<Vec<_>>()
                            .join(",")
                    })
                    .unwrap_or_default()
            } else {
                format!("blocked: {blockers}")
            };
            println!("   {marker} {:>8}  {path}", human_bytes(bytes));
            if !detail.is_empty() {
                println!("              {detail}");
            }
        }
        println!();
    }

    let reclaim = value
        .get("reclaimable_bytes")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    println!("reclaimable {}", human_bytes(reclaim));
    println!("`tm-agent gc sweep` previews the removal; add --apply to perform it");
}

fn render_gc_sweep(value: &Value, applied: bool) {
    let outcomes = value
        .get("outcomes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    for outcome in &outcomes {
        let action = outcome.get("action").and_then(Value::as_str).unwrap_or("?");
        if action == "skipped" {
            continue;
        }
        println!(
            "{:<13} {:>8}  {}",
            action,
            human_bytes(outcome.get("bytes").and_then(Value::as_u64).unwrap_or(0)),
            outcome.get("path").and_then(Value::as_str).unwrap_or("?")
        );
    }

    let removed = value.get("removed").and_then(Value::as_u64).unwrap_or(0);
    let skipped = value.get("skipped").and_then(Value::as_u64).unwrap_or(0);
    let reclaimed = value
        .get("reclaimed_bytes")
        .and_then(Value::as_u64)
        .unwrap_or(0);

    println!();
    println!(
        "{} item(s), {} — {} skipped by blockers",
        removed,
        human_bytes(reclaimed),
        skipped
    );
    if !applied {
        println!("(dry-run — pass --apply to delete)");
    }
}

/// Say so when this binary and the app it just failed to talk to are from
/// different builds.
///
/// A stale CLI fails in whatever way its own generation failed: a 0.167.0
/// `tm-agent` driving a 0.170.x app answered every leader-scoped command with
/// `noMatchingLeaderSession` — a name that exists nowhere in the current tree,
/// so the message pointed at nothing and the team simply never received an
/// instruction. Nothing in that failure suggested the binary was the problem,
/// and the binary was the whole problem.
///
/// This runs only on the failure path, so the check costs nothing when things
/// work, and it stays quiet unless the two builds actually disagree — a
/// version line printed under every unrelated error would train people to
/// scroll past it.
fn eprint_version_skew() {
    let Some(sock) = detect_socket() else { return };
    let Ok(info) = rpc_call(&sock, "system.info", json!({})) else {
        return;
    };
    if let Some(note) = version_skew_note(
        GIT_SHA,
        info["result"]["git_sha"].as_str().unwrap_or_default(),
        env!("CARGO_PKG_VERSION"),
        info["result"]["app_version"].as_str().unwrap_or("unknown"),
    ) {
        eprintln!("{note}");
    }
}

/// The note for a CLI and an app built from different commits, or `None` when
/// they agree — or when the app did not say, which is not evidence of skew and
/// must not be reported as one.
fn version_skew_note(
    cli_sha: &str,
    app_sha: &str,
    cli_version: &str,
    app_version: &str,
) -> Option<String> {
    if app_sha.is_empty() || app_sha == cli_sha {
        return None;
    }
    Some(format!(
        "\nThis tm-agent is {} ({}), the term-mesh app is {} ({}).\n\
         Different builds: the command above may have failed for that reason \
         alone. Check which binary is running with `command -v tm-agent` — an \
         older copy earlier in PATH shadows a current one.",
        cli_version,
        short_sha(cli_sha),
        app_version,
        short_sha(app_sha),
    ))
}

fn short_sha(sha: &str) -> &str {
    if sha.len() > 9 {
        &sha[..9]
    } else {
        sha
    }
}

/// Parse a `tm-agent daemon replay-capacity --set` value: a plain byte
/// count, or a byte count with a `k`/`kb` (KiB, ×1024) or `m`/`mb` (MiB,
/// ×1024²) suffix — case-insensitive (e.g. `262144`, `256kb`, `2mb`, `2M`).
fn parse_byte_size(raw: &str) -> Result<usize, String> {
    let s = raw.trim();
    if s.is_empty() {
        return Err("empty value".to_string());
    }
    let lower = s.to_ascii_lowercase();
    let (digits, multiplier) =
        if let Some(prefix) = lower.strip_suffix("kb").or_else(|| lower.strip_suffix('k')) {
            (prefix, 1024usize)
        } else if let Some(prefix) = lower.strip_suffix("mb").or_else(|| lower.strip_suffix('m')) {
            (prefix, 1024usize * 1024)
        } else {
            (lower.as_str(), 1usize)
        };
    let n: usize = digits
        .trim()
        .parse()
        .map_err(|e| format!("invalid byte size {raw:?}: {e}"))?;
    n.checked_mul(multiplier)
        .ok_or_else(|| format!("byte size overflow: {raw:?}"))
}

/// One daemon RPC: the `result` value, or the transport/RPC error message.
fn cmd_daemon_rpc(
    sock: &PathBuf,
    method: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value, String> {
    // Forced prune waits for each selected process group to stop.
    let response = if method == "peer.project_presentations.prune"
        && params["force"] == true
        && params["apply"] == true
    {
        let timeout = env::var("TERMMESH_RPC_TIMEOUT")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(120);
        rpc_call_timeout(sock, method, params, timeout)
    } else {
        rpc_call(sock, method, params)
    };
    match response {
        Ok(resp) if resp["error"].is_null() => Ok(resp["result"].clone()),
        Ok(resp) => Err(resp["error"]["message"]
            .as_str()
            .map(str::to_string)
            .unwrap_or_else(|| format!("{method} failed"))),
        Err(e) => Err(e.to_string()),
    }
}

/// Print a daemon RPC result, or the error and a non-zero exit so scripts
/// can trust the status. Returns the result for callers adding a summary.
fn cmd_daemon_rpc_print(
    sock: &PathBuf,
    method: &str,
    params: serde_json::Value,
) -> serde_json::Value {
    match cmd_daemon_rpc(sock, method, params) {
        Ok(result) => {
            println!("{}", pretty(&result));
            result
        }
        Err(msg) => {
            eprintln!("Error: {msg}");
            process::exit(1);
        }
    }
}

/// The peer state directory term-meshd writes.
///
/// Mirrors `peer::persist::default_workspaces_path`'s base deliberately: that
/// function reads no environment variable, so every daemon on this machine —
/// tagged dev builds included — shares one directory, and an offline reset has
/// exactly one place to look.
fn peer_state_dir() -> std::path::PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("/tmp"))
        .join("term-meshd")
}

/// Which files a scope covers. Ensured-surface records are never included:
/// losing those costs runner identity, not a stale name.
fn peer_state_files(scope: &str) -> Vec<(&'static str, std::path::PathBuf)> {
    let dir = peer_state_dir();
    let mut out = Vec::new();
    if scope == "projects" || scope == "all" {
        out.push(("projects", dir.join("peer-project-presentations.json")));
    }
    if scope == "workspaces" || scope == "all" {
        out.push(("workspaces", dir.join("peer-workspaces.json")));
    }
    out
}

/// Take `.peer-state.lock` exclusively. Failing is the answer to "is a daemon
/// still running": one holds this shared for the life of its listener, and
/// rewriting these files under it would just be saved over by its next write.
fn try_lock_peer_state_dir(dir: &std::path::Path) -> std::io::Result<std::fs::File> {
    use std::os::fd::AsRawFd;

    std::fs::create_dir_all(dir)?;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(dir.join(".peer-state.lock"))?;
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(file)
}

/// Copy `path` next to itself before removing it, matching the daemon's
/// `persist::backup_state_file` naming so both paths leave the same trail.
fn backup_peer_state_file(path: &std::path::Path) -> Result<Option<String>, String> {
    if !path.exists() {
        return Ok(None);
    }
    let stem = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .ok_or_else(|| format!("cannot derive a backup name for {}", path.display()))?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0);
    let mut candidate = path.with_file_name(format!("{stem}.{stamp}.bak.json"));
    let mut suffix = 1;
    while candidate.exists() {
        if suffix > 1000 {
            return Err(format!("too many backups beside {}", path.display()));
        }
        candidate = path.with_file_name(format!("{stem}.{stamp}-{suffix}.bak.json"));
        suffix += 1;
    }
    std::fs::copy(path, &candidate).map_err(|e| format!("backup failed: {e}"))?;
    Ok(Some(candidate.display().to_string()))
}

/// Reset with no daemon to ask.
///
/// This cannot tell a live surface from a dead one, so it does not try to be
/// selective: it backs each file up and removes it, which the loaders treat
/// exactly like an empty file. The daemon path (`peer.state.reset`) is the one
/// that refuses live work — prefer it whenever the daemon is up.
fn cmd_daemon_reset_offline(scope: &str, apply: bool) -> ! {
    let dir = peer_state_dir();
    let files = peer_state_files(scope);

    let lock = match try_lock_peer_state_dir(&dir) {
        Ok(lock) => lock,
        Err(error) => {
            eprintln!(
                "Error: {} is still owned by a running term-meshd ({error}).\n\
                 Stop it first (systemctl stop term-meshd, or quit the app), or run this\n\
                 with the daemon up so it can clear its in-memory copy too.",
                dir.display()
            );
            // Same class as `watch doctor`'s \"tried and it is still wrong\".
            process::exit(3);
        }
    };

    let mut entries = Vec::new();
    for (scope_name, path) in &files {
        entries.push(json!({
            "scope": scope_name,
            "path": path.display().to_string(),
            "present": path.exists(),
        }));
    }

    if !apply {
        let present = files.iter().filter(|(_, path)| path.exists()).count();
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "applied": false,
                "daemon": "not running",
                "files": entries,
            }))
            .unwrap_or_default()
        );
        if present > 0 {
            println!("(dry-run — pass --apply to clear {present} file(s))");
        }
        drop(lock);
        process::exit(0);
    }

    // `scope=all` clears two files, so a failure on the second one leaves the
    // first already gone. Exiting inside the loop would take the `cleared`
    // list with it — including the backup path that is the only way back — so
    // failures are collected and reported next to what did get removed.
    let mut cleared = Vec::new();
    let mut failed = Vec::new();
    for (scope_name, path) in &files {
        if !path.exists() {
            continue;
        }
        let backup = match backup_peer_state_file(path) {
            Ok(backup) => backup,
            Err(error) => {
                failed.push(json!({
                    "scope": scope_name,
                    "path": path.display().to_string(),
                    "error": error,
                }));
                continue;
            }
        };
        if let Err(error) = std::fs::remove_file(path) {
            failed.push(json!({
                "scope": scope_name,
                "path": path.display().to_string(),
                "backup_path": backup,
                "error": format!("could not remove: {error}"),
            }));
            continue;
        }
        cleared.push(json!({
            "scope": scope_name,
            "path": path.display().to_string(),
            "backup_path": backup,
        }));
    }

    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            // What ran, not what qualified: an --apply that found nothing to
            // clear still ran, and `cleared` says it removed nothing.
            "applied": true,
            "daemon": "not running",
            "directory": dir.display().to_string(),
            "cleared": cleared,
            "failed": failed,
        }))
        .unwrap_or_default()
    );
    for failure in &failed {
        eprintln!(
            "Error: {} — {}",
            failure["path"].as_str().unwrap_or("?"),
            failure["error"].as_str().unwrap_or("?")
        );
    }
    let exit_code = if failed.is_empty() { 0 } else { 1 };
    drop(lock);
    process::exit(exit_code);
}

/// `tm-agent daemon replay-capacity [--set <value>]` — get or set the peer
/// PTY-surface replay buffer capacity via the `peer.replay_capacity` RPC.
fn cmd_daemon_replay_capacity(sock: &PathBuf, set: Option<&str>) {
    let params = match set {
        Some(raw) => match parse_byte_size(raw) {
            Ok(bytes) => json!({ "bytes": bytes }),
            Err(e) => {
                eprintln!("Error: {e}");
                process::exit(1);
            }
        },
        None => json!({}),
    };
    match rpc_call(sock, "peer.replay_capacity", params) {
        Ok(resp) if resp["error"].is_null() => {
            println!("{}", pretty(&resp["result"]));
        }
        Ok(resp) => {
            let msg = resp["error"]["message"]
                .as_str()
                .unwrap_or("peer.replay_capacity failed");
            eprintln!("Error: {msg}");
            process::exit(1);
        }
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    }
}

#[cfg(test)]
mod daemon_replay_capacity_tests {
    use super::*;

    #[test]
    fn reply_task_identity_rejects_same_name_sibling() {
        let task = json!({
            "assignee": "executor",
            "agent_instance_id": "instance-a",
        });
        assert_eq!(
            task_instance_for_reply(&task, "task-a", "executor", Some("instance-a")).unwrap(),
            Some("instance-a".to_string())
        );
        assert!(task_instance_for_reply(&task, "task-a", "executor", Some("instance-b")).is_err());
    }

    #[test]
    fn parse_byte_size_plain_digits() {
        assert_eq!(parse_byte_size("262144"), Ok(262144));
    }

    #[test]
    fn parse_byte_size_kb_and_k_suffix() {
        assert_eq!(parse_byte_size("256kb"), Ok(256 * 1024));
        assert_eq!(parse_byte_size("256KB"), Ok(256 * 1024));
        assert_eq!(parse_byte_size("256k"), Ok(256 * 1024));
        assert_eq!(parse_byte_size("256K"), Ok(256 * 1024));
    }

    #[test]
    fn parse_byte_size_mb_and_m_suffix() {
        assert_eq!(parse_byte_size("2mb"), Ok(2 * 1024 * 1024));
        assert_eq!(parse_byte_size("2MB"), Ok(2 * 1024 * 1024));
        assert_eq!(parse_byte_size("2m"), Ok(2 * 1024 * 1024));
        assert_eq!(parse_byte_size("2M"), Ok(2 * 1024 * 1024));
    }

    #[test]
    fn parse_byte_size_trims_whitespace() {
        assert_eq!(parse_byte_size(" 2mb \n"), Ok(2 * 1024 * 1024));
    }

    #[test]
    fn parse_byte_size_rejects_garbage_and_empty() {
        assert!(parse_byte_size("").is_err());
        assert!(parse_byte_size("not-a-number").is_err());
        assert!(parse_byte_size("kb").is_err()); // suffix with no digits
    }
}

fn run_recycle(sock: &PathBuf, team: &str, target: &str, force: bool) {
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

// ── watch doctor: phantom watcher diagnose + repair ─────────────────
//
// Design: ~/.term-mesh/results/term-mesh/ai-watch-doctor-design.md
// Captures the liveness-probe + phantom-repair procedure (previously hand-run
// prose in watch.md) as one deterministic primitive. All team.* RPCs ride the
// *app* (Swift) socket; no new RPCs are introduced — only existing team.read /
// team.status / team.detach / team.attach / team.add_agent are reused.

/// Liveness verdict for a watcher pane, used by `run_watch_doctor`.
enum WatcherProbe {
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
fn probe_watcher(app_sock: &PathBuf, team: &str, watcher: &str) -> WatcherProbe {
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
fn read_watcher_cli_model(
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
fn doctor_emit(out: &Value, code: i32) -> ! {
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
fn run_watch_doctor(
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

// ── Session picker ──────────────────────────────────────────────────

/// A Claude Code session entry parsed from the project session directory.
struct SessionEntry {
    id: String,
    modified: std::time::SystemTime,
    first_message: String,
    last_message: String,
}

/// Discover the Claude Code sessions directory for the current working directory.
fn claude_sessions_dir() -> Option<PathBuf> {
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
fn list_recent_sessions(limit: usize) -> Vec<SessionEntry> {
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
fn extract_text_from_entry(val: &Value) -> String {
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
fn extract_messages(path: &PathBuf) -> (String, String) {
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
fn format_relative_time(time: std::time::SystemTime) -> String {
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
fn pick_session() -> String {
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
fn resolve_resume_session(flag: Option<Option<String>>) -> Option<String> {
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
fn resolve_watcher_spec(spec: Option<&str>) -> Result<Option<String>, String> {
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
fn apply_watcher_spec(agents: &mut [serde_json::Value], watcher_spec: Option<&str>) {
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

fn run_create(
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

fn is_auto_watch_disabled_by_env() -> bool {
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
struct AutoWatchAgent {
    name: String,
    agent_type: String,
    cli: String,
    model: String,
}

/// Decision returned by `auto_watch_decision`.
#[derive(Debug, PartialEq)]
enum AutoWatchDecision {
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
fn auto_watch_decision(agents: &[AutoWatchAgent], spec_exists: bool) -> AutoWatchDecision {
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
enum WatchOnOutcome {
    Enabled,
    Failed(String),
    Unexpected(String),
}

/// Classify a watch.on JSON-RPC response for unit testing without RPC mocking.
fn parse_watch_on_response(r: &serde_json::Value) -> WatchOnOutcome {
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
fn apply_auto_watch(team_name: &str, working_dir: &std::path::Path, decision: AutoWatchDecision) {
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
fn roster_from_gui_status(agents: &[Value]) -> Vec<AutoWatchAgent> {
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
fn roster_from_headless_specs(specs: &[Value]) -> Vec<AutoWatchAgent> {
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
fn roster_from_headless_daemon(daemon_sock: &PathBuf, team_name: &str) -> Vec<AutoWatchAgent> {
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

fn run_auto_watch_if_enabled(
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
fn maybe_auto_watch_after_team_change(
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
fn maybe_auto_watch_after_headless_create(
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
fn maybe_auto_watch_after_headless_add(
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
fn validate_agent_name(name: &str) -> Result<(), String> {
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
enum TeamNameSource {
    Explicit,
    Environment,
    Workspace,
    LiveTeamFallback,
}

#[derive(Debug, PartialEq, Eq)]
struct TeamNameResolution {
    name: String,
    source: TeamNameSource,
}

const LIVE_TEAM_FALLBACK_WARNING: &str = "Warning: no --team, TERMMESH_TEAM, or usable TERMMESH_WORKSPACE_ID; falling back to live-team. Pass --team <name> to select a team explicitly.";

fn resolve_team_name_inputs(
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

fn resolve_team_name_with_source(explicit: Option<&str>) -> TeamNameResolution {
    let environment = env::var("TERMMESH_TEAM").ok();
    // resolve_workspace_team_name re-checks TERMMESH_TEAM (already handled by
    // `resolve_team_name_inputs`) and otherwise derives ws-<hex>; errors are
    // intentionally reduced to absence so diagnostics never expose env values.
    let workspace = resolve_workspace_team_name().ok();
    resolve_team_name_inputs(explicit, environment.as_deref(), workspace.as_deref())
}

fn resolve_team_name(explicit: Option<&str>) -> String {
    let resolution = resolve_team_name_with_source(explicit);
    if resolution.source == TeamNameSource::LiveTeamFallback {
        eprintln!("{LIVE_TEAM_FALLBACK_WARNING}");
    }
    resolution.name
}

fn resolve_workspace_team_name() -> Result<String, String> {
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
fn require_termmesh_context() -> Result<(String, String, Option<String>), String> {
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
fn run_attach(sock: &PathBuf, agent_type: &str, agent_name: &str, model: &str, cli: &str) {
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
fn run_detach(
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
fn run_add_gui(
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
fn run_remove_gui(
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

/// Does this socket path look like the term-mesh *app* socket rather than the
/// term-meshd daemon socket? App sockets are `term-mesh*.sock` (no trailing `d`)
/// or `cmux.sock`; the daemon is `term-meshd*.sock`. Used to keep daemon RPCs off
/// the app socket.
fn is_app_socket_path(path: &Path) -> bool {
    match path.file_name().and_then(|n| n.to_str()) {
        Some(name) => {
            name == "cmux.sock"
                || (name.starts_with("term-mesh") && !name.starts_with("term-meshd"))
        }
        None => false,
    }
}

/// Resolve the app (Swift) socket for watch's GUI execution path (§4 pane
/// recycle). The daemon needs it to drive recycle/send/read on a GUI watcher
/// pane; without it the GUI path can't run and watch falls back to the headless
/// one-shot. Priority: an explicit value, then an app `TERMMESH_SOCKET`, then an
/// auto-detected *app* socket (a detected daemon socket is rejected — the
/// `watch on` caller's leader pane may lack TERMMESH_SOCKET, so detection covers
/// it). Returns None for pure-headless callers, which keeps the headless path.
fn resolve_app_socket(explicit: Option<&str>) -> Option<String> {
    if let Some(e) = explicit {
        let p = PathBuf::from(e);
        if !e.is_empty() && is_app_socket_path(&p) && is_socket_alive(&p) {
            return Some(e.to_string());
        }
    }
    if let Ok(ts) = env::var("TERMMESH_SOCKET") {
        let p = PathBuf::from(&ts);
        if !ts.is_empty() && is_app_socket_path(&p) && is_socket_alive(&p) {
            return Some(ts);
        }
    }
    detect_socket()
        .filter(|p| is_app_socket_path(p))
        .map(|p| p.to_string_lossy().into_owned())
}

/// Derive this app instance's term-meshd socket from its *app* socket path (P15).
///
/// Mirrors `scripts/reload.sh`: a tagged app socket `/tmp/term-mesh-debug-<tag>.sock`
/// is served by daemon `~/Library/Application Support/term-mesh/term-meshd-dev-<tag>.sock`.
/// Returns `None` for the live/untagged app socket so it falls through to the
/// default daemon — preserving instance isolation (a tagged leader never derives
/// the live daemon, and the live leader keeps using the default).
fn derive_daemon_socket_from_app(app_path: &Path) -> Option<PathBuf> {
    let name = app_path.file_name().and_then(|n| n.to_str())?;
    // Only the tagged debug app socket maps to an isolated Application Support daemon.
    let tag = name
        .strip_prefix("term-mesh-debug-")
        .and_then(|rest| rest.strip_suffix(".sock"))
        .filter(|t| !t.is_empty())?;
    let home = env::var("HOME").ok().filter(|h| !h.is_empty())?;
    Some(
        PathBuf::from(home)
            .join("Library/Application Support/term-mesh")
            .join(format!("term-meshd-dev-{tag}.sock")),
    )
}

/// Resolve the term-meshd socket for `tm-agent watch` (P12 #4, P15 routing).
///
/// Priority:
/// 1. `TERMMESH_DAEMON_SOCKET` / `TERMMESH_DAEMON_UNIX_PATH` (the app injects the
///    latter into every pane env, so a leader pane reaches its own daemon).
/// 2. `TERMMESH_SOCKET` when it is itself a *daemon* socket (tagged standalone).
/// 3. `TERMMESH_SOCKET` when it is an *app* socket → derive this instance's daemon
///    socket from it (P15: `TERMMESH_SOCKET`-only routing, isolation-preserving).
/// 4. the default daemon socket.
/// 5. any live socket as a last resort.
///
/// The app-socket guard at steps 2/3 keeps a leader pane from misrouting `watch.*`
/// to the app socket (which returns method_not_found) while still reaching the
/// correct per-instance daemon.
fn detect_watch_socket() -> Option<PathBuf> {
    // Highest priority (F1): an explicit *app-socket* TERMMESH_SOCKET is a deliberate
    // instance selection. Derive its daemon and use it, overriding the ambient
    // TERMMESH_DAEMON_* env (which reflects the *calling pane's* default instance,
    // not the explicitly chosen one). Without this, running `tm-agent watch …` with
    // an explicit TERMMESH_SOCKET from inside another instance's pane misroutes the
    // watch (and its ticks) to the wrong/stale daemon. Only applies when the app
    // socket is derivable (tagged) and its daemon is alive; otherwise fall through.
    if let Ok(p) = env::var("TERMMESH_SOCKET") {
        if !p.is_empty() {
            let path = PathBuf::from(&p);
            if is_socket_alive(&path) && is_app_socket_path(&path) {
                if let Some(derived) = derive_daemon_socket_from_app(&path) {
                    if is_socket_alive(&derived) {
                        return Some(derived);
                    }
                }
            }
        }
    }
    for var in ["TERMMESH_DAEMON_SOCKET", "TERMMESH_DAEMON_UNIX_PATH"] {
        if let Ok(p) = env::var(var) {
            if !p.is_empty() {
                let path = PathBuf::from(&p);
                if is_socket_alive(&path) {
                    return Some(path);
                }
            }
        }
    }
    if let Ok(p) = env::var("TERMMESH_SOCKET") {
        if !p.is_empty() {
            let path = PathBuf::from(&p);
            if is_socket_alive(&path) {
                // Explicit daemon socket → use directly.
                if !is_app_socket_path(&path) {
                    return Some(path);
                }
                // App socket → derive this instance's daemon (P15).
                if let Some(derived) = derive_daemon_socket_from_app(&path) {
                    if is_socket_alive(&derived) {
                        return Some(derived);
                    }
                }
            }
        }
    }
    // Default daemon socket, then every other place a daemon binds one.
    daemon_socket_candidates()
        .into_iter()
        .find(is_socket_alive)
        // Last resort: any socket the generic resolver finds.
        .or_else(detect_socket)
}

/// `TERMMESH_DAEMON_UNIX_PATH` as the peer-host config records it.
///
/// systemd hands this file to the service through `EnvironmentFile`, so the
/// daemon binds what it says while a login shell never sees the value. That
/// is the whole reason a Linux operator had to export the variable by hand
/// before `tm-agent` could reach their own daemon.
///
/// Later files win, matching the `tail -n 1` the ssh probe applies over the
/// same two paths.
fn peer_env_daemon_sockets_from_paths(configs: &[PathBuf]) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for config in configs {
        let Ok(contents) = std::fs::read_to_string(&config) else {
            continue;
        };
        for line in contents.lines() {
            let Some(value) = line.trim().strip_prefix("TERMMESH_DAEMON_UNIX_PATH=") else {
                continue;
            };
            let value = value.trim().trim_matches(['"', '\''].as_slice());
            if !value.is_empty() {
                let path = PathBuf::from(value);
                found.retain(|existing| existing != &path);
                found.insert(0, path);
            }
        }
    }
    found
}

fn peer_env_daemon_sockets() -> Vec<PathBuf> {
    let mut configs = Vec::new();
    if let Some(home) = env::var_os("HOME") {
        configs.push(PathBuf::from(home).join(".config/term-mesh/peer.env"));
    }
    configs.push(PathBuf::from("/etc/term-mesh/peer.env"));
    peer_env_daemon_sockets_from_paths(&configs)
}

/// Every place a term-meshd control socket can live, in the order to try.
///
/// The daemon's own `default_socket_path` resolves `dirs::runtime_dir()`
/// before `TMPDIR`. On Linux that is `$XDG_RUNTIME_DIR` — a directory this
/// resolver never looked in — while on macOS there is no runtime dir at all
/// and the daemon lands in `TMPDIR`. That asymmetry, not any Linux-specific
/// packaging, is why the CLI needed no environment on a Mac and needed
/// `TERMMESH_DAEMON_UNIX_PATH` exported by hand on every Linux host.
///
/// The installer's two scopes add the rest: a user service binds
/// `/run/user/<uid>/term-meshd.sock`, a system service
/// `/run/term-mesh/term-meshd.sock`.
///
/// Same paths and same order as `REMOTE_CONTROL_SOCKET_DISCOVERY` in
/// `peer.rs`, which has always resolved this correctly over ssh. A path that
/// cannot exist on this platform fails the liveness probe on its first
/// syscall, so one list serves both rather than a per-OS pair that can drift.
fn daemon_socket_candidates() -> Vec<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    let mut push = |path: PathBuf| {
        if !path.as_os_str().is_empty() && !candidates.contains(&path) {
            candidates.push(path);
        }
    };
    for var in ["TERMMESH_DAEMON_SOCKET", "TERMMESH_DAEMON_UNIX_PATH"] {
        if let Ok(value) = env::var(var) {
            push(PathBuf::from(value));
        }
    }
    for path in peer_env_daemon_sockets() {
        push(path);
    }
    if let Ok(runtime_dir) = env::var("XDG_RUNTIME_DIR") {
        if !runtime_dir.is_empty() {
            push(PathBuf::from(runtime_dir).join("term-meshd.sock"));
        }
    }
    // `id -u` without spawning it: the ssh probe's `/run/user/$(id -u)` for a
    // user-scope service whose XDG_RUNTIME_DIR did not reach this shell.
    push(PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() })).join("term-meshd.sock"));
    push(PathBuf::from("/run/term-mesh/term-meshd.sock"));
    if let Ok(tmpdir) = env::var("TMPDIR") {
        if !tmpdir.is_empty() {
            push(PathBuf::from(tmpdir).join("term-meshd.sock"));
        }
    }
    push(PathBuf::from("/tmp/term-meshd.sock"));
    candidates
}

fn detect_daemon_socket() -> Option<PathBuf> {
    daemon_socket_candidates().into_iter().find(is_socket_alive)
}

/// The daemon whose headless agents are members of this process's team. A
/// remote leader's team lives on the owning host, so a same-name headless team
/// on this host's daemon is unrelated and must never be resolved.
fn team_headless_daemon_socket() -> Option<PathBuf> {
    headless_daemon_socket_for_route(remote_leader_route().is_some(), detect_daemon_socket)
}

fn headless_daemon_socket_for_route(
    has_route: bool,
    detect: impl FnOnce() -> Option<PathBuf>,
) -> Option<PathBuf> {
    if has_route {
        return None;
    }
    detect()
}

#[derive(Debug, Clone)]
enum DoctorSocketOutcome {
    Report(Vec<Value>),
    Unsupported(String),
    RpcFailed(String),
    ProbeFailed(String),
    Untrusted(String),
}

fn parse_doctor_result(result: Value) -> Result<Vec<Value>, String> {
    let object = result
        .as_object()
        .ok_or_else(|| "protocol error: peer.doctor result is not an object".to_string())?;
    let healthy = object
        .get("healthy")
        .and_then(Value::as_bool)
        .ok_or_else(|| "protocol error: peer.doctor result has no boolean healthy".to_string())?;
    let findings = object
        .get("findings")
        .and_then(Value::as_array)
        .cloned()
        .ok_or_else(|| "protocol error: peer.doctor result has no findings array".to_string())?;
    if healthy != findings.is_empty() {
        return Err("protocol error: peer.doctor healthy disagrees with findings".to_string());
    }
    Ok(findings)
}

fn local_doctor_finding(code: &str, socket: &Path, detail: String) -> Value {
    json!({
        "code": code,
        "severity": "error",
        "socket": socket.display().to_string(),
        "detail": detail,
        "remedy": "",
        "repair_argv": [],
    })
}

fn safe_inspect_repair() -> (String, Vec<Value>) {
    let argv = vec![
        Value::String("tm-agent".into()),
        Value::String("daemon".into()),
        Value::String("project-presentations".into()),
        Value::String("list".into()),
    ];
    (
        "'tm-agent' 'daemon' 'project-presentations' 'list'".into(),
        argv,
    )
}

fn with_multiple_daemon_repair_withheld(mut finding: Value) -> Value {
    let repair_argv = finding["repair_argv"].as_array();
    let applied = repair_argv
        .and_then(|argv| argv.last())
        .and_then(Value::as_str)
        == Some("--apply");
    let legacy_nonempty_remedy = repair_argv.is_none_or(Vec::is_empty)
        && finding["remedy"]
            .as_str()
            .is_some_and(|remedy| !remedy.is_empty());
    if !applied && !legacy_nonempty_remedy {
        return finding;
    }
    if let Some(object) = finding.as_object_mut() {
        let detail = object
            .get("detail")
            .and_then(Value::as_str)
            .unwrap_or_default();
        object.insert(
            "detail".into(),
            Value::String(format!(
                "{detail}; applied repair is withheld because multiple daemons are live and the source socket must be resolved first"
            )),
        );
        let (remedy, argv) = safe_inspect_repair();
        object.insert("remedy".into(), Value::String(remedy));
        object.insert("repair_argv".into(), Value::Array(argv));
    }
    finding
}

fn doctor_is_complete(outcomes: &[(PathBuf, DoctorSocketOutcome)]) -> bool {
    outcomes
        .iter()
        .any(|(_, outcome)| matches!(outcome, DoctorSocketOutcome::Report(_)))
        && !outcomes.iter().any(|(_, outcome)| {
            matches!(
                outcome,
                DoctorSocketOutcome::Unsupported(_)
                    | DoctorSocketOutcome::RpcFailed(_)
                    | DoctorSocketOutcome::ProbeFailed(_)
            )
        })
}

fn doctor_exit_code(outcomes: &[(PathBuf, DoctorSocketOutcome)], findings: &[Value]) -> i32 {
    if !doctor_is_complete(outcomes) {
        1
    } else if findings.is_empty() {
        0
    } else {
        2
    }
}

fn human_remedy(finding: &Value) -> String {
    let has_control = finding["repair_argv"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .any(|argument| argument.chars().any(char::is_control));
    if has_control {
        "unavailable in human output; inspect --json".into()
    } else {
        terminal_safe(finding["remedy"].as_str().unwrap_or_default())
    }
}

fn human_remedy_line(finding: &Value) -> Option<String> {
    let remedy = finding["remedy"].as_str().unwrap_or_default();
    if remedy.is_empty() {
        None
    } else {
        Some(human_remedy(finding))
    }
}

fn aggregate_doctor_findings(outcomes: &[(PathBuf, DoctorSocketOutcome)]) -> Vec<Value> {
    let trusted: Vec<_> = outcomes
        .iter()
        .filter(|(_, outcome)| {
            !matches!(
                outcome,
                DoctorSocketOutcome::ProbeFailed(_) | DoctorSocketOutcome::Untrusted(_)
            )
        })
        .collect();
    let connected_count = outcomes
        .iter()
        .filter(|(_, outcome)| !matches!(outcome, DoctorSocketOutcome::ProbeFailed(_)))
        .count();
    let mut findings = Vec::new();
    if trusted.len() > 1 {
        let paths = trusted
            .iter()
            .map(|(path, _)| path.display().to_string())
            .collect::<Vec<_>>();
        findings.push(json!({
            "code": "multiple_daemon_owners",
            "severity": "error",
            "detail": format!(
                "{} trusted term-meshd sockets are listening ({})",
                paths.len(),
                paths.join(", ")
            ),
            "remedy": "stop every term-meshd but the intended owner, then restart it",
            "repair_argv": [],
        }));
    }
    let connected_ambiguity = connected_count > 1;
    for (path, outcome) in outcomes {
        match outcome {
            DoctorSocketOutcome::Report(reported) => {
                for finding in reported {
                    let mut finding = finding.clone();
                    if let Some(object) = finding.as_object_mut() {
                        object.insert("socket".into(), Value::String(path.display().to_string()));
                    }
                    findings.push(if connected_ambiguity {
                        with_multiple_daemon_repair_withheld(finding)
                    } else {
                        finding
                    });
                }
            }
            DoctorSocketOutcome::Unsupported(message) => {
                findings.push(local_doctor_finding(
                    "doctor_unsupported",
                    path,
                    format!("the daemon does not support peer.doctor: {message}"),
                ));
            }
            DoctorSocketOutcome::RpcFailed(message) => {
                findings.push(local_doctor_finding(
                    "doctor_rpc_failed",
                    path,
                    format!("peer.doctor failed: {message}"),
                ));
            }
            DoctorSocketOutcome::ProbeFailed(message) => findings.push(local_doctor_finding(
                "socket_probe_failed",
                path,
                message.clone(),
            )),
            DoctorSocketOutcome::Untrusted(message) => findings.push(local_doctor_finding(
                "untrusted_socket_owner",
                path,
                message.clone(),
            )),
        }
    }
    findings
}

fn daemon_rpc_on_stream(stream: &UnixStream) -> Result<Value, String> {
    stream.set_read_timeout(Some(Duration::from_secs(6))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(6))).ok();
    let mut reader = BufReader::new(stream);
    let response = rpc_call_with_reader(stream, &mut reader, "peer.doctor", json!({}))?;
    if response["error"].is_null() {
        Ok(response["result"].clone())
    } else {
        Err(response["error"]["message"]
            .as_str()
            .unwrap_or("peer.doctor failed")
            .to_string())
    }
}

/// `tm-agent daemon doctor`: report, never repair.
///
/// Probes the whole candidate list rather than stopping at the first live
/// socket the way [`detect_daemon_socket`] does. Which one a client picks is
/// exactly the thing being checked: a host was found running one daemon under
/// systemd and a second, left from a `--help` invocation weeks earlier, still
/// listening on the runtime-dir default. Every client silently chose one of
/// them.
/// Probe every candidate socket once and keep what each one answered.
///
/// Split out of `cmd_daemon_doctor` so the interactive picker diagnoses with
/// exactly the same probe rather than a second, drifting copy of it.
fn collect_doctor_outcomes() -> Vec<(PathBuf, DoctorSocketOutcome)> {
    let expected_uid = doctor_expected_uid();
    let mut outcomes = Vec::new();
    let mut trusted_identities = std::collections::HashSet::new();
    for path in daemon_socket_candidates() {
        let stream = match UnixStream::connect(&path) {
            Ok(stream) => stream,
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::NotFound | ErrorKind::ConnectionRefused
                ) =>
            {
                continue;
            }
            Err(error) => {
                outcomes.push((
                    path,
                    DoctorSocketOutcome::ProbeFailed(format!("connect: {error}")),
                ));
                continue;
            }
        };
        let Some(identity) = doctor_peer_identity(&stream) else {
            outcomes.push((
                path,
                DoctorSocketOutcome::Untrusted(
                    "peer credentials are unavailable; refusing this socket".into(),
                ),
            ));
            continue;
        };
        if !uid_is_trusted(identity.uid, expected_uid) {
            outcomes.push((
                path,
                DoctorSocketOutcome::Untrusted(format!(
                    "socket owner uid {} is neither expected uid {expected_uid} nor root",
                    identity.uid
                )),
            ));
            continue;
        }
        if !trusted_identities.insert(identity) {
            continue;
        }
        let outcome = match daemon_rpc_on_stream(&stream) {
            Ok(result) => match parse_doctor_result(result) {
                Ok(findings) => DoctorSocketOutcome::Report(findings),
                Err(message) => DoctorSocketOutcome::RpcFailed(message),
            },
            Err(message) if message.contains("unknown method") => {
                DoctorSocketOutcome::Unsupported(message)
            }
            Err(message) => DoctorSocketOutcome::RpcFailed(message),
        };
        outcomes.push((path, outcome));
    }
    outcomes
}

fn cmd_daemon_doctor(json: bool) {
    let outcomes = collect_doctor_outcomes();

    if outcomes.is_empty() {
        let report = json!({
            "sockets": [],
            "complete": false,
            "healthy": false,
            "findings": [{
                "code": "no_daemon",
                "severity": "error",
                "detail": "no term-meshd is listening on any known socket path on this host",
                "remedy": "start term-meshd",
                "repair_argv": []
            }]
        });
        if json {
            println!("{}", pretty(&report));
        } else {
            println!("no term-meshd is listening on this host.");
        }
        process::exit(1);
    }
    let findings = aggregate_doctor_findings(&outcomes);
    let exit_code = doctor_exit_code(&outcomes, &findings);
    let complete = doctor_is_complete(&outcomes);
    let healthy = complete && findings.is_empty();
    let sockets = outcomes
        .iter()
        .map(|(path, _)| path.display().to_string())
        .collect::<Vec<_>>();
    if json {
        println!(
            "{}",
            pretty(
                &json!({ "sockets": sockets, "complete": complete, "healthy": healthy,
                            "findings": findings })
            )
        );
    } else if healthy {
        println!("{}: no problems found.", terminal_safe(&sockets.join(", ")));
    } else {
        println!(
            "{} problem(s) across {} socket(s).\n",
            findings.len(),
            sockets.len()
        );
        for finding in &findings {
            let text = |key: &str| terminal_safe(finding[key].as_str().unwrap_or(""));
            let (severity, code) = (text("severity"), text("code"));
            println!("[{severity}] {code}");
            let socket = text("socket");
            if !socket.is_empty() {
                println!("  socket {socket}");
            }
            let project = text("project_id");
            if !project.is_empty() {
                let team = text("team_name");
                println!(
                    "  project {project}{}",
                    if team.is_empty() {
                        String::new()
                    } else {
                        format!(" (team {team})")
                    }
                );
            }
            println!("  {}", text("detail"));
            if let Some(remedy) = human_remedy_line(finding) {
                println!("  fix: {remedy}\n");
            } else {
                println!();
            }
        }
    }
    if exit_code != 0 {
        process::exit(exit_code);
    }
}

/// The `daemon` help clap would have printed for a missing subcommand.
fn daemon_help_text() -> String {
    use clap::CommandFactory;
    let mut command = Cli::command();
    // Without build() the nested command renders its usage as bare `daemon`
    // instead of `tm-agent daemon`.
    command.build();
    command
        .find_subcommand_mut("daemon")
        .map(|daemon| daemon.render_help().to_string())
        .unwrap_or_default()
}

/// `daemon` subcommands whose argv the picker will execute.
///
/// The daemon composes `repair_argv`, so this list is the boundary that keeps
/// a malformed or unexpected report from choosing what runs. Everything else
/// is printed for the operator to run by hand.
const DAEMON_REPAIR_COMMANDS: [&str; 2] = ["project-presentations", "reset"];

/// The runnable argv a finding carries, or None when the picker must not run it.
fn daemon_repair_argv(finding: &Value) -> Option<Vec<String>> {
    let argv = finding["repair_argv"]
        .as_array()?
        .iter()
        .map(|value| value.as_str().map(str::to_string))
        .collect::<Option<Vec<String>>>()?;
    if argv.first().map(String::as_str) != Some("tm-agent")
        || argv.get(1).map(String::as_str) != Some("daemon")
    {
        return None;
    }
    let group = argv.get(2)?;
    if !DAEMON_REPAIR_COMMANDS.contains(&group.as_str()) {
        return None;
    }
    Some(argv)
}

/// The word the applied run needs. Anything else cancels.
const DAEMON_REPAIR_CONFIRM_WORD: &str = "apply";

/// Split one repair into the run that reports and the run that changes things.
///
/// The dry run is the same argv without `--apply`, so what the operator sees
/// is what the applied run repeats. The second element is None when the repair
/// only inspects, and there is then nothing to confirm.
fn daemon_repair_runs(argv: &[String]) -> (Vec<String>, Option<Vec<String>>) {
    let dry_run: Vec<String> = argv
        .iter()
        .filter(|arg| *arg != "--apply")
        .cloned()
        .collect();
    let applied = (dry_run.len() != argv.len()).then(|| argv.to_vec());
    (dry_run, applied)
}

fn daemon_repair_display(argv: &[String]) -> String {
    terminal_safe(&argv.join(" "))
}

/// Run one repair argv by re-entering this same binary.
///
/// Arguments go to the process directly, never through a shell, and the child
/// inherits the terminal so its own report reaches the operator unchanged.
fn run_daemon_repair(argv: &[String]) -> Result<i32, String> {
    let exe = env::current_exe().map_err(|error| format!("cannot locate this binary: {error}"))?;
    let status = process::Command::new(exe)
        .args(&argv[1..])
        .status()
        .map_err(|error| format!("cannot run the repair: {error}"))?;
    Ok(status.code().unwrap_or(1))
}

/// Read one line from the terminal, or None when stdin ends.
fn daemon_prompt_line(prompt: &str) -> Option<String> {
    eprint!("{prompt}");
    std::io::stderr().flush().ok();
    let mut input = String::new();
    match std::io::stdin().read_line(&mut input) {
        Ok(0) | Err(_) => None,
        Ok(_) => Some(input.trim().to_string()),
    }
}

/// `daemon -i` / `daemon doctor -i`: diagnose, then offer each finding's
/// repair as a numbered choice.
///
/// The picker never applies anything on its own. It runs the dry run first,
/// shows what the repair reports, and asks for a typed word before it repeats
/// the command with `--apply`.
fn cmd_daemon_interactive() -> ! {
    // Without this the picker blocks forever in a script, a hook, or an ssh
    // command — the places that call this CLI without a terminal.
    if !std::io::stdin().is_terminal() {
        eprintln!("Error: -i/--interactive needs a terminal on stdin.");
        eprintln!("       Run `tm-agent daemon doctor --json` and act on the findings instead.");
        process::exit(2);
    }

    let outcomes = collect_doctor_outcomes();
    if outcomes.is_empty() {
        println!("no term-meshd is listening on this host.");
        process::exit(1);
    }
    let findings = aggregate_doctor_findings(&outcomes);
    let exit_code = doctor_exit_code(&outcomes, &findings);
    if findings.is_empty() {
        let sockets = outcomes
            .iter()
            .map(|(path, _)| path.display().to_string())
            .collect::<Vec<_>>();
        println!("{}: no problems found.", terminal_safe(&sockets.join(", ")));
        process::exit(exit_code);
    }

    println!("{} problem(s) found.\n", findings.len());
    let mut choices: Vec<Vec<String>> = Vec::new();
    for finding in &findings {
        let text = |key: &str| terminal_safe(finding[key].as_str().unwrap_or(""));
        let argv = daemon_repair_argv(finding);
        let label = match &argv {
            Some(_) => {
                choices.push(argv.clone().expect("checked above"));
                format!("{:>2})", choices.len())
            }
            None => "  -".to_string(),
        };
        println!("{label} [{}] {}", text("severity"), text("code"));
        let project = text("project_id");
        if !project.is_empty() {
            println!("     project {project}");
        }
        println!("     {}", text("detail"));
        match &argv {
            Some(argv) => println!("     fix: {}\n", daemon_repair_display(argv)),
            None => match human_remedy_line(finding) {
                // A finding the daemon did not hand a runnable repair for:
                // report it the way `doctor` does and let the operator act.
                Some(remedy) => println!("     fix (run by hand): {remedy}\n"),
                None => println!(),
            },
        }
    }

    if choices.is_empty() {
        println!("No repair here is runnable from this picker. Act on the findings by hand.");
        process::exit(exit_code);
    }

    let prompt = format!("Select a repair [1-{}] or q to quit: ", choices.len());
    let Some(answer) = daemon_prompt_line(&prompt) else {
        process::exit(exit_code);
    };
    if answer.is_empty() || answer == "q" {
        process::exit(exit_code);
    }
    let Some(argv) = answer
        .parse::<usize>()
        .ok()
        .filter(|choice| (1..=choices.len()).contains(choice))
        .map(|choice| choices[choice - 1].clone())
    else {
        eprintln!(
            "Error: `{}` is not one of the choices.",
            terminal_safe(&answer)
        );
        process::exit(2);
    };

    let (dry_run, applied) = daemon_repair_runs(&argv);
    println!("\n$ {}", daemon_repair_display(&dry_run));
    let code = match run_daemon_repair(&dry_run) {
        Ok(code) => code,
        Err(message) => {
            eprintln!("Error: {message}");
            process::exit(1);
        }
    };
    if code != 0 {
        eprintln!("The dry run failed (exit {code}). Nothing was changed.");
        process::exit(code);
    }
    let Some(applied) = applied else {
        // The daemon offered inspection only, so there is nothing to confirm.
        process::exit(exit_code);
    };

    println!("\nThe run above changed nothing. Applying repeats it with --apply:");
    println!("  {}", daemon_repair_display(&applied));
    let confirmed = daemon_prompt_line(&format!(
        "Type `{DAEMON_REPAIR_CONFIRM_WORD}` to run it, anything else to cancel: "
    ))
    .is_some_and(|answer| answer == DAEMON_REPAIR_CONFIRM_WORD);
    if !confirmed {
        println!("Cancelled. Nothing was changed.");
        process::exit(exit_code);
    }
    println!("\n$ {}", daemon_repair_display(&applied));
    match run_daemon_repair(&applied) {
        Ok(0) => {
            println!("\nRepair applied. Run `tm-agent daemon doctor` again to confirm.");
            process::exit(0);
        }
        Ok(code) => process::exit(code),
        Err(message) => {
            eprintln!("Error: {message}");
            process::exit(1);
        }
    }
}

// ── `tm-agent remote` (docs/mobile-remote-control.md §4.2) ─────────────

/// Run one `remote` subcommand against the daemon control socket.
fn run_remote_command(sock: &PathBuf, team_flag: Option<&str>, cmd: &RemoteCommand) {
    match cmd {
        RemoteCommand::On {
            keys,
            ttl,
            surface,
            leader,
            agent,
            terminal,
            app_socket,
            cli,
            title,
            json,
        } => {
            let env_agent = env::var("TERMMESH_AGENT_NAME").ok();
            let agent_name = remote_agent_target(
                agent.as_deref(),
                env_agent.as_deref(),
                *leader || surface.is_some(),
                *terminal,
            )
            .unwrap_or_else(|e| {
                eprintln!("Error: {e}");
                process::exit(1);
            });
            if let Some(agent_name) = agent_name {
                run_remote_on_agent(
                    sock,
                    team_flag,
                    &agent_name,
                    *terminal,
                    keys,
                    ttl.as_deref(),
                    title.as_deref(),
                    *json,
                );
                return;
            }
            let surface_id = resolve_remote_surface(surface.as_deref()).unwrap_or_else(|e| {
                // A native agent pane has no terminal surface, so `--terminal`
                // there cannot mean anything.
                if *terminal && env_agent.as_deref().is_some_and(|a| !a.trim().is_empty()) {
                    eprintln!("Error: this agent pane has no terminal to mirror; run without --terminal to expose it as a chat");
                } else {
                    eprintln!("Error: {e}");
                }
                process::exit(1);
            });
            let ttl_secs = match ttl.as_deref().map(parse_ttl_secs).transpose() {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            };
            let is_leader = *leader || remote_pane_is_leader();
            let team_name = is_leader.then(|| resolve_team_name(team_flag));
            let app_socket = app_socket
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .or_else(resolve_remote_app_socket);
            // No app socket means no app owns this surface: a peer host's pane
            // or a headless one, where the daemon that injected the surface id
            // owns the PTY itself. Its own listener reads those surfaces, so
            // the exposure goes in with `app_socket` unset instead of being
            // refused. A pane the app owns always carries both variables
            // (`GhosttyTerminalView` writes them together).
            let cwd = env::current_dir()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            let title = title
                .clone()
                .filter(|t| !t.trim().is_empty())
                .unwrap_or_else(|| remote_default_title(&cwd));
            let agent_cli = cli.clone().unwrap_or_else(detect_remote_cli);
            let session_id = (!*terminal)
                .then(|| remote_session_id(&agent_cli))
                .flatten();
            let mut params = json!({
                "surface_id": surface_id,
                "kind": if is_leader { "leader" } else { "pane" },
                "keys": keys,
                "app_socket": app_socket,
                "agent_cli": agent_cli,
                "chat_capable": session_id.is_some(),
                "session_id": session_id,
                "title": title,
                "cwd": cwd,
                "owner": env::var("USER").ok(),
            });
            if let Some(team) = &team_name {
                params["team_name"] = json!(team);
            }
            if let Some(ttl) = ttl_secs {
                params["ttl_secs"] = json!(ttl);
            }
            if is_leader {
                // The durable board's list RPC needs the leader pane's capability
                // token; only the daemon ever sees it.
                if let Some(token) = env::var("TERMMESH_LEADER_REQUEST_TOKEN")
                    .ok()
                    .map(|t| t.trim().to_string())
                    .filter(|t| !t.is_empty())
                {
                    params["leader_request_token"] = json!(token);
                }
            }
            let result = remote_rpc(sock, "remote.on", params);
            if *json {
                println!("{}", pretty(&result));
                return;
            }
            let entry = &result["entry"];
            println!(
                "exposed {} ({}, keys={}{})",
                entry["surface_id"].as_str().unwrap_or(&surface_id),
                entry["kind"].as_str().unwrap_or("pane"),
                entry["keys"].as_str().unwrap_or(keys),
                team_name
                    .as_deref()
                    .map(|t| format!(", team={t}"))
                    .unwrap_or_default()
            );
            match result["url"].as_str() {
                Some(url) => {
                    println!("url: {url}");
                    for line in remote_tailnet_lines(url, &surface_id) {
                        println!("{line}");
                    }
                }
                None => println!(
                    "url: unavailable ({})",
                    result["listener_error"]
                        .as_str()
                        .unwrap_or("listener address invalid")
                ),
            }
            if let Some(exp) = entry["expires_at"].as_u64() {
                println!("expires: in {} (unix {exp})", format_remote_relative(exp));
            }
            if result["listener_enabled"].as_bool() != Some(true) {
                eprintln!(
                    "note: the mobile listener is disabled on this daemon; enable it in \
                     Settings or set TERM_MESH_MOBILE_ENABLED=1 before the daemon starts"
                );
            }
            if !is_leader && !*terminal {
                if entry["chat_capable"].as_bool() == Some(true) {
                    eprintln!(
                        "note: the mobile page can switch this target between Chat and Terminal"
                    );
                } else {
                    eprintln!("note: terminal mirror only; no supported Claude/Codex session id was found");
                }
            }
        }
        RemoteCommand::Off { surface, json } => {
            let surface_id = resolve_remote_surface(surface.as_deref()).unwrap_or_else(|e| {
                eprintln!("Error: {e}");
                process::exit(1);
            });
            let result = remote_rpc(sock, "remote.off", json!({ "surface_id": surface_id }));
            if *json {
                println!("{}", pretty(&result));
                return;
            }
            if result["removed"].as_bool() == Some(true) {
                println!("no longer exposed: {surface_id}");
            } else {
                println!("was not exposed: {surface_id}");
            }
        }
        RemoteCommand::Status { surface, all, json } => {
            let params = if *all {
                json!({})
            } else {
                let surface_id = resolve_remote_surface(surface.as_deref()).unwrap_or_else(|e| {
                    eprintln!("Error: {e}");
                    process::exit(1);
                });
                json!({ "surface_id": surface_id })
            };
            let result = remote_rpc(sock, "remote.status", params);
            if *json {
                println!("{}", pretty(&result));
                return;
            }
            let listener = if result["listener_enabled"].as_bool() == Some(true) {
                "enabled".to_string()
            } else {
                "disabled".to_string()
            };
            if *all {
                let entries = result["entries"].as_array().cloned().unwrap_or_default();
                println!("listener: {listener}; exposed surfaces: {}", entries.len());
                for e in entries {
                    println!(
                        "  {}  {}  keys={}  {}",
                        e["surface_id"].as_str().unwrap_or("?"),
                        e["kind"].as_str().unwrap_or("?"),
                        e["keys"].as_str().unwrap_or("?"),
                        e["title"].as_str().unwrap_or("")
                    );
                }
            } else if result["exposed"].as_bool() == Some(true) {
                let e = &result["entry"];
                println!(
                    "exposed: {} ({}, keys={})",
                    result["surface_id"].as_str().unwrap_or("?"),
                    e["kind"].as_str().unwrap_or("?"),
                    e["keys"].as_str().unwrap_or("?")
                );
                if let Some(url) = result["url"].as_str() {
                    println!("url: {url}");
                    let sid = result["surface_id"].as_str().unwrap_or("");
                    for line in remote_tailnet_lines(url, sid) {
                        println!("{line}");
                    }
                }
                if let Some(exp) = e["expires_at"].as_u64() {
                    println!("expires: in {} (unix {exp})", format_remote_relative(exp));
                }
                println!("listener: {listener}");
            } else {
                println!(
                    "not exposed: {} (listener {listener})",
                    result["surface_id"].as_str().unwrap_or("?")
                );
            }
        }
    }
}

/// `tm-agent remote on [--agent <name>]`: expose a team agent's pane as a
/// chat target. The pane is found through the app's `team.status` (panel_id,
/// cli), registered with `kind=agent`, and served from its structured
/// transcript. `terminal` registers the pane as a screen mirror instead.
fn run_remote_on_agent(
    sock: &PathBuf,
    team_flag: Option<&str>,
    agent_name: &str,
    terminal: bool,
    keys: &str,
    ttl: Option<&str>,
    title: Option<&str>,
    json: bool,
) {
    let team_name = resolve_team_name(team_flag);
    let Some(app_sock) = detect_socket() else {
        eprintln!(
            "Error: no term-mesh app socket found to look up the agent (TERMMESH_SOCKET_PATH)"
        );
        process::exit(1);
    };
    let status = match rpc_call(&app_sock, "team.status", json!({ "team_name": team_name })) {
        Ok(resp) if resp.get("error").is_none() => resp["result"].clone(),
        Ok(resp) => {
            eprintln!(
                "Error: team.status: {}",
                resp["error"]["message"].as_str().unwrap_or("rpc error")
            );
            process::exit(1);
        }
        Err(e) => {
            eprintln!("Error: team.status: {e}");
            process::exit(1);
        }
    };
    let agent = status["agents"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|a| {
            a["agent_name"].as_str() == Some(agent_name) || a["name"].as_str() == Some(agent_name)
        })
        .cloned();
    let Some(agent) = agent else {
        eprintln!("Error: agent {agent_name:?} is not in team {team_name:?}");
        process::exit(1);
    };
    let Some(panel_id) = agent["panel_id"].as_str().filter(|p| !p.is_empty()) else {
        eprintln!(
            "Error: agent {agent_name:?} has no pane (headless agents cannot be exposed yet)"
        );
        process::exit(1);
    };
    // Which view: a native pane has a structured transcript (chat); a
    // terminal-mode agent pane only has a screen (mirror). `team.status`
    // does not say which, so ask for one transcript entry unless the caller
    // forced the mirror.
    let kind = if terminal {
        "pane"
    } else {
        let probe = rpc_call(
            &app_sock,
            "team.agent.transcript",
            json!({ "team_name": team_name, "agent_name": agent_name, "limit": 1 }),
        );
        match probe {
            Ok(resp) if resp.get("error").is_none() => "agent",
            Ok(resp) if resp["error"]["code"].as_str() == Some("not_native") => "pane",
            Ok(resp) => {
                eprintln!(
                    "Error: team.agent.transcript: {}",
                    resp["error"]["message"].as_str().unwrap_or("rpc error")
                );
                process::exit(1);
            }
            Err(e) => {
                eprintln!("Error: team.agent.transcript: {e}");
                process::exit(1);
            }
        }
    };
    let session_id = agent["session_id"]
        .as_str()
        .map(str::to_string)
        .or_else(|| {
            let this_agent = env::var("TERMMESH_AGENT_NAME").ok();
            (this_agent.as_deref().map(str::trim) == Some(agent_name))
                .then(|| remote_session_id(agent["cli"].as_str().unwrap_or("")))
                .flatten()
        });
    let ttl_secs = match ttl.map(parse_ttl_secs).transpose() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };
    let mut params = json!({
        "surface_id": panel_id,
        "kind": kind,
        "team_name": team_name,
        "agent_name": agent_name,
        "keys": keys,
        "app_socket": app_sock.to_string_lossy(),
        "agent_cli": agent["cli"].as_str().unwrap_or(""),
        "chat_capable": kind == "agent" || session_id.is_some(),
        "session_id": session_id,
        "title": title.unwrap_or(agent_name),
        "cwd": agent["working_directory"]
            .as_str()
            .map(str::to_string)
            .unwrap_or_else(|| env::current_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()),
        "owner": env::var("USER").ok(),
    });
    if let Some(ttl) = ttl_secs {
        params["ttl_secs"] = json!(ttl);
    }
    let result = remote_rpc(sock, "remote.on", params);
    if json {
        println!("{}", pretty(&result));
        return;
    }
    if kind == "agent" {
        println!("exposed agent {agent_name} of {team_name} as chat (native pane)");
    } else if terminal {
        println!("exposed agent {agent_name} of {team_name} as terminal mirror (--terminal, keys={keys})");
    } else {
        println!("exposed agent {agent_name} of {team_name} as terminal mirror (pane is not native, keys={keys})");
    }
    match result["url"].as_str() {
        Some(url) => {
            println!("url: {url}");
            for line in remote_tailnet_lines(url, panel_id) {
                println!("{line}");
            }
        }
        None => println!(
            "url: unavailable ({})",
            result["listener_error"]
                .as_str()
                .unwrap_or("listener address invalid")
        ),
    }
    if let Some(exp) = result["entry"]["expires_at"].as_u64() {
        println!("expires: in {} (unix {exp})", format_remote_relative(exp));
    }
    if result["listener_enabled"].as_bool() != Some(true) {
        eprintln!(
            "note: the mobile listener is disabled on this daemon; enable it in Settings first"
        );
    }
}

/// One `remote.*` RPC; any failure is fatal for the command.
fn remote_rpc(sock: &PathBuf, method: &str, params: Value) -> Value {
    match rpc_call(sock, method, params) {
        Ok(resp) => {
            if let Some(err) = resp.get("error") {
                let msg = err["message"].as_str().unwrap_or("rpc error");
                eprintln!("Error: {method}: {msg}");
                process::exit(1);
            }
            resp.get("result").cloned().unwrap_or(Value::Null)
        }
        Err(e) => {
            eprintln!("Error: {method}: {e}");
            process::exit(1);
        }
    }
}

/// `--surface` wins; otherwise the pane's own `TERMMESH_SURFACE_ID`.
fn resolve_remote_surface(explicit: Option<&str>) -> Result<String, String> {
    remote_surface_from(
        explicit,
        env::var("TERMMESH_SURFACE_ID").ok().as_deref(),
        is_claude_background_session(&|name| env::var(name).ok()),
    )
}

/// In a Claude background session the inherited surface is another session's
/// pane ([`is_claude_background_session`]); exposing it would route mobile
/// input to that session.
fn remote_surface_from(
    explicit: Option<&str>,
    env_value: Option<&str>,
    background: bool,
) -> Result<String, String> {
    if let Some(s) = explicit.map(str::trim).filter(|s| !s.is_empty()) {
        return Ok(s.to_string());
    }
    if background {
        return Err(
            "this is a Claude background session: it has no term-mesh pane, and \
             $TERMMESH_SURFACE_ID belongs to another session's pane. Run /rc in the pane \
             that shows this session; pass --surface only with that pane's id, never \
             $TERMMESH_SURFACE_ID"
                .to_string(),
        );
    }
    env_value
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .ok_or_else(|| {
            "no surface id: run inside a term-mesh pane (TERMMESH_SURFACE_ID) or pass --surface <id>"
                .to_string()
        })
}

/// The app socket that owns this pane. `TERMMESH_SOCKET_PATH` is what the app
/// injects into every pane; `TERMMESH_SOCKET` counts only when it is an app
/// socket (agent panes get it too, but daemon-spawned panes get the daemon's).
fn resolve_remote_app_socket() -> Option<String> {
    remote_app_socket_from(
        env::var("TERMMESH_SOCKET_PATH").ok().as_deref(),
        env::var("TERMMESH_SOCKET").ok().as_deref(),
    )
}

fn remote_app_socket_from(socket_path: Option<&str>, socket: Option<&str>) -> Option<String> {
    let absolute = |s: &str| {
        let s = s.trim();
        (!s.is_empty() && s.starts_with('/')).then(|| s.to_string())
    };
    if let Some(p) = socket_path.and_then(absolute) {
        return Some(p);
    }
    socket
        .and_then(absolute)
        .filter(|p| is_app_socket_path(Path::new(p)))
}

/// A leader pane the app launched carries `TERMMESH_LEADER_REQUEST_TOKEN` and
/// no `TERMMESH_AGENT_NAME` (workers get the latter). Adopted leaders have
/// neither and must pass `--leader`.
/// Which agent `remote on` exposes as a chat, or `None` for this pane's own
/// surface. `--agent NAME` names one; a bare `--agent` and the default both
/// take the pane's own agent name, so an agent exposes itself without naming
/// itself. `pane_flow` (`--leader` or `--surface`) and `--terminal` without a
/// name keep the surface flow, which needs no team lookup.
fn remote_agent_target(
    flag: Option<&str>,
    env_agent: Option<&str>,
    pane_flow: bool,
    terminal: bool,
) -> Result<Option<String>, String> {
    let env_agent = env_agent.map(str::trim).filter(|a| !a.is_empty());
    match flag.map(str::trim) {
        Some(name) if !name.is_empty() => Ok(Some(name.to_string())),
        Some(_) => env_agent.map(|a| Some(a.to_string())).ok_or_else(|| {
            "no agent name: pass --agent <name>, or run inside a team agent pane \
             (TERMMESH_AGENT_NAME)"
                .to_string()
        }),
        None if pane_flow || terminal => Ok(None),
        None => Ok(env_agent.map(str::to_string)),
    }
}

fn remote_pane_is_leader() -> bool {
    remote_leader_from(
        env::var("TERMMESH_LEADER_REQUEST_TOKEN").ok().as_deref(),
        env::var("TERMMESH_AGENT_NAME").ok().as_deref(),
    )
}

fn remote_leader_from(leader_token: Option<&str>, agent_name: Option<&str>) -> bool {
    let has_token = leader_token.map(str::trim).is_some_and(|t| !t.is_empty());
    let is_worker = agent_name.map(str::trim).is_some_and(|a| !a.is_empty());
    has_token && !is_worker
}

/// Best-effort label for the page. Claude Code exports `CLAUDECODE` into the
/// shells it runs; Codex marks its sandboxed commands. Unknown stays empty
/// rather than guessing.
fn detect_remote_cli() -> String {
    let set = |k: &str| env::var(k).map(|v| !v.trim().is_empty()).unwrap_or(false);
    if set("CLAUDECODE") {
        "claude".into()
    } else if set("CODEX_SANDBOX")
        || set("CODEX_SANDBOX_NETWORK_DISABLED")
        || set("CODEX_SESSION_ID")
        || set("CODEX_THREAD_ID")
    {
        "codex".into()
    } else {
        String::new()
    }
}

fn remote_session_id(cli: &str) -> Option<String> {
    remote_session_id_from(cli, |key| env::var(key).ok())
}

fn remote_session_id_from<F>(cli: &str, mut get: F) -> Option<String>
where
    F: FnMut(&str) -> Option<String>,
{
    let keys: &[&str] = match cli {
        // CODEX_SESSION_ID can describe the parent shell while THREAD_ID is
        // the active conversation whose rollout the mobile page must follow.
        "codex" => &["CODEX_THREAD_ID", "CODEX_SESSION_ID"],
        "claude" => &["CLAUDE_CODE_SESSION_ID"],
        _ => &[],
    };
    keys.iter().find_map(|key| {
        get(key)
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    })
}

fn remote_default_title(cwd: &str) -> String {
    Path::new(cwd)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| "pane".to_string())
}

/// `12h`, `30m`, `2d`, `90s`, or plain seconds.
fn parse_ttl_secs(raw: &str) -> Result<u64, String> {
    let s = raw.trim();
    if s.is_empty() {
        return Err("ttl is empty".into());
    }
    let (digits, unit) = match s.char_indices().find(|(_, c)| !c.is_ascii_digit()) {
        Some((i, _)) => (&s[..i], s[i..].trim()),
        None => (s, ""),
    };
    let n: u64 = digits
        .parse()
        .map_err(|_| format!("ttl {raw:?} must be a number with an optional s/m/h/d suffix"))?;
    let mult = match unit {
        "" | "s" | "sec" | "secs" => 1,
        "m" | "min" | "mins" => 60,
        "h" | "hr" | "hrs" => 3600,
        "d" | "day" | "days" => 86_400,
        _ => {
            return Err(format!(
                "ttl {raw:?}: unknown unit {unit:?} (use s, m, h, d)"
            ))
        }
    };
    n.checked_mul(mult)
        .ok_or_else(|| format!("ttl {raw:?} is too large"))
}

/// What Tailscale Serve says about the mobile listener (Phase 2,
/// docs/mobile-remote-control.md §9). Read-only: `tailscale serve status --json`.
#[derive(Debug, Clone, PartialEq, Eq)]
enum TailnetServe {
    /// `https://<host>[:port][/path]` proxies to the listener. `funnel` means
    /// the same host is also published to the public internet, which the
    /// mobile listener refuses to serve (no identity header).
    Served { base: String, funnel: bool },
    /// Tailscale answered, but nothing proxies to the listener.
    NotServed,
}

/// `127.0.0.1:9877` out of `http://127.0.0.1:9877/t/<id>`.
fn listener_addr_from_url(url: &str) -> Option<String> {
    let rest = url.strip_prefix("http://")?;
    let host_port = rest.split('/').next()?;
    (!host_port.is_empty()).then(|| host_port.to_string())
}

/// Parse `tailscale serve status --json`. The shape is Tailscale's
/// `ipn.ServeConfig`: `Web` maps `host:port` to `{Handlers: {path: {Proxy}}}`
/// and `AllowFunnel` maps the same `host:port` keys to booleans.
fn parse_serve_status(status: &Value, listener_addr: &str) -> TailnetServe {
    let listener_port = listener_addr.rsplit(':').next().unwrap_or("");
    let proxies_listener = |proxy: &str| {
        let target = proxy
            .strip_prefix("http://")
            .or_else(|| proxy.strip_prefix("https://"))
            .unwrap_or(proxy);
        let target = target.trim_end_matches('/');
        let (host, port) = match target.rsplit_once(':') {
            Some((h, p)) => (h, p),
            None => (target, ""),
        };
        matches!(host, "127.0.0.1" | "localhost" | "[::1]" | "::1") && port == listener_port
    };
    let Some(web) = status.get("Web").and_then(Value::as_object) else {
        return TailnetServe::NotServed;
    };
    for (host_port, site) in web {
        let Some(handlers) = site.get("Handlers").and_then(Value::as_object) else {
            continue;
        };
        for (path, handler) in handlers {
            let Some(proxy) = handler.get("Proxy").and_then(Value::as_str) else {
                continue;
            };
            if !proxies_listener(proxy) {
                continue;
            }
            let (host, port) = host_port
                .rsplit_once(':')
                .unwrap_or((host_port.as_str(), "443"));
            let mut base = format!("https://{host}");
            if port != "443" {
                base.push(':');
                base.push_str(port);
            }
            let mount = path.trim_end_matches('/');
            if !mount.is_empty() {
                base.push_str(mount);
            }
            let funnel = status
                .get("AllowFunnel")
                .and_then(|f| f.get(host_port))
                .and_then(Value::as_bool)
                .unwrap_or(false);
            return TailnetServe::Served { base, funnel };
        }
    }
    TailnetServe::NotServed
}

fn tailscale_binary() -> Option<PathBuf> {
    if let Ok(path_var) = env::var("PATH") {
        for dir in path_var.split(':').filter(|d| !d.is_empty()) {
            let candidate = Path::new(dir).join("tailscale");
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    let app = PathBuf::from("/Applications/Tailscale.app/Contents/MacOS/Tailscale");
    app.is_file().then_some(app)
}

fn tailscale_serve_status() -> Option<Value> {
    let bin = tailscale_binary()?;
    let out = std::process::Command::new(bin)
        .args(["serve", "status", "--json"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    serde_json::from_slice(&out.stdout).ok()
}

/// Human lines for the tailnet side of a loopback listener URL. Empty when
/// Tailscale is absent or does not answer: the loopback URL is still right.
fn remote_tailnet_lines(listener_url: &str, surface_id: &str) -> Vec<String> {
    let Some(addr) = listener_addr_from_url(listener_url) else {
        return Vec::new();
    };
    let Some(status) = tailscale_serve_status() else {
        return Vec::new();
    };
    tailnet_lines_for(&parse_serve_status(&status, &addr), &addr, surface_id)
}

fn tailnet_lines_for(serve: &TailnetServe, listener_addr: &str, surface_id: &str) -> Vec<String> {
    match serve {
        TailnetServe::Served { base, funnel } => {
            let mut lines = vec![format!("tailnet: {base}/t/{surface_id}")];
            if *funnel {
                lines.push(
                    "warning: Funnel is enabled for this host; the listener refuses public \
                     requests (no Tailscale identity). Run: tailscale funnel off"
                        .to_string(),
                );
            }
            lines
        }
        TailnetServe::NotServed => {
            let port = listener_addr.rsplit(':').next().unwrap_or("9877");
            vec![format!(
                "tailnet: not served yet; on this Mac run: tailscale serve --bg {port}"
            )]
        }
    }
}

fn format_remote_relative(expires_at: u64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let left = expires_at.saturating_sub(now);
    if left >= 86_400 {
        format!("{}d {}h", left / 86_400, (left % 86_400) / 3600)
    } else if left >= 3600 {
        format!("{}h {}m", left / 3600, (left % 3600) / 60)
    } else {
        format!("{}m", left / 60)
    }
}

#[cfg(test)]
mod remote_command_tests {
    use super::*;

    #[test]
    fn ttl_accepts_units_and_plain_seconds() {
        assert_eq!(parse_ttl_secs("90").unwrap(), 90);
        assert_eq!(parse_ttl_secs("90s").unwrap(), 90);
        assert_eq!(parse_ttl_secs("30m").unwrap(), 1800);
        assert_eq!(parse_ttl_secs("12h").unwrap(), 43_200);
        assert_eq!(parse_ttl_secs("2d").unwrap(), 172_800);
        assert_eq!(parse_ttl_secs(" 1 h ").unwrap(), 3600);
        assert!(parse_ttl_secs("").is_err());
        assert!(parse_ttl_secs("h").is_err());
        assert!(parse_ttl_secs("12w").is_err());
        assert!(parse_ttl_secs("99999999999999999999d").is_err());
    }

    #[test]
    fn surface_flag_wins_over_env_and_missing_is_an_error() {
        assert_eq!(
            remote_surface_from(Some(" abc "), Some("env"), false).unwrap(),
            "abc"
        );
        assert_eq!(
            remote_surface_from(Some("  "), Some("env"), false).unwrap(),
            "env"
        );
        assert_eq!(
            remote_surface_from(None, Some("env"), false).unwrap(),
            "env"
        );
        assert!(remote_surface_from(None, None, false)
            .unwrap_err()
            .contains("--surface"));
        assert!(remote_surface_from(None, Some(" "), false).is_err());
    }

    #[test]
    fn background_session_refuses_the_inherited_surface() {
        let err = remote_surface_from(None, Some("env"), true).unwrap_err();
        assert!(err.contains("background session"));
        assert_eq!(
            remote_surface_from(Some("abc"), Some("env"), true).unwrap(),
            "abc"
        );
    }

    /// The Bash tool of a background session has `CLAUDE_JOB_DIR` but not
    /// `CLAUDE_CODE_SESSION_KIND`; a pane session has neither.
    #[test]
    fn a_background_session_is_recognized_from_what_its_tools_see() {
        let detect = |vars: &[(&str, &str)]| {
            let vars: Vec<(String, String)> = vars
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect();
            is_claude_background_session(&|name| {
                vars.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone())
            })
        };
        assert!(detect(&[(
            "CLAUDE_JOB_DIR",
            "/Users/me/.claude/jobs/99e1e8fa"
        )]));
        assert!(detect(&[("CLAUDE_CODE_SESSION_KIND", "bg")]));
        assert!(!detect(&[("CLAUDE_CODE_SESSION_KIND", "interactive")]));
        assert!(!detect(&[("CLAUDE_JOB_DIR", " ")]));
        assert!(!detect(&[]));
    }

    #[test]
    fn app_socket_prefers_pane_socket_path_then_app_typed_socket() {
        assert_eq!(
            remote_app_socket_from(Some("/tmp/term-mesh.sock"), Some("/tmp/term-meshd.sock")),
            Some("/tmp/term-mesh.sock".into())
        );
        // TERMMESH_SOCKET pointing at a daemon socket is not an app socket.
        assert_eq!(
            remote_app_socket_from(None, Some("/tmp/term-meshd.sock")),
            None
        );
        assert_eq!(
            remote_app_socket_from(None, Some("/tmp/term-mesh-debug-x.sock")),
            Some("/tmp/term-mesh-debug-x.sock".into())
        );
        assert_eq!(remote_app_socket_from(Some("relative.sock"), None), None);
        assert_eq!(remote_app_socket_from(None, None), None);
    }

    #[test]
    fn agent_target_defaults_to_this_panes_agent_unless_the_pane_flow_is_forced() {
        // Bare `remote on` inside a team agent pane exposes that agent.
        assert_eq!(
            remote_agent_target(None, Some("reviewer"), false, false)
                .unwrap()
                .as_deref(),
            Some("reviewer")
        );
        // Outside a team it is the plain pane.
        assert_eq!(remote_agent_target(None, None, false, false).unwrap(), None);
        assert_eq!(
            remote_agent_target(None, Some(" "), false, false).unwrap(),
            None
        );
        // `--terminal`, `--leader`, and `--surface` keep the surface flow.
        assert_eq!(
            remote_agent_target(None, Some("reviewer"), false, true).unwrap(),
            None
        );
        assert_eq!(
            remote_agent_target(None, Some("reviewer"), true, false).unwrap(),
            None
        );
        // `--agent NAME` always names, `--agent` alone borrows the pane's name.
        assert_eq!(
            remote_agent_target(Some(" other "), Some("reviewer"), true, true)
                .unwrap()
                .as_deref(),
            Some("other")
        );
        assert_eq!(
            remote_agent_target(Some(""), Some("reviewer"), false, false)
                .unwrap()
                .as_deref(),
            Some("reviewer")
        );
        assert!(remote_agent_target(Some(""), None, false, false)
            .unwrap_err()
            .contains("--agent <name>"));
    }

    #[test]
    fn leader_detection_needs_token_and_no_worker_name() {
        assert!(remote_leader_from(Some("tok"), None));
        assert!(remote_leader_from(Some("tok"), Some("")));
        assert!(!remote_leader_from(Some("tok"), Some("worker-1")));
        assert!(!remote_leader_from(None, None));
        assert!(!remote_leader_from(Some(" "), None));
    }

    #[test]
    fn codex_remote_prefers_the_active_thread_over_the_parent_session() {
        let id = remote_session_id_from("codex", |key| match key {
            "CODEX_THREAD_ID" => Some("active-thread".into()),
            "CODEX_SESSION_ID" => Some("parent-session".into()),
            _ => None,
        });
        assert_eq!(id.as_deref(), Some("active-thread"));
    }

    #[test]
    fn serve_status_maps_the_listener_to_its_tailnet_base() {
        let status = json!({
            "TCP": {"443": {"HTTPS": true}},
            "Web": {"mac.tail5b1e6.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:9877"}}}},
            "AllowFunnel": {}
        });
        assert_eq!(
            parse_serve_status(&status, "127.0.0.1:9877"),
            TailnetServe::Served {
                base: "https://mac.tail5b1e6.ts.net".into(),
                funnel: false
            }
        );
        // A different port is somebody else's serve.
        assert_eq!(
            parse_serve_status(&status, "127.0.0.1:9876"),
            TailnetServe::NotServed
        );
        assert_eq!(
            parse_serve_status(&json!({}), "127.0.0.1:9877"),
            TailnetServe::NotServed
        );

        let mounted = json!({
            "Web": {"mac.tail5b1e6.ts.net:8443": {"Handlers": {"/rc/": {"Proxy": "http://localhost:9877"}}}},
            "AllowFunnel": {"mac.tail5b1e6.ts.net:8443": true}
        });
        assert_eq!(
            parse_serve_status(&mounted, "127.0.0.1:9877"),
            TailnetServe::Served {
                base: "https://mac.tail5b1e6.ts.net:8443/rc".into(),
                funnel: true
            }
        );
    }

    #[test]
    fn tailnet_lines_name_the_url_or_the_command_to_run() {
        let served = TailnetServe::Served {
            base: "https://mac.ts.net".into(),
            funnel: false,
        };
        assert_eq!(
            tailnet_lines_for(&served, "127.0.0.1:9877", "abc"),
            vec!["tailnet: https://mac.ts.net/t/abc".to_string()]
        );
        let funnel = TailnetServe::Served {
            base: "https://mac.ts.net".into(),
            funnel: true,
        };
        let lines = tailnet_lines_for(&funnel, "127.0.0.1:9877", "abc");
        assert_eq!(lines.len(), 2);
        assert!(lines[1].contains("tailscale funnel off"));
        let not = tailnet_lines_for(&TailnetServe::NotServed, "127.0.0.1:20226", "abc");
        assert_eq!(
            not,
            vec![
                "tailnet: not served yet; on this Mac run: tailscale serve --bg 20226".to_string()
            ]
        );
        assert_eq!(
            listener_addr_from_url("http://127.0.0.1:9877/t/abc").as_deref(),
            Some("127.0.0.1:9877")
        );
        assert_eq!(listener_addr_from_url("https://x/t/abc"), None);
    }

    #[test]
    fn default_title_is_the_cwd_basename() {
        assert_eq!(
            remote_default_title("/Users/me/work/term-mesh"),
            "term-mesh"
        );
        assert_eq!(remote_default_title("/"), "pane");
        assert_eq!(remote_default_title(""), "pane");
    }
}

fn discover_term_mesh_sockets() -> Vec<Value> {
    let patterns = [
        "/tmp/term-mesh-debug-*.sock",
        "/tmp/term-mesh-debug.sock",
        "/tmp/term-mesh*.sock",
        "/tmp/cmux.sock",
    ];
    let mut sockets = Vec::new();
    let mut seen = std::collections::BTreeSet::new();

    for pattern in patterns {
        if let Ok(paths) = glob::glob(pattern) {
            for path in paths.flatten() {
                let display = path.to_string_lossy().to_string();
                if !seen.insert(display.clone()) {
                    continue;
                }
                sockets.push(json!({
                    "path": display,
                    "alive": is_socket_alive(&path),
                }));
            }
        }
    }

    sockets
}

/// What the peer state directory holds, read straight off disk.
///
/// Read from the files rather than asked of the daemon, because the moment
/// someone runs doctor is often the moment no daemon is up. The one fact only
/// a daemon knows is how many of a manifest's surfaces are alive, so that
/// field stays null without one.
fn peer_state_report(daemon_socket: Option<&PathBuf>, live_sockets: usize) -> Value {
    let dir = peer_state_dir();

    // Asking the daemon costs nothing when it is down and gives the liveness
    // column when it is up.
    let live_by_project: std::collections::HashMap<String, u64> = daemon_socket
        // `cmd_daemon_rpc`, not `rpc_call`: this is a daemon-local query with
        // no team context, and `rpc_call` would route it through the remote
        // leader policy and fail.
        .and_then(|sock| cmd_daemon_rpc(sock, "peer.project_presentations.list", json!({})).ok())
        .and_then(|value| value["records"].as_array().cloned())
        .map(|records| {
            records
                .iter()
                .filter_map(|record| {
                    Some((
                        record["project_id"].as_str()?.to_string(),
                        record["live_surfaces"].as_u64().unwrap_or(0),
                    ))
                })
                .collect()
        })
        .unwrap_or_default();

    let mut files = Vec::new();
    let mut projects = Vec::new();
    let mut workspaces = Vec::new();

    for (scope, path) in peer_state_files("all") {
        let present = path.exists();
        let bytes = std::fs::metadata(&path).map(|meta| meta.len()).ok();
        let parsed: Option<Value> = std::fs::read(&path)
            .ok()
            .and_then(|raw| serde_json::from_slice(&raw).ok());
        let records = match (scope, &parsed) {
            ("projects", Some(value)) => value["records"].as_array().map(|r| r.len()),
            ("workspaces", Some(value)) => value.as_array().map(|r| r.len()),
            _ => None,
        };
        files.push(json!({
            "scope": scope,
            "path": path.display().to_string(),
            "present": present,
            "bytes": bytes,
            // Distinguishes "no file" from "a file that will not load" — the
            // loaders treat both as empty, so only this tells them apart.
            "parsed": if present { Some(parsed.is_some()) } else { None },
            "records": records,
        }));

        match (scope, parsed) {
            ("projects", Some(value)) => {
                for record in value["records"].as_array().cloned().unwrap_or_default() {
                    let project_id = record["project_id"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string();
                    let working_directory = record["working_directory"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string();
                    projects.push(json!({
                        "team_name": record["team_name"],
                        "project_id": project_id.clone(),
                        "working_directory": working_directory.clone(),
                        "leader_surface_id": record["leader_surface_id"],
                        "directory_present": !working_directory.is_empty()
                            && std::path::Path::new(&working_directory).is_dir(),
                        "live_surfaces": live_by_project.get(&project_id),
                    }));
                }
            }
            ("workspaces", Some(value)) => {
                for entry in value.as_array().cloned().unwrap_or_default() {
                    workspaces.push(json!({
                        "id": entry["id"],
                        "name": entry["name"],
                        "is_default": entry["is_default"],
                    }));
                }
            }
            _ => {}
        }
    }

    // Taking it exclusively for an instant is the only way to learn whether a
    // daemon holds it shared. Dropped immediately; a daemon that boots while
    // we hold it logs a warning and carries on.
    let lock_error = match try_lock_peer_state_dir(&dir) {
        Ok(lock) => {
            drop(lock);
            None
        }
        Err(error) => Some(error),
    };
    // The lock alone is not enough. A daemon built before the lock existed
    // never takes it, yet still saves a full snapshot over anything written
    // here — so a live socket has to count as ownership too.
    let reset_blocked_by = match (lock_error, live_sockets) {
        (Some(error), _) => Some(format!(
            "a running term-meshd holds the state lock ({error})"
        )),
        (None, 0) => None,
        (None, count) => Some(format!(
            "{count} live term-mesh socket(s): a daemon that predates the state \
             lock does not take it and would save over this"
        )),
    };

    json!({
        "directory": dir.display().to_string(),
        "reset_safe": reset_blocked_by.is_none(),
        "reset_blocked_by": reset_blocked_by,
        "files": files,
        "projects": projects,
        "workspaces": workspaces,
    })
}

fn cmd_doctor(verbose: bool, json_output: bool) {
    let app_socket = detect_socket();
    let daemon_socket = detect_daemon_socket();
    let sockets = discover_term_mesh_sockets();
    let team = resolve_team_name(None);
    let agent = env::var("TERMMESH_AGENT_NAME").unwrap_or_else(|_| "anonymous".into());

    let app_status = app_socket
        .as_ref()
        .and_then(|sock| rpc_call(sock, "team.status", json!({ "team_name": &team })).ok());
    let daemon_status = daemon_socket
        .as_ref()
        .and_then(|sock| rpc_call(sock, "daemon.status", json!({})).ok());

    // `discover_term_mesh_sockets` globs /tmp, which is where a Mac keeps its
    // sockets. A Linux peer host puts them under the systemd RuntimeDirectory
    // (/run/term-mesh), so counting only the glob's hits reports zero owners on
    // exactly the hosts this reset targets. Fold in the two resolved paths.
    let mut owner_paths: std::collections::BTreeSet<String> = sockets
        .iter()
        .filter(|socket| socket["alive"].as_bool().unwrap_or(false))
        .filter_map(|socket| socket["path"].as_str().map(str::to_string))
        .collect();
    for candidate in [daemon_socket.as_ref(), app_socket.as_ref()]
        .into_iter()
        .flatten()
    {
        if is_socket_alive(candidate) {
            owner_paths.insert(candidate.to_string_lossy().to_string());
        }
    }
    let live_sockets = owner_paths.len();
    // Same fallback `daemon project-presentations` uses: the peer host answers
    // on whichever of the two sockets this machine actually exposes.
    let peer_rpc_socket = daemon_socket.as_ref().or(app_socket.as_ref());
    let peer_state = peer_state_report(peer_rpc_socket, live_sockets);

    let result = json!({
        "ok": app_socket.is_some() || daemon_socket.is_some(),
        "team": team,
        "agent": agent,
        "app_socket": app_socket.as_ref().map(|p| p.to_string_lossy().to_string()),
        "daemon_socket": daemon_socket.as_ref().map(|p| p.to_string_lossy().to_string()),
        "app_status": app_status,
        "daemon_status": daemon_status,
        "sockets": if verbose { Value::Array(sockets.clone()) } else { json!(sockets.iter().filter(|s| s["alive"].as_bool().unwrap_or(false)).count()) },
        "peer_state": peer_state,
    });

    if json_output {
        println!("{}", pretty(&result));
        return;
    }

    println!("tm-agent doctor");
    println!("team: {}", result["team"].as_str().unwrap_or("unknown"));
    println!("agent: {}", result["agent"].as_str().unwrap_or("unknown"));
    println!(
        "app socket: {}",
        result["app_socket"].as_str().unwrap_or("not found")
    );
    println!(
        "daemon socket: {}",
        result["daemon_socket"].as_str().unwrap_or("not found")
    );
    if verbose {
        println!("sockets:");
        for socket in sockets {
            println!(
                "  {} {}",
                if socket["alive"].as_bool().unwrap_or(false) {
                    "alive"
                } else {
                    "dead"
                },
                socket["path"].as_str().unwrap_or("")
            );
        }
    } else {
        println!("alive sockets: {}", result["sockets"].as_u64().unwrap_or(0));
    }

    println!(
        "peer state: {}",
        peer_state["directory"].as_str().unwrap_or("?")
    );
    for file in peer_state["files"].as_array().cloned().unwrap_or_default() {
        let scope = file["scope"].as_str().unwrap_or("?");
        if !file["present"].as_bool().unwrap_or(false) {
            println!("  {scope}: absent");
            continue;
        }
        // A file that will not parse loads as empty, silently. Say so.
        if file["parsed"].as_bool() == Some(false) {
            println!("  {scope}: UNREADABLE (loads as empty)");
            continue;
        }
        println!(
            "  {scope}: {} record(s)",
            file["records"].as_u64().unwrap_or(0)
        );
    }
    for project in peer_state["projects"]
        .as_array()
        .cloned()
        .unwrap_or_default()
    {
        let live = match project["live_surfaces"].as_u64() {
            Some(count) => format!("{count} live surface(s)"),
            None => "liveness unknown (no daemon)".to_string(),
        };
        println!(
            "    project {} [{}] dir={} {}{}",
            project["team_name"].as_str().unwrap_or("?"),
            project["project_id"].as_str().unwrap_or("?"),
            project["working_directory"].as_str().unwrap_or("?"),
            live,
            if project["directory_present"].as_bool().unwrap_or(false) {
                ""
            } else {
                " (directory gone)"
            }
        );
    }
    for workspace in peer_state["workspaces"]
        .as_array()
        .cloned()
        .unwrap_or_default()
    {
        println!(
            "    workspace {}{}",
            workspace["name"].as_str().unwrap_or("?"),
            if workspace["is_default"].as_bool().unwrap_or(false) {
                " (default)"
            } else {
                ""
            }
        );
    }
    match peer_state["reset_blocked_by"].as_str() {
        Some(reason) => println!("  reset: unsafe — {reason}"),
        None => println!("  reset: safe (no daemon holds this directory)"),
    }

    println!(
        "status: {}",
        if result["ok"].as_bool().unwrap_or(false) {
            "ok"
        } else {
            "no live sockets found"
        }
    );
}

/// Check if an agent is headless by querying the daemon's headless.resolve RPC.
fn is_headless_agent(daemon_sock: &PathBuf, team: &str, agent_name: &str) -> Option<String> {
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

fn run_create_headless(
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

fn run_add_headless(
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

struct DelegateOptions<'a> {
    title: Option<String>,
    priority: Option<u32>,
    accept: &'a [String],
    deps: &'a [String],
    desc: Option<String>,
    no_report: bool,
    context: Option<&'a str>,
    fix_budget: Option<u8>,
    panel_id: Option<&'a str>,
    agent_instance_id: Option<&'a str>,
    worktree_policy: WorktreePolicyArg,
    from_ref: Option<&'a str>,
    request_id: Option<&'a str>,
    /// Measurement only, forwarded verbatim to the board. See `TeamTask.route`.
    route: Option<&'a str>,
    /// Measurement only, forwarded verbatim to the board. See `TeamTask.waveId`.
    wave_id: Option<&'a str>,
}

fn run_delegate_result(
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

fn delegate_rpc_params(
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
enum UnifiedDelegateOutcome {
    Response(Value),
    LegacyFallback,
}

fn delegate_response_is_explicitly_unsupported(response: &Value) -> bool {
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

fn delegate_error_is_explicitly_unsupported(error: &str) -> bool {
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

const DELEGATE_AGENT_BUSY_HINT: &str =
    "\nHint: Agent has an active task — finish/block it first, or delegate to another idle agent.";

fn delegate_response_error_code(response: &Value) -> Option<&str> {
    response["error"]["code"]
        .as_str()
        .or_else(|| response["result"]["error_code"].as_str())
}

fn delegate_error_with_agent_busy_hint(error: String) -> String {
    if error.contains("[agent_busy]") && !error.contains(DELEGATE_AGENT_BUSY_HINT) {
        format!("{error}{DELEGATE_AGENT_BUSY_HINT}")
    } else {
        error
    }
}

fn resolve_unified_delegate<F>(
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
struct GkWorktreeMeta {
    path: String,
    branch: String,
    parent: Option<String>,
    created: Option<bool>,
    reused: Option<bool>,
    init: Option<String>,
}

fn should_acquire_worktree(
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

fn sanitize_branch_component(raw: &str) -> String {
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

fn xmb_project_from_text(text: &str) -> Option<String> {
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

fn worktree_branch_for_task(team: &str, task: &Value, text: &str) -> String {
    let task_id = task["id"].as_str().unwrap_or("task");
    let task_short = sanitize_branch_component(task_id);
    if let Some(project) = xmb_project_from_text(text) {
        format!("xmb/{project}/{task_short}")
    } else {
        format!("tm/{}/{}", sanitize_branch_component(team), task_short)
    }
}

fn run_gk_json(args: &[String], cwd: Option<&str>) -> Result<Value, String> {
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

fn epoch_ms_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

struct TaskWorktreeLock {
    path: PathBuf,
}

impl Drop for TaskWorktreeLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn acquire_task_worktree_lock(team: &str, task_id: &str) -> Result<TaskWorktreeLock, String> {
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

fn gk_wt_acquire(
    branch: &str,
    from_ref: Option<&str>,
    working_directory: Option<&str>,
) -> Result<GkWorktreeMeta, String> {
    gk_wt_acquire_with(branch, from_ref, working_directory, run_gk_json)
}

fn gk_wt_acquire_with<F>(
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

fn update_task_with_worktree(
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
fn mark_task_isolation_degraded(sock: &PathBuf, team: &str, task_id: &str, reason: &str) {
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

fn block_task_for_worktree_error(sock: &PathBuf, team: &str, task_id: &str, reason: &str) {
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

fn run_task_finish_worktree(
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

fn worktree_task_create_params(
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

fn run_delegate_result_with_worktree(
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

fn run_delegate(
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
fn run_delegate_autonomous(
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

fn run_fan_out(
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

/// Connect to the daemon's `events.subscribe` streaming endpoint and print
/// each received JSONL event to stdout until timeout or Ctrl+C.
fn run_watch(
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
fn run_watch_command(sock: &PathBuf, action: &WatchAction) {
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
fn print_watch_trigger(resp: &Value) {
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
fn print_watch_status(resp: &Value) {
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
fn fmt_tick(v: Option<&Value>, now: u64, future: bool) -> String {
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
fn fmt_dur(secs: u64) -> String {
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        format!("{}m", secs / 60)
    } else {
        format!("{}h", secs / 3600)
    }
}

fn run_warmup(sock: &PathBuf, team: &str, target: Option<&str>, timeout: u32) {
    use std::time::Instant;

    // Get agent list
    let status = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };
    let agents = status["result"]["agents"]
        .as_array()
        .unwrap_or(&vec![])
        .clone();
    if agents.is_empty() {
        eprintln!("No agents in team '{team}'");
        process::exit(1);
    }

    // Filter to specific agent if requested
    let targets: Vec<&Value> = if let Some(name) = target {
        let filtered: Vec<&Value> = agents
            .iter()
            .filter(|a| a["name"].as_str() == Some(name))
            .collect();
        if filtered.is_empty() {
            eprintln!("Agent '{name}' not found in team '{team}'");
            process::exit(1);
        }
        filtered
    } else {
        agents.iter().collect()
    };

    let count = targets.len();
    eprintln!("Warming up {count} agent(s) in team '{team}'...");

    // Delegate pong task to each agent
    let mut task_ids: Vec<(String, String, String, Instant)> = Vec::new(); // (name, instance, task, start)
    let mut failed: Vec<(String, String, u128, String)> = Vec::new(); // (name, instance, ms, reason)
    for agent_val in &targets {
        let name = agent_val["name"].as_str().unwrap_or("?");
        let instance_id = agent_val["agent_instance_id"].as_str().unwrap_or("");
        if instance_id.is_empty() {
            eprintln!("  {name}: missing agent_instance_id");
            failed.push((
                name.to_string(),
                "unknown".to_string(),
                0,
                "missing agent_instance_id".into(),
            ));
            continue;
        }
        let start = Instant::now();
        let result = run_delegate_result(
            sock,
            team,
            name,
            "Reply with exactly one word: pong",
            DelegateOptions {
                title: Some("warmup-ping".to_string()),
                priority: Some(3),
                accept: &[],
                deps: &[],
                desc: None,
                no_report: true,
                context: None,
                fix_budget: None,
                panel_id: None,
                agent_instance_id: Some(instance_id),
                worktree_policy: WorktreePolicyArg::Off,
                from_ref: None,
                request_id: None,
                route: None,
                wave_id: None,
            },
        );
        match result {
            Ok(v) => {
                if let Some(tid) = v["result"]["task"]["id"].as_str() {
                    let assigned_instance = v["result"]["task"]["agent_instance_id"]
                        .as_str()
                        .unwrap_or(instance_id);
                    task_ids.push((
                        name.to_string(),
                        assigned_instance.to_string(),
                        tid.to_string(),
                        start,
                    ));
                } else {
                    eprintln!("  {name} ({instance_id}): failed to create task");
                    failed.push((
                        name.to_string(),
                        instance_id.to_string(),
                        start.elapsed().as_millis(),
                        "dispatch failed".into(),
                    ));
                }
            }
            Err(e) => {
                eprintln!("  {name} ({instance_id}): delegate error: {e}");
                failed.push((
                    name.to_string(),
                    instance_id.to_string(),
                    start.elapsed().as_millis(),
                    "dispatch failed".into(),
                ));
            }
        }
    }

    if task_ids.is_empty() {
        eprintln!("No warmup tasks created");
        process::exit(1);
    }

    // Poll for completion
    let deadline = Instant::now() + Duration::from_secs(timeout as u64);
    let mut completed: Vec<(String, String, u128, String)> = Vec::new(); // (name, instance, ms, result)
    let mut pending = task_ids.clone();

    while !pending.is_empty() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(500));
        let mut still_pending = Vec::new();
        for (agent_name, instance_id, tid, start) in &pending {
            if let Ok(v) = rpc_call(
                sock,
                "team.task.get",
                json!({
                    "team_name": team, "task_id": tid,
                }),
            ) {
                let status = v["result"]["status"].as_str().unwrap_or("");
                if matches!(status, "completed" | "review_ready" | "blocked") {
                    let ms = start.elapsed().as_millis();
                    let result = v["result"]["result"].as_str().unwrap_or("").to_string();
                    if warmup_task_succeeded(status, &result) {
                        completed.push((agent_name.clone(), instance_id.clone(), ms, result));
                    } else {
                        failed.push((
                            agent_name.clone(),
                            instance_id.clone(),
                            ms,
                            status.to_string(),
                        ));
                    }
                    continue;
                }
            }
            still_pending.push((agent_name.clone(), instance_id.clone(), tid.clone(), *start));
        }
        pending = still_pending;
    }

    // Print results
    let pass = completed.len();
    let fail = failed.len() + pending.len();
    println!();
    for (name, instance_id, ms, result) in &completed {
        let icon = if result.to_lowercase().contains("pong") {
            "✓"
        } else {
            "?"
        };
        println!("  {icon} {name} ({instance_id}): {ms}ms");
    }
    for (name, instance_id, _, start) in &pending {
        let ms = start.elapsed().as_millis();
        println!("  ✗ {name} ({instance_id}): timeout ({ms}ms)");
    }
    for (name, instance_id, ms, reason) in &failed {
        println!("  ✗ {name} ({instance_id}): {reason} without pong ({ms}ms)");
    }
    println!();
    if fail == 0 {
        println!("All {pass} agent(s) warm ✓");
    } else {
        println!("{pass} warm, {fail} timed out");
        process::exit(1);
    }
}

fn warmup_task_succeeded(status: &str, result: &str) -> bool {
    matches!(status, "completed" | "review_ready")
        && result
            .split(|character: char| !character.is_ascii_alphanumeric())
            .any(|word| word.eq_ignore_ascii_case("pong"))
}

/// Work-stealing: claim the next available pending/unassigned task for this agent.
fn run_claim(sock: &PathBuf, team: &str, agent: &str) {
    let result = rpc_call(
        sock,
        "team.task.claim",
        json!({
            "team_name": team,
            "agent_name": agent,
            "push": false,
        }),
    );
    match result {
        Ok(mut v) if v["ok"].as_bool().unwrap_or(false) => {
            if v["result"].is_null() {
                println!(
                    "{}",
                    pretty(
                        &json!({ "ok": true, "result": null, "message": "No claimable tasks available" })
                    )
                );
            } else {
                let mut task = v["result"].clone();
                let task_id = task["id"].as_str().unwrap_or("").to_string();
                let title = task["title"].as_str().unwrap_or("Claimed task").to_string();
                let details = task["details"]
                    .as_str()
                    .or_else(|| task["description"].as_str())
                    .filter(|s| !s.is_empty())
                    .map(String::from);
                let goal = details.clone().unwrap_or_else(|| title.clone());
                let policy = parse_worktree_policy_name(task["worktree_policy"].as_str());

                if task["worktree_path"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .is_none()
                    && should_acquire_worktree(policy, agent, &goal, &title, details.as_deref())
                {
                    let branch = worktree_branch_for_task(team, &task, &goal);
                    match gk_wt_acquire(&branch, None, None) {
                        Ok(meta) => {
                            match update_task_with_worktree(sock, team, &task_id, &meta, policy) {
                                Ok(updated) => {
                                    task = updated["result"].clone();
                                    v["result"] = task.clone();
                                }
                                Err(e) => {
                                    let reason =
                                        format!("task.update worktree metadata failed: {e}");
                                    block_task_for_worktree_error(sock, team, &task_id, &reason);
                                    eprintln!("Error: {reason}");
                                    process::exit(1);
                                }
                            }
                        }
                        Err(e) if !worktree_failure_is_fatal(policy, &e) => {
                            mark_task_isolation_degraded(sock, team, &task_id, &e);
                            eprintln!(
                                "note: {e}; running {task_id} in the shared checkout \
                                 without worktree isolation"
                            );
                        }
                        Err(e) => {
                            let reason = format!("worktree acquire failed: {e}");
                            block_task_for_worktree_error(sock, team, &task_id, &reason);
                            eprintln!("Error: {reason} (task_id={task_id})");
                            process::exit(1);
                        }
                    }
                }

                let instruction =
                    format_task_instruction(sock, team, &task, &goal, false, None, None);
                let send_text = format!("{instruction}\n");
                let send_result = if let Some(daemon_sock) = team_headless_daemon_socket() {
                    if let Some(agent_id) = is_headless_agent(&daemon_sock, team, agent) {
                        match rpc_call(
                            &daemon_sock,
                            "headless.send",
                            json!({
                                "agent_id": agent_id,
                                "text": &send_text,
                            }),
                        ) {
                            Ok(hr) if !hr["result"].is_null() => {
                                let mut result = hr["result"].clone();
                                if result.is_object() {
                                    // headless.send is the whole submission — no pane
                                    // exists for a Return — so declare it and spare the
                                    // follow-up its ~11 s headless_no_pane ladder.
                                    result["return_required"] = json!(false);
                                }
                                Ok(json!({ "ok": true, "result": result }))
                            }
                            Ok(hr) => Err(format!("headless.send returned null: {}", pretty(&hr))),
                            Err(e) => Err(format!("headless.send: {e}")),
                        }
                    } else {
                        rpc_call(
                            sock,
                            "team.send",
                            json!({
                                "team_name": team,
                                "agent_name": agent,
                                "text": &send_text,
                                "send_sequence_aware": true,
                            }),
                        )
                    }
                } else {
                    rpc_call(
                        sock,
                        "team.send",
                        json!({
                            "team_name": team,
                            "agent_name": agent,
                            "text": &send_text,
                            "send_sequence_aware": true,
                        }),
                    )
                };

                match send_result {
                    Ok(sent) if sent["ok"].as_bool().unwrap_or(true) => {
                        let _ = send_return_key_with_retry(
                            sock,
                            team,
                            agent,
                            true,
                            "team.task.claim",
                            None,
                            None,
                            sent["result"]["send_sequence_id"].as_str(),
                            send_response_return_required(&sent),
                        );
                        println!(
                            "{}",
                            pretty(&json!({
                                "ok": true,
                                "result": {
                                    "task": task,
                                    "send": sent,
                                }
                            }))
                        );
                    }
                    Ok(sent) => {
                        let reason = format!("claim delivery failed: {}", pretty(&sent));
                        block_task_for_worktree_error(sock, team, &task_id, &reason);
                        eprintln!("Error: {reason}");
                        process::exit(1);
                    }
                    Err(e) => {
                        let reason = format!("claim delivery failed: {e}");
                        block_task_for_worktree_error(sock, team, &task_id, &reason);
                        eprintln!("Error: {reason}");
                        process::exit(1);
                    }
                }
            }
        }
        Ok(ref v) => println!("{}", pretty(v)),
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    }
}

/// Returns capabilities (keywords) for a given agent_type.
/// Used by `tm-agent suggest` to match task descriptions to agents.
fn capabilities_for_agent_type(agent_type: &str) -> Vec<&'static str> {
    match agent_type.to_lowercase().as_str() {
        "architect" => vec![
            "architecture",
            "design",
            "system",
            "review",
            "structure",
            "plan",
            "interface",
            "boundary",
        ],
        "executor" => vec![
            "implement",
            "code",
            "coding",
            "refactor",
            "fix",
            "build",
            "develop",
            "feature",
        ],
        "explorer" => vec![
            "explore",
            "discover",
            "search",
            "analyze",
            "investigate",
            "map",
            "find",
        ],
        "reviewer" => vec![
            "review",
            "check",
            "audit",
            "quality",
            "lint",
            "standards",
            "critique",
        ],
        "tester" => vec![
            "test",
            "testing",
            "qa",
            "verification",
            "unit",
            "integration",
            "e2e",
            "spec",
        ],
        "debugger" => vec![
            "debug",
            "trace",
            "crash",
            "error",
            "bug",
            "fix",
            "diagnose",
            "root cause",
        ],
        "writer" => vec![
            "document",
            "docs",
            "readme",
            "guide",
            "migration",
            "notes",
            "write",
        ],
        "security" => vec![
            "security",
            "auth",
            "vulnerability",
            "pentest",
            "owasp",
            "injection",
            "xss",
        ],
        "ai" => vec![
            "ai",
            "ml",
            "llm",
            "model",
            "inference",
            "prompt",
            "embedding",
            "rag",
        ],
        "backend" => vec![
            "api", "server", "database", "backend", "service", "schema", "query", "rest",
        ],
        "frontend" => vec![
            "ui",
            "frontend",
            "component",
            "react",
            "swiftui",
            "css",
            "layout",
            "ux",
        ],
        "watcher" => vec![
            "watch",
            "oversight",
            "drift",
            "monitor",
            "spec",
            "review",
            "audit",
        ],
        _ => vec![],
    }
}

/// Score how well a task description matches an agent's capabilities.
fn capability_score(description_lower: &str, capabilities: &[&str]) -> usize {
    capabilities
        .iter()
        .filter(|kw| description_lower.contains(*kw))
        .count()
}

/// Suggest the best agent for a task description based on capability mapping.
fn run_suggest(sock: &PathBuf, team: &str, description: &str) {
    let status = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };

    let agents = match status["result"]["agents"].as_array() {
        Some(a) => a.clone(),
        None => {
            eprintln!("Error: no agents in team");
            process::exit(1);
        }
    };

    let desc_lower = description.to_lowercase();
    let mut scored: Vec<(String, String, Vec<&'static str>, usize)> = agents
        .iter()
        .filter_map(|a| {
            let name = a["name"].as_str()?.to_string();
            let agent_type = a["agent_type"].as_str().unwrap_or(&name).to_string();
            let caps = capabilities_for_agent_type(&agent_type);
            let score = capability_score(&desc_lower, &caps);
            Some((name, agent_type, caps, score))
        })
        .collect();

    scored.sort_by(|a, b| b.3.cmp(&a.3));

    let suggestions: Vec<Value> = scored
        .iter()
        .map(|(name, agent_type, caps, score)| {
            json!({
                "agent": name,
                "agent_type": agent_type,
                "capabilities": caps,
                "score": score,
            })
        })
        .collect();

    let best = scored
        .first()
        .map(|(name, _, _, _)| name.as_str())
        .unwrap_or("none");
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "ok": true,
            "result": {
                "task": description,
                "best_match": best,
                "ranking": suggestions,
            }
        }))
        .unwrap_or_default()
    );
}

fn run_brief(sock: &PathBuf, team: &str, target: &str, lines: u32) {
    let status = match rpc_call(sock, "team.status", json!({ "team_name": team })) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };

    let agents = status["result"]["agents"].as_array();
    let agent_info = agents.and_then(|arr| arr.iter().find(|a| a["name"].as_str() == Some(target)));
    let agent_info = match agent_info {
        Some(a) => a.clone(),
        None => {
            eprintln!("Error: agent '{target}' not found in team '{team}'");
            process::exit(1);
        }
    };

    // Get active task
    let mut active_task = json!(null);
    if let Some(task_id) = agent_info["active_task_id"].as_str() {
        if let Ok(r) = rpc_call(
            sock,
            "team.task.get",
            json!({ "team_name": team, "task_id": task_id }),
        ) {
            if r["ok"].as_bool().unwrap_or(false) {
                active_task = r["result"].clone();
            }
        }
    }

    // Get recent messages
    let mut messages = json!([]);
    if let Ok(r) = rpc_call(
        sock,
        "team.message.list",
        json!({ "team_name": team, "from": target, "limit": 5 }),
    ) {
        if r["ok"].as_bool().unwrap_or(false) {
            messages = r["result"]["messages"].clone();
        }
    }

    // Read terminal output (3-level fallback)
    let mut terminal_tail = String::new();

    // 1: team.read
    if let Ok(r) = rpc_call(
        sock,
        "team.read",
        json!({ "team_name": team, "agent_name": target, "lines": lines }),
    ) {
        if r["ok"].as_bool().unwrap_or(false) {
            terminal_tail = r["result"]["text"].as_str().unwrap_or("").to_string();
        }
    }

    // 2: pane.read
    if terminal_tail.trim().is_empty() {
        if let Some(panel_id) = agent_info["panel_id"].as_str() {
            if let Ok(r) = rpc_call(
                sock,
                "pane.read",
                json!({ "panel_id": panel_id, "lines": lines }),
            ) {
                if r["ok"].as_bool().unwrap_or(false) {
                    terminal_tail = r["result"]["text"].as_str().unwrap_or("").to_string();
                }
            }
        }
    }

    // 3: last report
    if terminal_tail.trim().is_empty() {
        if let Ok(r) = rpc_call(
            sock,
            "team.reports",
            json!({ "team_name": team, "agent_name": target, "limit": 1 }),
        ) {
            if r["ok"].as_bool().unwrap_or(false) {
                if let Some(reports) = r["result"]["reports"].as_array() {
                    if let Some(first) = reports.first() {
                        let content = first["content"].as_str().unwrap_or("");
                        let trunc = if content.len() > 500 {
                            let mut end = 500;
                            while end > 0 && !content.is_char_boundary(end) {
                                end -= 1;
                            }
                            &content[..end]
                        } else {
                            content
                        };
                        terminal_tail = format!("[Last report] {trunc}");
                    }
                }
            }
        }
    }

    println!(
        "{}",
        pretty(&json!({
            "team_name": team,
            "agent": {
                "name": agent_info["name"],
                "status": agent_info["status"],
                "agent_type": agent_info["agent_type"],
                "panel_id": agent_info["panel_id"],
                "active_task_id": agent_info["active_task_id"],
                "active_task_status": agent_info["active_task_status"],
                "active_task_title": agent_info["active_task_title"],
                "attention_reason": agent_info["attention_reason"],
                "last_heartbeat_at": agent_info["last_heartbeat_at"],
                "last_heartbeat_summary": agent_info["last_heartbeat_summary"],
                "heartbeat_age_seconds": agent_info["heartbeat_age_seconds"],
                "heartbeat_is_stale": agent_info["heartbeat_is_stale"],
            },
            "active_task": active_task,
            "recent_messages": messages,
            "terminal_tail": terminal_tail,
        }))
    );
}

/// Read board.jsonl and print a human-readable synthesis to stderr.
/// Each line in board.jsonl is expected to be a JSON object with fields:
///   agent, round, finding, source, implication
/// Missing fields are tolerated — raw JSON is used as fallback.
/// Poll task IDs until all are completed/failed/abandoned, or timeout.
/// Returns the set of task IDs that completed successfully.
fn wait_for_tasks(
    sock: &PathBuf,
    team: &str,
    task_ids: &[String],
    timeout_secs: u64,
    label: &str,
) -> Vec<String> {
    if task_ids.is_empty() {
        return Vec::new();
    }
    eprintln!(
        "Waiting for {} task(s) to complete ({}, timeout: {}s)...",
        task_ids.len(),
        label,
        timeout_secs
    );
    let poll_interval = Duration::from_secs(3);
    let start = std::time::Instant::now();
    let deadline = start + Duration::from_secs(timeout_secs);
    let mut completed_ids: Vec<String> = Vec::new();
    loop {
        if std::time::Instant::now() >= deadline {
            eprintln!(
                "Timeout: {}/{} tasks completed within {}s",
                completed_ids.len(),
                task_ids.len(),
                timeout_secs
            );
            break;
        }
        thread::sleep(poll_interval);
        let mut all_done = true;
        let mut done_count = 0usize;
        if let Ok(r) = rpc_call(sock, "team.task.list", json!({ "team_name": team })) {
            if let Some(tasks) = r["result"]["tasks"].as_array() {
                completed_ids.clear();
                for tid in task_ids {
                    let task_status = tasks
                        .iter()
                        .find(|t| t["id"].as_str() == Some(tid.as_str()))
                        .and_then(|t| t["status"].as_str());
                    match task_status {
                        Some("completed") => {
                            done_count += 1;
                            completed_ids.push(tid.clone());
                        }
                        Some("failed") | Some("abandoned") => {
                            done_count += 1;
                        }
                        _ => {
                            all_done = false;
                        }
                    }
                }
            }
        }
        let elapsed = start.elapsed().as_secs();
        eprintln!(
            "  [{}/{}s] {}/{} done ({})",
            elapsed,
            timeout_secs,
            done_count,
            task_ids.len(),
            label
        );
        if all_done {
            break;
        }
    }
    completed_ids
}

/// Dispatch delegates with stagger and wait for completion.
/// Returns (agent_name, task_id, agent_instance_id) for dispatched tasks.
fn dispatch_and_wait(
    sock: &PathBuf,
    team: &str,
    timeout_secs: u64,
    agents_and_prompts: Vec<(String, String, String)>, // (agent_name, prompt, title)
    label: &str,
) -> Vec<(String, String, Option<String>)> {
    // (agent_name, task_id, agent_instance_id) for dispatched tasks
    let mut handles = Vec::new();
    for (i, (name, prompt, title)) in agents_and_prompts.into_iter().enumerate() {
        if i > 0 {
            thread::sleep(Duration::from_secs(2)); // stagger to avoid pane contention
        }
        let sock_clone = sock.clone();
        let team_owned = team.to_string();
        let h = thread::spawn(move || {
            let result = run_delegate_result(
                &sock_clone,
                &team_owned,
                &name,
                &prompt,
                DelegateOptions {
                    title: Some(title),
                    priority: None,
                    accept: &[],
                    deps: &[],
                    desc: None,
                    no_report: false,
                    context: None,
                    fix_budget: None,
                    panel_id: None,
                    agent_instance_id: None,
                    worktree_policy: WorktreePolicyArg::Off,
                    from_ref: None,
                    request_id: None,
                    route: None,
                    wave_id: None,
                },
            );
            (name, result)
        });
        handles.push(h);
    }

    let results: Vec<(String, Result<Value, String>)> = handles
        .into_iter()
        .map(|h| h.join().expect("thread panicked"))
        .collect();

    let mut agent_task_pairs: Vec<(String, String, Option<String>)> = Vec::new();
    let mut task_ids: Vec<String> = Vec::new();
    for (name, result) in &results {
        match result {
            Ok(v) => {
                if let Some(tid) = v["result"]["task"]["id"].as_str() {
                    task_ids.push(tid.to_string());
                    let instance_id = v["result"]["task"]["agent_instance_id"]
                        .as_str()
                        .map(str::to_string);
                    agent_task_pairs.push((name.clone(), tid.to_string(), instance_id));
                }
            }
            Err(e) => {
                eprintln!("  {name}: delegate failed: {e}");
            }
        }
    }

    // Wait for all tasks to complete
    wait_for_tasks(sock, team, &task_ids, timeout_secs, label);
    agent_task_pairs
}

fn task_result_candidates(
    team: &str,
    task_id: &str,
    agent_name: &str,
    agent_instance_id: Option<&str>,
) -> Vec<PathBuf> {
    let mut candidates = vec![result_file_path(team, &format!("{task_id}.md"))];
    candidates.push(result_file_path(
        team,
        &reply_alias_filename(agent_name, agent_instance_id),
    ));
    candidates
}

/// Read canonical task output first, then its instance alias. Name-only alias
/// fallback is retained only for legacy tasks that have no durable instance id.
fn read_task_result(
    team: &str,
    task_id: &str,
    agent_name: &str,
    agent_instance_id: Option<&str>,
) -> String {
    task_result_candidates(team, task_id, agent_name, agent_instance_id)
        .into_iter()
        .find_map(|path| std::fs::read_to_string(path).ok())
        .unwrap_or_else(|| "(no response)".to_string())
}

fn synthesize_board(board_path: &PathBuf, board_path_str: &str) {
    use std::collections::HashMap;
    use std::fs::File;
    use std::io::{BufRead, BufReader};

    let file = match File::open(board_path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("\n══ Research Results ══");
            eprintln!("(Could not read board.jsonl: {e})");
            eprintln!("Board path: {board_path_str}");
            return;
        }
    };

    let reader = BufReader::new(file);
    let mut entries: Vec<Value> = Vec::new();
    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        match serde_json::from_str::<Value>(trimmed) {
            Ok(v) => entries.push(v),
            Err(_) => {
                // Keep malformed lines as raw string values so they appear in output
                entries.push(Value::String(trimmed.to_string()));
            }
        }
    }

    eprintln!("\n══ Research Results ══");

    if entries.is_empty() {
        eprintln!("No board entries found. Check agent outputs above for results.");
        eprintln!("Board path: {board_path_str}");
        return;
    }

    // Count entries per agent and rounds covered
    let mut per_agent: HashMap<String, usize> = HashMap::new();
    let mut rounds: std::collections::BTreeSet<u64> = std::collections::BTreeSet::new();
    for entry in &entries {
        let agent = entry
            .get("agent")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();
        *per_agent.entry(agent).or_insert(0) += 1;
        if let Some(r) = entry.get("round").and_then(|v| v.as_u64()) {
            rounds.insert(r);
        }
    }

    let rounds_str = if rounds.is_empty() {
        "unknown".to_string()
    } else {
        let v: Vec<String> = rounds.iter().map(|r| r.to_string()).collect();
        v.join(", ")
    };

    eprintln!(
        "Board statistics: {} entries | {} agent(s) | rounds: {}",
        entries.len(),
        per_agent.len(),
        rounds_str
    );
    for (agent, count) in &per_agent {
        eprintln!("  {agent}: {count} finding(s)");
    }
    eprintln!();

    // Print each entry in readable format
    for (i, entry) in entries.iter().enumerate() {
        match entry {
            Value::Object(_) => {
                let agent = entry
                    .get("agent")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown");
                let round = entry
                    .get("round")
                    .and_then(|v| v.as_u64())
                    .map(|r| r.to_string())
                    .unwrap_or_else(|| "?".to_string());
                let finding = entry
                    .get("finding")
                    .and_then(|v| v.as_str())
                    .unwrap_or("(no finding field)");
                let source = entry.get("source").and_then(|v| v.as_str()).unwrap_or("");
                let implication = entry
                    .get("implication")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");

                eprintln!("[{}] (round {}): {}", agent, round, finding);
                if !source.is_empty() {
                    eprintln!("  source: {source}");
                }
                if !implication.is_empty() {
                    eprintln!("  implication: {implication}");
                }
            }
            Value::String(raw) => {
                eprintln!("[entry {}]: {}", i + 1, raw);
            }
            other => {
                eprintln!("[entry {}]: {}", i + 1, other);
            }
        }
    }

    eprintln!("\nBoard path: {board_path_str}");
}

fn run_autonomous(
    sock: &PathBuf,
    team: &str,
    mode: &str,  // "research", "solve", "consensus", "swarm"
    topic: &str, // topic/problem/question/goal
    agents_requested: u32,
    budget: u32,
    timeout: u64,
    depth: &str,
    web: bool,
    focus: Option<&str>,
    no_discuss: bool,
    // Mode-specific options:
    verify_cmd: Option<&str>, // solve only
    target: Option<&str>,     // solve only
    extra: Option<&str>,      // consensus: perspectives, swarm: seed tasks
) {
    let idle = detect_idle_agents(sock, team, None);
    let (selected, warn_or_err) = select_agents(idle, agents_requested);

    if selected.is_empty() {
        eprintln!("Error: {}", warn_or_err.unwrap_or_default());
        process::exit(1);
    }
    if let Some(ref w) = warn_or_err {
        eprintln!("{w}");
    }

    let agent_names: Vec<&str> = selected.iter().map(|a| a.name.as_str()).collect();
    let total_agents = agent_names.len() as u32;
    eprintln!(
        "{}: topic='{}' agents={} budget={} timeout={}s",
        mode.to_uppercase(),
        topic,
        agent_names.join(","),
        budget,
        timeout
    );

    let (board_path, run_id) = match create_board(mode) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error creating {mode} board: {e}");
            process::exit(1);
        }
    };
    let board_path_str = board_path_for_prompt(&board_path);
    eprintln!("Board: {board_path_str} (run: {run_id})");

    // For swarm mode: seed initial tasks to board
    if mode == "swarm" {
        let seed_tasks: Vec<&str> = extra
            .map(|s| s.split(',').map(|t| t.trim()).collect::<Vec<_>>())
            .unwrap_or_default();
        if seed_tasks.is_empty() {
            // Auto-generate 3 generic seed tasks
            let seeds = vec![
                format!(
                    r#"{{"type":"task","id":1,"desc":"Analyze scope and requirements for: {}","status":"open","added_by":"leader"}}"#,
                    topic
                ),
                format!(
                    r#"{{"type":"task","id":2,"desc":"Identify key components and dependencies","status":"open","added_by":"leader"}}"#
                ),
                format!(
                    r#"{{"type":"task","id":3,"desc":"Create implementation plan with priorities","status":"open","added_by":"leader"}}"#
                ),
            ];
            let mut content = String::new();
            for s in &seeds {
                content.push_str(s);
                content.push('\n');
            }
            let _ = std::fs::write(&board_path, &content);
        } else {
            let mut content = String::new();
            for (i, task) in seed_tasks.iter().enumerate() {
                content.push_str(&format!(
                    r#"{{"type":"task","id":{},"desc":"{}","status":"open","added_by":"leader"}}"#,
                    i + 1,
                    task
                ));
                content.push('\n');
            }
            let _ = std::fs::write(&board_path, &content);
        }
    }

    // Build per-agent instructions
    let instructions: Vec<String> = agent_names
        .iter()
        .enumerate()
        .map(|(i, _name)| {
            let n = (i + 1) as u32;
            match mode {
                "research" => prompts::research_prompt(
                    topic,
                    &board_path_str,
                    n,
                    total_agents,
                    depth,
                    budget,
                    web,
                    focus,
                ),
                "solve" => prompts::solve_prompt(
                    topic,
                    &board_path_str,
                    n,
                    total_agents,
                    budget,
                    verify_cmd,
                    target,
                ),
                "consensus" => {
                    // Parse perspectives if provided, assign round-robin
                    let perspectives: Vec<&str> = extra
                        .map(|s| s.split(',').map(|t| t.trim()).collect::<Vec<_>>())
                        .unwrap_or_default();
                    let perspective = if perspectives.is_empty() {
                        None
                    } else {
                        Some(perspectives[i % perspectives.len()])
                    };
                    prompts::consensus_prompt(
                        topic,
                        &board_path_str,
                        n,
                        total_agents,
                        budget,
                        perspective,
                    )
                }
                "swarm" => {
                    prompts::swarm_prompt(topic, &board_path_str, n, total_agents, budget, extra)
                }
                _ => unreachable!(),
            }
        })
        .collect();

    // Stagger timing per mode
    let stagger_secs: u64 = match mode {
        "consensus" => 8,
        _ => 3,
    };

    // Dispatch to each agent
    let truncated_topic = match topic.char_indices().nth(60) {
        Some((idx, _)) => &topic[..idx],
        None => topic,
    };
    let task_title = format!("{}: {}", mode, truncated_topic);
    let mut handles = Vec::new();
    for (i, (name, instr)) in agent_names.iter().zip(instructions.iter()).enumerate() {
        if i > 0 {
            thread::sleep(Duration::from_secs(stagger_secs));
        }
        let instr = instr.clone();
        let title = task_title.clone();
        let sock_clone = sock.clone();
        let team_owned = team.to_string();
        let name_owned = name.to_string();
        let h = thread::spawn(move || {
            let result = run_delegate_result(
                &sock_clone,
                &team_owned,
                &name_owned,
                &instr,
                DelegateOptions {
                    title: Some(title),
                    priority: None,
                    accept: &[],
                    deps: &[],
                    desc: None,
                    no_report: false,
                    context: None,
                    fix_budget: None,
                    panel_id: None,
                    agent_instance_id: None,
                    worktree_policy: WorktreePolicyArg::Off,
                    from_ref: None,
                    request_id: None,
                    route: None,
                    wave_id: None,
                },
            );
            (name_owned, result)
        });
        handles.push(h);
    }

    let results: Vec<(String, Result<Value, String>)> = handles
        .into_iter()
        .map(|h| h.join().expect("thread panicked"))
        .collect();

    let mut succeeded: Vec<String> = Vec::new();
    let mut failed: Vec<String> = Vec::new();
    let mut task_ids: Vec<String> = Vec::new();
    for (name, result) in &results {
        match result {
            Ok(v) => {
                println!("{}", pretty(v));
                if let Some(tid) = v["result"]["task"]["id"].as_str() {
                    task_ids.push(tid.to_string());
                }
                succeeded.push(name.clone());
            }
            Err(e) => {
                eprintln!("Error delegating {mode} to {name}: {e}");
                failed.push(name.clone());
            }
        }
    }

    wait_for_tasks(sock, team, &task_ids, timeout, mode);
    synthesize_board(&board_path, &board_path_str);

    // === Discussion Phase (same for all modes) ===
    if !no_discuss && succeeded.len() >= 2 {
        let board_text = std::fs::read_to_string(&board_path).unwrap_or_default();
        if !board_text.trim().is_empty() {
            thread::sleep(Duration::from_secs(5));
            eprintln!("\n══ Discussion Phase ══");
            let discuss_timeout = 180u64;

            eprintln!("Phase 1: Cross-Review — agents examining each other's findings...");
            let cross_tasks: Vec<(String, String, String)> = succeeded
                .iter()
                .map(|name| {
                    let prompt = prompts::cross_review_prompt(topic, &board_text, name, &succeeded);
                    (
                        name.clone(),
                        prompt,
                        format!("{mode}-discuss: cross-review"),
                    )
                })
                .collect();
            let cross_pairs =
                dispatch_and_wait(sock, team, discuss_timeout, cross_tasks, "cross-review");

            let cross_texts: Vec<(String, String)> = cross_pairs
                .iter()
                .map(|(name, tid, instance_id)| {
                    (
                        name.clone(),
                        read_task_result(team, tid, name, instance_id.as_deref()),
                    )
                })
                .collect();

            for (name, text) in &cross_texts {
                let truncated = match text.char_indices().nth(500) {
                    Some((idx, _)) => &text[..idx],
                    None => text,
                };
                eprintln!("[{name}] cross-review:\n{truncated}\n");
            }

            if cross_texts.len() >= 2 {
                eprintln!("Phase 2: Synthesis — converging on consensus...");
                let cross_summary: String = cross_texts
                    .iter()
                    .map(|(name, text)| format!("### {name}의 교차 검토\n{text}"))
                    .collect::<Vec<_>>()
                    .join("\n\n");

                let synth_tasks: Vec<(String, String, String)> = succeeded
                    .iter()
                    .map(|name| {
                        let prompt = prompts::synthesis_prompt(topic, &cross_summary);
                        (name.clone(), prompt, format!("{mode}-discuss: synthesis"))
                    })
                    .collect();
                let synth_pairs =
                    dispatch_and_wait(sock, team, discuss_timeout, synth_tasks, "synthesis");

                eprintln!("\n══ Discussion Results ══");
                for (name, tid, instance_id) in &synth_pairs {
                    let text = read_task_result(team, tid, name, instance_id.as_deref());
                    eprintln!("[{name}] synthesis:\n{text}\n");
                }
            }
        }
    }

    println!(
        "{}",
        pretty(&json!({
            "ok": !succeeded.is_empty(),
            "result": {
                "mode": mode,
                "topic": topic,
                "budget": budget,
                "timeout_secs": timeout,
                "assigned": succeeded,
                "failed": failed,
                "agent_count": succeeded.len(),
                "board_path": board_path_str,
                "run_id": run_id,
            }
        }))
    );

    if succeeded.is_empty() {
        process::exit(1);
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

#[cfg(test)]
mod version_skew_tests {
    use super::version_skew_note;

    /// The case that cost an afternoon: a 0.167.0 CLI driving a 0.170.x app
    /// answered every leader command with `noMatchingLeaderSession`, a name
    /// that exists nowhere in the current tree. The note has to name both
    /// builds, or it explains nothing.
    #[test]
    fn different_builds_name_both_versions() {
        let note = version_skew_note("abc123456", "def987654", "0.167.0", "0.170.1")
            .expect("mismatched builds must produce a note");
        assert!(note.contains("0.167.0"), "{note}");
        assert!(note.contains("0.170.1"), "{note}");
        assert!(
            note.contains("abc123456") && note.contains("def987654"),
            "{note}"
        );
        // The actionable half: which binary is actually running.
        assert!(note.contains("command -v tm-agent"), "{note}");
    }

    #[test]
    fn matching_builds_say_nothing() {
        assert_eq!(
            version_skew_note("abc123456", "abc123456", "0.170.1", "0.170.1"),
            None
        );
    }

    /// An app that reports no SHA is unknown, not skewed. Printing a version
    /// warning under every unrelated failure would train people to ignore it.
    #[test]
    fn an_unknown_app_build_is_not_a_mismatch() {
        assert_eq!(
            version_skew_note("abc123456", "", "0.170.1", "unknown"),
            None
        );
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
