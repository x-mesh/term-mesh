#!/usr/bin/env python3
"""Verify that team.restart(mode=hard) replaces the agent panel_id with a new pane.

Regression guard: after recycle GUI + serialized bulk recycle changes, hard restart
must produce a distinct panel_id so the scheduler resolves the refreshed pane.
NOTE: GUI-only behaviors (NSAlert active-task guard, sidebar context menu) are not
tested here — only the socket-observable panel_id swap is verified.
"""

from __future__ import annotations

import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

TEAM_NAME = f"test-recycle-panel-{uuid.uuid4().hex[:8]}"
TIMEOUT_S = 10.0
POLL_S = 0.1


def _agent_panel_id(c: "termmesh", team: str, agent: str) -> str | None:
    """Return the panel_id of a named agent, or None if not found / headless."""
    resp = c._call("team.status", {"team_name": team})
    for a in resp.get("agents", []):
        if a.get("name") == agent:
            return a.get("panel_id")  # None for headless agents
    return None


def main() -> int:
    with termmesh() as c:
        # arrange: create a pane-mode team with one agent (REPL leader → no CLI required)
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
            panel_before = _agent_panel_id(c, TEAM_NAME, "worker")
            if not panel_before:
                raise termmeshError(
                    "agent 'worker' has no panel_id before restart — "
                    "pane-mode team required (headless agents never have panel_ids)"
                )

            # act: hard restart via team.restart
            c._call("team.restart", {
                "team_name": TEAM_NAME,
                "agent_name": "worker",
                "mode": "hard",
            })

            # assert: poll until panel_id changes (hard restart spawns a new pane)
            deadline = time.monotonic() + TIMEOUT_S
            panel_after = panel_before
            while time.monotonic() < deadline:
                panel_after = _agent_panel_id(c, TEAM_NAME, "worker")
                if panel_after and panel_after != panel_before:
                    break
                time.sleep(POLL_S)

            if panel_after == panel_before:
                raise termmeshError(
                    f"panel_id did not change after hard restart "
                    f"(before={panel_before!r}, after={panel_after!r})"
                )

        finally:
            try:
                c._call("team.destroy", {"team_name": TEAM_NAME})
            except Exception:
                pass

    print("PASS: team.restart(mode=hard) replaces agent panel_id with a new pane")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
