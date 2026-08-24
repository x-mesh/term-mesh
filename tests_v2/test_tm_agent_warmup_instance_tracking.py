#!/usr/bin/env python3
"""Warmup tracks duplicate-named agents by instance and taskless wait fails fast."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


TEAM_NAME = f"test-warmup-instances-{uuid.uuid4().hex[:8]}"
AGENT_NAME = "duplicate-reviewer"
AGENT_COUNT = 4
DEFAULTS_DOMAIN = "com.termmesh.app.debug"
DEFAULTS_KEY = "cliPath.codex"

FAKE_CODEX = r'''#!/usr/bin/env python3
import json
import sys

for raw in sys.stdin:
    try:
        request = json.loads(raw)
    except json.JSONDecodeError:
        continue
    request_id = request.get("id")
    method = request.get("method")
    if method == "initialize":
        print(json.dumps({"id": request_id, "result": {}}), flush=True)
    elif method == "thread/start":
        print(json.dumps({"id": request_id, "result": {"thread": {"id": "e2e-thread"}}}), flush=True)
    elif method == "turn/start":
        print(json.dumps({"id": request_id, "result": {"turn": {"id": "e2e-turn"}}}), flush=True)
        print(json.dumps({"method": "item/completed", "params": {"item": {
            "type": "agentMessage", "text": "pong"
        }}}), flush=True)
        print(json.dumps({"method": "turn/completed", "params": {
            "threadId": "e2e-thread", "turn": {"status": "completed"}
        }}), flush=True)
'''


def _read_default() -> tuple[bool, str]:
    proc = subprocess.run(
        ["defaults", "read", DEFAULTS_DOMAIN, DEFAULTS_KEY],
        text=True, capture_output=True, check=False,
    )
    return proc.returncode == 0, proc.stdout.rstrip("\n")


def _restore_default(existed: bool, value: str) -> None:
    if existed:
        subprocess.run(
            ["defaults", "write", DEFAULTS_DOMAIN, DEFAULTS_KEY, "-string", value],
            check=True,
        )
    else:
        subprocess.run(
            ["defaults", "delete", DEFAULTS_DOMAIN, DEFAULTS_KEY],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )


def _run(tm_agent: Path, env: dict[str, str], *args: str, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(tm_agent), *args], cwd=tm_agent.parents[3], env=env,
        text=True, capture_output=True, timeout=timeout, check=False,
    )


def main() -> int:
    repo = Path(__file__).resolve().parents[1]
    tm_agent = repo / "daemon" / "target" / "release" / "tm-agent"
    if not tm_agent.is_file():
        raise termmeshError(f"tm-agent binary not found: {tm_agent}")

    old_existed, old_value = _read_default()
    with tempfile.TemporaryDirectory(prefix="term-mesh-fake-codex-") as tmp:
        fake_codex = Path(tmp) / "codex"
        fake_codex.write_text(FAKE_CODEX)
        fake_codex.chmod(fake_codex.stat().st_mode | stat.S_IXUSR)
        subprocess.run(
            ["defaults", "write", DEFAULTS_DOMAIN, DEFAULTS_KEY, "-string", str(fake_codex)],
            check=True,
        )

        try:
            with termmesh() as client:
                client.team_create(TEAM_NAME, [])
                try:
                    env = os.environ.copy()
                    env["TERMMESH_SOCKET"] = client.socket_path
                    env["TERMMESH_TEAM"] = TEAM_NAME

                    for _ in range(AGENT_COUNT):
                        added = _run(
                            tm_agent, env, "add", "reviewer", "--name", AGENT_NAME,
                            "--cli", "codex",
                        )
                        if added.returncode != 0:
                            raise termmeshError(
                                f"duplicate agent add failed ({added.returncode}):\n"
                                f"{added.stdout}{added.stderr}"
                            )

                    status = dict(client._call("team.status", {"team_name": TEAM_NAME}) or {})
                    instances = {
                        agent.get("agent_instance_id")
                        for agent in status.get("agents", [])
                        if agent.get("name") == AGENT_NAME
                    }
                    if None in instances or len(instances) != AGENT_COUNT:
                        raise termmeshError(
                            f"expected {AGENT_COUNT} durable duplicate instances, got {status!r}"
                        )

                    warmup = _run(
                        tm_agent, env, "warmup", AGENT_NAME, "--timeout", "20", timeout=30,
                    )
                    output = warmup.stdout + warmup.stderr
                    if warmup.returncode != 0:
                        raise termmeshError(f"warmup exited {warmup.returncode}:\n{output}")
                    if f"All {AGENT_COUNT} agent(s) warm" not in output:
                        raise termmeshError(f"warmup did not collect every instance:\n{output}")
                    for instance_id in instances:
                        if f"({instance_id})" not in output:
                            raise termmeshError(
                                f"warmup omitted instance {instance_id!r}:\n{output}"
                            )

                    tasks_result = dict(client._call(
                        "team.task.list", {"team_name": TEAM_NAME}
                    ) or {})
                    for task in tasks_result.get("tasks", []):
                        if task.get("title") == "warmup-ping":
                            client._call("team.task.update", {
                                "team_name": TEAM_NAME,
                                "task_id": task.get("id"),
                                "status": "completed",
                                "result": "warmup verified",
                            })

                    # A name-only message can identify a role, not a specific
                    # duplicate instance. It must never count as four replies.
                    message_wait = subprocess.Popen(
                        [str(tm_agent), "wait", "--mode", "msg", "--timeout", "1"],
                        cwd=repo, env=env, text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    )
                    time.sleep(0.2)
                    client.team_message_post(TEAM_NAME, AGENT_NAME, "one uncorrelated message")
                    message_stdout, message_stderr = message_wait.communicate(timeout=5)
                    message_output = message_stdout + message_stderr
                    if message_wait.returncode == 0:
                        raise termmeshError(
                            "one name-only message was counted as every duplicate instance:\n"
                            f"{message_output}"
                        )
                    if f"1/{AGENT_COUNT} agents messaged" not in message_output:
                        raise termmeshError(
                            f"message wait did not preserve duplicate instance count:\n{message_output}"
                        )

                    broadcast = _run(tm_agent, env, "broadcast", "Reply with PONG")
                    if broadcast.returncode != 0:
                        raise termmeshError(
                            f"broadcast failed ({broadcast.returncode}):\n"
                            f"{broadcast.stdout}{broadcast.stderr}"
                        )

                    started = time.monotonic()
                    waited = _run(
                        tm_agent, env, "wait", "--mode", "any", "--timeout", "20", timeout=5,
                    )
                    elapsed = time.monotonic() - started
                    wait_output = waited.stdout + waited.stderr
                    if waited.returncode == 0 or elapsed >= 5:
                        raise termmeshError(
                            f"taskless wait did not fail fast (code={waited.returncode}, "
                            f"elapsed={elapsed:.2f}s):\n{wait_output}"
                        )
                    if "no task or correlation to track" not in wait_output:
                        raise termmeshError(f"wait error was not actionable:\n{wait_output}")
                finally:
                    client.team_destroy(TEAM_NAME)
        finally:
            _restore_default(old_existed, old_value)

    print("PASS: warmup tracks duplicate instances and taskless wait fails fast")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
