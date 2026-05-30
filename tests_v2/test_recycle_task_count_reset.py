#!/usr/bin/env python3
"""Verify that team.restart(mode=hard) resets completed_task_count to 0.

Regression guard: completedTaskCount reset was added in this session (GUI + headless
parity). Without the fix, the auto-recycle threshold could fire again immediately
after a restart because the counter was not cleared.
NOTE: auto-recycle trigger (recycleAgent/handleTaskCompletionForAutoRecycle) and
NSAlert guard are GUI-only; only the socket-observable counter reset is verified here.
"""

from __future__ import annotations

import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

TEAM_NAME = f"test-recycle-count-{uuid.uuid4().hex[:8]}"
TIMEOUT_S = 10.0
POLL_S = 0.1


def _agent_count(c: "termmesh", team: str, agent: str) -> int | None:
    """Return completed_task_count for a named agent, or None if not present."""
    resp = c._call("team.status", {"team_name": team})
    for a in resp.get("agents", []):
        if a.get("name") == agent:
            v = a.get("completed_task_count")
            return int(v) if v is not None else None
    return None


def _poll_until(predicate, timeout_s: float, interval_s: float):
    """Call predicate() repeatedly until it returns a truthy value or timeout."""
    deadline = time.monotonic() + timeout_s
    result = None
    while time.monotonic() < deadline:
        result = predicate()
        if result is not None and result is not False:
            return result
        time.sleep(interval_s)
    return result


def main() -> int:
    with termmesh() as c:
        # arrange: create a pane-mode team with one agent
        c._call("team.create", {
            "team_name": TEAM_NAME,
            "leader_mode": "repl",
            "agents": [{
                "name": "worker",
                "cli": "claude",
                "model": "sonnet",
                "agent_type": "worker",
                "color": "green",
            }],
        })

        try:
            # confirm initial count is 0
            count_init = _agent_count(c, TEAM_NAME, "worker")
            if count_init != 0:
                raise termmeshError(
                    f"expected completed_task_count=0 initially, got {count_init!r}"
                )

            # Create a task assigned to the agent and transition it to 'completed'
            # so handleTaskCompletionForAutoRecycle fires and increments the counter.
            task_resp = c._call("team.task.create", {
                "team_name": TEAM_NAME,
                "title": "e2e-recycle-count-probe",
                "assign": "worker",
            })
            task_id = task_resp.get("id")
            if not task_id:
                raise termmeshError(
                    f"team.task.create did not return an 'id'; got keys: {list(task_resp.keys())}"
                )

            # Start then complete the task (completion triggers counter increment)
            c._call("team.task.update", {
                "team_name": TEAM_NAME,
                "task_id": task_id,
                "status": "in_progress",
            })
            c._call("team.task.update", {
                "team_name": TEAM_NAME,
                "task_id": task_id,
                "status": "completed",
            })

            # Poll until counter reaches ≥ 1 (increment is async on @MainActor)
            def count_incremented():
                v = _agent_count(c, TEAM_NAME, "worker")
                return v if (v is not None and v >= 1) else False

            count_after_task = _poll_until(count_incremented, TIMEOUT_S, POLL_S)
            if not count_after_task:
                raise termmeshError(
                    f"completed_task_count did not increment after task completion "
                    f"(got {_agent_count(c, TEAM_NAME, 'worker')!r})"
                )

            # act: hard restart resets the counter (recycle path)
            c._call("team.restart", {
                "team_name": TEAM_NAME,
                "agent_name": "worker",
                "mode": "hard",
            })

            # assert: poll until completed_task_count resets to 0
            def count_reset():
                v = _agent_count(c, TEAM_NAME, "worker")
                return True if v == 0 else False

            reset_ok = _poll_until(count_reset, TIMEOUT_S, POLL_S)
            final_count = _agent_count(c, TEAM_NAME, "worker")
            if final_count != 0:
                raise termmeshError(
                    f"completed_task_count not reset after hard restart "
                    f"(expected 0, got {final_count!r})"
                )

        finally:
            try:
                c._call("team.destroy", {"team_name": TEAM_NAME})
            except Exception:
                pass

    print("PASS: team.restart(mode=hard) resets agent completed_task_count to 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
