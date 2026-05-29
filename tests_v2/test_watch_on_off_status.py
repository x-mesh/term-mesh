#!/usr/bin/env python3
"""
watch.on → watch.status → watch.off lifecycle test.

Verifies:
- watch.on registers a watch state (enabled=True, target, worker_count present)
- watch.status reflects the registered config without running a check
- watch.off disables the watch (enabled=False)

watch.* RPCs target the daemon socket (term-meshd), not the app socket.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from termmesh import daemon_call, termmeshError

TEAM_ID = "e2e-watch-on-off-status"
WORKING_DIR = "/tmp"


class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = False
        self.message = ""

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg

    def failure(self, msg: str):
        self.passed = False
        self.message = msg


def _cleanup():
    try:
        daemon_call("watch.off", {"team_id": TEAM_ID})
    except Exception:
        pass


def test_watch_on_enables(wd: str) -> TestResult:
    r = TestResult("watch_on_enables_state")
    try:
        result = daemon_call("watch.on", {
            "team_id": TEAM_ID,
            "target": None,
            "workers": ["executor", "reviewer"],
            "interval_secs": 300,
            "cli": "claude",
            "model": "sonnet",
            "stance": "critic",
            "spec": "Workers must complete tasks.",
            "working_directory": wd,
        })
        if not isinstance(result, dict):
            return r.failure(f"expected dict, got {type(result).__name__}")
        if not result.get("enabled"):
            return r.failure(f"expected enabled=True in response, got {result}")
        r.success(f"watch.on returned enabled=True interval={result.get('interval_secs')}")
    except termmeshError as e:
        r.failure(f"watch.on failed: {e}")
    return r


def test_watch_status_reflects_config() -> TestResult:
    r = TestResult("watch_status_reflects_config")
    try:
        result = daemon_call("watch.status", {
            "team_id": TEAM_ID,
            "working_directory": WORKING_DIR,
        })
        watch = (result or {}).get("watch") or {}
        if not watch:
            # list form
            watches = (result or {}).get("watches") or []
            for w in watches:
                if w.get("team_id") == TEAM_ID:
                    watch = w
                    break
        if not watch:
            return r.failure(f"no watch state found for team {TEAM_ID!r}: {result}")
        if not watch.get("enabled"):
            return r.failure(f"expected enabled=True in status, got {watch.get('enabled')}")
        if watch.get("stance") != "critic":
            return r.failure(f"expected stance=critic, got {watch.get('stance')!r}")
        # R1: worker_count should be present (may be 0 before R1 daemon update)
        if "worker_count" not in watch and "workers" not in watch:
            return r.failure("worker_count/workers not in watch.status response (R1 field missing)")
        r.success(
            f"status enabled=True stance=critic "
            f"worker_count={watch.get('worker_count', '(absent)')} "
            f"workers={watch.get('workers', '(absent)')}"
        )
    except termmeshError as e:
        r.failure(f"watch.status failed: {e}")
    return r


def test_watch_off_disables() -> TestResult:
    r = TestResult("watch_off_disables")
    try:
        daemon_call("watch.off", {"team_id": TEAM_ID})
        result = daemon_call("watch.status", {
            "team_id": TEAM_ID,
            "working_directory": WORKING_DIR,
        })
        watch = (result or {}).get("watch") or {}
        if not watch:
            watches = (result or {}).get("watches") or []
            for w in watches:
                if w.get("team_id") == TEAM_ID:
                    watch = w
                    break
        if watch.get("enabled"):
            return r.failure(f"expected enabled=False after watch.off, got {watch.get('enabled')}")
        r.success("enabled=False after watch.off")
    except termmeshError as e:
        r.failure(f"watch.off/status failed: {e}")
    return r


def run_tests() -> int:
    _cleanup()

    wd = WORKING_DIR
    results = []

    print("watch.on → status → off lifecycle")
    print("=" * 50)

    print("watch.on enables watch state...")
    results.append(test_watch_on_enables(wd))
    status = "PASS" if results[-1].passed else "FAIL"
    print(f"  {status}: {results[-1].message}")

    print("watch.status reflects config...")
    results.append(test_watch_status_reflects_config())
    status = "PASS" if results[-1].passed else "FAIL"
    print(f"  {status}: {results[-1].message}")

    print("watch.off disables watch...")
    results.append(test_watch_off_disables())
    status = "PASS" if results[-1].passed else "FAIL"
    print(f"  {status}: {results[-1].message}")

    _cleanup()

    passed = sum(1 for r in results if r.passed)
    total = len(results)
    print()
    print(f"Passed: {passed}/{total}")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(run_tests())
