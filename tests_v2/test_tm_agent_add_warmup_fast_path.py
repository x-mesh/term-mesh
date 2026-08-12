#!/usr/bin/env python3
"""One tm-agent invocation adds a Codex reviewer and waits for its pong.

The fake Codex process speaks the real app-server protocol, so this covers the
GUI team RPC, native pane bridge, task delivery, result correlation, and warmup
completion without using network credentials.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


TEAM_NAME = f"test-add-warmup-{uuid.uuid4().hex[:8]}"
AGENT_NAME = f"codex-reviewer-{uuid.uuid4().hex[:8]}"
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
        reply = {"id": request_id, "result": {"thread": {"id": "e2e-thread"}}}
        print(json.dumps(reply), flush=True)
    elif method == "turn/start":
        print(json.dumps({"id": request_id, "result": {"turn": {"id": "e2e-turn"}}}), flush=True)
        result = ("STATUS: DONE\nFILES: none\nVERIFY: n/a\n"
                  "NEXT: NONE\nFULL_REPORT: n/a\n\npong")
        completed = {"method": "item/completed", "params": {"item": {
            "type": "agentMessage", "text": result
        }}}
        print(json.dumps(completed), flush=True)
        done = {"method": "turn/completed", "params": {
            "threadId": "e2e-thread", "turn": {"status": "completed"}
        }}
        print(json.dumps(done), flush=True)
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
            ["defaults", "write", DEFAULTS_DOMAIN, DEFAULTS_KEY,
             "-string", str(fake_codex)],
            check=True,
        )

        try:
            with termmesh() as client:
                client.team_create(TEAM_NAME, [])
                try:
                    env = os.environ.copy()
                    env["TERMMESH_SOCKET"] = client.socket_path
                    env["TERMMESH_TEAM"] = TEAM_NAME

                    # This is deliberately the only tm-agent subprocess in the test.
                    proc = subprocess.run(
                        [str(tm_agent), "add", "reviewer", "--name", AGENT_NAME,
                         "--cli", "codex", "--warmup",
                         "--warmup-timeout", "20"],
                        cwd=repo, env=env, text=True, capture_output=True, timeout=30,
                        check=False,
                    )
                    output = proc.stdout + proc.stderr
                    if proc.returncode != 0:
                        raise termmeshError(
                            f"single-call add+warmup exited {proc.returncode}:\n{output}"
                        )
                    if "All 1 agent(s) warm" not in output:
                        raise termmeshError(f"warmup completion missing from output:\n{output}")

                    status = client._call("team.status", {"team_name": TEAM_NAME})
                    agents = status.get("agents", []) if isinstance(status, dict) else []
                    added = next((a for a in agents if a.get("name") == AGENT_NAME), None)
                    if added is None:
                        raise termmeshError(f"added agent missing from team status: {status!r}")
                    if added.get("cli") != "codex":
                        raise termmeshError(f"added agent used wrong CLI: {added!r}")
                    if added.get("model") != "gpt-5.6-sol":
                        raise termmeshError(f"Codex native default was not applied: {added!r}")
                finally:
                    client.team_destroy(TEAM_NAME)
        finally:
            _restore_default(old_existed, old_value)

    print("PASS: one tm-agent call adds a Codex reviewer and completes warmup")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
