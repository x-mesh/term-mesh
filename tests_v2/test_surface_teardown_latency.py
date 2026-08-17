#!/usr/bin/env python3
"""Bound the synchronous surface free, and keep other socket commands answering
while it runs.

Closing a pane calls `ghostty_surface_free` on the main actor, and that call
blocks until Ghostty joins the surface's renderer and IO threads. When the pane's
child ignores SIGHUP the join waits out the fork's bounded kill deadlines, so this
is the workload that turns a close into a visible UI freeze.

Two properties matter and this test asserts both:

  * the free itself stays inside a known range — the cause,
  * a command issued on another connection still answers during it — the symptom
    a user actually feels.

An earlier version asserted only the second, and could pass without measuring
anything: `surface.close` merely schedules the free and returns in about a
millisecond, so a fixed sleep before probing was a guess about when the blocking
window opened. Probing too early recorded a short value that satisfied the budget.
The fix is to stop guessing — `debug.surface_free.status` reports when the free
starts, and that query is answered off-main so it works while the main thread is
blocked.
"""

import threading
import time
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


ITERATIONS = 5
READY_TIMEOUT_SECONDS = 8.0

# The floor proves the resistant path actually ran. With the fork's current
# deadlines a HUP-ignoring child costs one grace period plus one force period
# (20 attempts x 10 ms each, so about 400 ms), and a free that skipped that path
# returns in single-digit milliseconds. 150 ms sits well clear of both. Revisit
# this number if those deadlines change; see docs/ghostty-fork.md.
MIN_FREE_MS = 150.0
MAX_FREE_MS = 1_500.0

# What a user waits for: another command must answer while the free blocks main.
# Held under the app's own 2 s main-thread command budget with margin.
PROBE_BUDGET_SECONDS = 1.5


def wait_for_marker(client: termmesh, surface_id: str, marker: str) -> None:
    deadline = time.monotonic() + READY_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if marker in client.read_terminal_text(surface_id):
            return
        time.sleep(0.05)
    raise termmeshError(f"HUP-resistant child did not become ready: {surface_id}")


def wait_for_count(
    client: termmesh, surface_id: str, key: str, baseline: int
) -> dict:
    deadline = time.monotonic() + READY_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        status = client.surface_free_status(surface_id)
        if int(status.get(key) or 0) > baseline:
            return status
        time.sleep(0.005)
    raise termmeshError(f"{key} never advanced past {baseline}: {surface_id}")


def start_resistant_pane(index: int) -> str:
    """Open a split whose child ignores SIGHUP, so its free must wait out the
    fork's grace and force deadlines rather than exiting on the first signal."""
    marker = f"TM_TEARDOWN_READY_{index}"
    with termmesh() as setup:
        victim = setup.new_split("right")
        setup.focus_surface(victim)
        setup.send_surface(
            victim,
            "/usr/bin/python3 -c '"
            "import signal,time; "
            "signal.signal(signal.SIGHUP, signal.SIG_IGN); "
            f'print("{marker}", flush=True); '
            "time.sleep(60)'\n",
        )
        wait_for_marker(setup, victim, marker)
    return victim


def measure_iteration(index: int) -> tuple[float, float]:
    """Return (free duration ms, probe latency seconds)."""
    victim = start_resistant_pane(index)

    with termmesh() as observer:
        baseline = observer.surface_free_status(victim)
        baseline_started = int(baseline.get("started_count") or 0)
        baseline_completed = int(baseline.get("completed_count") or 0)

        # Close from its own connection so this one stays free to observe. The
        # call returns as soon as the free is scheduled.
        close_error: list[BaseException] = []

        def close_victim() -> None:
            try:
                with termmesh() as closer:
                    closer.close_surface(victim)
            except BaseException as exc:  # noqa: BLE001 - reported below
                close_error.append(exc)

        close_thread = threading.Thread(target=close_victim, daemon=True)
        close_thread.start()

        # Wait for the free to actually begin instead of sleeping a guess.
        wait_for_count(observer, victim, "started_count", baseline_started)

        # Main is now inside pthread_join. A command that needs it must still
        # answer within budget.
        probe_started = time.monotonic()
        with termmesh() as probe:
            probe.list_surfaces()
        probe_seconds = time.monotonic() - probe_started

        status = wait_for_count(observer, victim, "completed_count", baseline_completed)
        close_thread.join(timeout=12.0)

    if close_thread.is_alive():
        raise termmeshError(f"surface.close did not return: {victim}")
    if close_error:
        raise termmeshError(f"surface.close failed: {close_error[0]!r}")

    started_delta = int(status.get("started_count") or 0) - baseline_started
    completed_delta = int(status.get("completed_count") or 0) - baseline_completed
    if started_delta != 1 or completed_delta != 1:
        raise termmeshError(
            "expected exactly one free for this surface, got "
            f"started={started_delta}, completed={completed_delta}"
        )

    duration_ms = status.get("last_duration_ms")
    if duration_ms is None:
        raise termmeshError("surface free completed without a duration")
    return float(duration_ms), probe_seconds


def main() -> int:
    frees: list[float] = []
    probes: list[float] = []
    for index in range(ITERATIONS):
        free_ms, probe_seconds = measure_iteration(index)
        frees.append(free_ms)
        probes.append(probe_seconds)

    free_report = [round(value, 1) for value in frees]
    probe_report = [round(value * 1000, 1) for value in probes]

    if min(frees) < MIN_FREE_MS:
        raise termmeshError(
            f"a free returned faster than {MIN_FREE_MS:.0f} ms, so the "
            f"HUP-resistant path did not run and this test proved nothing: "
            f"{free_report} ms"
        )
    if max(frees) >= MAX_FREE_MS:
        raise termmeshError(
            f"surface free exceeded {MAX_FREE_MS:.0f} ms: {free_report} ms"
        )
    if max(probes) >= PROBE_BUDGET_SECONDS:
        raise termmeshError(
            f"main-thread command exceeded {PROBE_BUDGET_SECONDS:.1f}s during "
            f"teardown: {probe_report} ms (frees {free_report} ms)"
        )

    print(
        "PASS: resistant surface free stayed bounded "
        f"({free_report} ms) and commands kept answering ({probe_report} ms)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
