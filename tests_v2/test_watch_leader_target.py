#!/usr/bin/env python3
"""
leader-as-watch-target (v0.139.0): worker 없는 팀에서 /watch가 leader pane을 감시.

Verifies the daemon watch.on target resolution for the leader fallback
(`apply_leader_watch_fallback`, daemon/term-meshd/src/socket.rs):

- fallback (D1): `--target all` with zero workers AND a GUI leader pane
  (app_socket_path present) resolves the watch target to ["leader"].
- explicit: `--target leader` resolves to a single "leader" target.
- regression (D1): when real workers are present, "leader" is never injected —
  a multi-member team must never watch the leader.
- headless (D6): no GUI leader pane (no app_socket_path) → no fallback; the
  watch is left with zero targets rather than a fabricated "leader".

daemon-only: watch.* RPCs target term-meshd, not the app socket. app_socket_path
is only a *presence* signal here (a nonexistent path still proves the GUI-leader
gate); reachability is not required for target resolution.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from termmesh import daemon_call, termmeshError

WD = "/tmp"
# Intentionally nonexistent: presence (not reachability) is what gates the fallback.
GUI_SOCK = "/tmp/e2e-leader-fallback-nogui.sock"

TEAMS = {
    "fallback": "e2e-leader-fallback",
    "explicit": "e2e-leader-explicit",
    "regress": "e2e-leader-regress",
    "headless": "e2e-leader-headless",
}

results = []


def _status(team_id: str) -> dict:
    res = daemon_call("watch.status", {"team_id": team_id, "working_directory": WD})
    if not isinstance(res, dict):
        return {}
    watch = res.get("watch") or {}
    if not watch:
        for w in res.get("watches") or []:
            if isinstance(w, dict) and w.get("team_id") == team_id:
                watch = w
                break
    if not watch and res.get("team_id") == team_id:
        watch = res  # status returned the state object directly
    return watch or {}


def _on(team_id: str, target, workers=None, app_socket=None):
    params = {
        "team_id": team_id,
        "target": target,
        "interval_secs": 300,
        "cli": "claude",
        "model": "sonnet",
        "stance": "critic",
        "spec": "Leader must stay on the stated task.",
        "working_directory": WD,
    }
    if workers is not None:
        params["workers"] = workers
    if app_socket is not None:
        params["app_socket_path"] = app_socket
    return daemon_call("watch.on", params)


def _off(team_id: str):
    try:
        daemon_call("watch.off", {"team_id": team_id})
    except Exception:
        pass


def check(name: str, cond: bool, detail: str):
    results.append((name, bool(cond)))
    print(f"  {'PASS' if cond else 'FAIL'}: {name} — {detail}")


def main() -> int:
    for t in TEAMS.values():
        _off(t)

    print("leader-as-watch-target daemon fallback")
    print("=" * 50)

    # 1) all-target + zero workers + GUI leader present → ["leader"]
    _on(TEAMS["fallback"], target=None, app_socket=GUI_SOCK)
    w = _status(TEAMS["fallback"])
    workers = w.get("workers") or []
    check(
        "fallback_all_resolves_to_leader",
        workers == ["leader"] and w.get("worker_count") == 1,
        f"workers={workers} worker_count={w.get('worker_count')} target={w.get('target')!r}",
    )

    # 2) explicit --target leader → single "leader" target
    _on(TEAMS["explicit"], target="leader")
    w = _status(TEAMS["explicit"])
    check(
        "explicit_target_leader",
        w.get("target") == "leader" and (w.get("workers") or []) == ["leader"],
        f"target={w.get('target')!r} workers={w.get('workers')}",
    )

    # 3) D1 regression: real workers present → "leader" never injected
    _on(TEAMS["regress"], target=None, workers=["executor", "reviewer"], app_socket=GUI_SOCK)
    w = _status(TEAMS["regress"])
    workers = w.get("workers") or []
    check(
        "workers_present_no_leader",
        "leader" not in workers and set(workers) == {"executor", "reviewer"},
        f"workers={workers}",
    )

    # 4) D6: no GUI leader (no app_socket) → no fallback, zero targets
    _on(TEAMS["headless"], target=None)
    w = _status(TEAMS["headless"])
    workers = w.get("workers") or []
    check(
        "headless_no_fallback",
        "leader" not in workers,
        f"workers={workers} worker_count={w.get('worker_count')}",
    )

    for t in TEAMS.values():
        _off(t)

    passed = sum(1 for _, c in results if c)
    total = len(results)
    print()
    print(f"Passed: {passed}/{total}")
    if passed == total:
        print("PASS: leader-as-watch-target daemon fallback resolves correctly")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
