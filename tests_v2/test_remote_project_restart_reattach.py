#!/usr/bin/env python3
"""A daemon-owned remote Project survives app restart and reattaches exact surfaces.

Set ``TERMMESH_E2E_REQUIRE_SESSION_OWNER_REDIRECT=1`` for the Mac GUI ->
sibling daemon regression topology. That mode waits for the advertised owner
to become ready, then pins the two endpoints, exact panes/surfaces, and cleanup.
"""
from __future__ import annotations

import json
import os
import base64
import subprocess
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


HOST_ENV = "TERMMESH_E2E_REMOTE_LEADER_HOST"
DIR_ENV = "TERMMESH_E2E_REMOTE_LEADER_DIR"
PHASE_ENV = "TERMMESH_E2E_REATTACH_PHASE"
CROSS_INSTALLATION_VIEWER_ENV = "TERMMESH_E2E_CROSS_INSTALLATION_VIEWER"
STATE_ENV = "TERMMESH_E2E_REATTACH_STATE"
ROLES_ENV = "TERMMESH_E2E_REATTACH_ROLES"
LEADER_CLI_ENV = "TERMMESH_E2E_REMOTE_LEADER_CLI"
WORKER_CLI_ENV = "TERMMESH_E2E_REMOTE_WORKER_CLI"
REQUIRE_SESSION_OWNER_REDIRECT_ENV = "TERMMESH_E2E_REQUIRE_SESSION_OWNER_REDIRECT"
REQUIRE_REMOTE_PROJECT_ENV = "TERMMESH_E2E_REQUIRE_REMOTE_PROJECT"
RECEIPT_ENV = "TERMMESH_E2E_RELAY_RECEIPT"
CANDIDATE_SHA_ENV = "TERMMESH_E2E_CANDIDATE_SHA"
REMOTE_FIXTURE_CANDIDATE_SHA_ENV = "TERMMESH_E2E_REMOTE_FIXTURE_CANDIDATE_SHA"
REMOTE_FIXTURE_VERSION_ENV = "TERMMESH_E2E_REMOTE_FIXTURE_VERSION"
LEADER_RELAY_STABILITY_SECONDS = 15.0
BACKGROUND_RESTORE_HOLD_SECONDS = 12.0


class _TerminalTestFailure(termmeshError):
    """A polled operation reached a terminal state and must not be retried."""


def _canonical_uuid(value: object, field: str = "team_uuid") -> str:
    try:
        parsed = uuid.UUID(str(value))
    except (ValueError, TypeError, AttributeError) as exc:
        raise termmeshError(f"{field} is not a canonical UUID: {value!r}") from exc
    canonical = str(parsed).upper()
    if str(value).upper() != canonical:
        raise termmeshError(f"{field} is not canonical: {value!r}")
    return canonical


def _ssh_target(host: str) -> str:
    if not host.startswith("ssh:"):
        raise termmeshError(f"remote Project host is not an SSH profile: {host!r}")
    return host.removeprefix("ssh:")


def _remote_stdout(host: str, command: str, timeout_s: int = 30) -> str:
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", _ssh_target(host), command],
        capture_output=True, text=True, timeout=timeout_s,
    )
    if result.returncode != 0:
        raise termmeshError(
            f"remote command failed on {host}: {command!r}: {result.stderr.strip()}"
        )
    return result.stdout.strip()


def _remote_project_manifest_status(
    host: str, remote_dir: str, project_id: str
) -> dict | None:
    """Read the daemon's durable record, independent of peer discovery."""
    root = str(Path(remote_dir).parent)
    output = _remote_stdout(
        host,
        f"env TERMMESH_DAEMON_UNIX_PATH={str(Path(root) / 'term-meshd.sock')!r} "
        "/tmp/term-mesh-release-relay-target/release/tm-agent "
        "daemon project-presentations list",
        timeout_s=30,
    )
    payload = json.loads(output)
    return next((
        record for record in payload.get("records", [])
        if record.get("project_id") == project_id
    ), None)


def _remote_participation_control(host: str, team_uuid: str) -> dict | None:
    team_uuid = _canonical_uuid(team_uuid)
    name = f"leader-participation-{team_uuid}.json"
    command = (
        'p="${XDG_CACHE_HOME:-$HOME/.cache}/term-mesh/leader-hooks/' + name + '"; '
        '[ -f "$p" ] || exit 44; cat "$p"'
    )
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", _ssh_target(host), command],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode == 44:
        return None
    if result.returncode != 0:
        raise termmeshError(f"could not read remote participation control: {result.stderr}")
    return json.loads(result.stdout)


def _bundled_tm_agent() -> Path:
    app_bin = Path(os.environ["TERMMESH_APP_BIN"])
    cli = app_bin.parents[2] / "Contents/Resources/bin/tm-agent"
    if not os.access(cli, os.X_OK):
        raise termmeshError(f"bundled tm-agent is not executable: {cli}")
    return cli


def _tm_agent_json(team: str, *args: str, timeout_s: int = 30) -> dict:
    result = subprocess.run(
        [str(_bundled_tm_agent()), "--team", team, *args],
        capture_output=True, text=True, timeout=timeout_s, env=os.environ.copy(),
    )
    if result.returncode != 0:
        raise termmeshError(
            f"tm-agent {' '.join(args)} failed: {result.stdout}\\n{result.stderr}"
        )
    start = result.stdout.find("{")
    if start < 0:
        raise termmeshError(f"tm-agent returned no JSON: {result.stdout!r}")
    return json.loads(result.stdout[start:])


def _prove_remote_agent_replies(team: str, names: list[str]) -> None:
    task_ids = []
    for name in names:
        delegated = _tm_agent_json(
            team, "delegate", name,
            "E2E proof: run hostname and pwd, then reply STATUS: DONE with exact values; do not edit files.",
            "--worktree", "off", "--title", f"{name} remote proof",
        )
        task_id = str(delegated.get("result", {}).get("task", {}).get("id") or "")
        if not task_id:
            raise termmeshError(f"delegate returned no task id for {name}: {delegated!r}")
        task_ids.append(task_id)
    deadline = time.time() + 180
    while time.time() < deadline:
        listed = _tm_agent_json(team, "task", "list")
        tasks = {
            str(task.get("id")): task
            for task in listed.get("result", {}).get("tasks", [])
        }
        if all(task_id in tasks and tasks[task_id].get("result") for task_id in task_ids):
            for task_id in task_ids:
                result = str(tasks[task_id].get("result") or "")
                if "STATUS: DONE" not in result or "hostname" not in result or "pwd" not in result:
                    raise termmeshError(f"remote agent did not return execution proof: {result!r}")
            return
        time.sleep(1)
    raise termmeshError(f"remote agent proof tasks timed out: {task_ids!r}")


def _wait(predicate, timeout_s: float = 45.0, interval_s: float = 0.2):
    deadline = time.time() + timeout_s
    last = None
    while time.time() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except _TerminalTestFailure:
            raise
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
            host_row = next(
                (item for item in c.peer_host_list() if item.get("id") == host),
                {},
            )
            raise termmeshError(
                "host did not provide authoritative leader process liveness: "
                f"serving_app_version={host_row.get('serving_app_version')!r} "
                f"project={project!r}"
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
        if row.get("state") == "connected":
            # A live transport can still carry stale/unresolved authenticated
            # PATH metadata. connect may be a no-op in that state; Retry is
            # the user-visible fresh-handshake operation.
            c.peer_host_retry(host)
        else:
            c.peer_host_connect(host)
        row = _wait(lambda: next((item for item in c.peer_host_list()
                                 if item.get("id") == host
                                 and item.get("state") == "connected"
                                 and item.get("launchable")), None),
                    timeout_s=25)
        if row is None:
            observed = next(
                (item for item in c.peer_host_list() if item.get("id") == host),
                None,
            )
            raise termmeshError(
                f"peer host did not become launchable: host={host!r} row={observed!r}"
            )
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
    if os.environ.get(REQUIRE_REMOTE_PROJECT_ENV) == "1":
        if not row.get("authoritative_leader_liveness"):
            raise termmeshError(
                "required remote endpoint does not advertise authoritative "
                "leader liveness (surface.foreground.v1); "
                f"row={row!r}"
            )
        expected_version = os.environ.get(REMOTE_FIXTURE_VERSION_ENV, "").strip()
        if expected_version and row.get("serving_app_version") != expected_version:
            raise termmeshError(
                "remote fixture version differs from the staged candidate: "
                f"expected={expected_version!r} row={row!r}"
            )
    return row


def _phase_create_inner(
    c, host: str, remote_dir: str, state_path: Path, team_name: str
) -> None:
    host_row = next(item for item in c.peer_host_list() if item.get("id") == host)
    route = (
        _assert_session_owner_route(host_row)
        if os.environ.get(REQUIRE_SESSION_OWNER_REDIRECT_ENV, "").strip() == "1"
        else None
    )
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
    created = c.debug_project_creation_attempt(
        name=team_name,
        directory=remote_dir,
        roles=roles,
        host=host,
        leader_cli=os.environ.get(LEADER_CLI_ENV, "claude").strip() or "claude",
        leader_model=(
            "gpt-5.6-sol"
            if os.environ.get(LEADER_CLI_ENV, "claude").strip() == "codex"
            else "sonnet"
        ),
        worker_cli=os.environ.get(WORKER_CLI_ENV, "").strip() or None,
    )
    operation_id = str(created.get("operation_id") or "")
    if not operation_id:
        raise termmeshError(f"remote Project bootstrap returned no operation id: {created!r}")

    def bootstrap_finished():
        status = c.debug_project_creation_status(operation_id)
        if status.get("state") == "failed":
            raise _TerminalTestFailure(
                f"remote Project bootstrap failed: {status.get('error')!r}"
            )
        return status if status.get("state") == "created" else None

    bootstrap = _wait(bootstrap_finished, timeout_s=240)
    if bootstrap is None:
        raise termmeshError("remote Project bootstrap did not finish")
    if bootstrap.get("working_directory") != remote_dir:
        raise termmeshError(
            "real ProjectCreationFlow lost the requested remote directory: "
            f"requested={remote_dir!r} status={bootstrap!r}"
        )
    checkouts = bootstrap.get("checkouts")
    if not isinstance(checkouts, list) or len(checkouts) != len(roles):
        raise termmeshError(
            "remote project bootstrap did not preserve the requested workers: "
            f"roles={roles!r} status={bootstrap!r}"
        )

    def ready_team():
        team = next((item for item in c.team_list() if item.get("team_name") == team_name), None)
        if team and team.get("leader_failure"):
            failure = str(team["leader_failure"])
            if "pending" not in failure.lower():
                raise _TerminalTestFailure(f"remote leader failed: {failure}")
        if team and team.get("remote_attach_failures"):
            raise _TerminalTestFailure(
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
    c.debug_leader_participation_configure("shadow", 100, [team_name])
    control = _wait(lambda: (
        payload if (payload := _remote_participation_control(host, project["team_uuid"]))
        and payload.get("mode") == "shadow" else None
    ))
    if control is None or control.get("mode") != "shadow" or not control.get("supported"):
        raise termmeshError(f"remote leader did not receive initial Shadow controls: {control!r}")
    c.debug_leader_participation_configure("canary", 100, [team_name])
    canary = _wait(lambda: (
        payload if (payload := _remote_participation_control(host, project["team_uuid"]))
        and payload.get("mode") == "canary" and payload.get("percent") == 100
        and payload.get("opt_in") else None
    ))
    if canary is None:
        raise termmeshError("live Canary settings did not reach the existing remote leader")
    c.debug_leader_participation_configure("shadow", 100, [team_name])
    shadow = _wait(lambda: (
        payload if (payload := _remote_participation_control(host, project["team_uuid"]))
        and payload.get("mode") == "shadow" else None
    ))
    if shadow is None:
        raise termmeshError("live Shadow rollback did not reach the existing remote leader")
    c.debug_leader_participation_configure("canary", 100, [team_name], kill_switch=True)
    killed = _wait(lambda: (
        payload if (payload := _remote_participation_control(host, project["team_uuid"]))
        and payload.get("kill_switch") is True else None
    ))
    if killed is None:
        raise termmeshError("live Kill Switch did not reach the existing remote leader")
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
        "team_uuid": project["team_uuid"],
        "member_instances": expected_instances,
        "member_surfaces": member_surfaces,
        "source_directory": remote_dir,
        "checkouts": checkouts,
        "route": route,
        "layout": saved_layout,
        "create_relay_io": relay.get("io") or {},
        "leader_participation_live_refresh": True,
    }))


def _phase_create(c, host: str, remote_dir: str, state_path: Path) -> None:
    """Create a fixture and reclaim it if any create-phase assertion fails."""
    team_name = f"remote-reattach-e2e-{uuid.uuid4().hex[:8]}"
    try:
        _phase_create_inner(c, host, remote_dir, state_path, team_name)
    except Exception as original:
        cleanup_error = None
        try:
            deletion = c.debug_project_delete(team_name)
            operation_id = deletion.get("operation_id")
            if operation_id:
                _wait_for_project_deletion(c, operation_id)
        except Exception as exc:
            cleanup_error = exc
        if cleanup_error is not None:
            raise termmeshError(
                f"{original}; failed fixture cleanup for {team_name!r}: {cleanup_error}"
            ) from original
        raise


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

    # This phase runs with a fresh ephemeral peer identity and reset app state:
    # it is another installation, not merely the owner process restarting.
    # Reproduce New Project's same-name/different-path submission first. It
    # must surface Open Existing and mutate no team, workspace, or process.
    teams_before = len(c.team_list())
    panes_before = len(c.list_panes())
    conflict = c.debug_project_creation_attempt(
        name=team_name,
        directory=f"{state['source_directory']}-duplicate",
        roles=list(state["member_instances"]),
        host=host,
        leader_cli=os.environ.get(LEADER_CLI_ENV, "claude").strip() or "claude",
        leader_model=(
            "gpt-5.6-sol"
            if os.environ.get(LEADER_CLI_ENV, "claude").strip() == "codex"
            else "sonnet"
        ),
        worker_cli=os.environ.get(WORKER_CLI_ENV, "").strip() or None,
    )
    conflict_id = str(conflict.get("operation_id") or "")
    if not conflict_id:
        raise termmeshError(f"duplicate creation returned no operation id: {conflict!r}")
    conflict_status = _wait(lambda: (
        status if (status := c.debug_project_creation_status(conflict_id)).get("state")
        != "running" else None
    ))
    if conflict_status is None or conflict_status.get("state") != "conflict":
        raise termmeshError(f"duplicate remote Project was not a conflict: {conflict_status!r}")
    if conflict_status.get("conflict") != "remote_name_collision" \
       or conflict_status.get("action") != "open_existing":
        raise termmeshError(f"duplicate remote Project did not offer Open Existing: {conflict_status!r}")
    if len(c.team_list()) != teams_before or len(c.list_panes()) != panes_before:
        raise termmeshError("duplicate conflict mutated the fresh viewer before Open Existing")

    opened = c.debug_project_adopt_remote(host, state["project_id"])
    if opened.get("leader_surface_id") != state["leader_surface_id"]:
        raise termmeshError(f"Open Existing targeted another leader: {opened!r}")

    # Open Existing creates the Project model without stealing focus. A
    # terminal relay cannot start until its Ghostty view is mounted.
    pending_team = _wait(lambda: next(
        (item for item in c.team_list() if item.get("team_name") == team_name), None
    ))
    if pending_team is None or not pending_team.get("workspace_id"):
        raise termmeshError("remote Project model was not restored after app restart")
    window_id = next(
        (window.get("id") for window in c.list_windows()
         if any(workspace_id == pending_team["workspace_id"]
                for _, workspace_id, _, _ in c.list_workspaces(window.get("id")))),
        None,
    )
    if not window_id:
        raise termmeshError("restored Project workspace has no owning window")
    visible = _wait(lambda: next(
        (row for row in c.debug_sidebar_projects(str(window_id))
         if row.get("project_id") == state["project_id"]),
        None,
    ))
    if visible is None:
        raise termmeshError(
            "authoritative remote Project is absent from the local Project list"
        )
    visibility_screenshot = c.screenshot("remote-project-visible-after-restart")
    if not visibility_screenshot.get("path"):
        raise termmeshError(
            f"Project visibility screenshot was not captured: {visibility_screenshot!r}"
        )
    if os.environ.get(CROSS_INSTALLATION_VIEWER_ENV) != "1":
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
    # A fresh installation does not own the owner's layout sidecar. Exact
    # surface and instance identity, distinct panes, and working task routes
    # are the portable restore contract; layout persistence is owner-local.

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
    _prove_remote_agent_replies(team_name, sorted(state["member_instances"]))
    if os.environ.get(CROSS_INSTALLATION_VIEWER_ENV) == "1":
        state.update({
            "viewer_task_proof": True,
            "cross_installation_open_existing": True,
            "visibility_screenshot": visibility_screenshot["path"],
            "restart_relay_io": restart_relay.get("io") or {},
            "reconnect_relay_io": reconnect_relay.get("io") or {},
        })
        state_path.write_text(json.dumps(state))
        return
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
                "remote_fixture_candidate_sha": os.environ.get(
                    REMOTE_FIXTURE_CANDIDATE_SHA_ENV, ""
                ).strip(),
                "remote_fixture_version": os.environ.get(
                    REMOTE_FIXTURE_VERSION_ENV, ""
                ).strip(),
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
                "project_visibility_screenshot": visibility_screenshot["path"],
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
    artifact_check = (
        'd="${XDG_CACHE_HOME:-$HOME/.cache}/term-mesh/leader-hooks"; '
        f'test ! -e "$d/leader-turn-{state["team_uuid"]}.sh"; '
        f'test ! -e "$d/leader-participation-{state["team_uuid"]}.json"'
    )
    _remote_stdout(host, artifact_check)
    if _wait(fully_deleted):
        recreation_directory = Path(f"/tmp/{team_name}-recreate")
        recreation_directory.mkdir(parents=True, exist_ok=True)
        if not (recreation_directory / ".git").exists():
            import subprocess
            subprocess.run(["git", "init", "-q", str(recreation_directory)], check=True)
            (recreation_directory / "README.md").write_text("same-name recreation\n")
            subprocess.run(
                ["git", "-C", str(recreation_directory), "add", "README.md"], check=True
            )
            subprocess.run([
                "git", "-C", str(recreation_directory),
                "-c", "user.name=term-mesh-e2e",
                "-c", "user.email=e2e@invalid",
                "commit", "-qm", "fixture",
            ], check=True)
        recreated = c.debug_project_creation_attempt(
            name=team_name, directory=str(recreation_directory)
        )
        recreation_operation_id = str(recreated.get("operation_id") or "")
        if not recreation_operation_id:
            raise termmeshError(
                f"same-name recreation returned no operation id: {recreated!r}"
            )
        recreation = _wait(lambda: (
            status if (status := c.debug_project_creation_status(
                recreation_operation_id
            )).get("state") != "running" else None
        ))
        if recreation is None or recreation.get("state") != "created":
            raise termmeshError(
                "deleted remote Project name was not reusable: "
                f"{recreation!r}"
            )
        cleanup = c.debug_project_delete(team_name)
        cleanup_id = str(cleanup.get("operation_id") or "")
        if not cleanup_id:
            raise termmeshError(f"same-name recreation cleanup did not start: {cleanup!r}")
        _wait_for_project_deletion(c, cleanup_id)
        import shutil
        shutil.rmtree(recreation_directory, ignore_errors=True)
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


def _phase_repair(c, host: str, remote_dir: str, state_path: Path) -> None:
    state = json.loads(state_path.read_text())
    team_name = state["team_name"]
    old_leader = state["leader_surface_id"]
    if any(item.get("team_name") == team_name for item in c.team_list()):
        raise termmeshError(
            "cold exact-repair fixture unexpectedly installed a local placeholder"
        )
    durable = _remote_project_manifest_status(host, remote_dir, state["project_id"])
    if durable is None:
        raise termmeshError(
            "durable Project manifest did not survive daemon restart"
        )
    expected_references = 1 + len(state["member_instances"])
    old_leader_hex = base64.b64decode(old_leader).hex()
    if durable.get("leader_surface_id") != old_leader_hex:
        raise termmeshError(f"durable Project leader identity changed: {durable!r}")
    if int(durable.get("referenced_surfaces") or 0) != expected_references:
        raise termmeshError(f"durable Project references changed: {durable!r}")
    live_references = int(durable.get("live_surfaces") or 0)
    if live_references >= expected_references:
        raise termmeshError(f"restart did not remove any Project surface: {durable!r}")

    # The current SSH tunnel may remain established across the remote listener
    # replacement. Retry forces a fresh authenticated generation.
    c.peer_host_retry(host)
    _wait(lambda: next((
        row for row in c.peer_host_list()
        if row.get("id") == host and row.get("state") == "connected"
        and row.get("team_host_readiness") == "ready"
        and "session_host_socket" in row
        and row.get("launchable") is True
    ), None), timeout_s=45)
    repair = c.team_repair_collaboration(
        team_name, host_key=host, team_uuid=state["team_uuid"],
        project_id=state["project_id"]
    )
    if not repair.get("succeeded") or not repair.get("route_verified"):
        raise termmeshError(f"one-call collaboration repair failed: {repair!r}")
    if int(repair.get("live_agents") or 0) != len(state["member_instances"]):
        raise termmeshError(f"repair did not restore every worker: {repair!r}")

    project = _wait(lambda: next((
        item for item in c.debug_project_remote_presentations(host)
        if item.get("project_id") == state["project_id"]
        and item.get("leader_surface_id") != old_leader
    ), None), timeout_s=30)
    if project is None:
        raise termmeshError("repaired Project did not publish its new leader surface")
    team = _wait(lambda: next((
        item for item in c.team_list()
        if item.get("team_name") == team_name
        and item.get("leader_ready")
        and len(item.get("agents") or []) == len(state["member_instances"])
    ), None), timeout_s=45)
    if team is None:
        raise termmeshError("repaired team did not converge to leader + workers")
    restored = {
        agent.get("name"): agent.get("agent_instance_id")
        for agent in team.get("agents", [])
    }
    if restored != state["member_instances"]:
        raise termmeshError(
            f"repair changed durable worker identities: {restored!r}"
        )
    # `route_verified` is produced only after the owner app runs tm-agent in
    # the remote leader's service-account environment and observes an exact
    # proxied team.status response. A test-runner tm-agent call would use the
    # local app socket instead and cannot prove that route.
    state["pre_repair_leader_surface_id"] = old_leader
    state["leader_surface_id"] = project["leader_surface_id"]
    state["repair_collaboration_verified"] = True
    state_path.write_text(json.dumps(state))


def _phase_cleanup(c, host: str, state_path: Path) -> None:
    state = json.loads(state_path.read_text())
    state["team_uuid"] = _canonical_uuid(state.get("team_uuid"))
    if not state.get("viewer_task_proof"):
        raise termmeshError("owner cleanup started without viewer task proof")
    if not state.get("repair_collaboration_verified"):
        raise termmeshError("owner cleanup started without one-call repair proof")
    project = _wait(lambda: next((
        item for item in c.debug_project_remote_presentations(host)
        if item.get("project_id") == state["project_id"]
    ), None))
    if project is None:
        raise termmeshError("owner cleanup cannot find the durable Project manifest")
    existing = next((
        item for item in c.team_list()
        if item.get("team_name") == state["team_name"]
    ), None)
    if existing is None:
        c.debug_project_adopt_remote(host, state["project_id"])
    pending = _wait(lambda: next((
        item for item in c.team_list()
        if item.get("team_name") == state["team_name"] and item.get("workspace_id")
    ), None))
    if pending is None:
        raise termmeshError("owner cleanup did not create the Project model")
    c.select_workspace(pending["workspace_id"])
    team = _wait(lambda: next((
        item for item in c.team_list()
        if item.get("team_name") == state["team_name"]
        and item.get("leader_pane_attached")
        and len(item.get("agents") or []) == len(state["member_instances"])
    ), None))
    if team is None:
        raise termmeshError("owner cleanup could not adopt the exact Project")
    deletion = c.debug_project_delete(state["team_name"])
    operation_id = str(deletion.get("operation_id") or "")
    if not operation_id:
        raise termmeshError(f"owner cleanup returned no operation id: {deletion!r}")
    _wait_for_project_deletion(c, operation_id)
    artifact_check = (
        'd="${XDG_CACHE_HOME:-$HOME/.cache}/term-mesh/leader-hooks"; '
        f'test ! -e "$d/leader-turn-{state["team_uuid"]}.sh"; '
        f'test ! -e "$d/leader-participation-{state["team_uuid"]}.json"'
    )
    _remote_stdout(host, artifact_check)
    if _remote_project_manifest_status(
        host, state["source_directory"], state["project_id"]
    ) is not None:
        raise termmeshError("owner cleanup left the manifest behind")
    receipt_path = os.environ.get(RECEIPT_ENV, "").strip()
    if receipt_path:
        reconnect_io = state.get("reconnect_relay_io") or {}
        receipt = {
            "schema": 1,
            "candidate_sha": os.environ.get(CANDIDATE_SHA_ENV, "").strip(),
            "remote_fixture_candidate_sha": os.environ.get(
                REMOTE_FIXTURE_CANDIDATE_SHA_ENV, ""
            ).strip(),
            "remote_fixture_version": os.environ.get(
                REMOTE_FIXTURE_VERSION_ENV, ""
            ).strip(),
            "result": "pass", "required_topology": True, "skipped": False,
            "host": host,
            "phases": {
                "create": "pass", "adopt": "pass",
                "reconnect": "pass", "repair": "pass",
                "cleanup": "pass",
            },
            "leader_surface_id": state["leader_surface_id"],
            "pre_repair_leader_surface_id": state.get(
                "pre_repair_leader_surface_id", ""
            ),
            "exact_surface_preserved": True,
            "repair_collaboration_verified": True,
            "leader_relay_stability_seconds": LEADER_RELAY_STABILITY_SECONDS,
            "background_restore_hold_seconds": BACKGROUND_RESTORE_HOLD_SECONDS,
            "cross_installation_open_existing": bool(
                state.get("cross_installation_open_existing")
            ),
            "remote_agent_task_replies": bool(state.get("viewer_task_proof")),
            "leader_participation_live_refresh": bool(
                state.get("leader_participation_live_refresh")
            ),
            "remote_artifacts_removed": True,
            "leader_process_active": True,
            "leader_process_active_known": True,
            "project_visibility_screenshot": state["visibility_screenshot"],
            "create_relay_io": state.get("create_relay_io") or {},
            "restart_relay_io": state.get("restart_relay_io") or {},
            "reconnect_relay_io": reconnect_io,
            "saw_first_byte": bool(reconnect_io.get("saw_first_byte")),
            "bytes_received": int(reconnect_io.get("bytes_received") or 0),
            "tested_at_unix": int(time.time()),
        }
        temp_receipt = Path(receipt_path + ".tmp")
        temp_receipt.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        temp_receipt.replace(receipt_path)
    state_path.unlink(missing_ok=True)


def main() -> int:
    host = os.environ.get(HOST_ENV, "").strip()
    remote_dir = os.environ.get(DIR_ENV, "").strip()
    phase = os.environ.get(PHASE_ENV, "").strip()
    state_path = Path(os.environ.get(STATE_ENV, "/tmp/term-mesh-remote-project-e2e-state.json"))
    if not host or not remote_dir or phase not in {"create", "adopt", "repair", "cleanup"}:
        if os.environ.get(REQUIRE_REMOTE_PROJECT_ENV) == "1":
            raise termmeshError(
                f"required remote Project topology missing: set {HOST_ENV}, "
                f"{DIR_ENV}, and {PHASE_ENV}=full (runner) or create|adopt|repair|cleanup"
            )
        print(
            f"SKIP: set {HOST_ENV}, {DIR_ENV}, and "
            f"{PHASE_ENV}=full (runner) or create|adopt|repair|cleanup"
        )
        return 0

    with termmesh() as c:
        _connect(c, host)
        if phase == "create":
            _phase_create(c, host, remote_dir, state_path)
        elif phase == "adopt":
            _phase_adopt(c, host, state_path)
        elif phase == "repair":
            _phase_repair(c, host, remote_dir, state_path)
        else:
            _phase_cleanup(c, host, state_path)
    print(f"PASS: remote Project restart reattach phase {phase}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
