#!/usr/bin/env python3
"""
End-to-end test for sidebar CWD + git branch updates.

This specifically covers the regression where the sidebar directory can get
stuck (e.g. showing "~" even after multiple `cd`s).

Run with a tagged instance to avoid unix socket conflicts:
  TERMMESH_TAG=<tag> python3 tests_v2/test_sidebar_cwd_git.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Add the directory containing termmesh.py to the path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from termmesh import termmesh, termmeshError  # noqa: E402


def _parse_sidebar_state(text: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for raw in (text or "").splitlines():
        line = raw.rstrip("\n")
        if not line or line.startswith("  "):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip()
    return data


def _wait_for(predicate, timeout: float, interval: float, label: str):
    start = time.time()
    last_error: Exception | None = None
    while time.time() - start < timeout:
        try:
            value = predicate()
            if value:
                return value
        except Exception as e:
            last_error = e
        time.sleep(interval)
    if last_error is not None:
        raise AssertionError(f"Timed out waiting for {label}. Last error: {last_error}")
    raise AssertionError(f"Timed out waiting for {label}.")


def _wait_for_state_field(
    client: termmesh,
    key: str,
    expected: str,
    timeout: float = 6.0,
    interval: float = 0.1,
) -> dict[str, str]:
    def pred():
        state = _parse_sidebar_state(client.sidebar_state())
        actual = state.get(key)
        if key in {"cwd", "focused_cwd"} and actual:
            return state if str(Path(actual).resolve()) == str(Path(expected).resolve()) else None
        return state if actual == expected else None

    return _wait_for(pred, timeout=timeout, interval=interval, label=f"{key}={expected!r}")


def _wait_for_git_branch(
    client: termmesh,
    expected: str,
    timeout: float = 12.0,
    interval: float = 0.15,
) -> dict[str, str]:
    def pred():
        state = _parse_sidebar_state(client.sidebar_state())
        raw = state.get("git_branch", "")
        branch = raw.split(" ", 1)[0]  # "main dirty" -> "main", "none" -> "none"
        return state if branch == expected else None

    return _wait_for(pred, timeout=timeout, interval=interval, label=f"git_branch={expected!r}")


def _git(cwd: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=str(cwd), check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _init_git_repo(repo: Path) -> None:
    repo.mkdir(parents=True, exist_ok=True)
    _git(repo, "init")
    _git(repo, "config", "user.email", "termmesh-test@example.com")
    _git(repo, "config", "user.name", "termmesh-test")
    (repo / "README.md").write_text("hello\n", encoding="utf-8")
    _git(repo, "add", "README.md")
    _git(repo, "commit", "-m", "init")
    # Normalize the initial branch to "main" so the test is deterministic.
    branch = subprocess.check_output(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=str(repo)
    ).decode("utf-8", errors="replace").strip()
    if branch and branch != "main":
        _git(repo, "branch", "-m", "main")


def _send_cd_and_wait(
    client: termmesh,
    target: Path,
    attempts: int = 3,
    timeout: float = 6.0,
    interval: float = 0.1,
) -> dict[str, str]:
    expected = str(target.resolve())
    last_error: AssertionError | None = None
    for _ in range(attempts):
        client.send(f"cd {target}\n")
        try:
            return _wait_for_state_field(client, "cwd", expected, timeout=timeout, interval=interval)
        except AssertionError as e:
            last_error = e
            time.sleep(0.15)

    raise last_error or AssertionError(f"Timed out waiting for cwd={expected!r}")


def main() -> int:
    tag = os.environ.get("TERMMESH_TAG") or os.environ.get("TERMMESH_TAG") or ""
    if not tag:
        print("Tip: set TERMMESH_TAG=<tag> when running this test to avoid socket conflicts.")

    base = Path("/tmp") / f"termmesh_sidebar_test_{os.getpid()}"
    repo = base / "repo"
    other = base / "other"

    try:
        if base.exists():
            shutil.rmtree(base)
        other.mkdir(parents=True, exist_ok=True)
        _init_git_repo(repo)

        with termmesh() as client:
            new_tab_id = client.new_tab()
            client.select_tab(new_tab_id)
            time.sleep(0.6)

            # Initial: sync via `pwd` to a file, then wait for sidebar_state cwd.
            marker = base / "pwd.txt"
            client.send(f"pwd > {marker}\n")
            _wait_for(lambda: marker.exists(), timeout=4.0, interval=0.1, label="pwd marker file")
            expected_pwd = str(Path(marker.read_text(encoding="utf-8").strip()).resolve())
            _wait_for_state_field(client, "cwd", expected_pwd)

            # Multiple cd's: ensure cwd tracks changes.
            _send_cd_and_wait(client, other)
            _wait_for_git_branch(client, "none")

            _send_cd_and_wait(client, repo)
            _wait_for_git_branch(client, "main")

            # Branch change should update.
            # Cover alias/non-`git ...` command paths too (regression: branch could
            # stick for ~3s when switching via alias/tools like `gh pr checkout`).
            client.send("alias gco='git checkout'\n")
            time.sleep(0.2)
            client.send("gco -b feature/sidebar\n")
            _wait_for_git_branch(client, "feature/sidebar")

            client.send("gco main\n")
            _wait_for_git_branch(client, "main")

            # Leaving the repo should clear the branch.
            _send_cd_and_wait(client, other)
            _wait_for_git_branch(client, "none")

            try:
                client.close_tab(new_tab_id)
            except Exception:
                pass

        print("Sidebar CWD + git branch test passed.")
        return 0

    except (termmeshError, subprocess.CalledProcessError, AssertionError) as e:
        print(f"Sidebar CWD + git branch test failed: {e}")
        return 1
    finally:
        try:
            shutil.rmtree(base)
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
