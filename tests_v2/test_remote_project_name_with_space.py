#!/usr/bin/env python3
"""A remote project whose name the wire grammar cannot spell still starts.

Requires a saved, reachable peer host and a directory on it:

    TERMMESH_E2E_REMOTE_LEADER_HOST=ssh:peer-host \
    TERMMESH_E2E_REMOTE_LEADER_DIR=/srv/project \
    python3 tests_v2/test_remote_project_name_with_space.py

Regression: the leader grant carried `name:<team>` verbatim, so New Project's
own duplicate suffix ("<repo> 2") — and every non-ASCII name — failed
`validateBootstrap` with `invalid_project`. The leader and all four workers
then reported the generic "could not open the remote pane", pointing every
diagnosis at the peer host, which was healthy the whole time.
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

# The exact shape New Project produces for a second project of the same repo.
UNSPELLABLE_SUFFIX = " 2"

# The exact symptom a rejected grant produced, on every leader and worker.
PANE_FAILURE = "could not open the remote pane"


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
        print(f"SKIP: set {HOST_ENV} and {DIR_ENV} for remote project name e2e")
        return 0

    team_name = f"grant-space-e2e-{uuid.uuid4().hex[:8]}{UNSPELLABLE_SUFFIX}"
    if " " not in team_name:
        raise termmeshError("test lost the character it exists to cover")
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

        # What this test gates on, and why:
        #
        # NOT `leader_panel_id` on its own: New Project installs a placeholder
        # anchor pane before the remote attach runs, so that id exists even
        # when the grant is about to be rejected — gating on it alone passed
        # against a deliberately unfixed build.
        #
        # A granted leader ends up with all three: no pane failure, a started
        # relay (`leader_ready`), and its CLI drawn in the pane. A rejected one
        # reaches none of them and carries PANE_FAILURE within ~2s.
        try:
            def verdict():
                team = next(
                    (item for item in c.team_list()
                     if item.get("team_name") == team_name),
                    None,
                )
                if not team:
                    return None
                if PANE_FAILURE in str(team.get("leader_failure") or ""):
                    return ("rejected", team, "")
                panel_id = team.get("leader_panel_id")
                if not panel_id or not team.get("leader_ready"):
                    return None
                try:
                    screen = c.read_terminal_text(panel_id)
                except termmeshError:
                    return None
                if "Claude Code" in screen:
                    return ("launched", team, screen)
                return None

            outcome = _wait(verdict, timeout_s=120)
            if outcome is None:
                last = next(
                    (item for item in c.team_list()
                     if item.get("team_name") == team_name),
                    None,
                )
                screen = ""
                if last and last.get("leader_panel_id"):
                    try:
                        screen = c.read_terminal_text(last["leader_panel_id"])
                    except termmeshError:
                        screen = "<unreadable>"
                raise termmeshError(
                    f"remote leader never launched its CLI; team={last!r}\nscreen:\n{screen}"
                )

            state, team, _screen = outcome
            if state == "rejected":
                raise termmeshError(
                    "leader grant still rejects an unspellable project name: "
                    f"{team.get('leader_failure')!r}"
                )
        finally:
            c.team_destroy(team_name)

    print("PASS: a remote project named with a space reaches a leader pane")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
