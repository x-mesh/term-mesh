#!/usr/bin/env python3
"""team.delegate to a native assignee announces return_required=false.

Both the first delivery and its request_id replay must carry the field, so the
CLI can skip its Return follow-up on either path without pressing a key into a
pane that has no composer.
"""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


TEAM_NAME = f"test-delegate-return-{uuid.uuid4().hex[:8]}"
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

                    request_id = f"contract-{uuid.uuid4().hex[:16]}"
                    params = {
                        "team_name": TEAM_NAME,
                        "agent_name": AGENT_NAME,
                        "text": "delegate contract ping",
                        "request_id": request_id,
                    }
                    first = client._call("team.delegate", params)
                    if first.get("return_required") is not False:
                        raise termmeshError(
                            f"first delegate must announce return_required=false: {first!r}"
                        )
                    if first.get("text_delivered") is not True:
                        raise termmeshError(f"delegate text was not delivered: {first!r}")
                    if first.get("request_replayed") is not False:
                        raise termmeshError(f"first delegate reported a replay: {first!r}")

                    replay = client._call("team.delegate", params)
                    if replay.get("request_replayed") is not True:
                        raise termmeshError(
                            f"identical request_id was not replayed: {replay!r}"
                        )
                    if replay.get("return_required") is not False:
                        raise termmeshError(
                            f"replay must keep return_required=false: {replay!r}"
                        )
                finally:
                    client.team_destroy(TEAM_NAME)
        finally:
            _restore_default(old_existed, old_value)

    print("PASS: native delegate and its replay both announce return_required=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
