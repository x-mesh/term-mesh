#!/usr/bin/env python3
"""A duplicate team.delegate request replays its active task instead of reporting busy."""

from __future__ import annotations

import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


TEAM_NAME = f"test-delegate-replay-{uuid.uuid4().hex[:8]}"
AGENT_NAME = "worker"
REQUEST_ID = f"delegate-replay-{uuid.uuid4()}"
TERMINAL_STATUSES = {"completed", "failed", "cancelled", "abandoned"}


def _tasks(c: "termmesh") -> list[dict]:
    result = c._call("team.task.list", {"team_name": TEAM_NAME})
    tasks = result.get("tasks")
    if not isinstance(tasks, list):
        raise termmeshError(f"team.task.list returned invalid tasks: {result!r}")
    return tasks


def main() -> int:
    with termmesh() as c:
        c._call("team.create", {
            "team_name": TEAM_NAME,
            "leader_mode": "repl",
            "skip_runbook_init_prompt": True,
            "agents": [{
                "name": AGENT_NAME,
                "cli": "claude",
                "model": "sonnet",
                "agent_type": "worker",
                "color": "green",
            }],
        })

        try:
            request = {
                "team": TEAM_NAME,
                "agent": AGENT_NAME,
                "text": "Keep this task active while its request is replayed.",
                "task_title": "active delegate replay probe",
                "request_id": REQUEST_ID,
            }

            first = c._call("team.delegate", request)
            first_task = first.get("task") or {}
            first_task_id = first_task.get("id")
            if not first_task_id:
                raise termmeshError(f"first delegate returned no task id: {first!r}")
            if first.get("request_replayed") is not False:
                raise termmeshError(
                    f"first delegate unexpectedly reported replay: {first!r}"
                )

            active_tasks = _tasks(c)
            if len(active_tasks) != 1:
                raise termmeshError(
                    f"expected one task after first delegate, got {len(active_tasks)}: "
                    f"{active_tasks!r}"
                )
            if active_tasks[0].get("id") != first_task_id:
                raise termmeshError(
                    f"task list id differs from delegate id: "
                    f"{active_tasks[0].get('id')!r} != {first_task_id!r}"
                )
            if active_tasks[0].get("status") in TERMINAL_STATUSES:
                raise termmeshError(
                    f"first task was not left active: {active_tasks[0]!r}"
                )

            # Replay while the first task still occupies the only worker. The
            # regression returned agent_busy/allInstancesBusy before reaching
            # request_id deduplication.
            replay = c._call("team.delegate", request)
            replay_task = replay.get("task") or {}
            if replay.get("request_replayed") is not True:
                raise termmeshError(
                    f"duplicate request was not acknowledged as replay: {replay!r}"
                )
            if replay_task.get("id") != first_task_id:
                raise termmeshError(
                    f"duplicate request returned a different task: "
                    f"{replay_task.get('id')!r} != {first_task_id!r}"
                )

            final_tasks = _tasks(c)
            if len(final_tasks) != 1 or final_tasks[0].get("id") != first_task_id:
                raise termmeshError(
                    f"duplicate request created another task: {final_tasks!r}"
                )
        finally:
            try:
                c._call("team.destroy", {"team_name": TEAM_NAME})
            except Exception:
                pass

    print("PASS: duplicate team.delegate request replays one active task")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
