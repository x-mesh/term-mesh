import importlib.util
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


BRIDGE_PATH = Path(__file__).with_name("tm-agent-bridge.py")
SPEC = importlib.util.spec_from_file_location("tm_agent_bridge", BRIDGE_PATH)
BRIDGE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(BRIDGE)


class RemoteProcessLocationTests(unittest.TestCase):
    def remote_command(
        self,
        remote_cwd: str,
        remote_env: dict[str, str] | None = None,
        child: list[str] | None = None,
    ) -> str:
        remote = {
            "TERMMESH_REMOTE_NATIVE_SSH_ARGS": '["/usr/bin/ssh", "root@peer"]',
            "TERMMESH_REMOTE_NATIVE_CWD": remote_cwd,
        }
        if remote_env is not None:
            import json
            remote["TERMMESH_REMOTE_NATIVE_ENV"] = json.dumps(remote_env)
        with patch.dict(os.environ, remote, clear=True):
            argv, cwd = BRIDGE.process_location(
                child or ["codex", "app-server"],
                "/local/project",
            )

        self.assertIsNone(cwd)
        return argv[-1]

    def run_remote_command(
        self,
        command: str,
        shell: str,
        home: Path,
    ) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment.update({"HOME": str(home), "SHELL": shell})
        return subprocess.run(
            ["/bin/sh", "-c", command],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_command_loads_agent_env_before_explicit_host_environment(self):
        command = self.remote_command(
            "/remote/project",
            {"AI_MESH_API_KEY": "from-host"},
        )
        source = '. "$HOME/.config/term-mesh/agent-env"'
        explicit = "AI_MESH_API_KEY=from-host"
        self.assertIn('exec "${SHELL:-/bin/sh}" -lc', command)
        self.assertIn(f'[ -f "$HOME/.config/term-mesh/agent-env" ]', command)
        self.assertIn(source, command)
        self.assertIn(">/dev/null || exit 78", command)
        self.assertLess(command.index(source), command.index(explicit))

    def test_bash_executes_profile_agent_env_and_explicit_precedence(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            remote_cwd = home / "project"
            (home / ".bash_profile").write_text(
                "export LOGIN_PROFILE=loaded\n",
                encoding="utf-8",
            )
            (home / ".profile").write_text(
                "export LITERAL_PROFILE=loaded\n"
                "export ORDER=profile\n"
                "printf 'profile-noise\\n'\n",
                encoding="utf-8",
            )
            agent_env = home / ".config" / "term-mesh" / "agent-env"
            agent_env.parent.mkdir(parents=True)
            agent_env.write_text(
                "AGENT_ONLY=loaded\n"
                "ORDER=agent\n"
                "printf 'agent-noise\\n'\n",
                encoding="utf-8",
            )
            command = self.remote_command(
                str(remote_cwd),
                {"ORDER": "host"},
                ["/usr/bin/env"],
            )

            result = self.run_remote_command(command, "/bin/bash", home)

        self.assertEqual(result.returncode, 0, result.stderr)
        values = dict(
            line.split("=", 1)
            for line in result.stdout.splitlines()
            if "=" in line
        )
        self.assertEqual(values["LOGIN_PROFILE"], "loaded")
        self.assertEqual(values["LITERAL_PROFILE"], "loaded")
        self.assertEqual(values["AGENT_ONLY"], "loaded")
        self.assertEqual(values["ORDER"], "host")
        self.assertNotIn("profile-noise", result.stdout)
        self.assertNotIn("agent-noise", result.stdout)

    def test_bash_does_not_double_source_profile_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / ".profile").write_text(
                "PROFILE_COUNT=$(( ${PROFILE_COUNT:-0} + 1 ))\n"
                "export PROFILE_COUNT\n",
                encoding="utf-8",
            )
            command = self.remote_command(
                str(home / "project"),
                child=["/usr/bin/env"],
            )

            result = self.run_remote_command(command, "/bin/bash", home)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PROFILE_COUNT=1", result.stdout.splitlines())

    @unittest.skipUnless(Path("/bin/zsh").exists(), "zsh is not installed")
    def test_zsh_loads_literal_profile_after_zprofile(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / ".zprofile").write_text(
                "export ZPROFILE_LOADED=yes\n",
                encoding="utf-8",
            )
            (home / ".profile").write_text(
                "export LITERAL_PROFILE=yes\n",
                encoding="utf-8",
            )
            command = self.remote_command(
                str(home / "project"),
                child=["/usr/bin/env"],
            )

            result = self.run_remote_command(command, "/bin/zsh", home)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ZPROFILE_LOADED=yes", result.stdout.splitlines())
        self.assertIn("LITERAL_PROFILE=yes", result.stdout.splitlines())

    def test_profile_and_agent_env_failures_use_reserved_exit_codes(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / ".bash_profile").write_text("", encoding="utf-8")
            (home / ".profile").write_text("false\n", encoding="utf-8")
            command = self.remote_command(
                str(home / "project"),
                child=["/usr/bin/env"],
            )
            profile_result = self.run_remote_command(command, "/bin/bash", home)

            (home / ".profile").write_text("", encoding="utf-8")
            agent_env = home / ".config" / "term-mesh" / "agent-env"
            agent_env.parent.mkdir(parents=True)
            agent_env.write_text("false\n", encoding="utf-8")
            agent_result = self.run_remote_command(command, "/bin/bash", home)

        self.assertEqual(profile_result.returncode, BRIDGE.PROFILE_LOAD_EXIT)
        self.assertEqual(agent_result.returncode, BRIDGE.AGENT_ENV_LOAD_EXIT)
        self.assertEqual(
            BRIDGE.remote_launch_failure(profile_result.returncode),
            "remote agent could not load ~/.profile",
        )
        self.assertEqual(
            BRIDGE.remote_launch_failure(agent_result.returncode),
            "remote agent could not load ~/.config/term-mesh/agent-env",
        )


class JsonRpcStartupFailureTests(unittest.TestCase):
    def test_remote_environment_exit_is_preserved_for_ui_result(self):
        class FailedChild:
            def __init__(self):
                self.inbox = queue.Queue()
                self.inbox.put({"__eof__": True})

            def exit_code(self):
                return BRIDGE.AGENT_ENV_LOAD_EXIT

        rpc = BRIDGE.JsonRpc(FailedChild(), emitter=None)

        self.assertIsNone(rpc.pump(until_id=1, timeout=0.1))
        self.assertEqual(
            rpc.failure,
            "remote agent could not load ~/.config/term-mesh/agent-env",
        )


class PersistentChildExitTests(unittest.TestCase):
    def test_send_reports_exit_code_and_stderr_instead_of_broken_pipe(self):
        child = BRIDGE.Child([
            sys.executable,
            "-c",
            "import sys; print('intentional child crash', file=sys.stderr); "
            "sys.exit(7)",
        ], tempfile.gettempdir())
        deadline = time.monotonic() + 2
        while child.alive and time.monotonic() < deadline:
            time.sleep(0.01)
        while not child.stderr_lines and time.monotonic() < deadline:
            time.sleep(0.01)

        with self.assertRaises(BRIDGE.ChildExitedError) as raised:
            child.send({"jsonrpc": "2.0", "method": "turn/start"})

        self.assertIn("exited with code 7", str(raised.exception))
        self.assertIn("intentional child crash", str(raised.exception))
        child.stop()

    def test_jsonrpc_turn_start_converts_dead_child_to_failure(self):
        class DeadChild:
            alive = False
            inbox = queue.Queue()

            def send(self, _obj):
                raise BRIDGE.ChildExitedError("agent process exited with code 9")

            def exit_code(self):
                return 9

        child = DeadChild()
        rpc = BRIDGE.JsonRpc(child, emitter=None)

        self.assertIsNone(rpc.request("turn/start", {}, timeout=1))
        self.assertEqual(rpc.failure, "agent process exited with code 9")

    def test_idle_bridge_observes_child_exit_without_waiting_for_another_turn(self):
        with tempfile.TemporaryDirectory() as temporary:
            fake = Path(temporary) / "fake-codex"
            fake.write_text(
                "#!/usr/bin/env python3\n"
                "import json, sys\n"
                "for line in sys.stdin:\n"
                "    frame = json.loads(line)\n"
                "    method = frame.get('method')\n"
                "    if method == 'initialize':\n"
                "        print(json.dumps({'jsonrpc':'2.0','id':frame['id'],"
                "'result':{}}), flush=True)\n"
                "    elif method == 'thread/start':\n"
                "        print(json.dumps({'jsonrpc':'2.0','id':frame['id'],"
                "'result':{'thread':{'id':'thread-dead'}}}), flush=True)\n"
                "        print('app-server crashed while idle', file=sys.stderr, flush=True)\n"
                "        sys.exit(7)\n",
                encoding="utf-8",
            )
            fake.chmod(0o700)
            process = subprocess.Popen(
                [sys.executable, str(BRIDGE_PATH), "--cli", "codex",
                 "--exe", str(fake), "--cwd", temporary],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                code = process.wait(timeout=3)
                stdout = process.stdout.read()
                stderr = process.stderr.read()
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream is not None and not stream.closed:
                        stream.close()

        self.assertEqual(code, 1)
        results = [json.loads(line) for line in stdout.splitlines()
                   if line.startswith("{")]
        terminal = [event for event in results if event.get("type") == "result"][-1]
        self.assertEqual(terminal["stop_reason"], "process_exited")
        self.assertIn("exited with code 7", terminal["result"])
        self.assertIn("app-server crashed while idle", terminal["result"])
        self.assertNotIn("Traceback", stderr)


class CapturedEmitter(BRIDGE.Emitter):
    """An emitter that keeps what it was told instead of printing it."""

    def __init__(self):
        super().__init__(None)
        self.events: list[dict] = []

    def emit(self, obj: dict) -> None:
        self.events.append(obj)

    def blocks(self, kind: str) -> list[dict]:
        found = []
        for event in self.events:
            for block in (event.get("message") or {}).get("content") or []:
                if isinstance(block, dict) and block.get("type") == kind:
                    found.append(block)
        return found


class ScriptedChild:
    """A CLI that says exactly what the test wrote down, and nothing else."""

    alive = True

    def __init__(self, frames=()):
        self.inbox = queue.Queue()
        self.sent: list[dict] = []
        for frame in frames:
            self.inbox.put(frame)
        # Ending the script rather than waiting out the timeout.
        self.inbox.put({"__eof__": True})

    def send(self, obj: dict) -> None:
        self.sent.append(obj)

    def exit_code(self):
        return None


def codex_bridge(frames=()) -> tuple:
    """A CodexBridge over a scripted child, without spawning anything."""
    bridge = BRIDGE.CodexBridge.__new__(BRIDGE.CodexBridge)
    child = ScriptedChild(frames)
    emitter = CapturedEmitter()
    bridge.child = child
    bridge.out = emitter
    bridge.cwd = "/tmp/project"
    bridge.model = None
    bridge.thread_id = "thread-1"
    bridge.rpc = BRIDGE.JsonRpc(child, emitter, on_request=bridge._serve_request)
    return bridge, child, emitter


def acp_bridge(frames=()) -> tuple:
    """An AcpBridge over a scripted child, without spawning anything."""
    bridge = BRIDGE.AcpBridge.__new__(BRIDGE.AcpBridge)
    child = ScriptedChild(frames)
    emitter = CapturedEmitter()
    bridge.child = child
    bridge.out = emitter
    bridge.session = "session-1"
    bridge.tool_output = {}
    bridge.rpc = BRIDGE.JsonRpc(child, emitter)
    return bridge, child, emitter


FILE_CHANGE_ITEM = {
    "type": "fileChange",
    "id": "item-9",
    "status": "completed",
    "changes": [
        {"path": "/repo/new.py", "kind": {"type": "add"},
         "diff": "@@ -0,0 +1,2 @@\n+one\n+two\n"},
        {"path": "/repo/old.py",
         "kind": {"type": "update", "move_path": "/repo/moved.py"},
         "diff": "@@ -1,2 +1,2 @@\n-before\n+after\n context\n"},
    ],
}


class FileChangeTests(unittest.TestCase):
    def test_a_patch_draws_a_row_per_file_carrying_its_diff(self):
        bridge, _, out = codex_bridge()

        bridge._file_change(FILE_CHANGE_ITEM)

        calls = out.blocks("tool_use")
        self.assertEqual(len(calls), 2)
        self.assertEqual([c["id"] for c in calls], ["item-9#0", "item-9#1"])
        self.assertEqual([c["name"] for c in calls], ["write", "edit"])
        self.assertEqual(calls[0]["input"]["file_path"], "/repo/new.py")
        self.assertEqual(calls[0]["input"]["kind"], "add")
        self.assertIn("+one", calls[0]["input"]["unified_diff"])
        self.assertEqual(calls[1]["input"]["move_path"], "/repo/moved.py")
        self.assertIn("-before", calls[1]["input"]["unified_diff"])

        results = out.blocks("tool_result")
        self.assertEqual([r["tool_use_id"] for r in results],
                         ["item-9#0", "item-9#1"])
        # An empty result is what took the disclosure control away.
        self.assertTrue(all(r["content"] for r in results))

    def test_an_edit_carries_no_command_key(self):
        """The reader tries `command` first, so its presence hides the path.

        This is the exact shape of the original bug: a row that named a tool
        and then had nothing to say about which file it touched.
        """
        bridge, _, out = codex_bridge()

        bridge._file_change(FILE_CHANGE_ITEM)

        for call in out.blocks("tool_use"):
            self.assertNotIn("command", call["input"])
            self.assertTrue(call["input"]["file_path"])

    def test_a_declined_patch_is_reported_as_a_failure(self):
        bridge, _, out = codex_bridge()

        bridge._file_change(dict(FILE_CHANGE_ITEM, status="declined"))

        self.assertTrue(all(r["is_error"] for r in out.blocks("tool_result")))

    def test_a_change_without_a_diff_still_says_what_happened(self):
        bridge, _, out = codex_bridge()

        bridge._file_change({"type": "fileChange", "id": "i", "changes": [
            {"path": "/repo/gone.py", "kind": {"type": "delete"}, "diff": ""}]})

        self.assertEqual(out.blocks("tool_result")[0]["content"],
                         "delete /repo/gone.py")

    def test_a_malformed_item_is_dropped_rather_than_raised(self):
        bridge, _, out = codex_bridge()

        bridge._file_change({"type": "fileChange", "id": "i"})
        bridge._file_change({"type": "fileChange", "id": "i", "changes": "no"})
        bridge._file_change({"type": "fileChange", "id": "i", "changes": [None]})

        self.assertEqual(out.blocks("tool_use"), [])

    def test_a_completed_patch_item_reaches_the_mapping(self):
        """The routing, not just the mapping: `item/completed` has to get here."""
        bridge, _, out = codex_bridge([
            {"jsonrpc": "2.0", "id": 1, "result": {}},
            {"jsonrpc": "2.0", "method": "item/completed",
             "params": {"item": FILE_CHANGE_ITEM}},
            {"jsonrpc": "2.0", "method": "turn/completed",
             "params": {"threadId": "thread-1", "turn": {}}},
        ])

        bridge.turn("edit those files", timeout=2)

        self.assertEqual(len(out.blocks("tool_use")), 2)


class ApprovalTests(unittest.TestCase):
    def pump_one(self, frame: dict, environment: dict | None = None):
        bridge, child, _ = codex_bridge([frame])
        with patch.dict(os.environ, environment or {}, clear=False):
            if environment is None:
                os.environ.pop("TERMMESH_AGENT_APPROVALS", None)
            bridge.rpc.pump(until_id=None, timeout=1)
        return [f for f in child.sent if "result" in f or "error" in f]

    def test_an_approval_request_is_answered_not_merely_observed(self):
        answers = self.pump_one({
            "jsonrpc": "2.0", "id": 7,
            "method": "item/fileChange/requestApproval",
            "params": {"itemId": "item-9"}})

        self.assertEqual(answers, [{"jsonrpc": "2.0", "id": 7,
                                    "result": {"decision": "accept"}}])

    def test_a_legacy_approval_uses_the_older_vocabulary(self):
        answers = self.pump_one({"jsonrpc": "2.0", "id": 3,
                                 "method": "applyPatchApproval", "params": {}})

        self.assertEqual(answers[0]["result"], {"decision": "approved"})

    def test_asking_is_answered_by_declining_rather_than_by_hanging(self):
        answers = self.pump_one(
            {"jsonrpc": "2.0", "id": 4,
             "method": "item/commandExecution/requestApproval", "params": {}},
            {"TERMMESH_AGENT_APPROVALS": "ask"})

        self.assertEqual(answers[0]["result"], {"decision": "decline"})

    def test_a_permission_request_grants_what_was_asked_and_no_more(self):
        answers = self.pump_one({
            "jsonrpc": "2.0", "id": 5,
            "method": "item/permissions/requestApproval",
            "params": {"permissions": {"network": True, "fileSystem": None}}})

        self.assertEqual(answers[0]["result"],
                         {"permissions": {"network": True}, "scope": "session"})

    def test_an_elicitation_is_declined_because_nobody_can_be_asked(self):
        answers = self.pump_one({"jsonrpc": "2.0", "id": 6,
                                 "method": "mcpServer/elicitation/request",
                                 "params": {}})

        self.assertEqual(answers[0]["result"]["action"], "decline")

    def test_an_unknown_request_gets_an_error_rather_than_silence(self):
        answers = self.pump_one({"jsonrpc": "2.0", "id": 8,
                                 "method": "some/futureRequest", "params": {}})

        self.assertEqual(answers[0]["id"], 8)
        self.assertEqual(answers[0]["error"]["code"], -32601)

    def test_a_notification_is_only_observed(self):
        bridge, child, _ = codex_bridge([
            {"jsonrpc": "2.0", "method": "item/agentMessage/delta",
             "params": {"delta": "hi"}}])

        bridge.rpc.pump(until_id=None, timeout=1)

        self.assertEqual(child.sent, [])


class ThreadStartTests(unittest.TestCase):
    def start_over(self, frames):
        bridge, child, _ = codex_bridge(frames)
        bridge.thread_id = None
        started = bridge.start()
        requests = [f for f in child.sent if f.get("method") == "thread/start"]
        return started, requests

    def test_thread_start_asks_for_no_approvals(self):
        started, requests = self.start_over([
            {"jsonrpc": "2.0", "id": 1, "result": {}},          # initialize
            {"jsonrpc": "2.0", "id": 2,
             "result": {"thread": {"id": "thread-2"}}},         # thread/start
        ])

        self.assertTrue(started)
        params = requests[0]["params"]
        self.assertEqual(params["approvalPolicy"], "never")
        self.assertEqual(params["sandbox"], "danger-full-access")
        # `sandboxPolicy` is turn/start's field, and a different type. Sent
        # here it is silently ignored, which reads as a policy that applied.
        self.assertNotIn("sandboxPolicy", params)

    def test_thread_start_retries_without_the_policy_when_refused(self):
        started, requests = self.start_over([
            {"jsonrpc": "2.0", "id": 1, "result": {}},
            {"jsonrpc": "2.0", "id": 2,
             "error": {"code": -32600, "message": "unknown variant `never`"}},
            {"jsonrpc": "2.0", "id": 3,
             "result": {"thread": {"id": "thread-3"}}},
        ])

        self.assertTrue(started)
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[1]["params"], {"cwd": "/tmp/project"})


class TimeoutTests(unittest.TestCase):
    def test_hung_per_turn_child_is_stopped_within_its_deadline(self):
        out = CapturedEmitter()
        bridge = BRIDGE.PerTurnBridge("agy", "/tmp", None, out)
        command = [
            sys.executable,
            "-c",
            "import sys,time; print('partial', flush=True); time.sleep(30)",
        ]

        started = time.monotonic()
        with patch.object(bridge, "_argv", return_value=command):
            bridge.turn("wait forever", timeout=0.15)
        elapsed = time.monotonic() - started

        self.assertLess(elapsed, 1.0)
        result = [e for e in out.events if e.get("type") == "result"][-1]
        self.assertEqual(result["stop_reason"], "timeout")
        self.assertTrue(result["is_error"])

    def test_codex_timeout_is_failed_and_preserves_partial_text(self):
        bridge, _, out = codex_bridge([
            {"jsonrpc": "2.0", "id": 1, "result": {}},
            {"jsonrpc": "2.0", "method": "item/agentMessage/delta",
             "params": {"delta": "partial codex answer"}},
        ])

        bridge.turn("do work", timeout=0.05)

        result = [e for e in out.events if e.get("type") == "result"][-1]
        self.assertEqual(result["stop_reason"], "timeout")
        self.assertTrue(result["is_error"])
        self.assertEqual(result["result"], "partial codex answer")

    def test_acp_timeout_is_failed_and_preserves_partial_text(self):
        bridge, _, out = acp_bridge([
            {"jsonrpc": "2.0", "method": "session/update", "params": {
                "update": {"sessionUpdate": "agent_message_chunk",
                           "content": {"text": "partial acp answer"}}}},
        ])

        bridge.turn("do work", timeout=0.05)

        result = [e for e in out.events if e.get("type") == "result"][-1]
        self.assertEqual(result["stop_reason"], "timeout")
        self.assertTrue(result["is_error"])
        self.assertEqual(result["result"], "partial acp answer")

    def test_stop_process_kills_reaps_and_closes_streams_idempotently(self):
        child = subprocess.Popen(
            [sys.executable, "-c",
             "import signal,time; signal.signal(signal.SIGTERM, "
             "signal.SIG_IGN); print('ready', flush=True); time.sleep(30)"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(child.stdout.readline().strip(), "ready")

        BRIDGE.stop_process(child, timeout=0.05)
        BRIDGE.stop_process(child, timeout=0.05)

        self.assertIsNotNone(child.returncode)
        self.assertTrue(child.stdin.closed)
        self.assertTrue(child.stdout.closed)


class ClampTests(unittest.TestCase):
    def test_short_output_is_left_alone(self):
        self.assertEqual(BRIDGE.clamp("hello", 100), "hello")

    def test_a_cut_lands_between_lines_and_says_so(self):
        text = "".join(f"line {n}\n" for n in range(200))

        cut = BRIDGE.clamp(text, 100)

        body, tail = cut.rsplit("\n", 1)
        self.assertTrue(all(line.startswith("line ") for line in body.split("\n")))
        self.assertRegex(tail, r"^… \d+ more lines$")

    def test_a_truncated_patch_is_marked_as_truncated(self):
        bridge, _, out = codex_bridge()
        huge = "".join(f"+line {n}\n" for n in range(20000))

        bridge._file_change({"type": "fileChange", "id": "i", "changes": [
            {"path": "/repo/big.py", "kind": {"type": "add"}, "diff": huge}]})

        self.assertTrue(out.blocks("tool_use")[0]["input"]["diff_truncated"])


class EmitterShapeTests(unittest.TestCase):
    def test_a_headline_caller_still_gets_the_old_shape(self):
        out = CapturedEmitter()

        out.tool("shell", "ls -l", call_id="c1")

        block = out.blocks("tool_use")[0]
        self.assertEqual(block["input"], {"command": "ls -l"})
        self.assertEqual(block["id"], "c1")

    def test_a_structured_caller_gets_its_fields_through_unchanged(self):
        out = CapturedEmitter()

        out.tool("edit", "ignored", fields={"file_path": "/a.py"})

        self.assertEqual(out.blocks("tool_use")[0]["input"],
                         {"file_path": "/a.py"})


class AcpToolShapeTests(unittest.TestCase):
    def test_a_tool_call_hands_over_its_input_rather_than_a_python_repr(self):
        bridge = BRIDGE.AcpBridge.__new__(BRIDGE.AcpBridge)
        out = CapturedEmitter()
        bridge.out = out

        raw = {"file_path": "/repo/a.py", "old_string": "x"}
        bridge.out.tool("Edit File", "", call_id="t1", fields=raw)

        block = out.blocks("tool_use")[0]
        self.assertEqual(block["input"]["file_path"], "/repo/a.py")
        self.assertNotIn("{'", str(block["input"].get("command", "")))


class CodexSchemaDriftTests(unittest.TestCase):
    """The mapping is only as true as the schema it was written against.

    Codex ships its own protocol generator, so a rename does not have to be
    discovered weeks later as a row that draws nothing.
    """

    @unittest.skipUnless(shutil.which("codex"), "codex is not installed")
    def test_codex_still_reports_a_patch_the_way_we_read_it(self):
        with tempfile.TemporaryDirectory() as out:
            done = subprocess.run(
                ["codex", "app-server", "generate-ts", "--out", out],
                capture_output=True, text=True, check=False)
            if done.returncode != 0:
                self.skipTest("this codex cannot generate its bindings")
            change = Path(out, "v2", "FileUpdateChange.ts")
            item = Path(out, "v2", "ThreadItem.ts")
            if not change.exists() or not item.exists():
                self.skipTest("this codex lays its bindings out differently")
            declaration = change.read_text(encoding="utf-8")
            union = item.read_text(encoding="utf-8")

        for field in ("path", "kind", "diff"):
            self.assertIn(f"{field}:", declaration)
        self.assertIn("fileChange", union)
        self.assertIn("changes", union)


if __name__ == "__main__":
    unittest.main()
