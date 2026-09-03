#!/usr/bin/env python3
"""A real remote leader completes work and changes behavior under healthy Canary."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError
from test_remote_project_restart_reattach import (
    DIR_ENV, HOST_ENV, REQUIRE_REMOTE_PROJECT_ENV,
    _connect, _remote_participation_control, _wait, _wait_for_project_deletion,
)


def remote_python(host: str, script: str) -> str:
    target = host.removeprefix("ssh:")
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", target, "python3", "-"],
        input=script, capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise termmeshError(f"remote Python failed: {result.stderr.strip()}")
    return result.stdout.strip()


def route_records(host: str, team: str) -> list[dict]:
    output = remote_python(host, f'''import json
from pathlib import Path
p = Path.home() / ".term-mesh/logs/turns.log"
rows = []
if p.exists():
    for line in p.read_text(errors="replace").splitlines():
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("team") == {team!r} and row.get("event") == "turn_route":
            rows.append(row)
print(json.dumps(rows))
''')
    return json.loads(output or "[]")


def seed_health_history(host: str, team: str) -> str:
    backup = f"/tmp/term-mesh-leader-turns-backup-{uuid.uuid4().hex}"
    output = remote_python(host, f'''import json, shutil
from pathlib import Path
path = Path.home() / ".term-mesh/logs/turns.log"
path.parent.mkdir(parents=True, exist_ok=True)
backup = Path({backup!r})
if path.exists(): shutil.copy2(path, backup)
rows = []
for turn, timestamp in (("history-first", "2026-08-18T00:00:00Z"), ("history-last", "2026-08-25T00:00:00Z")):
    rows.extend([
        {{"event": "turn_start", "turn_id": turn, "ts": timestamp, "team": {team!r}}},
        {{"event": "turn_route", "turn_id": turn, "ts": timestamp, "team": {team!r}}},
        {{"event": "turn_end", "turn_id": turn, "ts": timestamp, "team": {team!r}}},
    ])
path.write_text("".join(json.dumps(row) + "\\n" for row in rows))
print(str(backup))
''')
    return output.strip() or backup


def restore_health_history(host: str, backup: str) -> None:
    remote_python(host, f'''import shutil
from pathlib import Path
path = Path.home() / ".term-mesh/logs/turns.log"
backup = Path({backup!r})
if backup.exists(): shutil.move(str(backup), str(path))
elif path.exists(): path.unlink()
''')


def wait_request(c: termmesh, team: str, request_id: str, marker: str, task_floor: int):
    def complete():
        status = c.debug_leader_request_status(team, request_id)
        team_row = next((row for row in c.team_list() if row.get("team_name") == team), None)
        screen = c.read_terminal_text(team_row["leader_panel_id"]) if team_row else ""
        tasks = c.team_task_list(team)
        return (
            {"status": status, "screen": screen, "tasks": tasks}
            if status.get("status") == "completed" and marker in screen
            and len(tasks) >= task_floor else None
        )
    # A cold remote Codex worker can spend several minutes starting on Linux.
    # The Project leader attach has a 180s budget of its own; this covers that
    # already-complete leader plus one separately cold worker turn.
    result = _wait(complete, timeout_s=480, interval_s=1)
    if result is None:
        raise termmeshError(f"leader request {request_id} did not complete with {marker}")
    return result


def main() -> int:
    host = os.environ.get(HOST_ENV, "").strip()
    remote_dir = os.environ.get(DIR_ENV, "").strip()
    require_macos = os.environ.get("TERMMESH_E2E_REQUIRE_MACOS_LEADER_WORK") == "1"
    if not host or not remote_dir:
        if os.environ.get(REQUIRE_REMOTE_PROJECT_ENV) == "1" or require_macos:
            raise termmeshError(f"required leader-work topology missing: {HOST_ENV}, {DIR_ENV}")
        print(f"SKIP: set {HOST_ENV} and {DIR_ENV}")
        return 0
    target = host.removeprefix("ssh:")
    probe = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", target, "uname", "-s"],
        capture_output=True, text=True, timeout=10,
    )
    if probe.returncode != 0 or probe.stdout.strip() != "Darwin":
        if require_macos:
            raise termmeshError(
                f"required macOS leader-work host unavailable: host={host!r} "
                f"stdout={probe.stdout!r} stderr={probe.stderr!r}"
            )
        print(f"SKIP: leader-work behavior requires an authenticated macOS peer, got {host}")
        return 0

    team = f"leader-work-e2e-{uuid.uuid4().hex[:8]}"
    health_backup = seed_health_history(host, team)
    with termmesh() as c:
        _connect(c, host)
        c.debug_leader_participation_configure("shadow", 100, [team])
        created = c.debug_project_creation_attempt(
            team, remote_dir, ["executor", "reviewer"], host=host,
            leader_cli="codex", leader_model="gpt-5.6-luna",
            worker_cli="codex", worker_model="gpt-5.6-luna",
        )
        operation_id = str(created.get("operation_id") or "")
        if not operation_id:
            raise termmeshError(f"leader-work create returned no operation: {created!r}")
        try:
            creation = _wait(lambda: (
                status if (status := c.debug_project_creation_status(operation_id)).get("state")
                != "running" else None
            ), timeout_s=240)
            if creation is None or creation.get("state") != "created":
                raise termmeshError(f"leader-work Project was not created: {creation!r}")
            ready = _wait(lambda: next((
                row for row in c.team_list()
                if row.get("team_name") == team and row.get("leader_ready")
                and len(row.get("agents") or []) == 2
            ), None), timeout_s=90)
            if ready is None:
                raise termmeshError("leader-work Project never became ready")

            shadow_id = "shadow-leader-work"
            shadow_marker = "LEADER_SHADOW_DIRECT_E2E"
            shadow_before = len(c.team_task_list(team))
            sent = c.team_leader_send(
                team,
                f"This is a trivial one-step request. Final response must contain {shadow_marker}. "
                "Before work run tm-agent leader turn route --route direct --task-shape "
                "parallelizable --available-workers 1 --wave-id shadow-leader-work. "
                "If directive is null, do not delegate. Run hostname and pwd yourself, "
                "verify them, synthesize the result, and complete this durable request.",
                shadow_id, task_shape="parallelizable",
            )
            if not sent.get("wake_dispatched"):
                raise termmeshError(f"leader request wake was not dispatched: {sent!r}")
            shadow = wait_request(c, team, shadow_id, shadow_marker, shadow_before)
            if len(shadow["tasks"]) != shadow_before:
                raise termmeshError(f"Shadow direct request unexpectedly delegated: {shadow['tasks']!r}")
            shadow_route = _wait(lambda: next((
                row for row in route_records(host, team)
                if row.get("wave_id") == shadow_id
            ), None), timeout_s=30)
            if not shadow_route or shadow_route.get("policy_mode") != "shadow" \
               or shadow_route.get("policy_applied"):
                raise termmeshError(f"Shadow route was not observable: {shadow_route!r}")

            c.debug_leader_participation_configure("canary", 100, [team])
            team_uuid = str(ready.get("team_uuid") or "")
            canary_control = _wait(lambda: (
                payload if team_uuid and (payload := _remote_participation_control(host, team_uuid))
                and payload.get("mode") == "canary"
                and payload.get("percent") == 100 else None
            ), timeout_s=30)
            if canary_control is None:
                raise termmeshError("Canary controls did not reach the remote leader")
            canary_id = "canary-leader-work"
            canary_wave = f"canary-leader-wave-{uuid.uuid4().hex[:8]}"
            canary_marker = "LEADER_CANARY_PARALLEL_E2E"
            canary_before = len(c.team_task_list(team))
            sent = c.team_leader_send(
                team,
                f"Perform a real parallel delegation test and include {canary_marker} in the final response. "
                f"First run exactly: tm-agent leader turn route --route parallel --task-shape multi_unit "
                f"--available-workers 2 --wave-id {canary_wave}. Read the JSON and follow its directive. "
                f"Then delegate exactly two independent read-only tasks, one to executor and one to reviewer, "
                f"with --route parallel --wave-id {canary_wave}. Each task must run hostname and pwd. "
                "Wait for both task ids, verify both completed, and synthesize their outputs. Do not do the "
                f"worker tasks yourself. Complete durable request {canary_id} before replying.",
                canary_id, task_shape="multi_unit",
            )
            if not sent.get("wake_dispatched"):
                raise termmeshError(f"Canary leader wake was not dispatched: {sent!r}")
            canary = wait_request(c, team, canary_id, canary_marker, canary_before + 2)
            wave_tasks = [task for task in canary["tasks"] if task.get("wave_id") == canary_wave]
            worker_done = [
                task for task in wave_tasks
                if task.get("status") == "completed"
                or (
                    task.get("status") == "review_ready"
                    and "STATUS: DONE" in str(task.get("result") or "")
                )
            ]
            if len(wave_tasks) != 2 or len(worker_done) != 2:
                raise termmeshError(
                    f"Canary did not produce two durable worker results: {wave_tasks!r}"
                )
            canary_route = _wait(lambda: next((
                row for row in route_records(host, team)
                if row.get("wave_id") == canary_wave
            ), None), timeout_s=30)
            if not canary_route or canary_route.get("policy_mode") != "canary" \
               or not canary_route.get("policy_applied") \
               or canary_route.get("suggested_route") != "parallel" \
               or canary_route.get("actual_route") != "parallel":
                raise termmeshError(f"Canary parallel route was not applied: {canary_route!r}")
            print(json.dumps({
                "canary_route": canary_route,
                "delegated_task_count": len(wave_tasks),
                "worker_result_count": len(worker_done),
                "delegation_completion_ratio": len(worker_done) / len(wave_tasks),
            }, sort_keys=True))

        finally:
            deletion = c.debug_project_delete(team)
            if operation := str(deletion.get("operation_id") or ""):
                _wait_for_project_deletion(c, operation, timeout_s=90)
            restore_health_history(host, health_backup)

    print("PASS: remote leader completes Shadow and Canary requests with verified delegation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
