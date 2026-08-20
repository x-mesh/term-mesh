#!/usr/bin/env python3
"""Fast contracts behind the real macOS/Linux Project matrix E2E."""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmeshError
from test_remote_project_host_matrix_reconnect import (
    ALLOW_PARTIAL_ENV,
    MATRIX_ENV,
    _exact_presentation,
    _fully_deleted,
    _matrix,
)
from test_remote_project_restart_reattach import _assert_session_owner_route


class FakeClient:
    def __init__(self, projects=None, teams=None, panes=None):
        self.projects = projects or []
        self.teams = teams or []
        self.panes = panes or []

    def debug_project_remote_presentations(self, _host):
        return self.projects

    def team_list(self):
        return self.teams

    def list_panes(self):
        return [(index, pane, 1, False) for index, pane in enumerate(self.panes)]


def rejects(callable_) -> bool:
    try:
        callable_()
    except termmeshError:
        return True
    return False


def main() -> int:
    saved_matrix = os.environ.get(MATRIX_ENV)
    saved_partial = os.environ.get(ALLOW_PARTIAL_ENV)
    try:
        both = [
            {"platform": "macos", "host": "ssh:mac", "directory": "/mac",
             "require_session_owner_redirect": True},
            {"platform": "linux", "host": "ssh:linux", "directory": "/linux"},
        ]
        os.environ[MATRIX_ENV] = json.dumps(both)
        os.environ.pop(ALLOW_PARTIAL_ENV, None)
        assert {row["platform"] for row in _matrix()} == {"macos", "linux"}

        os.environ[MATRIX_ENV] = json.dumps(both[:1])
        assert rejects(_matrix), "one platform must not masquerade as the full matrix"
        os.environ[ALLOW_PARTIAL_ENV] = "1"
        assert [row["platform"] for row in _matrix()] == ["macos"]

        valid_route = {
            "remote_sock_path": "/tmp/gui.sock",
            "session_host_socket": "/tmp/daemon.sock",
            "team_host_endpoint": "ssh:mac:/tmp/daemon.sock",
            "team_host_readiness": "ready",
        }
        assert _assert_session_owner_route(valid_route)["session_owner_socket"] == (
            "/tmp/daemon.sock"
        )
        broken_routes = (
            {**valid_route, "session_host_socket": ""},
            {**valid_route, "session_host_socket": "/tmp/gui.sock"},
            {**valid_route, "team_host_endpoint": "ssh:mac:/tmp/other.sock"},
            {**valid_route, "team_host_readiness": "unresolved"},
        )
        assert all(
            rejects(lambda row=row: _assert_session_owner_route(row))
            for row in broken_routes
        )

        state = {
            "team_name": "matrix-project",
            "project_id": "team:one",
            "leader_surface_id": "leader",
            "member_instances": {"executor": "instance"},
            "member_surfaces": {"executor": "worker"},
        }
        exact = {
            "project_id": "team:one",
            "leader_surface_id": "leader",
            "members": [{
                "name": "executor", "agent_instance_id": "instance",
                "surface_id": "worker",
            }],
        }
        assert _exact_presentation(FakeClient(projects=[exact]), "host", state) == exact
        assert _exact_presentation(
            FakeClient(projects=[{**exact, "leader_surface_id": "replacement"}]),
            "host", state,
        ) is None

        assert _fully_deleted(FakeClient(), "host", state, {"leader-pane"})
        assert not _fully_deleted(
            FakeClient(panes=["leader-pane"]), "host", state, {"leader-pane"}
        ), "a leaked relay pane must fail deletion even after team/manifest disappear"
        assert not _fully_deleted(
            FakeClient(projects=[exact]), "host", state, set()
        )
        assert not _fully_deleted(
            FakeClient(teams=[{"team_name": "matrix-project"}]),
            "host", state, set(),
        )
    finally:
        if saved_matrix is None:
            os.environ.pop(MATRIX_ENV, None)
        else:
            os.environ[MATRIX_ENV] = saved_matrix
        if saved_partial is None:
            os.environ.pop(ALLOW_PARTIAL_ENV, None)
        else:
            os.environ[ALLOW_PARTIAL_ENV] = saved_partial

    print("PASS: Project host matrix parser, route, identity, and cleanup contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
