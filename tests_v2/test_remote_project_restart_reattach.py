#!/usr/bin/env python3
"""A daemon-owned remote Project survives app restart and reattaches exact surfaces."""
from __future__ import annotations

import json
import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


HOST_ENV = "TERMMESH_E2E_REMOTE_LEADER_HOST"
DIR_ENV = "TERMMESH_E2E_REMOTE_LEADER_DIR"
PHASE_ENV = "TERMMESH_E2E_REATTACH_PHASE"
STATE_ENV = "TERMMESH_E2E_REATTACH_STATE"


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


def _connect(c, host: str) -> None:
    row = next((item for item in c.peer_host_list() if item.get("id") == host), None)
    if row is None:
        raise termmeshError(f"saved peer host not found: {host!r}")
    if row.get("state") != "connected" or not row.get("launchable"):
        c.peer_host_connect(host)
        row = _wait(lambda: next((item for item in c.peer_host_list()
                                 if item.get("id") == host
                                 and item.get("state") == "connected"
                                 and item.get("launchable")), None),
                    timeout_s=25)
        if row is None:
            raise termmeshError(f"peer host did not become launchable: {host!r}")


def _phase_create(c, host: str, remote_dir: str, state_path: Path) -> None:
    team_name = f"remote-reattach-e2e-{uuid.uuid4().hex[:8]}"
    created = c.debug_project_create(
        directory=f"/tmp/{team_name}",
        roles=[],
        leader_cli="claude",
        leader_model="sonnet",
        leader_host=host,
        leader_directory=remote_dir,
    )
    if created.get("team") != team_name:
        raise termmeshError(f"remote project was not created: {created!r}")

    def ready_team():
        team = next((item for item in c.team_list() if item.get("team_name") == team_name), None)
        if team and team.get("leader_failure"):
            raise termmeshError(f"remote leader failed: {team['leader_failure']}")
        return team if team and team.get("leader_ready") and team.get("leader_panel_id") else None

    team = _wait(ready_team)
    if team is None:
        raise termmeshError("remote leader never became ready")
    project = _wait(lambda: next((item for item in c.debug_project_remote_presentations(host)
                                  if item.get("name") == team_name
                                  and item.get("project_id")
                                  and item.get("leader_surface_id")), None))
    if project is None:
        raise termmeshError("remote project manifest was not published")
    state_path.write_text(json.dumps({
        "team_name": team_name,
        "project_id": project["project_id"],
        "leader_surface_id": project["leader_surface_id"],
    }))


def _phase_adopt(c, host: str, state_path: Path) -> None:
    state = json.loads(state_path.read_text())
    team_name = state["team_name"]
    project = _wait(lambda: next((item for item in c.debug_project_remote_presentations(host)
                                  if item.get("project_id") == state["project_id"]), None))
    if project is None:
        raise termmeshError("remote project manifest did not survive app restart")
    if project.get("leader_surface_id") != state["leader_surface_id"]:
        raise termmeshError(f"leader surface changed across restart: {project!r}")

    adopted = c.debug_project_adopt_remote(host, state["project_id"])
    if adopted.get("leader_surface_id") != state["leader_surface_id"]:
        raise termmeshError(f"adopt selected a different leader surface: {adopted!r}")
    team = _wait(lambda: next((item for item in c.team_list()
                               if item.get("team_name") == team_name
                               and item.get("leader_pane_attached")
                               and item.get("leader_panel_id")), None))
    if team is None:
        raise termmeshError("remote Project did not reattach after app restart")
    c.debug_project_delete(team_name)
    if _wait(lambda: not any(item.get("project_id") == state["project_id"]
                             for item in c.debug_project_remote_presentations(host))):
        state_path.unlink(missing_ok=True)
        return
    raise termmeshError("remote Project manifest was not deleted after verification")


def main() -> int:
    host = os.environ.get(HOST_ENV, "").strip()
    remote_dir = os.environ.get(DIR_ENV, "").strip()
    phase = os.environ.get(PHASE_ENV, "").strip()
    state_path = Path(os.environ.get(STATE_ENV, "/tmp/term-mesh-remote-project-e2e-state.json"))
    if not host or not remote_dir or phase not in {"create", "adopt"}:
        print(f"SKIP: set {HOST_ENV}, {DIR_ENV}, and {PHASE_ENV}=create|adopt")
        return 0

    with termmesh() as c:
        _connect(c, host)
        if phase == "create":
            _phase_create(c, host, remote_dir, state_path)
        else:
            _phase_adopt(c, host, state_path)
    print(f"PASS: remote Project restart reattach phase {phase}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
