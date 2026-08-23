#!/usr/bin/env python3
"""A daemon-owned remote Project survives app restart and reattaches exact surfaces.

Set ``TERMMESH_E2E_REQUIRE_SESSION_OWNER_REDIRECT=1`` for the Mac GUI ->
sibling daemon regression topology. That mode waits for the advertised owner
to become ready, then pins the two endpoints, exact panes/surfaces, and cleanup.
"""
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
REQUIRE_SESSION_OWNER_REDIRECT_ENV = "TERMMESH_E2E_REQUIRE_SESSION_OWNER_REDIRECT"
REQUIRE_REMOTE_PROJECT_ENV = "TERMMESH_E2E_REQUIRE_REMOTE_PROJECT"
RECEIPT_ENV = "TERMMESH_E2E_RELAY_RECEIPT"
CANDIDATE_SHA_ENV = "TERMMESH_E2E_CANDIDATE_SHA"
LEADER_RELAY_STABILITY_SECONDS = 15.0
BACKGROUND_RESTORE_HOLD_SECONDS = 12.0


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


def _project_deletion_succeeded(c: termmesh, operation_id: str):
    status = c.debug_project_delete_status(operation_id)
    if status.get("state") == "failed":
        raise termmeshError(
            f"remote Project deletion operation failed: {status.get('error')!r}"
        )
    return status if status.get("state") == "succeeded" else None


def _wait_for_project_deletion(c: termmesh, operation_id: str, timeout_s: float = 45.0):
    """Wait for the deletion receipt without swallowing a terminal failure."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        result = _project_deletion_succeeded(c, operation_id)
        if result:
            return result
        time.sleep(0.2)
    raise termmeshError(
        f"remote Project deletion operation timed out: operation_id={operation_id!r}"
    )


def _assert_leader_relay_stable(
    c: termmesh, host: str, project_id: str, team_name: str, leader_surface_id: str,
    duration_s: float = LEADER_RELAY_STABILITY_SECONDS,
) -> dict:
    """Hold exact attachment and actual relay bytes past the 10s accept timeout."""
    deadline = time.time() + duration_s
    last_relay = None
    while time.time() < deadline:
        team = next(
            (item for item in c.team_list() if item.get("team_name") == team_name),
            None,
        )
        if not team or not team.get("leader_pane_attached"):
            raise termmeshError(
                f"leader pane detached during relay stability window: team={team!r}"
            )
        if team.get("leader_failure"):
            raise termmeshError(
                f"leader failed during relay stability window: team={team!r}"
            )
        project = next(
            (item for item in c.debug_project_remote_presentations(host)
             if item.get("project_id") == project_id),
            None,
        )
        if not project or not project.get("leader_process_active_known"):
            raise termmeshError(
                f"host did not provide authoritative leader process liveness: {project!r}"
            )
        if not project.get("leader_process_active"):
            raise termmeshError(
                f"manifest points at an idle shell, not a live leader process: {project!r}"
            )
        pane_sessions = c.peer_pane_status().get("pane_sessions") or []
        last_relay = next(
            (row for row in pane_sessions
             if row.get("surface_id") == leader_surface_id),
            None,
        )
        if not last_relay or last_relay.get("torn_down"):
            raise termmeshError(
                "exact leader relay disappeared during stability window: "
                f"surface={leader_surface_id!r} relay={last_relay!r}"
            )
        io = last_relay.get("io") or {}
        if not io.get("saw_first_byte") or int(io.get("bytes_received") or 0) <= 0:
            raise termmeshError(
                "leader relay is attached without receiving bytes: "
                f"surface={leader_surface_id!r} io={io!r}"
            )
        time.sleep(0.25)
    return last_relay or {}


def _assert_background_project_waits_for_mount(
    c: termmesh, team_name: str, duration_s: float = BACKGROUND_RESTORE_HOLD_SECONDS
) -> dict:
    """Reproduce the production boundary: restored Project stays background >10s.

    Old code started the relay accept timer as soon as the pane model existed,
    even though no Ghostty view/helper could exist. It then tore the session down
    at 10 seconds. Correct code keeps the session pending until selection mounts it.
    """
    deadline = time.time() + duration_s
    last_team = None
    while time.time() < deadline:
        last_team = next(
            (item for item in c.team_list() if item.get("team_name") == team_name),
            None,
        )
        if last_team is None or not last_team.get("leader_panel_id"):
            raise termmeshError(f"background Project disappeared: {last_team!r}")
        if last_team.get("leader_pane_attached"):
            raise termmeshError(
                "background Project claimed an attached relay before its view mounted: "
                f"{last_team!r}"
            )
        failure = str(last_team.get("leader_failure") or "")
        if failure and "pending" not in failure.lower():
            raise termmeshError(
                f"background Project relay failed before mount: {last_team!r}"
            )
        time.sleep(0.25)
    return last_team or {}


def _layout_dividers(layout: dict | None) -> tuple[float, ...]:
    values: list[float] = []

    def walk(node):
        if not isinstance(node, dict) or node.get("type") != "split":
            return
        values.append(round(float(node.get("dividerPosition", 0)), 6))
        walk(node.get("first"))
        walk(node.get("second"))

    walk((layout or {}).get("root"))
    return tuple(values)


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


def _assert_session_owner_route(row: dict) -> dict:
    """Pin the Mac GUI -> daemon split that durable Projects require.

    Most remote hosts own panes and Projects on one socket. A Mac GUI host is
    intentionally different: its serving socket owns workspace mirrors, while
    the advertised session owner owns agent surfaces and project manifests.
    The original regression passed a generic "connected" check while all
    Project RPCs still went to the serving GUI socket.
    """
    serving = str(row.get("remote_sock_path") or "")
    session_owner = str(row.get("session_host_socket") or "")
    team_endpoint = str(row.get("team_host_endpoint") or "")
    readiness = str(row.get("team_host_readiness") or "")
    if not session_owner:
        raise termmeshError(
            "connected GUI host did not advertise session_host_socket; "
            f"row={row!r}"
        )
    if session_owner == serving:
        raise termmeshError(
            "session owner collapsed onto the serving GUI socket; "
            f"socket={serving!r}"
        )
    if session_owner not in team_endpoint:
        raise termmeshError(
            "team endpoint does not target the advertised session owner; "
            f"owner={session_owner!r} endpoint={team_endpoint!r}"
        )
    if readiness not in {"probing", "ready"}:
        raise termmeshError(
            "session owner route resolved without a usable readiness state; "
            f"row={row!r}"
        )
    return {
        "serving_socket": serving,
        "session_owner_socket": session_owner,
        "team_host_endpoint": team_endpoint,
    }


def _connect(c, host: str) -> dict:
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
    if os.environ.get(REQUIRE_SESSION_OWNER_REDIRECT_ENV, "").strip() == "1":
        def ready_session_owner():
            current = next(
                (item for item in c.peer_host_list() if item.get("id") == host),
                None,
            )
            if current is None:
                raise termmeshError(f"saved peer host disappeared: {host!r}")
            _assert_session_owner_route(current)
            return current if current.get("team_host_readiness") == "ready" else None

        row = _wait(ready_session_owner, timeout_s=45)
        if row is None:
            raise termmeshError(
                f"advertised session owner did not become ready: {host!r}"
            )
    return row


def _phase_create(c, host: str, remote_dir: str, state_path: Path) -> None:
    host_row = next(item for item in c.peer_host_list() if item.get("id") == host)
    route = (
        _assert_session_owner_route(host_row)
        if os.environ.get(REQUIRE_SESSION_OWNER_REDIRECT_ENV, "").strip() == "1"
        else None
    )
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
            failure = str(team["leader_failure"])
            if "pending" not in failure.lower():
                raise termmeshError(f"remote leader failed: {failure}")
        if team and team.get("remote_attach_failures"):
            raise termmeshError(
                f"remote worker failed: {team['remote_attach_failures']}"
            )
        agents = team.get("agents") if team else None
        agents_ready = (
            isinstance(agents, list)
            and len(agents) == len(roles)
            and all(agent.get("panel_id") and agent.get("agent_instance_id") for agent in agents)
        )
        return (
            team
            if team and team.get("leader_ready") and team.get("leader_pane_attached")
            and team.get("leader_panel_id") and agents_ready
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
    panel_ids = [team["leader_panel_id"]] + [
        agent["panel_id"] for agent in team["agents"]
    ]
    if len(set(panel_ids)) != len(panel_ids):
        raise termmeshError(
            "leader and workers did not receive distinct panes: "
            f"panels={panel_ids!r}"
        )
    matching_teams = [
        item for item in c.team_list() if item.get("team_name") == team_name
    ]
    if len(matching_teams) != 1:
        raise termmeshError(
            "project creation produced duplicate local teams: "
            f"matches={matching_teams!r}"
        )

    # Persist a non-default divider position so the restart check cannot pass
    # merely because both runs happened to build the same balanced fallback.
    c.select_workspace(team["workspace_id"])
    selected = _wait(
        lambda: c.current_workspace() == team["workspace_id"]
        and team["workspace_id"]
    )
    if selected is None:
        raise termmeshError("Project workspace did not become selected before resize")
    panes = c.list_panes()
    if len(panes) < 2:
        raise termmeshError(f"Project layout has fewer than two panes: {panes!r}")
    layout_before_resize = c.debug_project_layout(team_name)["live"]
    dividers_before_resize = _layout_dividers(layout_before_resize)
    # Depending on which side of the root split this pane occupies, only one
    # horizontal direction grows it. Try both and require an observed mutation.
    for direction in ("right", "left"):
        c.resize_pane(panes[0][1], direction, 40)
        changed = _wait(
            lambda: (live if (live := c.debug_project_layout(team_name)["live"])
                     != layout_before_resize else None),
            timeout_s=2,
        )
        if changed is not None:
            break
    def changed_layout():
        layouts = c.debug_project_layout(team_name)
        persisted = layouts["persisted"]
        # Canonical equalization may redraw the live split after a resize. The
        # durable sidecar is the restart source of truth; record its non-default
        # value here, then the adopt phase proves it becomes the live layout.
        return (
            persisted
            if persisted and _layout_dividers(persisted) != dividers_before_resize
            else None
        )

    saved_layout = _wait(changed_layout, timeout_s=10)
    if saved_layout is None:
        raise termmeshError(
            "Project divider change was not persisted to its layout sidecar: "
            f"workspace={c.current_workspace()!r} before={layout_before_resize!r} "
            f"after={c.debug_project_layout(team_name)!r}"
        )

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
    local_team = next(
        (item for item in c.team_list() if item.get("team_name") == team_name), None
    )
    if local_team is None or local_team.get("remote_project_id") != project["project_id"]:
        raise termmeshError(
            "owner Project identity differs from its published manifest: "
            f"local={local_team!r} remote={project!r}"
        )
    if local_team.get("remote_project_host") != host:
        raise termmeshError(
            "owner Project host identity differs from its published manifest: "
            f"local={local_team!r} expected_host={host!r}"
        )
    relay = _assert_leader_relay_stable(
        c, host, project["project_id"], team_name, project["leader_surface_id"]
    )
    # Agent panes and canonical equalization can settle after the divider write.
    # Persist the final topology, not the transient leader-only snapshot that
    # happened to exist when resize first returned.
    final_layouts = c.debug_project_layout(team_name)
    saved_layout = final_layouts["persisted"] or final_layouts["live"]
    if saved_layout is None or saved_layout.get("root", {}).get("type") != "split":
        raise termmeshError(
            f"final Project layout did not contain leader + worker panes: {final_layouts!r}"
        )
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
        "source_directory": remote_dir,
        "checkouts": checkouts,
        "route": route,
        "layout": saved_layout,
        "create_relay_io": relay.get("io") or {},
    }))


def _phase_adopt(c, host: str, state_path: Path) -> None:
    state = json.loads(state_path.read_text())
    team_name = state["team_name"]
    if state.get("route") is not None:
        row = next(item for item in c.peer_host_list() if item.get("id") == host)
        route = _assert_session_owner_route(row)
        if route != state["route"]:
            raise termmeshError(
                "Project route changed across app restart: "
                f"before={state['route']!r} after={route!r}"
            )
    project = _wait(lambda: next((item for item in c.debug_project_remote_presentations(host)
                                  if item.get("project_id") == state["project_id"]), None))
    if project is None:
        raise termmeshError("remote project manifest did not survive app restart")
    if project.get("leader_surface_id") != state["leader_surface_id"]:
        raise termmeshError(f"leader surface changed across restart: {project!r}")

    # Automatic restore creates the Project model without stealing focus. A
    # terminal relay cannot start until its Ghostty view is mounted, so open the
    # Project exactly as a user does before requiring transport readiness.
    pending_team = _wait(lambda: next(
        (item for item in c.team_list() if item.get("team_name") == team_name), None
    ))
    if pending_team is None or not pending_team.get("workspace_id"):
        raise termmeshError("remote Project model was not restored after app restart")
    _assert_background_project_waits_for_mount(c, team_name)
    c.select_workspace(pending_team["workspace_id"])
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

    # Relaunch recovery is automatic. The old test called
    # debug_project_adopt_remote here, which proved only that a hidden manual
    # repair path worked and missed the user-visible regression entirely.
    team = _wait(lambda: next((item for item in c.team_list()
                               if item.get("team_name") == team_name
                               and item.get("leader_pane_attached")
                               and item.get("leader_panel_id")), None))
    if team is None:
        raise termmeshError("remote Project was not restored automatically after app restart")
    restart_relay = _assert_leader_relay_stable(
        c, host, state["project_id"], team_name, state["leader_surface_id"]
    )
    restored_instances = {
        agent.get("name"): agent.get("agent_instance_id")
        for agent in team.get("agents", [])
    }
    if restored_instances != state["member_instances"]:
        raise termmeshError(
            "automatic restore did not recover the exact remote workers: "
            f"expected={state['member_instances']!r} actual={restored_instances!r}"
        )
    restored_layout = c.debug_project_layout(team_name)["live"]

    def same_layout(expected, actual, tolerance=0.015):
        if not isinstance(expected, dict) or not isinstance(actual, dict):
            return expected == actual
        if expected.get("projectID") != actual.get("projectID"):
            return False
        if expected.get("focusedSurfaceID") != actual.get("focusedSurfaceID"):
            return False

        def same_node(left, right):
            if left.get("type") != right.get("type"):
                return False
            if left.get("type") == "pane":
                return left.get("pane") == right.get("pane")
            return (
                left.get("orientation") == right.get("orientation")
                and abs(float(left.get("dividerPosition", 0))
                        - float(right.get("dividerPosition", 0))) <= tolerance
                and same_node(left.get("first") or {}, right.get("first") or {})
                and same_node(left.get("second") or {}, right.get("second") or {})
            )

        return same_node(expected.get("root") or {}, actual.get("root") or {})

    if not same_layout(state.get("layout"), restored_layout):
        raise termmeshError(
            "automatic restore changed project pane order or divider layout: "
            f"before={state.get('layout')!r} after={restored_layout!r}"
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
    team = _wait(lambda: next((item for item in c.team_list()
                               if item.get("team_name") == team_name
                               and item.get("leader_pane_attached")
                               and item.get("leader_panel_id")), None))
    if team is None:
        raise termmeshError("remote Project did not reattach after app restart")
    reconnect_relay = _assert_leader_relay_stable(
        c, host, state["project_id"], team_name, state["leader_surface_id"]
    )
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
    matching_teams = [
        item for item in c.team_list() if item.get("team_name") == team_name
    ]
    if len(matching_teams) != 1:
        raise termmeshError(
            "remote Project adoption produced duplicate local teams: "
            f"matches={matching_teams!r}"
        )
    adopted_panels = [team["leader_panel_id"]] + [
        agent["panel_id"] for agent in team.get("agents", [])
    ]
    if len(set(adopted_panels)) != len(adopted_panels):
        raise termmeshError(
            "adopted leader and workers share or duplicate a pane: "
            f"panels={adopted_panels!r}"
        )
    deletion = c.debug_project_delete(team_name)
    deletion_operation_id = deletion.get("operation_id")
    if not deletion_operation_id:
        raise termmeshError(f"Project deletion returned no operation id: {deletion!r}")

    def fully_deleted():
        project_exists = any(
            item.get("project_id") == state["project_id"]
            for item in c.debug_project_remote_presentations(host)
        )
        team_exists = any(
            item.get("team_name") == team_name for item in c.team_list()
        )
        remaining_panes = {pane_id for _, pane_id, _, _ in c.list_panes()}
        project_pane_exists = any(
            panel_id in remaining_panes for panel_id in adopted_panels
        )
        return not project_exists and not team_exists and not project_pane_exists

    receipt_path = os.environ.get(RECEIPT_ENV, "").strip()
    if receipt_path:
        # The release receipt proves the non-destructive lifecycle boundary.
        # Write it before cleanup so a cleanup regression cannot erase evidence
        # that create/restart/background/mount/reconnect itself passed. Cleanup
        # remains a separate failing assertion below.
        try:
            candidate_sha = os.environ.get(CANDIDATE_SHA_ENV, "").strip()
            if not candidate_sha:
                raise termmeshError(
                    f"{CANDIDATE_SHA_ENV} is required when writing a relay receipt"
                )
            reconnect_io = reconnect_relay.get("io") or {}
            receipt = {
                "schema": 1,
                "candidate_sha": candidate_sha,
                "result": "lifecycle_pass_cleanup_pending",
                "required_topology": True,
                "skipped": False,
                "host": host,
                "phases": {
                    "create": "pass",
                    "adopt": "pass",
                    "reconnect": "pass",
                    "cleanup": "pending",
                },
                "leader_surface_id": state["leader_surface_id"],
                "exact_surface_preserved": True,
                "leader_relay_stability_seconds": LEADER_RELAY_STABILITY_SECONDS,
                "background_restore_hold_seconds": BACKGROUND_RESTORE_HOLD_SECONDS,
                "saw_first_byte": bool(reconnect_io.get("saw_first_byte")),
                "bytes_received": int(reconnect_io.get("bytes_received") or 0),
                "leader_process_active": True,
                "leader_process_active_known": True,
                "create_relay_io": state.get("create_relay_io") or {},
                "restart_relay_io": restart_relay.get("io") or {},
                "reconnect_relay_io": reconnect_io,
                "tested_at_unix": int(time.time()),
            }
            payload = json.dumps(receipt, indent=2, sort_keys=True) + "\n"
            temp_receipt = Path(receipt_path + ".tmp")
            temp_receipt.write_text(payload)
            temp_receipt.replace(receipt_path)
        except OSError as exc:
            raise termmeshError(f"could not write relay E2E receipt: {exc}") from exc

    _wait_for_project_deletion(c, deletion_operation_id)
    if _wait(fully_deleted):
        if receipt_path:
            receipt["result"] = "pass"
            receipt["phases"]["cleanup"] = "pass"
            receipt["tested_at_unix"] = int(time.time())
            temp_receipt = Path(receipt_path + ".tmp")
            temp_receipt.write_text(json.dumps(
                receipt, indent=2, sort_keys=True
            ) + "\n")
            temp_receipt.replace(receipt_path)
        state_path.unlink(missing_ok=True)
        return
    project_exists = any(
        item.get("project_id") == state["project_id"]
        for item in c.debug_project_remote_presentations(host)
    )
    remaining_teams = [
        item for item in c.team_list() if item.get("team_name") == team_name
    ]
    remaining_panes = {pane_id for _, pane_id, _, _ in c.list_panes()}
    raise termmeshError(
        "remote Project deletion left state behind: "
        f"manifest={project_exists} teams={remaining_teams!r} "
        f"project_panes={sorted(set(adopted_panels) & remaining_panes)!r}"
    )


def main() -> int:
    host = os.environ.get(HOST_ENV, "").strip()
    remote_dir = os.environ.get(DIR_ENV, "").strip()
    phase = os.environ.get(PHASE_ENV, "").strip()
    state_path = Path(os.environ.get(STATE_ENV, "/tmp/term-mesh-remote-project-e2e-state.json"))
    if not host or not remote_dir or phase not in {"create", "adopt"}:
        if os.environ.get(REQUIRE_REMOTE_PROJECT_ENV) == "1":
            raise termmeshError(
                f"required remote Project topology missing: set {HOST_ENV}, "
                f"{DIR_ENV}, and {PHASE_ENV}=full (runner) or create|adopt"
            )
        print(
            f"SKIP: set {HOST_ENV}, {DIR_ENV}, and "
            f"{PHASE_ENV}=full (runner) or create|adopt"
        )
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
