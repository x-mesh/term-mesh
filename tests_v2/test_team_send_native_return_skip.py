#!/usr/bin/env python3
"""tm-agent send to a native agent submits without the Return round trip.

The team.send acknowledgement carries return_required=false for a natively-held
target, so the CLI must skip its legacy 250ms pre-delay and team.send_key call
(send_key.skip) while still reporting the send as submitted.
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


TEAM_NAME = f"test-native-return-skip-{uuid.uuid4().hex[:8]}"
AGENT_NAME = f"codex-native-{uuid.uuid4().hex[:8]}"
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
        completed = {"method": "item/completed", "params": {"item": {
            "type": "agentMessage", "text": "pong"
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


def _result_json(stdout: str) -> dict:
    """print_result writes one pretty JSON envelope; tolerate leading noise."""
    start = stdout.find("{")
    if start < 0:
        raise termmeshError(f"no JSON envelope in tm-agent stdout: {stdout!r}")
    return json.loads(stdout[start:])


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

                    add = subprocess.run(
                        [str(tm_agent), "add", "reviewer", "--name", AGENT_NAME,
                         "--cli", "codex", "--warmup", "--warmup-timeout", "20"],
                        cwd=repo, env=env, text=True, capture_output=True,
                        timeout=30, check=False,
                    )
                    if add.returncode != 0:
                        raise termmeshError(
                            f"add+warmup exited {add.returncode}:\n{add.stdout}{add.stderr}"
                        )

                    send = subprocess.run(
                        [str(tm_agent), "send", AGENT_NAME, "contract ping",
                         "--no-report"],
                        cwd=repo, env=env, text=True, capture_output=True,
                        timeout=30, check=False,
                    )
                    if send.returncode != 0:
                        raise termmeshError(
                            f"send exited {send.returncode}:\n{send.stdout}{send.stderr}"
                        )
                    if "send_key.skip" not in send.stderr:
                        raise termmeshError(
                            "expected send_key.skip (return_not_required) in stderr, "
                            f"got:\n{send.stderr}"
                        )
                    result = _result_json(send.stdout).get("result", {})
                    if result.get("return_required") is not False:
                        raise termmeshError(
                            f"expected return_required=false in the ack: {result!r}"
                        )
                    if result.get("delivery_scope") != "transport_write":
                        raise termmeshError(
                            "a local native write must report "
                            f"delivery_scope=transport_write: {result!r}"
                        )
                    if result.get("sent") is not True \
                            or result.get("return_submitted") is not True \
                            or result.get("delivery_state") != "submitted":
                        raise termmeshError(
                            f"native send did not report a submitted turn: {result!r}"
                        )
                finally:
                    client.team_destroy(TEAM_NAME)
        finally:
            _restore_default(old_existed, old_value)

    print("PASS: native team.send skips the Return round trip and reports submitted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
