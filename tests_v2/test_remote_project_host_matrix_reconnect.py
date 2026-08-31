#!/usr/bin/env python3
"""Create and reconnect durable Projects on real macOS and Linux peers.

The matrix is explicit because a loopback or same-host run cannot prove the
GUI-serving-socket -> daemon-session-owner boundary on macOS, while a macOS-
only run cannot prove the direct daemon route used by Linux.

Set ``TERMMESH_E2E_PROJECT_HOST_MATRIX`` to a JSON array, for example::

    [
      {"platform": "macos", "host": "ssh:jinwoo-macmini",
       "directory": "/Users/jinwoo/work/project/term-mesh",
       "require_session_owner_redirect": true},
      {"platform": "linux", "host": "ssh:root@jwserver68",
       "directory": "/app/tm-projects/term-mesh"}
    ]

Each case pins: create -> exact manifest/panes -> force transport disconnect ->
reconnect -> exact persisted surfaces -> adopt -> delete -> no manifest/team/
relay pane left behind.
"""
from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError
from test_remote_project_restart_reattach import (
    REQUIRE_SESSION_OWNER_REDIRECT_ENV,
    ROLES_ENV,
    _assert_session_owner_route,
    _connect,
    _phase_create,
    _phase_create_inner,
    _wait_for_project_deletion,
    _wait,
)

MATRIX_ENV = "TERMMESH_E2E_PROJECT_HOST_MATRIX"
ALLOW_PARTIAL_ENV = "TERMMESH_E2E_PROJECT_HOST_MATRIX_ALLOW_PARTIAL"
REQUIRED_PLATFORMS = {"macos", "linux"}


def _matrix() -> list[dict]:
    raw = os.environ.get(MATRIX_ENV, "").strip()
    if not raw:
        return []
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise termmeshError(f"{MATRIX_ENV} is not valid JSON: {exc}") from exc
    if not isinstance(value, list):
        raise termmeshError(f"{MATRIX_ENV} must be a JSON array")

    result: list[dict] = []
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            raise termmeshError(f"matrix row {index} must be an object: {item!r}")
        platform = str(item.get("platform") or "").strip().lower()
        host = str(item.get("host") or "").strip()
        directory = str(item.get("directory") or "").strip()
        if platform not in REQUIRED_PLATFORMS or not host or not directory:
            raise termmeshError(
                f"matrix row {index} needs platform=macos|linux, host, and directory: "
                f"{item!r}"
            )
        result.append({
            "platform": platform,
            "host": host,
            "directory": directory,
            "ssh_port": item.get("ssh_port"),
            "identity_file": str(item.get("identity_file") or "").strip() or None,
            "require_session_owner_redirect": bool(
                item.get("require_session_owner_redirect", False)
            ),
        })

    present = {item["platform"] for item in result}
    allow_partial = os.environ.get(ALLOW_PARTIAL_ENV, "").strip() == "1"
    if present != REQUIRED_PLATFORMS and not allow_partial:
        raise termmeshError(
            f"matrix must contain macos and linux exactly as platform classes; got {present!r}"
        )
    if allow_partial and not present:
        raise termmeshError("partial matrix still needs at least one platform row")
    return result


def _exact_presentation(c: termmesh, host: str, state: dict) -> dict | None:
    project = next((
        item for item in c.debug_project_remote_presentations(host)
        if item.get("project_id") == state["project_id"]
    ), None)
    if project is None or project.get("leader_surface_id") != state["leader_surface_id"]:
        return None
    actual = {
        member.get("name"): (
            member.get("agent_instance_id"), member.get("surface_id")
        )
        for member in project.get("members", [])
    }
    expected = {
        name: (state["member_instances"][name], surface_id)
        for name, surface_id in state["member_surfaces"].items()
    }
    return project if actual == expected else None


def _live_team(c: termmesh, team_name: str) -> dict | None:
    matches = [item for item in c.team_list() if item.get("team_name") == team_name]
    if len(matches) > 1:
        raise termmeshError(f"duplicate local teams after reconnect: {matches!r}")
    return matches[0] if matches else None


def _visible_project(c: termmesh, team: dict, project_id: str) -> dict | None:
    workspace_id = str(team.get("workspace_id") or "")
    if not workspace_id:
        return None
    for window in c.list_windows():
        window_id = str(window.get("id") or "")
        if any(candidate == workspace_id
               for _, candidate, _, _ in c.list_workspaces(window_id)):
            return next((
                row for row in c.debug_sidebar_projects(window_id)
                if row.get("project_id") == project_id
            ), None)
    return None


def _fully_deleted(c: termmesh, host: str, state: dict, panel_ids: set[str]) -> bool:
    project_exists = any(
        item.get("project_id") == state["project_id"]
        for item in c.debug_project_remote_presentations(host)
    )
    team_exists = _live_team(c, state["team_name"]) is not None
    remaining_panes = {pane_id for _, pane_id, _, _ in c.list_panes()}
    return not project_exists and not team_exists and panel_ids.isdisjoint(remaining_panes)


def _ssh_target(host: str) -> str:
    if not host.startswith("ssh:") or not host.removeprefix("ssh:").strip():
        raise termmeshError(f"matrix host must be an SSH stable id: {host!r}")
    return host.removeprefix("ssh:")


def _remote_stdout(
    host: str, command: str, ssh_port: int | None = None,
    identity_file: str | None = None,
) -> str:
    ssh = ["ssh", "-o", "BatchMode=yes"]
    if ssh_port is not None:
        ssh.extend(["-p", str(ssh_port)])
    if identity_file:
        ssh.extend(["-i", identity_file])
    completed = subprocess.run(
        [*ssh, _ssh_target(host), command],
        capture_output=True, text=True, timeout=30,
    )
    if completed.returncode != 0:
        raise termmeshError(
            f"remote verification failed on {host}: {command!r}: "
            f"{completed.stderr.strip()}"
        )
    return completed.stdout.strip()


def _source_head(host: str, directory: str, case: dict) -> str:
    path = shlex.quote(directory)
    return _remote_stdout(
        host, f"git -C {path} rev-parse HEAD",
        case.get("ssh_port"), case.get("identity_file")
    )


def _assert_created_checkouts_removed(host: str, state: dict, case: dict) -> None:
    paths = [
        str(checkout.get("path") or "")
        for checkout in state.get("checkouts", [])
        if str(checkout.get("path") or "")
            != str(state.get("source_directory") or "")
    ]
    if not paths:
        raise termmeshError("matrix Project did not report an owned worker checkout")
    tests = " && ".join(f"test ! -e {shlex.quote(path)}" for path in paths)
    _remote_stdout(host, tests, case.get("ssh_port"), case.get("identity_file"))


def _run_case(c: termmesh, case: dict) -> dict:
    platform = case["platform"]
    host = case["host"]
    require_redirect = case["require_session_owner_redirect"]
    old_redirect = os.environ.get(REQUIRE_SESSION_OWNER_REDIRECT_ENV)
    old_roles = os.environ.get(ROLES_ENV)
    os.environ[REQUIRE_SESSION_OWNER_REDIRECT_ENV] = "1" if require_redirect else "0"
    os.environ[ROLES_ENV] = "executor"

    state_path = Path(tempfile.gettempdir()) / f"term-mesh-project-matrix-{platform}.json"
    state_path.unlink(missing_ok=True)
    state: dict | None = None
    known_panels: set[str] = set()
    try:
        row = _connect(c, host)
        if require_redirect:
            _assert_session_owner_route(row)
        elif row.get("session_host_socket"):
            raise termmeshError(
                f"{platform} direct-daemon case unexpectedly redirected: {row!r}"
            )

        source_head = _source_head(host, case["directory"], case)
        _phase_create(c, host, case["directory"], state_path)
        state = json.loads(state_path.read_text())
        before = _wait(lambda: _exact_presentation(c, host, state), timeout_s=45)
        if before is None:
            raise termmeshError(f"{platform} Project never published its exact manifest")
        team = _live_team(c, state["team_name"])
        if team is None:
            raise termmeshError(f"{platform} Project has a manifest but no local team")
        visible = _wait(
            lambda: _visible_project(c, team, state["project_id"]), timeout_s=20
        )
        if visible is None:
            raise termmeshError(
                f"{platform} authoritative Project is absent from the local Project list"
            )
        screenshot = c.screenshot(f"project-host-matrix-{platform}-visible")
        if not screenshot.get("path"):
            raise termmeshError(
                f"{platform} Project visibility screenshot failed: {screenshot!r}"
            )
        known_panels = {team["leader_panel_id"]} | {
            agent["panel_id"] for agent in team.get("agents", [])
        }

        disconnected = c.peer_host_force_disconnect(host)
        if not disconnected.get("ok"):
            raise termmeshError(f"{platform} force disconnect failed: {disconnected!r}")
        row = _wait(lambda: next((
            item for item in c.peer_host_list()
            if item.get("id") == host
            and item.get("state") in {"saved", "failed"}
            and not item.get("has_sidebar_lease")
        ), None), timeout_s=20)
        if row is None:
            raise termmeshError(f"{platform} host did not fully disconnect")

        row = _connect(c, host)
        if require_redirect:
            route = _assert_session_owner_route(row)
            if route != state.get("route"):
                raise termmeshError(
                    f"{platform} route changed across reconnect: "
                    f"before={state.get('route')!r} after={route!r}"
                )
        after = _wait(lambda: _exact_presentation(c, host, state), timeout_s=45)
        if after is None:
            raise termmeshError(
                f"{platform} Project did not republish the exact surfaces after reconnect"
            )

        adopted = c.debug_project_adopt_remote(host, state["project_id"])
        if adopted.get("leader_surface_id") != state["leader_surface_id"]:
            raise termmeshError(f"{platform} adopted another leader: {adopted!r}")
        restored = _wait(lambda: (
            team if (team := _live_team(c, state["team_name"]))
            and team.get("leader_panel_id")
            and all(agent.get("panel_id") for agent in team.get("agents", []))
            else None
        ), timeout_s=45)
        if restored is None:
            raise termmeshError(f"{platform} Project did not restore its panes")
        restored_instances = {
            agent.get("name"): agent.get("agent_instance_id")
            for agent in restored.get("agents", [])
        }
        if restored_instances != state["member_instances"]:
            raise termmeshError(
                f"{platform} restored different workers: "
                f"expected={state['member_instances']!r} actual={restored_instances!r}"
            )
        known_panels |= {restored["leader_panel_id"]} | {
            agent["panel_id"] for agent in restored.get("agents", [])
        }

        c.debug_project_delete(state["team_name"])
        if not _wait(
            lambda: _fully_deleted(c, host, state, known_panels), timeout_s=45
        ):
            raise termmeshError(
                f"{platform} deletion left a manifest, team, or relay pane behind"
            )
        if _source_head(host, case["directory"], case) != source_head:
            raise termmeshError(
                f"{platform} Delete Project changed or removed the selected source checkout"
            )
        _assert_created_checkouts_removed(host, state, case)

        recreated_path = Path(tempfile.gettempdir()) / f"term-mesh-project-matrix-{platform}-recreated.json"
        recreated_path.unlink(missing_ok=True)
        _phase_create_inner(
            c, host, case["directory"], recreated_path, state["team_name"]
        )
        recreated = json.loads(recreated_path.read_text())
        if recreated.get("team_name") != state["team_name"]:
            raise termmeshError(
                f"{platform} same-name Project was renamed: {recreated!r}"
            )
        recreated_team = _live_team(c, state["team_name"])
        if recreated_team is None or _wait(
            lambda: _visible_project(c, recreated_team, recreated["project_id"]),
            timeout_s=20,
        ) is None:
            raise termmeshError(
                f"{platform} same-name recreated Project is absent from the Project list"
            )
        cleanup = c.debug_project_delete(state["team_name"])
        cleanup_id = str(cleanup.get("operation_id") or "")
        if not cleanup_id:
            raise termmeshError(
                f"{platform} same-name Project cleanup returned no operation id"
            )
        _wait_for_project_deletion(c, cleanup_id)
        recreated_path.unlink(missing_ok=True)
        state_path.unlink(missing_ok=True)
        return {
            "platform": platform, "host": host,
            "project_id": state["project_id"],
            "leader_surface_id": state["leader_surface_id"],
            "project_visibility_screenshot": screenshot["path"],
            "same_name_recreated": True,
        }
    finally:
        if state is not None and _live_team(c, state["team_name"]) is not None:
            try:
                c.debug_project_delete(state["team_name"])
            except termmeshError:
                pass
        state_path.unlink(missing_ok=True)
        if old_redirect is None:
            os.environ.pop(REQUIRE_SESSION_OWNER_REDIRECT_ENV, None)
        else:
            os.environ[REQUIRE_SESSION_OWNER_REDIRECT_ENV] = old_redirect
        if old_roles is None:
            os.environ.pop(ROLES_ENV, None)
        else:
            os.environ[ROLES_ENV] = old_roles


def main() -> int:
    matrix = _matrix()
    if not matrix:
        print(f"SKIP: set {MATRIX_ENV} with macos and linux target rows")
        return 0
    with termmesh() as client:
        results = [_run_case(client, case) for case in matrix]
    platforms = ", ".join(sorted(result["platform"] for result in results))
    print(
        f"PASS: {platforms} Projects survived force disconnect/reconnect "
        + json.dumps(results, sort_keys=True)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
