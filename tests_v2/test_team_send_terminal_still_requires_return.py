#!/usr/bin/env python3
"""A terminal-hosted agent still requires the Return round trip.

The other half of the return_required contract: with the native panel (and the
pipe transport) switched off, team.send must answer return_required=true and
the follow-up team.send_key must type a real Return (no no_keyboard shortcut).
A false answer here would leave every terminal paste sitting unsubmitted.
"""

from __future__ import annotations

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


TEAM_NAME = f"test-terminal-return-{uuid.uuid4().hex[:8]}"
AGENT_NAME = f"codex-terminal-{uuid.uuid4().hex[:8]}"
DEFAULTS_DOMAIN = "com.termmesh.app.debug"
CLI_PATH_KEY = "cliPath.codex"
PIPE_ENABLED_KEY = "agentPipeTransport.enabled"
NATIVE_PANEL_KEY = "agentPipeTransport.nativePanel"

# Prints a banner immediately: the first paste into a fresh terminal pane is
# gated on pty output, and a silent child would hold that gate shut forever.
FAKE_CODEX = r'''#!/usr/bin/env python3
import sys

print("fake-codex terminal ready", flush=True)
for raw in sys.stdin:
    pass
'''


def _read_default(key: str) -> tuple[bool, str]:
    proc = subprocess.run(
        ["defaults", "read", DEFAULTS_DOMAIN, key],
        text=True, capture_output=True, check=False,
    )
    return proc.returncode == 0, proc.stdout.rstrip("\n")


def _write_default(key: str, value: str) -> None:
    subprocess.run(
        ["defaults", "write", DEFAULTS_DOMAIN, key, "-string", value],
        check=True,
    )


def _write_default_bool(key: str, value: bool) -> None:
    subprocess.run(
        ["defaults", "write", DEFAULTS_DOMAIN, key, "-bool",
         "true" if value else "false"],
        check=True,
    )


def _restore_default(key: str, existed: bool, value: str) -> None:
    if existed:
        _write_default(key, value)
    else:
        subprocess.run(
            ["defaults", "delete", DEFAULTS_DOMAIN, key],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )


def main() -> int:
    repo = Path(__file__).resolve().parents[1]
    tm_agent = repo / "daemon" / "target" / "release" / "tm-agent"
    if not tm_agent.is_file():
        raise termmeshError(f"tm-agent binary not found: {tm_agent}")

    saved = {
        key: _read_default(key)
        for key in (CLI_PATH_KEY, PIPE_ENABLED_KEY, NATIVE_PANEL_KEY)
    }
    with tempfile.TemporaryDirectory(prefix="term-mesh-fake-codex-") as tmp:
        fake_codex = Path(tmp) / "codex"
        fake_codex.write_text(FAKE_CODEX)
        fake_codex.chmod(fake_codex.stat().st_mode | stat.S_IXUSR)
        _write_default(CLI_PATH_KEY, str(fake_codex))
        _write_default_bool(PIPE_ENABLED_KEY, False)
        _write_default_bool(NATIVE_PANEL_KEY, False)

        try:
            with termmesh() as client:
                client.team_create(TEAM_NAME, [])
                try:
                    env = os.environ.copy()
                    env["TERMMESH_SOCKET"] = client.socket_path
                    env["TERMMESH_TEAM"] = TEAM_NAME
                    add = subprocess.run(
                        [str(tm_agent), "add", "reviewer", "--name", AGENT_NAME,
                         "--cli", "codex"],
                        cwd=repo, env=env, text=True, capture_output=True,
                        timeout=30, check=False,
                    )
                    if add.returncode != 0:
                        raise termmeshError(
                            f"add exited {add.returncode}:\n{add.stdout}{add.stderr}"
                        )

                    deadline = time.monotonic() + 15
                    panel_id = None
                    while time.monotonic() < deadline:
                        status = client._call("team.status", {"team_name": TEAM_NAME})
                        agents = status.get("agents", []) if isinstance(status, dict) else []
                        entry = next(
                            (a for a in agents if a.get("name") == AGENT_NAME), None
                        )
                        panel_id = (entry or {}).get("panel_id")
                        if panel_id:
                            break
                        time.sleep(0.2)
                    if not panel_id:
                        raise termmeshError(f"agent pane never appeared: {AGENT_NAME}")

                    sent = client._call("team.send", {
                        "team_name": TEAM_NAME,
                        "agent_name": AGENT_NAME,
                        "text": "terminal contract ping\n",
                        "send_sequence_aware": True,
                    })
                    if sent.get("return_required") is not True:
                        raise termmeshError(
                            "a terminal target must keep return_required=true "
                            f"(a false here loses the turn): {sent!r}"
                        )
                    if sent.get("text_delivered") is not True:
                        raise termmeshError(f"terminal paste was not delivered: {sent!r}")
                    sequence_id = sent.get("send_sequence_id")
                    if not sequence_id:
                        raise termmeshError(
                            f"sequence-aware ack carried no send_sequence_id: {sent!r}"
                        )

                    key = client._call("team.send_key", {
                        "team_name": TEAM_NAME,
                        "agent_name": AGENT_NAME,
                        "key": "return",
                        "send_sequence_id": sequence_id,
                    })
                    if key.get("sent") is not True:
                        raise termmeshError(f"terminal Return was not delivered: {key!r}")
                    if key.get("no_keyboard") is not None:
                        raise termmeshError(
                            f"terminal Return must be typed, not shortcut: {key!r}"
                        )
                finally:
                    client.team_destroy(TEAM_NAME)
        finally:
            for key, (existed, value) in saved.items():
                _restore_default(key, existed, value)

    print("PASS: terminal agent keeps return_required=true and a typed Return")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
