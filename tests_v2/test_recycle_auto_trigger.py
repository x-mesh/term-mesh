#!/usr/bin/env python3
"""Verify that count-based auto-recycle triggers a pane restart without manual team.restart.

Regression guard: handleTaskCompletionForAutoRecycle fires recycleAgent(force:false)
when completedTaskCount % autoRecycleEvery == 0. This test proves the full end-to-end
path from task.update(completed) → auto-recycle → panel_id change, with NO explicit
team.restart call.

NOTE: This tests the GUI pane path (handleTaskCompletionForAutoRecycle →
recycleAgent → restartAgentPaneHard). Headless auto-recycle (socket.rs) is a
separate daemon-side path not tested here.
"""

from __future__ import annotations

import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

TEAM_NAME = f"test-auto-recycle-{uuid.uuid4().hex[:8]}"
# Use threshold=1 so every completed task triggers a recycle.
RECYCLE_EVERY = 1
TIMEOUT_S = 15.0
POLL_S = 0.1


def _agent_info(c: "termmesh", team: str, agent: str) -> dict:
    """Return agent dict from team.status, or {} if not found."""
    resp = c._call("team.status", {"team_name": team})
    for a in resp.get("agents", []):
        if a.get("name") == agent:
            return a
    return {}


def main() -> int:
    with termmesh() as c:
        # arrange: create team with default_auto_recycle_every=1
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
            # Set auto-recycle threshold to 1 — recycles on every task completion.
            "default_auto_recycle_every": RECYCLE_EVERY,
        })

        try:
            # Confirm auto_recycle is set by checking team status
            info_before = _agent_info(c, TEAM_NAME, "worker")
            panel_before = info_before.get("panel_id")
            count_before = info_before.get("completed_task_count", 0)

            if not panel_before:
                raise termmeshError(
                    "worker agent has no panel_id — pane-mode team required for auto-recycle GUI path"
                )

            # act: create a task and complete it — NO manual team.restart
            task = c._call("team.task.create", {
                "team_name": TEAM_NAME,
                "title": "auto-recycle-probe-task",
                "assign": "worker",
            })
            task_id = task.get("id")
            if not task_id:
                raise termmeshError(f"team.task.create did not return 'id'; got: {list(task.keys())}")

            # Start → complete to trigger handleTaskCompletionForAutoRecycle
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

            # assert: poll until panel_id changes WITHOUT any manual team.restart call.
            # handleTaskCompletionForAutoRecycle fires async on @MainActor, then
            # restartAgentPaneHard spawns a new pane and updates the team struct.
            deadline = time.monotonic() + TIMEOUT_S
            panel_after = panel_before
            count_after = count_before
            while time.monotonic() < deadline:
                info = _agent_info(c, TEAM_NAME, "worker")
                panel_after = info.get("panel_id", panel_before)
                count_after = info.get("completed_task_count", count_before)
                if panel_after and panel_after != panel_before:
                    break
                time.sleep(POLL_S)

            if panel_after == panel_before:
                raise termmeshError(
                    f"auto-recycle did NOT fire after task completion "
                    f"(panel_id unchanged: {panel_before!r}, "
                    f"completed_task_count={count_after!r}, threshold={RECYCLE_EVERY}). "
                    f"Check: default_auto_recycle_every accepted? task assignee matches agent name?"
                )

            # count should be reset to 0 after auto-recycle (recycleAgent → restartAgentPaneHard
            # → completedTaskCount = 0 via the success path fix).
            if count_after != 0:
                raise termmeshError(
                    f"panel_id changed (auto-recycle fired) but completed_task_count "
                    f"was not reset (got {count_after!r}, expected 0)"
                )

        finally:
            try:
                c._call("team.destroy", {"team_name": TEAM_NAME})
            except Exception:
                pass

    print(
        "PASS: count-based auto-recycle fires automatically after task completion "
        f"(threshold={RECYCLE_EVERY}) and resets completed_task_count to 0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
