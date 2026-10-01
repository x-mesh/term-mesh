#!/usr/bin/env python3
"""Adopted leaders authenticate metrics and durable requests by their pane's PTY.

A caller passes when its own or an ancestor's controlling terminal is the
leader pane's PTY, so a nested PTY (shell wrappers) and a process with no
controlling terminal (an agent's tool runner) inside the pane both pass.
Sibling panes never do.
"""

from __future__ import annotations

import os
import re
import shlex
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def _wait_text(path: Path, timeout: float = 10.0) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if path.exists():
                return path.read_text(errors="replace")
        except OSError:
            pass
        time.sleep(0.05)
    raise termmeshError(f"timed out waiting for {path}")


def _wait_contains(path: Path, needle: str, timeout: float = 10.0) -> str:
    deadline = time.time() + timeout
    text = ""
    while time.time() < deadline:
        try:
            text = path.read_text(errors="replace")
        except OSError:
            text = ""
        if needle in text:
            return text
        time.sleep(0.05)
    raise termmeshError(f"timed out waiting for {needle!r} in {path}: {text!r}")


def _succeeded(output: str) -> bool:
    return re.search(r'"ok"\s*:\s*true', output) is not None


# An interactive shell makes each job a process-group leader, and setsid()
# refuses a group leader, so detach in a forked child.
DETACH = """\
import os, sys
pid = os.fork()
if pid == 0:
    os.setsid()
    os.execvp(sys.argv[1], sys.argv[1:])
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
"""


def _surface_ids(client: termmesh, workspace_id: str) -> list[str]:
    payload = client._call("surface.list", {"workspace_id": workspace_id}) or {}
    surfaces = payload.get("surfaces") or []
    result = [str(item.get("surface_id") or item.get("id") or "") for item in surfaces]
    return [value for value in result if value]


def _run_in_surface(client: termmesh, surface_id: str, command: str, output: Path) -> str:
    done = output.with_suffix(output.suffix + ".done")
    shell = f"{command} > {shlex.quote(str(output))} 2>&1; printf done > {shlex.quote(str(done))}"
    client.send_surface(surface_id, shell + "\n")
    _wait_text(done)
    return _wait_text(output)


def main() -> int:
    app_bin = Path(os.environ["TERMMESH_APP_BIN"])
    cli = app_bin.parents[2] / "Contents" / "Resources" / "bin" / "tm-agent"
    if not os.access(cli, os.X_OK):
        raise termmeshError(f"bundled tm-agent is not executable: {cli}")

    team = f"adopted-metrics-{uuid.uuid4().hex[:8]}"
    with tempfile.TemporaryDirectory(prefix="adopted-metrics-e2e-") as temp_dir:
        root = Path(temp_dir)
        with termmesh() as client:
            current = client._call("workspace.current") or {}
            workspace_id = str(current.get("workspace_id") or "")
            if not workspace_id:
                raise termmeshError(f"workspace.current returned no id: {current!r}")
            before = _surface_ids(client, workspace_id)
            if not before:
                raise termmeshError("initial workspace has no terminal surface")
            leader_surface = before[0]
            sibling_surface = client.new_split("right")
            if not sibling_surface or sibling_surface == leader_surface:
                raise termmeshError(
                    f"failed to create a distinct sibling terminal: "
                    f"leader={leader_surface} sibling={sibling_surface}"
                )
            client._call("team.create", {
                "team_name": team,
                "leader_mode": "adopted",
                "leader_cli": "codex",
                "surface_id": leader_surface,
                "working_directory": str(Path.cwd()),
                "runbook_init_prompt": False,
                "agents": [{
                    "name": "worker",
                    "cli": "claude",
                    "model": "sonnet",
                    "agent_type": "worker",
                    "color": "green",
                }],
            })
            try:
                leader_tty = root / "leader.tty"
                sibling_tty = root / "sibling.tty"
                _run_in_surface(client, leader_surface, "tty", leader_tty)
                _run_in_surface(client, sibling_surface, "tty", sibling_tty)
                if leader_tty.read_text().strip() == sibling_tty.read_text().strip():
                    raise termmeshError("leader and sibling unexpectedly share one controlling TTY")

                tm = (
                    f"env -u TERMMESH_LEADER_REQUEST_TOKEN {shlex.quote(str(cli))} "
                    f"--team {shlex.quote(team)}"
                )
                args = f"{tm} task metrics"
                leader_output = _run_in_surface(
                    client, leader_surface, args, root / "leader.metrics"
                )
                sibling_output = _run_in_surface(
                    client, sibling_surface, args, root / "sibling.metrics"
                )
                if "unauthorized" in leader_output.lower():
                    raise termmeshError(f"adopted leader was rejected: {leader_output!r}")
                if "not_found" not in leader_output.lower() and "no durable leader request" not in leader_output.lower():
                    raise termmeshError(
                        f"adopted leader did not reach the metrics store: {leader_output!r}"
                    )
                if "unauthorized" not in sibling_output.lower():
                    raise termmeshError(f"sibling pane bypassed TTY authorization: {sibling_output!r}")

                take_missing = f"{tm} leader request take e2e-missing-request"
                output = _run_in_surface(client, leader_surface, take_missing, root / "leader.take-missing")
                if "not_found" not in output or "unauthorized" in output.lower():
                    raise termmeshError(f"adopted leader take was not authorized: {output!r}")
                output = _run_in_surface(client, sibling_surface, take_missing, root / "sibling.take-missing")
                if "unauthorized" not in output.lower():
                    raise termmeshError(f"sibling pane took a durable request: {output!r}")

                leader_device = leader_tty.read_text().strip()
                nested_tty = _run_in_surface(
                    client, leader_surface, "script -q /dev/null tty", root / "nested.tty"
                ).strip()
                if not nested_tty.startswith("/dev/") or nested_tty == leader_device:
                    raise termmeshError(f"script did not give the caller its own PTY: {nested_tty!r}")
                output = _run_in_surface(
                    client, leader_surface, f"script -q /dev/null {take_missing}", root / "nested.take-missing"
                )
                if "not_found" not in output or "unauthorized" in output.lower():
                    raise termmeshError(f"caller on a nested PTY in the leader pane was rejected: {output!r}")

                detach = root / "detach.py"
                detach.write_text(DETACH)
                detached = f"{shlex.quote(sys.executable)} {shlex.quote(str(detach))}"
                output = _run_in_surface(client, leader_surface, f"{detached} tty", root / "detached.tty")
                if "not a tty" not in output:
                    raise termmeshError(f"detached caller still has a controlling terminal: {output!r}")
                output = _run_in_surface(
                    client, leader_surface, f"{detached} {take_missing}", root / "detached.take-missing"
                )
                if "not_found" not in output or "unauthorized" in output.lower():
                    raise termmeshError(f"caller without a controlling terminal was rejected: {output!r}")

                # The wake is pasted into the leader pane; a shell would run it,
                # so capture it with cat and keep the request queued.
                wake_file = root / "leader.wake"
                client.send_surface(leader_surface, f"cat > {shlex.quote(str(wake_file))}\n")
                _wait_text(wake_file)
                request_id = f"e2e-adopted-{uuid.uuid4().hex[:8]}"
                content = f"adopted leader e2e request {request_id}"
                sent = client._call("team.leader.send", {
                    "team_name": team, "text": content, "request_id": request_id,
                }) or {}
                if sent.get("stored") is not True or sent.get("wake_dispatched") is not True:
                    raise termmeshError(f"durable request was not stored and dispatched: {sent!r}")
                wake = _wait_contains(wake_file, f"leader request take {request_id}")
                client.send_key_surface(leader_surface, "ctrl-c")
                if not re.search(rf"--team '?{re.escape(team)}'? leader request take", wake):
                    raise termmeshError(f"adopted leader wake does not name its team: {wake!r}")

                output = _run_in_surface(
                    client, sibling_surface, f"{tm} leader request take {request_id}", root / "sibling.take"
                )
                if "unauthorized" not in output.lower():
                    raise termmeshError(f"sibling pane took the queued request: {output!r}")
                output = _run_in_surface(client, leader_surface, f"{tm} leader request list", root / "leader.list")
                if not _succeeded(output) or request_id not in output:
                    raise termmeshError(f"adopted leader could not list its request: {output!r}")
                output = _run_in_surface(
                    client, leader_surface, f"{tm} leader request take {request_id}", root / "leader.take"
                )
                if not _succeeded(output) or content not in output:
                    raise termmeshError(f"adopted leader could not take its request: {output!r}")
                output = _run_in_surface(
                    client, leader_surface, f"{tm} leader request complete {request_id}", root / "leader.complete"
                )
                if not _succeeded(output):
                    raise termmeshError(f"adopted leader could not complete its request: {output!r}")
            finally:
                client.team_destroy(team)

    print("PASS: adopted leader metrics and durable requests use the pane's PTY ancestry and reject sibling panes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
