#!/usr/bin/env python3
"""Installed-app leader measurement smoke: bundle, linked turn, read-only report, cleanup."""
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def main() -> int:
    app_bin = Path(os.environ["TERMMESH_APP_BIN"])
    app = app_bin.parents[2]
    hook = app / "Contents" / "Resources" / "scripts" / "leader-turn-hook.sh"
    cli = app / "Contents" / "Resources" / "bin" / "tm-agent"
    if not os.access(cli, os.X_OK):
        raise termmeshError(f"bundled tm-agent is not executable: {cli}")
    if not os.access(hook, os.X_OK):
        raise termmeshError(f"bundled leader hook is not executable: {hook}")

    with tempfile.TemporaryDirectory(prefix="leader-turn-e2e-") as home:
        env = os.environ.copy()
        env.update({
            "HOME": home, "TERMMESH_TEAM": "e2e-measurement",
            "TERMMESH_SURFACE_ID": "surface-e2e",
            "TERMMESH_LEADER_REQUEST_TOKEN": "test-only-token",
        })
        start = {"session_id": "session-e2e", "prompt": "private e2e prompt"}
        subprocess.run([str(hook), "--start"], input=json.dumps(start), text=True, env=env, check=True)
        subprocess.run([str(cli), "leader", "turn", "route",
                        "--route", "direct", "--task-shape", "single_unit",
                        "--available-workers", "0"], env=env, check=True, capture_output=True, text=True)
        subprocess.run([str(hook), "--end"], input="{}", text=True, env=env, check=True)
        rows = [json.loads(line) for line in (Path(home) / ".term-mesh/logs/turns.log").read_text().splitlines()]
        if [row["event"] for row in rows] != ["turn_start", "turn_route", "turn_end"]:
            raise termmeshError(f"unexpected turn sequence: {rows}")
        if len({row["turn_id"] for row in rows}) != 1:
            raise termmeshError(f"turn ids are not linked: {rows}")
        if "private e2e prompt" in json.dumps(rows):
            raise termmeshError("prompt content leaked into measurement log")
        if rows[1].get("policy_mode") != "shadow" or rows[1].get("policy_applied") is not False:
            raise termmeshError(f"default is not shadow/non-applied: {rows[1]}")

    team = f"measure-e2e-{os.getpid()}"
    with termmesh() as client:
        client.team_create(team, [], leader_mode="repl")
        before = client._call("system.identify")
        status = client.team_status(team)
        after = client._call("system.identify")
        if "leader_measurement" not in status:
            raise termmeshError(f"team.status omitted leader_measurement: {status}")
        if before.get("focused") != after.get("focused"):
            raise termmeshError("read-only measurement query changed focus")
        client.team_destroy(team)

    print("PASS: installed bundle emits linked privacy-safe shadow turn and read-only health report")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
