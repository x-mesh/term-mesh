#!/usr/bin/env python3
"""A duplicate Project name is a typed conflict, never a silent open or mutation."""
from __future__ import annotations

import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def wait_for_creation(c: termmesh, operation_id: str) -> dict:
    deadline = time.monotonic() + 15
    last: dict = {}
    while time.monotonic() < deadline:
        last = c.debug_project_creation_status(operation_id)
        if last.get("state") != "running":
            return last
        time.sleep(0.1)
    raise termmeshError(f"creation attempt did not settle: {last!r}")


def wait_for_delete(c: termmesh, operation_id: str) -> None:
    deadline = time.monotonic() + 20
    last: dict = {}
    while time.monotonic() < deadline:
        last = c.debug_project_delete_status(operation_id)
        if last.get("state") == "succeeded":
            return
        if last.get("state") == "failed":
            raise termmeshError(f"Project cleanup failed: {last!r}")
        time.sleep(0.1)
    raise termmeshError(f"Project cleanup did not settle: {last!r}")


def start_and_wait(c: termmesh, name: str, directory: str) -> dict:
    attempt = c.debug_project_creation_attempt(name=name, directory=directory)
    operation_id = attempt.get("operation_id")
    if not operation_id:
        raise termmeshError(f"creation attempt did not return an operation id: {attempt!r}")
    return wait_for_creation(c, operation_id)


def assert_zero_delta(status: dict, label: str) -> None:
    for resource in (
        "team", "workspace", "participant", "owned_checkout", "process",
    ):
        before = status.get(f"before_{resource}_count")
        after = status.get(f"after_{resource}_count")
        if before != after:
            raise termmeshError(
                f"{label} changed {resource} count: {before!r}->{after!r}; {status!r}"
            )


def wait_for_zero_delta_conflict(
    c: termmesh, name: str, directory: str, label: str, timeout: float = 10
) -> dict:
    """Wait for unrelated window/process startup to settle, then sample conflict."""
    deadline = time.monotonic() + timeout
    last: dict = {}
    while time.monotonic() < deadline:
        last = start_and_wait(c, name, directory)
        if all(
            last.get(f"before_{resource}_count")
            == last.get(f"after_{resource}_count")
            for resource in (
                "team", "workspace", "participant", "owned_checkout", "process"
            )
        ):
            return last
        time.sleep(0.1)
    raise termmeshError(f"{label} never reached a stable resource snapshot: {last!r}")


def main() -> int:
    team = f"duplicate-project-e2e-{uuid.uuid4().hex[:8]}"
    directory = f"/tmp/{team}"
    with termmesh() as c:
        initial_team_count = len(c.team_list())
        initial_workspace_count = sum(
            len(c.list_workspaces(w["id"])) for w in c.list_windows()
        )
        window_id = c.current_window()
        c.request_sheet(window_id, "project")
        sheet = c.sheet_state(window_id)
        if sheet.get("active_sheet") != "project-creation":
            raise termmeshError(f"Project sheet did not open before conflict test: {sheet!r}")
        created = c.debug_project_create(
            directory=directory, roles=[], leader_cli="repl", leader_model=""
        )
        if created.get("team") != team:
            raise termmeshError(f"fixture Project was not created: {created!r}")
        try:
            before_teams = len(c.team_list())
            before_workspaces = len(c.list_workspaces())
            # Same resampling the other-window case uses: the fixture Project's
            # own leader is still settling here, so a single sample can catch a
            # process count that moves for reasons this test is not about.
            status = wait_for_zero_delta_conflict(
                c, team, directory, "same-window duplicate create"
            )
            expected = {
                "state": "conflict",
                "conflict": "exact_live",
                "action": "open_existing",
                "location": "current_window",
                "progress_state": "conflict",
                "sheet_stays_open": True,
                "shows_creation_failure_actions": False,
            }
            actual = {key: status.get(key) for key in expected}
            if actual != expected:
                raise termmeshError(
                    f"duplicate Project did not expose the explicit Open Existing conflict: "
                    f"expected={expected!r} actual={actual!r} full={status!r}"
                )
            assert_zero_delta(status, "same-window duplicate create")
            if len(c.team_list()) != before_teams or len(c.list_workspaces()) != before_workspaces:
                raise termmeshError(
                    "duplicate create changed observable state after typed conflict: "
                    f"teams {before_teams}->{len(c.team_list())}, "
                    f"workspaces {before_workspaces}->{len(c.list_workspaces())}"
                )

            other_window = c.new_window()
            c.move_workspace_to_window(created["workspace_id"], other_window, focus=False)
            other_status = wait_for_zero_delta_conflict(
                c, team, directory, "other-window duplicate create"
            )
            if other_status.get("conflict") != "exact_live" \
                    or other_status.get("action") != "open_existing" \
                    or other_status.get("location") != "other_window":
                raise termmeshError(
                    f"other-window duplicate was not explicit Open Existing: {other_status!r}"
                )
            assert_zero_delta(other_status, "other-window duplicate create")
            c.move_workspace_to_window(created["workspace_id"], window_id, focus=False)
            c.close_window(other_window)

            concurrent_team = f"concurrent-project-e2e-{uuid.uuid4().hex[:8]}"
            concurrent_dir = f"/tmp/{concurrent_team}"
            Path(concurrent_dir).mkdir(parents=True, exist_ok=True)
            base_team_count = len(c.team_list())
            base_workspace_count = sum(len(c.list_workspaces(w["id"])) for w in c.list_windows())
            first = c.debug_project_creation_attempt(concurrent_team, concurrent_dir)
            second = c.debug_project_creation_attempt(concurrent_team, concurrent_dir)
            results = [
                wait_for_creation(c, str(first["operation_id"])),
                wait_for_creation(c, str(second["operation_id"])),
            ]
            states = sorted(result.get("state") for result in results)
            if states != ["conflict", "created"]:
                raise termmeshError(
                    f"concurrent create did not yield one winner and one conflict: {results!r}"
                )
            loser = next(result for result in results if result.get("state") == "conflict")
            if loser.get("conflict") not in {"reserved", "exact_live"}:
                raise termmeshError(f"concurrent loser was not a typed name conflict: {loser!r}")
            after_team_count = len(c.team_list())
            after_workspace_count = sum(
                len(c.list_workspaces(w["id"])) for w in c.list_windows()
            )
            if after_team_count != base_team_count + 1 \
                    or after_workspace_count != base_workspace_count + 1:
                raise termmeshError(
                    "concurrent create changed resource counts by more than one: "
                    f"teams {base_team_count}->{after_team_count}, "
                    f"workspaces {base_workspace_count}->{after_workspace_count}"
                )
            concurrent_deleted = c.debug_project_delete(concurrent_team)
            wait_for_delete(c, str(concurrent_deleted["operation_id"]))
            Path(concurrent_dir).rmdir()
        finally:
            deleted = c.debug_project_delete(team)
            operation_id = deleted.get("operation_id")
            if not operation_id:
                raise termmeshError(f"fixture Project cleanup did not start: {deleted!r}")
            wait_for_delete(c, operation_id)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                final_team_count = len(c.team_list())
                final_workspace_count = sum(
                    len(c.list_workspaces(w["id"])) for w in c.list_windows()
                )
                if final_team_count == initial_team_count \
                        and final_workspace_count == initial_workspace_count:
                    break
                time.sleep(0.1)
            else:
                raise termmeshError(
                    "fixture cleanup did not restore the baseline: "
                    f"teams {initial_team_count}->{final_team_count}, "
                    f"workspaces {initial_workspace_count}->{final_workspace_count}"
                )
            if c.sheet_state(window_id).get("active_sheet") != "project-creation":
                raise termmeshError("duplicate conflict dismissed the Project sheet")
            c.dismiss_sheet(window_id)

    print(
        "PASS: same/other-window duplicates and concurrent creates keep a single explicit owner"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
