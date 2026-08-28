#!/usr/bin/env python3
"""Adopted leaders may read task metrics from their own TTY; sibling panes may not."""

from __future__ import annotations

import os
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

                args = (
                    f"env -u TERMMESH_LEADER_REQUEST_TOKEN {shlex.quote(str(cli))} "
                    f"--team {shlex.quote(team)} task metrics"
                )
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
            finally:
                client.team_destroy(team)

    print("PASS: adopted leader metrics uses live TTY identity and rejects sibling panes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
