#!/usr/bin/env python3
"""Installed CLI proves canary, deterministic holdout, and next-turn kill-switch rollback."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

from termmesh import termmeshError


def route(cli: Path, env: dict, turn: str) -> dict:
    current = Path(env["HOME"]) / ".term-mesh/logs/.turn-current-surface-canary"
    current.parent.mkdir(parents=True, exist_ok=True)
    current.write_text(turn + "\n")
    result = subprocess.run([str(cli), "leader", "turn", "route",
        "--route", "direct", "--task-shape", "multi_unit",
        "--available-workers", "3"], env=env, check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def main() -> int:
    app_bin = Path(os.environ["TERMMESH_APP_BIN"])
    cli = app_bin.parents[2] / "Contents" / "Resources" / "bin" / "tm-agent"
    if not os.access(cli, os.X_OK):
        raise termmeshError(f"bundled tm-agent is not executable: {cli}")
    with tempfile.TemporaryDirectory(prefix="leader-canary-e2e-") as home:
        log = Path(home) / ".term-mesh/logs/turns.log"
        log.parent.mkdir(parents=True)
        linked = []
        for turn, timestamp in (
            ("first", "2026-08-26T00:00:00Z"),
            ("last", "2026-09-01T00:00:00Z"),
        ):
            linked.extend([
                {"event": "turn_start", "turn_id": turn, "ts": timestamp, "team": "p"},
                {"event": "turn_route", "turn_id": turn, "ts": timestamp, "team": "p"},
                {"event": "turn_end", "turn_id": turn, "ts": timestamp, "team": "p"},
            ])
        log.write_text("".join(json.dumps(record) + "\n" for record in linked))
        control = Path(home) / "control.json"
        config = {"mode": "canary", "percent": 100, "kill_switch": False,
                  "supported": True, "healthy": False, "opt_in": True,
                  "health_scope": "execution_host",
                  "project_id": "p", "session_id": "s"}
        control.write_text(json.dumps(config))
        control.chmod(0o600)
        env = os.environ.copy()
        env.update({"HOME": home, "TERMMESH_TEAM": "canary-e2e",
                    "TERMMESH_SURFACE_ID": "surface-canary",
                    "TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE": str(control)})
        applied = route(cli, env, "turn-canary")
        if not applied.get("directive") or not applied["record"].get("policy_applied"):
            raise termmeshError(f"eligible canary did not apply: {applied}")

        config["mode"] = "shadow"
        control.write_text(json.dumps(config))
        shadow = route(cli, env, "turn-shadow")
        if shadow.get("directive") is not None \
           or shadow["record"].get("policy_mode") != "shadow":
            raise termmeshError(f"Shadow mode changed the live route: {shadow}")

        config["mode"] = "canary"
        config["project_id"] = "missing-project"
        control.write_text(json.dumps(config))
        unhealthy = route(cli, env, "turn-unhealthy")
        if unhealthy.get("directive") is not None \
           or unhealthy["record"].get("policy_applied"):
            raise termmeshError(
                f"missing execution-host health did not fail closed: {unhealthy}"
            )
        config["project_id"] = "p"

        config["kill_switch"] = True
        control.write_text(json.dumps(config))
        killed = route(cli, env, "turn-killed")
        if killed.get("directive") is not None or killed["record"].get("policy_applied"):
            raise termmeshError(f"kill switch did not affect next turn: {killed}")

        config.update({"kill_switch": False, "percent": 0})
        control.write_text(json.dumps(config))
        holdout1 = route(cli, env, "turn-holdout-1")
        holdout2 = route(cli, env, "turn-holdout-2")
        cohorts = [holdout1["record"].get("cohort"), holdout2["record"].get("cohort")]
        if cohorts != ["holdout", "holdout"]:
            raise termmeshError(f"zero-percent holdout is not deterministic: {cohorts}")

    print("PASS: eligible canary applies and next-turn kill switch/zero-percent holdout fail closed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
