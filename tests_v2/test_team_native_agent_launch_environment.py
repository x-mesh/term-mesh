#!/usr/bin/env python3
"""A native agent pane is launched carrying its own team identity.

Regression: worker panes were started with the app's own environment, which
holds no `TERMMESH_*`, so `tm-agent` inside the pane resolved no team and fell
through to `live-team` -- a team that exists nowhere. Every agent-to-agent
call then failed with `Agent 'x' not found in team 'live-team'`, and the same
omission dropped `PATH`, so `tm-agent` was not even on it. Leader panes were
built by a different path and never showed the symptom.

Both ends of that wiring were already unit-tested (`buildAgentPaneEnv` builds
the identity; `AgentSession.Launch` carries an environment). What broke was
the join between them, which nothing outside the process could observe -- so
this asserts it through `debug.team.agent_launch_env`.
"""

from __future__ import annotations

import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


TEAM_NAME = f"test-native-env-{uuid.uuid4().hex[:8]}"
AGENT_NAME = "worker"


def main() -> int:
    with termmesh() as c:
        c.team_create(TEAM_NAME, [{
            "name": AGENT_NAME,
            "cli": "claude",
            "model": "sonnet",
            "agent_type": "worker",
            "color": "green",
        }])

        try:
            probe = c.team_agent_launch_env(TEAM_NAME, AGENT_NAME)
            identity = probe.get("identity")
            if not isinstance(identity, dict):
                raise termmeshError(
                    "debug.team.agent_launch_env returned no identity "
                    f"(native agent panes must be enabled): {probe!r}"
                )

            team = identity.get("TERMMESH_TEAM_NAME")
            if team != TEAM_NAME:
                raise termmeshError(
                    f"pane launched with the wrong team: expected {TEAM_NAME!r}, got {team!r}"
                )

            # `TERMMESH_TEAM` is what tm-agent reads first; without it the CLI
            # walks its fallback chain and lands on `live-team`.
            if identity.get("TERMMESH_TEAM") != TEAM_NAME:
                raise termmeshError(
                    "pane is missing TERMMESH_TEAM, so tm-agent inside it would "
                    f"fall back to live-team: {identity!r}"
                )

            if identity.get("TERMMESH_TEAM_AGENT") != "1":
                raise termmeshError(f"pane is not marked as a team agent: {identity!r}")

            if not identity.get("TERMMESH_AGENT_INSTANCE_ID"):
                raise termmeshError(
                    f"pane carries no agent instance id, so replies cannot be "
                    f"attributed to it: {identity!r}"
                )

            if probe.get("path_present") is not True:
                raise termmeshError(
                    f"pane launched without PATH, so tm-agent is not reachable "
                    f"from inside it: {probe!r}"
                )
        finally:
            c.team_destroy(TEAM_NAME)

    print("PASS: native agent panes launch with their team identity and PATH")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
