#!/usr/bin/env python3
"""
watch.update partial-update test.

Verifies:
- watch.update patches only the supplied fields; absent fields preserve existing values
- interval_secs < MIN_WATCH_INTERVAL_SECS (30) is clamped to 30 (cost guard R2)
- stance changes propagate; cli is unchanged when not supplied (partial semantics)

watch.* RPCs target the daemon socket (term-meshd), not the app socket.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from termmesh import daemon_call, termmeshError

TEAM_ID = "e2e-watch-update-partial"
WORKING_DIR = "/tmp"
MIN_WATCH_INTERVAL = 30


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


def test_partial_update_stance_only() -> TestResult:
    r = TestResult("partial_update_stance_only")
    try:
        # Baseline: critic stance, claude cli
        daemon_call("watch.on", {
            "team_id": TEAM_ID,
            "stance": "critic",
            "cli": "claude",
            "model": "sonnet",
            "spec": "Spec for partial update test.",
            "working_directory": WORKING_DIR,
        })
        # Partial update: only stance → cli must be preserved
        daemon_call("watch.update", {
            "team_id": TEAM_ID,
            "stance": "advisor",
        })
        w = _status()
        if w.get("stance") != "advisor":
            return r.failure(f"expected stance=advisor after update, got {w.get('stance')!r}")
        if w.get("cli") != "claude":
            return r.failure(f"cli changed unexpectedly: expected claude, got {w.get('cli')!r}")
        r.success(f"stance=advisor cli=claude (preserved)")
    except termmeshError as e:
        r.failure(f"RPC error: {e}")
    return r


def test_interval_clamp_below_minimum() -> TestResult:
    r = TestResult("interval_clamp_below_minimum")
    try:
        # Set a valid interval first
        daemon_call("watch.on", {
            "team_id": TEAM_ID,
            "interval_secs": 300,
            "stance": "critic",
            "cli": "claude",
            "model": "sonnet",
            "spec": "Spec for interval clamp test.",
            "working_directory": WORKING_DIR,
        })
        # Update with interval below the 30s floor — should be clamped
        daemon_call("watch.update", {
            "team_id": TEAM_ID,
            "interval_secs": 1,
        })
        w = _status()
        actual = w.get("interval_secs")
        if actual is None:
            return r.failure("interval_secs missing from status")
        if actual < MIN_WATCH_INTERVAL:
            return r.failure(
                f"interval not clamped: expected >= {MIN_WATCH_INTERVAL}, got {actual}"
            )
        r.success(f"interval_secs={actual} (>= {MIN_WATCH_INTERVAL} floor)")
    except termmeshError as e:
        r.failure(f"RPC error: {e}")
    return r


def test_none_fields_preserved() -> TestResult:
    r = TestResult("none_fields_preserved")
    try:
        # Set known values
        daemon_call("watch.on", {
            "team_id": TEAM_ID,
            "interval_secs": 300,
            "stance": "pair",
            "cli": "codex",
            "model": "sonnet",
            "spec": "Spec for none-field test.",
            "working_directory": WORKING_DIR,
        })
        # update without stance/cli → must stay unchanged
        daemon_call("watch.update", {
            "team_id": TEAM_ID,
            "spec": "Updated spec only.",
        })
        w = _status()
        if w.get("stance") != "pair":
            return r.failure(f"stance changed unexpectedly: {w.get('stance')!r}")
        if w.get("cli") != "codex":
            return r.failure(f"cli changed unexpectedly: {w.get('cli')!r}")
        if "Updated spec only" not in (w.get("spec") or ""):
            return r.failure(f"spec not updated: {w.get('spec')!r}")
        r.success("spec updated; stance/cli preserved (partial semantics)")
    except termmeshError as e:
        r.failure(f"RPC error: {e}")
    return r


def run_tests() -> int:
    _cleanup()

    results = []

    print("watch.update partial-update semantics + interval clamp")
    print("=" * 55)

    print("Partial update (stance only, cli preserved)...")
    results.append(test_partial_update_stance_only())
    print(f"  {'PASS' if results[-1].passed else 'FAIL'}: {results[-1].message}")

    print("Interval < 30s clamped to minimum...")
    results.append(test_interval_clamp_below_minimum())
    print(f"  {'PASS' if results[-1].passed else 'FAIL'}: {results[-1].message}")

    print("None fields preserved (only spec updated)...")
    results.append(test_none_fields_preserved())
    print(f"  {'PASS' if results[-1].passed else 'FAIL'}: {results[-1].message}")

    _cleanup()

    passed = sum(1 for r in results if r.passed)
    total = len(results)
    print()
    print(f"Passed: {passed}/{total}")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(run_tests())
