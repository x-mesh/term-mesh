#!/usr/bin/env python3
"""
watch duplicate-name warning test (R3).

Verifies:
- watch.on with workers=[..., "executor", "executor", ...] (duplicate names) results in
  duplicate_name_warning being set in watch.status
- The duplicate is deduped in the stored workers list (only one "executor" kept)
- watch.on without duplicates leaves duplicate_name_warning absent or null

Approach: pass workers explicitly via watch.on params rather than auto-querying
team roster. This avoids needing a real headless team to be running.

watch.* RPCs target the daemon socket (term-meshd), not the app socket.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from termmesh import daemon_call, termmeshError

TEAM_ID = "e2e-watch-dup-warning"
WORKING_DIR = "/tmp"


class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = False
        self.message = ""

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg
        return self

    def failure(self, msg: str):
        self.passed = False
        self.message = msg
        return self


def _cleanup():
    try:
        daemon_call("watch.off", {"team_id": TEAM_ID})
    except Exception:
        pass


def _status() -> dict:
    result = daemon_call("watch.status", {
        "team_id": TEAM_ID,
        "working_directory": WORKING_DIR,
    })
    watch = (result or {}).get("watch") or {}
    if not watch:
        for w in (result or {}).get("watches") or []:
            if w.get("team_id") == TEAM_ID:
                return w
    return watch


def test_duplicate_workers_sets_warning() -> TestResult:
    r = TestResult("duplicate_workers_sets_warning")
    try:
        # Pass workers with a duplicate ("executor" appears twice)
        daemon_call("watch.on", {
            "team_id": TEAM_ID,
            "target": None,
            "workers": ["explorer", "executor", "reviewer", "executor"],
            "interval_secs": 300,
            "cli": "claude",
            "model": "sonnet",
            "stance": "critic",
            "spec": "Dup-name warning test spec.",
            "working_directory": WORKING_DIR,
        })
        w = _status()
        warning = w.get("duplicate_name_warning")
        workers = w.get("workers") or []
        if not warning:
            return r.failure(
                f"expected duplicate_name_warning to be set, got {warning!r}. "
                f"workers={workers}"
            )
        # Duplicate should be deduped: "executor" appears only once
        executor_count = workers.count("executor")
        if executor_count > 1:
            return r.failure(
                f"duplicate not deduped in workers list: found {executor_count} 'executor' entries"
            )
        r.success(
            f"warning set: {warning!r}; workers deduped to {len(workers)} unique names"
        )
    except termmeshError as e:
        r.failure(f"RPC error: {e}")
    return r


def test_no_duplicate_no_warning() -> TestResult:
    r = TestResult("no_duplicate_no_warning")
    try:
        # Workers with unique names — no warning expected
        daemon_call("watch.on", {
            "team_id": TEAM_ID,
            "target": None,
            "workers": ["explorer", "executor", "reviewer"],
            "interval_secs": 300,
            "cli": "claude",
            "model": "sonnet",
            "stance": "critic",
            "spec": "No-dup test spec.",
            "working_directory": WORKING_DIR,
        })
        w = _status()
        warning = w.get("duplicate_name_warning")
        # warning should be absent (null/None) when no duplicates
        if warning:
            return r.failure(
                f"expected no warning for unique workers, got {warning!r}"
            )
        r.success("duplicate_name_warning absent/null for unique workers")
    except termmeshError as e:
        r.failure(f"RPC error: {e}")
    return r


def run_tests() -> int:
    _cleanup()

    results = []

    print("watch.on duplicate-name warning (R3)")
    print("=" * 44)

    print("Duplicate workers → warning set + list deduped...")
    results.append(test_duplicate_workers_sets_warning())
    print(f"  {'PASS' if results[-1].passed else 'FAIL'}: {results[-1].message}")

    print("Unique workers → no warning...")
    results.append(test_no_duplicate_no_warning())
    print(f"  {'PASS' if results[-1].passed else 'FAIL'}: {results[-1].message}")

    _cleanup()

    passed = sum(1 for r in results if r.passed)
    total = len(results)
    print()
    print(f"Passed: {passed}/{total}")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(run_tests())
