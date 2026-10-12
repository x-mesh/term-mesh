#!/usr/bin/env python3
"""A correction is stored before an unblocked task is dispatched again."""

from __future__ import annotations

import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


TEAM_NAME = f"test-unblock-correction-{uuid.uuid4().hex[:8]}"
CORRECTION = f"CORRECTION-{uuid.uuid4()}"


def wait_for_correction(client: termmesh, timeout: float = 20.0) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        transcript = client._call("team.read", {
            "team_name": TEAM_NAME,
            "agent_name": "worker",
            "lines": 200,
        })
        text = transcript.get("text", "")
        if CORRECTION in text:
            return text
        time.sleep(0.25)
    raise termmeshError("corrected task dispatch did not reach the worker transcript")


def main() -> int:
    with termmesh() as client:
        client.team_create(TEAM_NAME, [{
            "name": "worker",
            "cli": "claude",
            "model": "sonnet",
            "agent_type": "worker",
            "color": "green",
        }])
        try:
            created = client._call("team.task.create", {
                "team_name": TEAM_NAME,
                "title": "unblock correction",
                "description": "old instruction",
                "assignee": "worker",
            })
            task_id = created.get("id")
            if not task_id:
                raise termmeshError(f"task creation returned no id: {created!r}")
            client._call("team.task.update", {
                "team_name": TEAM_NAME,
                "task_id": task_id,
                "status": "blocked",
                "blocked_reason": "needs correction",
            })

            resumed = client._call("team.task.unblock", {
                "team_name": TEAM_NAME,
                "task_id": task_id,
                "correction": CORRECTION,
            })
            task = resumed.get("task") or {}
            if task.get("description") != CORRECTION:
                raise termmeshError(
                    f"unblock returned stale details: {task.get('description')!r}"
                )
            if task.get("status") != "assigned" or task.get("blocked_reason") is not None:
                raise termmeshError(f"task did not resume cleanly: {task!r}")

            fetched = client._call("team.task.get", {
                "team_name": TEAM_NAME, "task_id": task_id,
            })
            if fetched.get("description") != CORRECTION:
                raise termmeshError(f"correction was not persisted: {fetched!r}")
            try:
                client._call("team.task.unblock", {
                    "team_name": TEAM_NAME,
                    "task_id": task_id,
                    "correction": ["not", "a", "string"],
                })
            except termmeshError as exc:
                if "invalid_params" not in str(exc):
                    raise
            else:
                raise termmeshError("non-string correction was accepted")
            transcript = wait_for_correction(client)
            if transcript.count(CORRECTION) != 1:
                raise termmeshError(
                    f"expected one corrected dispatch, got {transcript.count(CORRECTION)}: "
                    f"{transcript!r}"
                )
            if "old instruction" in transcript:
                raise termmeshError(f"stale instruction was dispatched: {transcript!r}")
        finally:
            client.team_destroy(TEAM_NAME)

    print("PASS: team.task.unblock persists correction before resumed dispatch")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
