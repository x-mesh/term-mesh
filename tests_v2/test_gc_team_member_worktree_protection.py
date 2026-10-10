#!/usr/bin/env python3
"""gc keeps a running team's isolated member checkouts out of reclaim.

Regression for #712: `gc plan` marked the checkouts of a running team's members
`no_active_session`, so `gc sweep --apply` could delete a live worker's working
directory. The app now sends each member's `worktree_path` in `team.sync`, and
gc blocks those checkouts with `active_session` until the team is gone.

This test calls `gc.plan` only, never `gc.sweep`. The test daemon scans the
runner's real ~/.term-mesh/worktrees, so every assertion is limited to the
checkouts this test creates.
"""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import daemon_call, termmesh, termmeshError
from test_team_send_native_return_skip import (
    DEFAULTS_DOMAIN,
    DEFAULTS_KEY,
    FAKE_CODEX,
    _read_default,
    _restore_default,
)

TEAM_NAME = f"gc-protect-{uuid.uuid4().hex[:8]}"
REPO_NAME = "gc-protect-e2e"
ROLES = ["executor", "reviewer"]
WORKTREE_ROOT = Path.home() / ".term-mesh" / "worktrees"
CREATION_TIMEOUT_SECONDS = 180
SYNC_TIMEOUT_SECONDS = 30
GC_PLAN_TIMEOUT_SECONDS = 120
POLL_SECONDS = 0.5


def _wait(predicate: Callable[[], Any], timeout_s: float, what: str) -> Any:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(POLL_SECONDS)
    raise termmeshError(f"timed out after {timeout_s:.0f}s waiting for {what}")


def _git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(repo), "-c", "user.name=term-mesh-e2e",
         "-c", "user.email=e2e@term-mesh.invalid", *args],
        check=True, capture_output=True, text=True,
    )


def _make_repo(parent: Path) -> Path:
    # The daemon names the worktree parent after the repository and leaves it
    # behind empty, so a fixed name keeps reruns from adding one per run.
    repo = parent / REPO_NAME
    repo.mkdir()
    _git(repo, "init", "-q")
    (repo / "README").write_text("gc team member protection e2e\n")
    _git(repo, "add", "README")
    _git(repo, "commit", "-q", "-m", "init")
    return repo


def _start_project(client, repo: Path) -> str:
    started = client.debug_project_creation_attempt(
        name=TEAM_NAME, directory=str(repo), roles=ROLES,
        worker_cli="codex", isolate=True,
    )
    operation_id = str(started.get("operation_id") or "")
    if not operation_id:
        raise termmeshError(f"Project creation returned no operation id: {started!r}")
    return operation_id


def _wait_project_created(client, operation_id: str) -> None:
    def finished() -> Optional[Dict[str, Any]]:
        status = client.debug_project_creation_status(operation_id)
        return None if status.get("state") == "running" else status

    status = _wait(finished, CREATION_TIMEOUT_SECONDS, "Project creation")
    if status.get("state") != "created":
        raise termmeshError(f"Project creation did not succeed: {status!r}")


def _delete_project(client, state_only: bool) -> None:
    started = client.debug_project_delete(TEAM_NAME, state_only=state_only)
    operation_id = str(started.get("operation_id") or "")
    if not operation_id:
        raise termmeshError(f"Project deletion returned no operation id: {started!r}")

    def finished() -> Optional[Dict[str, Any]]:
        status = client.debug_project_delete_status(operation_id)
        return None if status.get("state") == "running" else status

    status = _wait(finished, 60, "Project deletion")
    if status.get("state") != "succeeded":
        raise termmeshError(f"Project deletion did not succeed: {status!r}")


def _member_worktrees(client, repo: Path) -> Dict[str, str]:
    agents = client.team_status(TEAM_NAME).get("agents") or []
    members = {
        str(agent.get("name")): os.path.realpath(str(agent["worktree_path"]))
        for agent in agents if agent.get("worktree_path")
    }
    if len(members) != len(ROLES):
        raise termmeshError(
            f"team.status did not report one isolated worktree per member: "
            f"expected {len(ROLES)} agents={agents!r}"
        )
    expected_parent = os.path.realpath(WORKTREE_ROOT / repo.name)
    for name, path in members.items():
        if os.path.dirname(path) != expected_parent or not os.path.isdir(path):
            raise termmeshError(
                f"member {name} worktree is not a daemon worktree gc scans: "
                f"path={path} expected_parent={expected_parent}"
            )
    return members


def _synced_paths() -> set:
    state = daemon_call("team.get", {}, timeout=10) or {}
    paths = set()
    for team in state.get("teams") or []:
        if team.get("team_name") != TEAM_NAME:
            continue
        for agent in team.get("agents") or []:
            path = agent.get("worktree_path")
            if isinstance(path, str) and path:
                paths.add(os.path.realpath(path))
    return paths


def _gc_candidates() -> Dict[str, Dict[str, Any]]:
    plan = daemon_call(
        "gc.plan", {"categories": ["daemon_worktrees"]}, timeout=GC_PLAN_TIMEOUT_SECONDS
    ) or {}
    for category in plan.get("categories") or []:
        if category.get("category") == "daemon_worktrees":
            return {
                os.path.realpath(str(candidate["path"])): candidate
                for candidate in category.get("candidates") or []
                if candidate.get("path")
            }
    raise termmeshError(f"gc.plan returned no daemon_worktrees category: {plan!r}")


def _assert_blocked(members: Dict[str, str], blocked: bool) -> None:
    candidates = _gc_candidates()
    for name, path in members.items():
        candidate = candidates.get(path)
        if candidate is None:
            raise termmeshError(f"gc.plan did not scan member {name} worktree: {path}")
        has_block = "active_session" in (candidate.get("blockers") or [])
        if has_block != blocked:
            state = "running" if blocked else "removed"
            raise termmeshError(
                f"member {name} worktree active_session={has_block} while the team is "
                f"{state}: blockers={candidate.get('blockers')!r} "
                f"reasons={candidate.get('reasons')!r} path={path}"
            )


def _repo_worktree_names() -> set:
    try:
        return {entry.name for entry in (WORKTREE_ROOT / REPO_NAME).iterdir() if entry.is_dir()}
    except FileNotFoundError:
        return set()


def _remove_worktrees(repo: Path, names: set) -> List[str]:
    problems = []
    for name in sorted(names):
        try:
            daemon_call("worktree.remove", {
                "repo_path": str(repo), "name": name, "force": False,
            }, timeout=30)
        except termmeshError as exc:
            problems.append(f"{name}: {exc}")
            continue
        if (WORKTREE_ROOT / REPO_NAME / name).is_dir():
            problems.append(f"{name}: worktree.remove left it in place")
    return problems


def _check_protection(client, repo: Path) -> Dict[str, str]:
    operation_id = _start_project(client, repo)
    team_present = True
    try:
        _wait_project_created(client, operation_id)
        members = _member_worktrees(client, repo)
        expected = set(members.values())
        # Separates a missing app sync from a gc that ignores it.
        _wait(lambda: expected <= _synced_paths(), SYNC_TIMEOUT_SECONDS,
              f"team.sync to carry member worktrees {sorted(expected)}")
        _assert_blocked(members, blocked=True)

        # state_only keeps the checkouts on disk, so gc can show that the
        # protection ends with the team.
        _delete_project(client, state_only=True)
        team_present = False
        _wait(lambda: not (expected & _synced_paths()), SYNC_TIMEOUT_SECONDS,
              "team.sync to drop the removed team")
        _assert_blocked(members, blocked=False)
        return members
    finally:
        # A full delete removes the checkouts later on another queue, after the
        # test has deleted the repository, and leaves them orphaned. state_only
        # leaves them for the test to remove while the repository exists.
        if team_present:
            try:
                _delete_project(client, state_only=True)
            except termmeshError as exc:
                print(f"cleanup: Project deletion failed: {exc}", file=sys.stderr)


def main() -> int:
    old_existed, old_value = _read_default()
    try:
        with tempfile.TemporaryDirectory(prefix="term-mesh-gc-protect-") as tmp:
            fake_codex = Path(tmp) / "codex"
            fake_codex.write_text(FAKE_CODEX)
            fake_codex.chmod(fake_codex.stat().st_mode | stat.S_IXUSR)
            subprocess.run(
                ["defaults", "write", DEFAULTS_DOMAIN, DEFAULTS_KEY, "-string", str(fake_codex)],
                check=True,
            )
            repo = _make_repo(Path(tmp))
            # Only this test uses REPO_NAME, so a new entry there is a checkout
            # it created, whether or not the member paths were read.
            existing = _repo_worktree_names()
            failure: Optional[BaseException] = None
            try:
                with termmesh() as client:
                    members = _check_protection(client, repo)
            except BaseException as exc:
                failure = exc
                raise
            finally:
                problems = _remove_worktrees(repo, _repo_worktree_names() - existing)
                if problems:
                    message = "cleanup left test worktrees: " + "; ".join(problems)
                    if failure is None:
                        raise termmeshError(message)
                    print(message, file=sys.stderr)
    finally:
        _restore_default(old_existed, old_value)

    print(
        f"PASS: gc blocks {len(members)} running team member worktrees with "
        f"active_session and releases them after the team is removed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
