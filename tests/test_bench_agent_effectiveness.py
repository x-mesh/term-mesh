#!/usr/bin/env python3

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "bench-agent-effectiveness.py"
SPEC = importlib.util.spec_from_file_location("bench_agent_effectiveness", SCRIPT)
module = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


class EffectivenessBenchmarkTests(unittest.TestCase):
    def test_default_matrix_is_18_paired_counterbalanced_runs(self):
        specs = module.build_matrix(module.FIXTURES, 3, module.DEFAULT_SEED)
        self.assertEqual(len(specs), 18)
        for fixture in module.FIXTURES:
            rows = [spec for spec in specs if spec.fixture == fixture]
            self.assertEqual([(row.condition, row.order) for row in rows[:4]], [
                ("single", 1), ("multi", 2), ("multi", 1), ("single", 2),
            ])

    def test_matrix_is_deterministic_and_keeps_pairs_adjacent(self):
        first = module.build_matrix(module.FIXTURES, 5, 42)
        self.assertEqual(first, module.build_matrix(module.FIXTURES, 5, 42))
        self.assertNotEqual(first, module.build_matrix(module.FIXTURES, 5, 43))
        for index in range(0, len(first), 2):
            self.assertEqual((first[index].fixture, first[index].trial), (first[index + 1].fixture, first[index + 1].trial))
            self.assertEqual({first[index].condition, first[index + 1].condition}, set(module.CONDITIONS))

    def test_matrix_can_select_multi_only_for_protocol_smoke(self):
        specs = module.build_matrix(("homebrew-smoke",), 1, 42, ("multi",))
        self.assertEqual(specs, [module.RunSpec("homebrew-smoke", 1, "multi", 2)])

    def test_resume_skips_only_cells_with_usable_durable_results(self):
        rows = [
            {"fixture": "homebrew-smoke", "trial": 1, "condition": "single",
             "total_wall_ms": 1000, "infra_invalid": False},
            {"fixture": "homebrew-smoke", "trial": 1, "condition": "multi",
             "total_wall_ms": None, "infra_invalid": False},
            {"fixture": "ghostty-kit-guard", "trial": 1, "condition": "multi",
             "total_wall_ms": 2000, "infra_invalid": True},
        ]
        self.assertEqual(module.completed_spec_keys(rows), {
            ("homebrew-smoke", 1, "single"),
        })

    def test_latest_effectiveness_rows_replaces_interrupted_attempt(self):
        rows = [
            {"run_id": "bad", "fixture": "homebrew-smoke", "trial": 1,
             "condition": "multi", "total_wall_ms": None, "infra_invalid": True,
             "finished_at": "2026-08-15T00:00:00Z"},
            {"run_id": "good", "fixture": "homebrew-smoke", "trial": 1,
             "condition": "multi", "total_wall_ms": 1200, "infra_invalid": False,
             "finished_at": "2026-08-15T00:01:00Z"},
        ]
        self.assertEqual(
            [row["run_id"] for row in module.latest_effectiveness_rows(rows)],
            ["good"],
        )

    def test_resume_manifest_rejects_config_drift(self):
        specs = module.build_matrix(("homebrew-smoke",), 1, 42)
        args = unittest.mock.Mock(
            model="sonnet", effort="medium", workers=3, trials=1, seed=42,
            timeout=2700, xcode_host="jinwoo-macbook-pro-sub", infra_retries=1,
        )
        manifest = {
            "model": "sonnet", "effort": "medium", "workers": 3,
            "trials": 1, "seed": 42, "timeout_seconds": 2700,
            "xcode_host": "jinwoo-macbook-pro-sub", "infra_retries": 1,
            "matrix": [module.asdict(spec) for spec in specs],
        }
        self.assertEqual(module.resume_manifest_errors(manifest, specs=specs, args=args), [])
        args.timeout = 1200
        self.assertRegex(module.resume_manifest_errors(manifest, specs=specs, args=args)[0], "timeout_seconds")

    def test_metadata_points_to_requested_real_regressions(self):
        rows = module.validate_fixture_metadata()
        self.assertEqual({row["solution"][:8] for row in rows}, {"8803af77", "9b7745b1", "4e954beb"})

    def test_homebrew_hidden_check_rejects_old_and_accepts_solution(self):
        fixture = module.FIXTURES["homebrew-smoke"]
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            target = checkout / "scripts/update-homebrew-cask.sh"
            target.parent.mkdir()
            release_doc = checkout / ".claude/commands/release.md"
            release_doc.parent.mkdir(parents=True)
            old = subprocess.run(("git", "show", f"{fixture.solution}^:{target.relative_to(checkout)}"), cwd=ROOT, capture_output=True, check=True).stdout
            target.write_bytes(old)
            release_doc.write_bytes(subprocess.run(("git", "show", f"{fixture.solution}^:{release_doc.relative_to(checkout)}"), cwd=ROOT, capture_output=True, check=True).stdout)
            self.assertFalse(module.homebrew_acceptance(checkout)[0])
            target.write_bytes(subprocess.run(("git", "show", f"{fixture.solution}:{target.relative_to(checkout)}"), cwd=ROOT, capture_output=True, check=True).stdout)
            release_doc.write_bytes(subprocess.run(("git", "show", f"{fixture.solution}:{release_doc.relative_to(checkout)}"), cwd=ROOT, capture_output=True, check=True).stdout)
            self.assertTrue(module.homebrew_acceptance(checkout)[0])

    def test_homebrew_check_accepts_safe_else_layout_and_directory_guard(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            script = checkout / "scripts/update-homebrew-cask.sh"
            script.parent.mkdir()
            script.write_text("""
preflight do
  if File.directory?("#{appdir}/term-mesh.app")
    system_command "/usr/bin/pkill"
  end
end
postflight do
end

# Post-publish smoke test
if [[ "${SMOKE_TEST:-1}" == "full" ]]; then
  brew uninstall --cask --force term-mesh || true
  brew install --cask term-mesh
else
  if ! hdiutil attach "$DMG_PATH"; then
    exit 2
  fi
  TAP_SHA=$(brew info --cask --json=v2 term-mesh)
  if ! brew fetch --cask term-mesh; then
    exit 2
  fi
fi
""")
            release_doc = checkout / ".claude/commands/release.md"
            release_doc.parent.mkdir(parents=True)
            release_doc.write_text(
                "The smoke test never installs by default. SMOKE_TEST=full performs a real install on a test machine.\n"
            )
            passed, reason = module.homebrew_acceptance(checkout)
            self.assertTrue(passed, reason)

    def test_homebrew_check_accepts_pathname_preflight_guard(self):
        fixture = module.FIXTURES["homebrew-smoke"]
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            for relative in ("scripts/update-homebrew-cask.sh", ".claude/commands/release.md"):
                target = checkout / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(subprocess.run(
                    ("git", "show", f"{fixture.solution}:{relative}"),
                    cwd=ROOT, capture_output=True, check=True,
                ).stdout)
            script = checkout / "scripts/update-homebrew-cask.sh"
            script.write_text(script.read_text().replace(
                'File.exist?("#{appdir}/term-mesh.app")',
                '(appdir/"term-mesh.app").exist?',
            ))
            passed, reason = module.homebrew_acceptance(checkout)
            self.assertTrue(passed, reason)

    def test_homebrew_check_rejects_install_outside_full_branch(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            script = checkout / "scripts/update-homebrew-cask.sh"
            script.parent.mkdir()
            script.write_text("""
# Post-publish smoke test
if [[ "${SMOKE_TEST:-1}" == "full" ]]; then
  echo opted-in
fi
hdiutil attach "$DMG_PATH"
TAP_SHA=$(brew info --json=v2)
brew fetch --cask term-mesh
brew install --cask term-mesh
preflight do
  if File.exist?("#{appdir}/term-mesh.app")
    system_command "/usr/bin/pkill"
  end
end
postflight do
end
""")
            release_doc = checkout / ".claude/commands/release.md"
            release_doc.parent.mkdir(parents=True)
            release_doc.write_text(
                "The smoke test never installs by default. SMOKE_TEST=full performs a real install.\n"
            )
            passed, reason = module.homebrew_acceptance(checkout)
            self.assertFalse(passed)
            self.assertIn("default smoke path invokes", reason)

    def test_homebrew_check_accepts_multiline_safe_default_documentation(self):
        fixture = module.FIXTURES["homebrew-smoke"]
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            for relative in ("scripts/update-homebrew-cask.sh", ".claude/commands/release.md"):
                target = checkout / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(subprocess.run(
                    ("git", "show", f"{fixture.solution}:{relative}"),
                    cwd=ROOT, capture_output=True, check=True,
                ).stdout)
            release_doc = checkout / ".claude/commands/release.md"
            release_doc.write_text(
                "The smoke test has a safe default path and a full opt-in path:\n"
                "- Safe default (SMOKE_TEST unset): never touches the local installed app.\n"
                "- SMOKE_TEST=full performs a real brew install on a test machine.\n"
            )
            passed, reason = module.homebrew_acceptance(checkout)
            self.assertTrue(passed, reason)

    def test_terminate_process_group_reaps_agent_children(self):
        process = subprocess.Popen(
            (sys.executable, "-c", "import subprocess,time; subprocess.Popen(['sleep','30']); time.sleep(30)"),
            start_new_session=True,
        )
        try:
            module.terminate_process_group(process)
            self.assertIsNotNone(process.poll())
            probe = subprocess.run(
                ("ps", "-o", "pid=", "-g", str(process.pid)),
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(probe.stdout.strip(), "")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, 9)

    def test_benchmark_git_hook_allows_local_and_blocks_external_pushes(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary) / "checkout"
            checkout.mkdir()
            env, guard_root = module.benchmark_agent_environment(checkout)
            hook = Path(env["GIT_TEMPLATE_DIR"]) / "hooks/pre-push"
            syntax = subprocess.run(
                ("bash", "-n", str(hook)), capture_output=True, text=True, check=False,
            )
            self.assertEqual(syntax.returncode, 0, syntax.stderr)
            local = subprocess.run(
                (str(hook), "origin", str(Path(temporary) / "origin.git")),
                capture_output=True, text=True, check=False,
            )
            external = subprocess.run(
                (str(hook), "origin", "git@github.com:x-mesh/homebrew-tap.git"),
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(local.returncode, 0)
            self.assertEqual(external.returncode, 97)
            self.assertIn("blocked push to external remote", external.stderr)
            self.assertEqual(guard_root.parent, checkout.parent)
            self.assertEqual(env["GIT_CONFIG_KEY_0"], "core.hooksPath")
            self.assertEqual(env["GIT_CONFIG_VALUE_0"], str(hook.parent))

    def test_benchmark_git_config_applies_guard_to_existing_repository(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout = root / "checkout"
            subprocess.run(("git", "init", "-q", str(checkout)), check=True)
            env, _ = module.benchmark_agent_environment(checkout)
            configured = subprocess.run(
                ("git", "config", "--get", "core.hooksPath"), cwd=checkout,
                env=env, capture_output=True, text=True, check=True,
            )
            self.assertEqual(configured.stdout.strip(), env["GIT_CONFIG_VALUE_0"])

    def test_benchmark_environment_rejects_stale_socket_aliases(self):
        old = dict(module.os.environ)
        try:
            module.os.environ.update({
                "TERMMESH_SOCKET_PATH": "/tmp/gui.sock",
                "TERMMESH_DAEMON_UNIX_PATH": "/tmp/daemon.sock",
                "TERMMESH_WORKSPACE_ID": "workspace",
            })
            with tempfile.TemporaryDirectory() as temporary:
                checkout = Path(temporary) / "checkout"
                checkout.mkdir()
                with self.assertRaisesRegex(RuntimeError, "app socket"):
                    module.benchmark_agent_environment(checkout)
        finally:
            module.os.environ.clear()
            module.os.environ.update(old)

    def test_benchmark_agent_environment_routes_leader_to_headless_daemon(self):
        old = dict(module.os.environ)
        try:
            with tempfile.TemporaryDirectory() as temporary:
                app = Path(temporary) / "gui-app.sock"
                daemon = Path(temporary) / "headless-daemon.sock"
                app.touch()
                daemon.touch()
                module.os.environ.update({
                    "TERMMESH_SOCKET_PATH": str(app),
                    "TERMMESH_DAEMON_UNIX_PATH": str(daemon),
                    "TERMMESH_WORKSPACE_ID": "gui-workspace",
                })
                checkout = Path(temporary) / "checkout"
                checkout.mkdir()
                env, _ = module.benchmark_agent_environment(checkout)
                self.assertEqual(env["TERMMESH_SOCKET"], str(app))
                self.assertEqual(env["TERMMESH_DAEMON_SOCKET"], str(daemon))
                self.assertNotIn("TERMMESH_WORKSPACE_ID", env)
        finally:
            module.os.environ.clear()
            module.os.environ.update(old)

    def test_benchmark_run_lock_rejects_duplicate_matrix(self):
        with tempfile.TemporaryDirectory() as temporary:
            results = Path(temporary) / "results"
            with module.benchmark_run_lock(results):
                with self.assertRaisesRegex(RuntimeError, "already running"):
                    with module.benchmark_run_lock(results):
                        self.fail("duplicate lock unexpectedly acquired")

    def test_sigterm_becomes_cleanup_exception_and_restores_handler(self):
        previous = module.signal.getsignal(module.signal.SIGTERM)
        with self.assertRaisesRegex(module.BenchmarkTerminated, "signal 15"):
            with module.benchmark_signal_cleanup():
                module.os.kill(module.os.getpid(), module.signal.SIGTERM)
        self.assertEqual(module.signal.getsignal(module.signal.SIGTERM), previous)
        self.assertTrue(module.classify_infra_failure(
            "BenchmarkTerminated: benchmark interrupted by signal 15"
        ))

    def test_oracle_overlay_restores_candidate_bytes(self):
        fixture = module.FIXTURES["ghostty-kit-guard"]
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            target = checkout / fixture.oracle_files[0]
            target.parent.mkdir(parents=True)
            target.write_text("candidate\n")
            with module.oracle_overlay(fixture, checkout):
                self.assertNotEqual(target.read_text(), "candidate\n")
            self.assertEqual(target.read_text(), "candidate\n")

    def test_build_info_is_generated_before_xcode_acceptance(self):
        source = SCRIPT.read_text()
        function = source[source.index("def run_divider_acceptance"):source.index("def run_acceptance")]
        self.assertGreaterEqual(function.count("scripts/generate-build-info.sh"), 2)

    def test_stream_parser_uses_result_usage_and_cost(self):
        stream = json.dumps({
            "type": "result", "session_id": "s", "num_turns": 2,
            "usage": {"input_tokens": 10, "output_tokens": 4, "reasoning_output_tokens": 2},
            "total_cost_usd": 0.12,
        })
        parsed = module.parse_stream(stream)
        self.assertEqual(parsed["tokens"]["input_tokens"], 10)
        self.assertEqual(parsed["tokens"]["reasoning_output_tokens"], 2)
        self.assertEqual(parsed["cost_usd"], 0.12)

    def test_worker_dispatch_counter_reads_bash_tool_commands(self):
        stream = json.dumps({
            "type": "assistant",
            "message": {"content": [{
                "type": "tool_use", "name": "Bash",
                "input": {"command": "tm-agent send explorer one; tm-agent send executor two"},
            }]},
        })
        self.assertEqual(module.count_worker_dispatches(stream), 2)

    def test_worker_dispatch_counter_handles_background_subshell(self):
        stream = json.dumps({
            "type": "assistant",
            "message": {"content": [{
                "type": "tool_use", "name": "Bash",
                "input": {"command": "(\n tm-agent send explorer one &\n tm-agent send executor two &\n tm-agent send reviewer three &\n wait\n)"},
            }]},
        })
        self.assertEqual(module.count_worker_dispatches(stream), 3)
        self.assertEqual(module.first_tool_dispatch_count(stream), 3)

    def test_first_tool_dispatch_rejects_preflight_before_sends(self):
        stream = "\n".join((
            json.dumps({"type": "assistant", "message": {"content": [{
                "type": "tool_use", "name": "Bash",
                "input": {"command": "which tm-agent; tm-agent --help"},
            }]}}),
            json.dumps({"type": "assistant", "message": {"content": [{
                "type": "tool_use", "name": "Bash",
                "input": {"command": (
                    "tm-agent send explorer one & tm-agent send executor two & "
                    "tm-agent send reviewer three & wait"
                )},
            }]}}),
        ))
        self.assertEqual(module.count_worker_dispatches(stream), 3)
        self.assertEqual(module.first_tool_dispatch_count(stream), 0)

    def test_multi_protocol_rejects_transcript_and_app_board_commands(self):
        stream = json.dumps({
            "type": "assistant",
            "message": {"content": [{
                "type": "tool_use", "name": "Bash",
                "input": {"command": "tm-agent read executor; tm-agent status --team bench"},
            }]},
        })
        self.assertEqual(module.forbidden_multi_commands(stream), ["read", "status"])

    def test_multi_protocol_rejects_auxiliary_wait_tools(self):
        stream = "\n".join((
            json.dumps({"type": "assistant", "message": {"content": [{
                "type": "tool_use", "name": "Monitor", "input": {"command": "true"},
            }]}}),
            json.dumps({"type": "assistant", "message": {"content": [{
                "type": "tool_use", "name": "Bash",
                "input": {"command": "ToolSearch mcp__mem-mesh__pin_add"},
            }]}}),
        ))
        forbidden = module.forbidden_multi_commands(stream)
        self.assertIn("Monitor", forbidden)
        self.assertIn("ToolSearch", forbidden)
        self.assertIn("mcp__mem-mesh", forbidden)

    def test_multi_protocol_allows_injected_mem_mesh_lifecycle_hooks(self):
        stream = "\n".join((
            json.dumps({"type": "assistant", "message": {"content": [{
                "type": "tool_use", "name": "mcp__mem-mesh__pin_add",
                "input": {"content": "automatic checkpoint"},
            }]}}),
            json.dumps({"type": "assistant", "message": {"content": [{
                "type": "tool_use", "name": "mcp__mem-mesh__pin_complete",
                "input": {"pin_id": "automatic"},
            }]}}),
        ))
        self.assertEqual(module.forbidden_multi_commands(stream), [])

    def test_multi_prompt_forbids_headless_team_app_status_probe(self):
        prompt = module.leader_prompt(
            module.FIXTURES["homebrew-smoke"], "multi", "bench-test",
            "STATUS: DONE\nFULL_REPORT: /tmp/explorer.md",
        )
        self.assertIn("세 worker를 이미 동시에 dispatch", prompt)
        self.assertIn("어떤 `tm-agent` 명령도 호출하지 마라", prompt)
        self.assertTrue(prompt.startswith("controller가 explorer"))
        self.assertIn("FULL_REPORT: /tmp/explorer.md", prompt)
        self.assertIn("다시 기다리거나", prompt)
        self.assertNotIn("for result_file in", prompt)
        self.assertNotIn("/bin/sleep", prompt)

    def test_controller_waits_once_and_returns_bounded_worker_headers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = [root / f"{role}.result" for role in ("explorer", "executor", "reviewer")]
            files[0].write_text("STATUS: DONE\nFULL_REPORT: /tmp/full.md\n")
            headers, elapsed_ms, ready = module.wait_for_worker_results(files, timeout=0.01)
            self.assertEqual(ready, 1)
            self.assertGreaterEqual(elapsed_ms, 0)
            self.assertIn("STATUS: DONE", headers)
            self.assertEqual(headers.count("STATUS: BLOCKED"), 2)

    def test_worker_instructions_partition_write_ownership(self):
        fixture = module.FIXTURES["homebrew-smoke"]
        explorer = module.worker_instruction(fixture, "bench-test", "explorer")
        executor = module.worker_instruction(fixture, "bench-test", "executor")
        reviewer = module.worker_instruction(fixture, "bench-test", "reviewer")
        self.assertIn("어떤 repo 파일도 수정하지 마라", explorer)
        self.assertIn("필요한 repo 파일을 소유", executor)
        self.assertIn("어떤 repo 파일도 수정하지 마라", reviewer)
        for role, instruction in (("explorer", explorer), ("executor", executor), ("reviewer", reviewer)):
            self.assertIn(f"bench-test-{role}.result.tmp.$$", instruction)
            self.assertIn("atomic `mv`", instruction)

    def test_claude_command_disables_external_mcp_servers(self):
        command = module.claude_command(
            "prompt", model="sonnet", effort="medium",
            session_id="00000000-0000-0000-0000-000000000001",
            resume=False, condition="multi",
        )
        self.assertIn("--strict-mcp-config", command)
        self.assertIn("--safe-mode", command)
        self.assertIn("--disable-slash-commands", command)
        config = command[command.index("--mcp-config") + 1]
        self.assertEqual(json.loads(config), {"mcpServers": {}})

    def test_benchmark_team_isolates_all_workers_from_customizations(self):
        with unittest.mock.patch.object(module, "tm_environment", return_value={
            "TERMMESH_SOCKET": "/tmp/app.sock",
        }), unittest.mock.patch.object(
            module, "daemon_json", return_value={"team_name": "bench"},
        ) as rpc:
            module.create_benchmark_team("bench", Path("/tmp/checkout"), "sonnet")
        method, params = rpc.call_args.args
        self.assertEqual(method, "headless.create_team")
        self.assertEqual([agent["name"] for agent in params["agents"]], [
            "explorer", "executor", "reviewer",
        ])
        for agent in params["agents"]:
            self.assertIn("--safe-mode", agent["extra_args"])
            self.assertIn("--disable-slash-commands", agent["extra_args"])
            self.assertIn("--strict-mcp-config", agent["extra_args"])
        self.assertEqual(params["app_socket_path"], "/tmp/app.sock")

    def test_usage_delta_clamps_agent_resets(self):
        before = {key: 10 for key in module.TOKEN_KEYS}
        after = {key: 8 for key in module.TOKEN_KEYS}
        self.assertEqual(module.usage_delta(after, before), {key: 0 for key in module.TOKEN_KEYS})

    def test_worker_usage_uses_only_latest_cumulative_model_usage(self):
        lines = [
            json.dumps({
                "type": "result",
                "usage": {"input_tokens": 2, "output_tokens": 3},
                "modelUsage": {"claude-sonnet-5": {
                    "inputTokens": 4, "outputTokens": 10,
                    "cacheReadInputTokens": 100, "cacheCreationInputTokens": 20,
                    "costUSD": 0.20,
                }},
            }),
            "not json",
            json.dumps({
                "type": "result",
                "usage": {"input_tokens": 1, "output_tokens": 2},
                "modelUsage": {
                    "claude-sonnet-5": {
                        "inputTokens": 6, "outputTokens": 15,
                        "cacheReadInputTokens": 150, "cacheCreationInputTokens": 25,
                        "costUSD": 0.27,
                    },
                    "claude-haiku-4-5": {
                        "inputTokens": 2, "outputTokens": 5,
                        "cacheReadInputTokens": 10, "cacheCreationInputTokens": 3,
                        "costUSD": 0.03,
                    },
                },
            }),
        ]
        tokens, cost, found = module.parse_worker_usage(lines)
        self.assertTrue(found)
        self.assertEqual(tokens, {
            "input_tokens": 8, "output_tokens": 20, "reasoning_output_tokens": 0,
            "cache_read_input_tokens": 160, "cache_creation_input_tokens": 28,
        })
        self.assertAlmostEqual(cost, 0.30)

    def test_worker_usage_falls_back_to_result_usage(self):
        tokens, cost, found = module.parse_worker_usage([json.dumps({
            "type": "result",
            "usage": {"input_tokens": 7, "output_tokens": 2},
            "total_cost_usd": 0.04,
        })])
        self.assertTrue(found)
        self.assertEqual(tokens["input_tokens"], 7)
        self.assertEqual(tokens["output_tokens"], 2)
        self.assertEqual(cost, 0.04)

    def test_worker_usage_reports_missing_result(self):
        tokens, cost, found = module.parse_worker_usage(["bad", '{"type":"assistant"}'])
        self.assertFalse(found)
        self.assertIsNone(cost)
        self.assertEqual(tokens, {key: 0 for key in module.TOKEN_KEYS})

    def test_team_usage_reads_daemon_metadata_without_transcript(self):
        old = dict(module.os.environ)
        try:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                team = root / "uuid"
                agents = team / "agents"
                agents.mkdir(parents=True)
                (team / "team.json").write_text(json.dumps({"team_name": "bench-test"}))
                for index, worker in enumerate(("explorer", "executor", "reviewer"), 1):
                    (agents / f"{worker}.json").write_text(json.dumps({
                        "usage_total": {
                            "input_tokens": index, "output_tokens": index * 2,
                            "cache_read_input_tokens": index * 3,
                            "cache_creation_input_tokens": index * 4,
                        },
                    }))
                module.os.environ["TERMMESH_HEADLESS_ROOT"] = str(root)
                tokens, cost, observed, expected = module.team_usage(
                    "bench-test", root,
                )
                self.assertEqual(observed, 3)
                self.assertEqual(expected, 3)
                self.assertEqual(tokens["input_tokens"], 6)
                self.assertEqual(tokens["output_tokens"], 12)
                self.assertEqual(tokens["cache_read_input_tokens"], 18)
                self.assertEqual(tokens["cache_creation_input_tokens"], 24)
                self.assertEqual(cost, 0.0)
        finally:
            module.os.environ.clear()
            module.os.environ.update(old)

    def test_cost_estimate_and_redaction(self):
        tokens = {"input_tokens": 1_000_000, "output_tokens": 100_000}
        self.assertEqual(module.estimate_cost(tokens, "sonnet"), 4.5)
        redacted = module.redact_text("API_KEY=abc token: xyz /tmp/private/file", Path("/tmp/private"))
        self.assertNotIn("abc", redacted)
        self.assertNotIn("xyz", redacted)
        self.assertNotIn("/tmp/private", redacted)

    def test_worker_timing_is_optional_and_computes_parallel_utilization(self):
        self.assertEqual(module.worker_timing([]), (None, None))
        span, utilization = module.worker_timing([
            {"started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:00:10Z"},
            {"started_at": "2026-01-01T00:00:05Z", "completed_at": "2026-01-01T00:00:15Z"},
        ])
        self.assertEqual(span, 15000)
        self.assertEqual(utilization, 0.667)

    def test_headless_tm_environment_uses_daemon_not_gui_socket(self):
        old = dict(module.os.environ)
        try:
            with tempfile.TemporaryDirectory() as temporary:
                app = Path(temporary) / "app.sock"
                daemon = Path(temporary) / "daemon.sock"
                app.touch()
                daemon.touch()
                module.os.environ.update({
                    "TERMMESH_SOCKET_PATH": str(app),
                    "TERMMESH_DAEMON_UNIX_PATH": str(daemon),
                    "TERMMESH_WORKSPACE_ID": "workspace",
                })
                env = module.tm_environment()
                self.assertEqual(env["TERMMESH_SOCKET"], str(app))
                self.assertEqual(env["TERMMESH_DAEMON_SOCKET"], str(daemon))
                self.assertNotIn("TERMMESH_WORKSPACE_ID", env)
        finally:
            module.os.environ.clear()
            module.os.environ.update(old)

    def test_tm_json_parser_accepts_create_guidance_after_json(self):
        output = '{"id":1,"result":{"name":"bench"}}\n\nCommands:\n  tm-agent status\n'
        self.assertEqual(module.parse_tm_json(output), {
            "id": 1, "result": {"name": "bench"},
        })

    def test_tm_json_parser_rejects_empty_stdout(self):
        with self.assertRaisesRegex(ValueError, "empty stdout"):
            module.parse_tm_json("  \n")

    def test_controller_errors_are_not_silently_infra_invalid(self):
        self.assertFalse(module.classify_infra_failure("KeyError: broken result schema"))
        self.assertTrue(module.classify_infra_failure("Team not found on daemon socket"))

    def test_failure_redaction_masks_home_and_secrets(self):
        value = module.safe_failure(f"{Path.home()}/repo token=abc123")
        self.assertNotIn(str(Path.home()), value)
        self.assertNotIn("abc123", value)

    def test_failed_and_timeout_runs_stay_out_of_latency_pairs(self):
        rows = [
            self.row("single", 1, 1000, True), self.row("multi", 1, 500, False),
            self.row("single", 2, 1200, True), self.row("multi", 2, 600, True),
        ]
        summary = module.summarize(rows, seed=7)
        self.assertEqual(summary["paired_speedup_median"], 2.0)
        self.assertEqual(summary["conditions"]["multi"]["pass_rate"], 0.5)
        self.assertFalse(summary["default_gate_passed"])

    def test_adoption_requires_quality_result(self):
        rows = []
        for fixture in module.FIXTURES:
            for trial in range(1, 4):
                rows.extend((
                    self.row("single", trial, 1200, True, fixture),
                    self.row("multi", trial, 800, True, fixture),
                ))
        without_quality = module.summarize(rows, seed=7)
        self.assertEqual(without_quality["default_route"], "single")
        quality = {"comparisons": [
            {"fixture": fixture, "trial": trial, "valid_judges": 3, "multi_regression": False}
            for fixture in module.FIXTURES
            for trial in range(1, 4)
        ]}
        with_quality = module.summarize(rows, seed=7, quality=quality)
        self.assertEqual(with_quality["default_route"], "multi")

    def test_fixture_route_does_not_ignore_multi_failure(self):
        rows = []
        for trial in range(1, 4):
            rows.extend((self.row("single", trial, 1200, True), self.row("multi", trial, 700, trial != 3)))
        quality = {"comparisons": [
            {"fixture": "homebrew-smoke", "trial": trial, "valid_judges": 3, "multi_regression": False}
            for trial in (1, 2)
        ]}
        self.assertEqual(module.summarize(rows, seed=7, quality=quality)["fixture_routes"]["homebrew-smoke"], "single")

    def test_bootstrap_is_seeded_and_ordered(self):
        values = [1.1, 1.2, 1.5]
        self.assertEqual(module.bootstrap_ci(values, seed=9), module.bootstrap_ci(values, seed=9))
        low, high = module.bootstrap_ci(values, seed=9)
        self.assertLessEqual(low, high)

    def test_judge_parser_rejects_non_json_and_bad_winner(self):
        with self.assertRaises(ValueError):
            module.parse_judge_output("looks good")
        with self.assertRaises(ValueError):
            module.parse_judge_output('{"winner":"single"}')
        with self.assertRaises(ValueError):
            module.parse_judge_output('{"winner":"A","A":{},"B":{}}')

    def test_dry_run_validates_contract_without_paid_calls(self):
        result = subprocess.run(
            (sys.executable, str(SCRIPT), "run", "--dry-run"),
            cwd=ROOT, text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("effectiveness matrix: 18 runs", result.stdout)

    def test_rpc_probe_is_diagnostic_and_persists_exit_code(self):
        completed = subprocess.CompletedProcess([], 7, "stdout /Users/example", "stderr")
        with tempfile.TemporaryDirectory() as temporary, unittest.mock.patch.object(
            module, "run_command", return_value=completed
        ):
            experiment = Path(temporary)
            probe = module.run_rpc_probe(experiment, "preflight")
            self.assertEqual(probe["exit_code"], 7)
            self.assertTrue((experiment / "rpc-preflight.log").exists())

    @staticmethod
    def row(condition, trial, wall, passed, fixture="homebrew-smoke"):
        return {
            "run_id": f"{fixture}-{condition}-{trial}", "fixture": fixture,
            "trial": trial, "condition": condition, "acceptance_passed": passed,
            "infra_invalid": False, "timed_out": not passed, "total_wall_ms": wall,
            "tokens": {"input_tokens": 100, "output_tokens": 20},
        }


if __name__ == "__main__":
    unittest.main()
