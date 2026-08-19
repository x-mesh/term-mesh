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
ROLES_ENV = "TERMMESH_E2E_REATTACH_ROLES"


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


def _hold(check, until, timeout_s: float = 20.0, interval_s: float = 0.2) -> bool:
    """Keep asserting `check` until `until` is observed, then assert it once more.

    `check` raises on violation, so an invariant that only holds because the
    asynchronous work has not started yet cannot pass unnoticed.
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        check()
        if until():
            # Re-assert after the completion is observed: the check above ran
            # before it, so a mutation landing in between would go unseen.
            check()
            return True
        time.sleep(interval_s)
    check()
    return bool(until())


_SHARED_DEBUG_LOGS = (
    "/tmp/cmux-debug-com.termmesh.app.debug.log",
    "/tmp/term-mesh-debug.log",
    "/tmp/cmux-debug.log",
)


def _debug_log_candidates() -> list[Path]:
    """Paths the DEBUG build can resolve its event log to (bonsplit DebugEventLog).

    Resolution is tiered and returns the first tier that exists, never a union,
    so a run-specific log is never watched alongside anything else:

    1. `TERMMESH_DEBUG_LOG`, this process's own environment;
    2. the log named by this process's socket stem;
    3. untrusted — the `/tmp/term-mesh-last-debug-log-path` pointer and the
       shared logs, collapsed to the single most recently written path.

    Only the first two tiers identify the instance under test. The pointer does
    not: `scripts/reload.sh` is its only writer and it holds whichever DEBUG
    build ran last, so a leftover from an earlier session would otherwise
    outrank the socket this test is actually driving and answer `grew()` /
    `contains()` for a foreign app.
    """
    env_log = os.environ.get("TERMMESH_DEBUG_LOG", "").strip()
    if env_log and Path(env_log).exists():
        return [Path(env_log)]

    socket_derived: list[Path] = []
    for key in ("TERMMESH_SOCKET_PATH", "TERMMESH_SOCKET"):
        socket_path = os.environ.get(key, "").strip()
        if not socket_path:
            continue
        stem = Path(socket_path).stem
        if not (stem.startswith("term-mesh-debug-") or stem.startswith("cmux-debug-")):
            continue
        path = Path(f"/tmp/{stem}.log")
        if path not in socket_derived and path.exists():
            socket_derived.append(path)
    if socket_derived:
        return socket_derived

    untrusted = list(_SHARED_DEBUG_LOGS)
    try:
        pointer = Path("/tmp/term-mesh-last-debug-log-path").read_text().strip()
    except OSError:
        pointer = ""
    if pointer:
        untrusted.insert(0, pointer)

    newest: tuple[float, Path] | None = None
    for candidate in untrusted:
        path = Path(candidate)
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        if newest is None or mtime > newest[0]:
            newest = (mtime, path)
    return [] if newest is None else [newest[1]]


class _DebugLogTail:
    """Follows the app debug log from a baseline offset.

    A debug RPC that only acknowledges scheduling gives the test no way to tell
    "the async attempt failed as required" from "the async attempt has not run
    yet". The app logs the completed attempt, so tailing the log turns that into
    positive evidence.

    Construction fails when no log resolves. Without one there is no evidence to
    wait for, and a run that quietly falls back to a settle window reads exactly
    like a verified one. Resolution gets a short bounded retry first, so a log
    the app has named but not yet written is waited for rather than reported as
    a missing one.
    """

    def __init__(self, resolve_timeout_s: float = 5.0, interval_s: float = 0.2) -> None:
        self._baselines: dict[Path, int] = {}
        deadline = time.time() + resolve_timeout_s
        while True:
            for path in _debug_log_candidates():
                try:
                    self._baselines[path] = path.stat().st_size
                except OSError:
                    continue
            if self._baselines or time.time() >= deadline:
                break
            time.sleep(interval_s)
        if not self._baselines:
            raise termmeshError(
                "no app debug log resolved; set TERMMESH_DEBUG_LOG or run against a "
                "DEBUG build that writes /tmp/term-mesh-last-debug-log-path"
            )

    def _tail_text(self, path: Path, baseline: int) -> str:
        try:
            size = path.stat().st_size
        except OSError:
            return ""
        # A rotated log is shorter than the baseline; re-read it from the top.
        start = baseline if size >= baseline else 0
        try:
            with path.open("rb") as handle:
                handle.seek(start)
                return handle.read().decode("utf-8", "replace")
        except OSError:
            return ""

    def grew(self) -> bool:
        """True once a watched log advanced, i.e. this really is the live log."""
        return any(self._tail_text(path, baseline)
                   for path, baseline in self._baselines.items())

    def contains(self, marker: str) -> bool:
        return any(marker in self._tail_text(path, baseline)
                   for path, baseline in self._baselines.items())


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
    roles = [
        role.strip()
        for role in os.environ.get(ROLES_ENV, "executor,reviewer").split(",")
        if role.strip()
    ]
    if not roles:
        raise termmeshError(
            f"{ROLES_ENV} must name at least one worker; a leader-only Project "
            "cannot verify member persistence"
        )
    created = c.debug_project_create(
        directory=f"/tmp/{team_name}",
        roles=roles,
        leader_cli="claude",
        leader_model="sonnet",
        leader_host=host,
        leader_directory=remote_dir,
        remote_host=host,
        remote_path=remote_dir,
    )
    if created.get("team") != team_name:
        raise termmeshError(f"remote project was not created: {created!r}")
    checkouts = created.get("checkouts")
    if not isinstance(checkouts, list) or len(checkouts) != len(roles):
        raise termmeshError(
            "remote project bootstrap did not preserve the requested workers: "
            f"roles={roles!r} created={created!r}"
        )

    def ready_team():
        team = next((item for item in c.team_list() if item.get("team_name") == team_name), None)
        if team and team.get("leader_failure"):
            raise termmeshError(f"remote leader failed: {team['leader_failure']}")
        agents = team.get("agents") if team else None
        agents_ready = (
            isinstance(agents, list)
            and len(agents) == len(roles)
            and all(agent.get("panel_id") and agent.get("agent_instance_id") for agent in agents)
        )
        return (
            team
            if team and team.get("leader_ready") and team.get("leader_panel_id") and agents_ready
            else None
        )

    team = _wait(ready_team)
    if team is None:
        observed = next(
            (item for item in c.team_list() if item.get("team_name") == team_name),
            None,
        )
        raise termmeshError(
            "remote Project never became fully ready; "
            f"last team snapshot={observed!r}"
        )
    expected_instances = {
        agent["name"]: agent["agent_instance_id"]
        for agent in team["agents"]
    }

    def complete_project():
        project = next((item for item in c.debug_project_remote_presentations(host)
                        if item.get("name") == team_name
                        and item.get("project_id")
                        and item.get("leader_surface_id")), None)
        if project is None:
            return None
        members = project.get("members")
        if not isinstance(members, list) or len(members) != len(expected_instances):
            return None
        actual = {member.get("name"): member.get("agent_instance_id") for member in members}
        return project if actual == expected_instances and all(member.get("surface_id") for member in members) else None

    project = _wait(complete_project)
    if project is None:
        raise termmeshError("complete remote project manifest was not published")
    member_surfaces = {
        member["name"]: member["surface_id"]
        for member in project["members"]
    }
    state_path.write_text(json.dumps({
        "team_name": team_name,
        "project_id": project["project_id"],
        "leader_surface_id": project["leader_surface_id"],
        "member_instances": expected_instances,
        "member_surfaces": member_surfaces,
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
    remote_members = {
        member.get("name"): (member.get("agent_instance_id"), member.get("surface_id"))
        for member in project.get("members", [])
    }
    expected_members = {
        name: (state["member_instances"][name], surface_id)
        for name, surface_id in state["member_surfaces"].items()
    }
    if remote_members != expected_members:
        raise termmeshError(
            "worker descriptors changed or disappeared across app/client restart: "
            f"expected={expected_members!r} actual={remote_members!r}"
        )

    # A stale id must be rejected before any asynchronous presentation work
    # starts. Pin the observable invariant as well: a rejected adoption cannot
    # add a pane or a partial local team.
    panes_before = len(c.list_panes())
    teams_before = {item.get("team_name") for item in c.team_list()}
    stale_id = f"{state['project_id']}-stale"
    try:
        c.debug_project_adopt_remote(host, stale_id)
    except termmeshError:
        pass
    else:
        raise termmeshError("stale remote project adoption was accepted")
    if len(c.list_panes()) != panes_before:
        raise termmeshError("stale adoption left a stray pane")
    if {item.get("team_name") for item in c.team_list()} != teams_before:
        raise termmeshError("stale adoption left a partial or duplicate team")

    # The debug RPC acknowledges scheduling before adoption completes, so the
    # failure it is meant to pin happens asynchronously inside the app. With the
    # host disconnected either outcome is legitimate: the RPC is rejected
    # outright (the roster no longer resolves the project), or it is accepted and
    # the scheduled attempt fails. Both must leave the current presentation
    # untouched and keep the project adoptable after reconnect.
    c.peer_host_disconnect(host)
    disconnected = _wait(lambda: next((item for item in c.peer_host_list()
                                        if item.get("id") == host
                                        and item.get("state") != "connected"), None),
                         timeout_s=10)
    if disconnected is None:
        raise termmeshError("peer host did not disconnect before adoption failure test")

    def presentation_unchanged() -> None:
        if len(c.list_panes()) != panes_before:
            raise termmeshError("disconnected adoption left a stray pane")
        if {item.get("team_name") for item in c.team_list()} != teams_before:
            raise termmeshError("disconnected adoption left a partial or duplicate team")

    tail = _DebugLogTail()
    try:
        scheduled = c.debug_project_adopt_remote(host, state["project_id"])
    except termmeshError:
        # Rejected before any presentation work started: nothing is in flight,
        # so the invariant is already final.
        presentation_unchanged()
    else:
        if not scheduled.get("started"):
            raise termmeshError(
                f"disconnected adoption was neither rejected nor scheduled: {scheduled!r}"
            )
        # Hold the invariant until the app logs the finished attempt, so the
        # check cannot pass merely because the failure path has not run yet.
        marker = f"debug.project.adopt_remote project={state['project_id']} adopted="
        completed = _hold(presentation_unchanged, lambda: tail.contains(marker))
        if not completed:
            raise termmeshError(
                "scheduled adoption never completed while the host was disconnected "
                f"(watched log advanced={tail.grew()})"
            )

    _connect(c, host)
    republished = _wait(lambda: next((item for item in c.debug_project_remote_presentations(host)
                                      if item.get("project_id") == state["project_id"]), None),
                        timeout_s=25)
    if republished is None:
        raise termmeshError("remote project manifest did not return after reconnect")
    adopted = c.debug_project_adopt_remote(host, state["project_id"])
    if adopted.get("leader_surface_id") != state["leader_surface_id"]:
        raise termmeshError(f"adopt selected a different leader surface: {adopted!r}")
    team = _wait(lambda: next((item for item in c.team_list()
                               if item.get("team_name") == team_name
                               and item.get("leader_pane_attached")
                               and item.get("leader_panel_id")), None))
    if team is None:
        raise termmeshError("remote Project did not reattach after app restart")
    restored_instances = {
        agent.get("name"): agent.get("agent_instance_id")
        for agent in team.get("agents", [])
    }
    if restored_instances != state["member_instances"]:
        raise termmeshError(
            "adopted Project did not restore the exact remote workers: "
            f"expected={state['member_instances']!r} actual={restored_instances!r}"
        )
    if any(not agent.get("panel_id") for agent in team.get("agents", [])):
        raise termmeshError(f"an adopted remote worker has no pane: {team!r}")
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
