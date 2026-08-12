#!/usr/bin/env python3
"""A remote project leader reaches the Claude UI instead of zsh's `# >` prompt.

Requires a saved, reachable peer host and a directory containing the project:

    TERMMESH_E2E_REMOTE_LEADER_HOST=ssh:root@peer \
    TERMMESH_E2E_REMOTE_LEADER_DIR=/srv/project \
    python3 tests_v2/test_remote_leader_launch.py

Regression: the login-shell environment prelude made the leader launch exceed
Linux's canonical PTY line limit. zsh received a truncated quote, displayed
`# >`, while the app incorrectly marked the leader ready.
"""
from __future__ import annotations

import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


HOST_ENV = "TERMMESH_E2E_REMOTE_LEADER_HOST"
DIR_ENV = "TERMMESH_E2E_REMOTE_LEADER_DIR"


def _wait(predicate, timeout_s: float = 45.0, interval_s: float = 0.2):
    deadline = time.time() + timeout_s
    last = None
    while time.time() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except termmeshError as exc:
            last = exc
        time.sleep(interval_s)
    if last:
        raise last
    return None


def main() -> int:
    host = os.environ.get(HOST_ENV, "").strip()
    remote_dir = os.environ.get(DIR_ENV, "").strip()
    if not host or not remote_dir:
        print(f"SKIP: set {HOST_ENV} and {DIR_ENV} for remote leader e2e")
        return 0

    team_name = f"remote-leader-e2e-{uuid.uuid4().hex[:8]}"
    local_directory = f"/tmp/{team_name}"

    with termmesh() as c:
        hosts = c.peer_host_list()
        row = next((item for item in hosts if item.get("id") == host), None)
        if row is None:
            raise termmeshError(f"saved peer host not found: {host!r}")
        if row.get("state") != "connected":
            c.peer_host_connect(host)
            row = _wait(
                lambda: next(
                    (item for item in c.peer_host_list()
                     if item.get("id") == host and item.get("state") == "connected"),
                    None,
                ),
                timeout_s=20,
            )
            if row is None:
                raise termmeshError(f"peer host did not connect: {host!r}")

        created = c.debug_project_create(
            directory=local_directory,
            roles=[],
            leader_cli="claude",
            leader_model="sonnet",
            leader_host=host,
            leader_directory=remote_dir,
        )
        if created.get("team") != team_name:
            raise termmeshError(f"remote project was not created: {created!r}")

        try:
            def ready_team():
                team = next(
                    (item for item in c.team_list() if item.get("team_name") == team_name),
                    None,
                )
                if team and team.get("leader_failure"):
                    raise termmeshError(f"remote leader failed: {team['leader_failure']}")
                if team and team.get("leader_ready") and team.get("leader_panel_id"):
                    return team
                return None

            team = _wait(ready_team, timeout_s=45)
            if team is None:
                raise termmeshError("remote leader never became ready")

            panel_id = team["leader_panel_id"]
            text = _wait(
                lambda: (screen if "Claude Code" in (screen := c.read_terminal_text(panel_id)) else None),
                timeout_s=25,
            )
            if text is None:
                text = c.read_terminal_text(panel_id)
                raise termmeshError(f"remote leader never rendered Claude Code:\n{text}")
            if "# >" in text:
                raise termmeshError(f"remote leader is stuck at zsh continuation prompt:\n{text}")
        finally:
            c.team_destroy(team_name)

    print("PASS: remote leader launch reaches Claude Code without a PTY continuation prompt")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
