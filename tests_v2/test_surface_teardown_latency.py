#!/usr/bin/env python3
"""Bound the synchronous surface free, and keep other socket commands answering
while it runs.

Closing a pane calls `ghostty_surface_free` on the main actor, and that call
blocks until Ghostty joins the surface's renderer and IO threads. Two children
make the join wait out a kill deadline, and each workload pins one of them:

  * `ignore` ignores SIGHUP and SIGTERM. Ghostty sees that the group leader
    ignores SIGHUP and moves straight to SIGTERM, so this waits out
    `sigterm_grace` before SIGKILL. Ignoring SIGHUP alone is not enough: SIGTERM
    then ends the child in a few milliseconds.
  * `slow_hup` handles SIGHUP but takes seconds to finish, like a Claude
    `SessionEnd` hook. Ghostty waits out `sighup_grace` before SIGKILL, so this
    is the only workload that fails if that grace returns to upstream's 12 s.

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

import os
import signal
import subprocess
import threading
import time
import uuid
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


ITERATIONS = 5
READY_TIMEOUT_SECONDS = 8.0
FREE_COUNT_QUIET_SECONDS = 1.0
CHILD_EXIT_SECONDS = 2.0

# The floor proves the resistant path actually ran. The workloads wait out the
# 250 ms SIGTERM grace or the 200 ms SIGHUP grace before SIGKILL, and a free
# that skipped them returns in about 30 ms. 150 ms sits well clear of both.
# The ceiling is what keeps the fork's shorter `KillTimeouts` defaults: upstream's
# 12 s `sighup_grace` puts `slow_hup` far above it. Revisit both numbers if the
# defaults change; see docs/ghostty-fork.md.
MIN_FREE_MS = 150.0
MAX_FREE_MS = 1_500.0

# Python runs the handler between bytecodes, so it interrupts the long sleep
# and holds the process past any grace below a few seconds.
WORKLOADS = {
    "ignore": (
        "signal.signal(signal.SIGHUP, signal.SIG_IGN); "
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
    ),
    "slow_hup": (
        "signal.signal(signal.SIGHUP, lambda *_: (time.sleep(5), sys.exit(0))); "
    ),
}

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


def assert_free_count_stays_exactly_one(
    client: termmesh,
    surface_id: str,
    baseline_started: int,
    baseline_completed: int,
) -> dict:
    """Observe the post-close window where a stale view update used to
    realize a second Ghostty surface under the same TerminalSurface id."""
    deadline = time.monotonic() + FREE_COUNT_QUIET_SECONDS
    latest: dict = {}
    while time.monotonic() < deadline:
        latest = client.surface_free_status(surface_id)
        started_delta = int(latest.get("started_count") or 0) - baseline_started
        completed_delta = int(latest.get("completed_count") or 0) - baseline_completed
        if started_delta != 1 or completed_delta != 1:
            raise termmeshError(
                "closing one terminal must free exactly one ghostty surface: "
                f"started={started_delta}, completed={completed_delta}"
            )
        time.sleep(0.01)
    return latest


def child_pid(token: str) -> str:
    """The token is only in the child's argv. `/usr/bin/python3` is a shim
    that briefly shares that argv while it starts the real interpreter, so
    wait until one process remains."""
    deadline = time.monotonic() + READY_TIMEOUT_SECONDS
    pids: list[str] = []
    while time.monotonic() < deadline:
        pids = subprocess.run(
            ["pgrep", "-f", token], capture_output=True, text=True
        ).stdout.split()
        if len(pids) == 1:
            return pids[0]
        time.sleep(0.05)
    raise termmeshError(f"expected one child for {token}, found {pids}")


def process_alive(pid: str) -> bool:
    return subprocess.run(["ps", "-p", pid], capture_output=True).returncode == 0


def start_resistant_pane(workload: str) -> tuple[str, str]:
    """Open a split whose child resists teardown as `WORKLOADS[workload]`
    describes, so its free must wait out a grace deadline and end in SIGKILL.
    Returns (surface, pid)."""
    # The shell echoes the typed command, so the marker is assembled at run
    # time; a marker that appears verbatim in the command line is matched
    # before the child has installed its handlers.
    token = uuid.uuid4().hex
    with termmesh() as setup:
        victim = setup.new_split("right")
        setup.focus_surface(victim)
        setup.send_surface(
            victim,
            "/usr/bin/python3 -c '"
            "import signal,sys,time; "
            f"{WORKLOADS[workload]}"
            'print("TM_TEARDOWN_READY_" + sys.argv[1], flush=True); '
            f"time.sleep(60)' {token}\n",
        )
        wait_for_marker(setup, victim, f"TM_TEARDOWN_READY_{token}")
    return victim, child_pid(token)


def measure_iteration(workload: str) -> tuple[float, float]:
    """Return (free duration ms, probe latency seconds)."""
    victim, pid = start_resistant_pane(workload)

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

        wait_for_count(observer, victim, "completed_count", baseline_completed)
        close_thread.join(timeout=12.0)
        status = assert_free_count_stays_exactly_one(
            observer, victim, baseline_started, baseline_completed
        )

    if close_thread.is_alive():
        raise termmeshError(f"surface.close did not return: {victim}")
    if close_error:
        raise termmeshError(f"surface.close failed: {close_error[0]!r}")

    # A free that returns while the child lives has bounded nothing. The child
    # sits in the terminal's foreground group, which differs from the group of
    # the direct child (`login`) once the shell uses job control.
    deadline = time.monotonic() + CHILD_EXIT_SECONDS
    while process_alive(pid) and time.monotonic() < deadline:
        time.sleep(0.01)
    if process_alive(pid):
        os.kill(int(pid), signal.SIGKILL)
        raise termmeshError(f"child {pid} survived the surface free: {victim}")

    # The close path is terminal, so this id must not realize another surface
    # before deinit. max_duration_ms remains the stable duration field exposed
    # by the shared DEBUG telemetry.
    duration_ms = status.get("max_duration_ms")
    if duration_ms is None:
        raise termmeshError("surface free completed without a duration")
    return float(duration_ms), probe_seconds


def check_workload(workload: str) -> str:
    frees: list[float] = []
    probes: list[float] = []
    for _ in range(ITERATIONS):
        free_ms, probe_seconds = measure_iteration(workload)
        frees.append(free_ms)
        probes.append(probe_seconds)

    free_report = [round(value, 1) for value in frees]
    probe_report = [round(value * 1000, 1) for value in probes]

    if min(frees) < MIN_FREE_MS:
        raise termmeshError(
            f"{workload}: a free returned faster than {MIN_FREE_MS:.0f} ms, so "
            f"the resistant path did not run and this test proved nothing: "
            f"{free_report} ms"
        )
    if max(frees) >= MAX_FREE_MS:
        raise termmeshError(
            f"{workload}: surface free exceeded {MAX_FREE_MS:.0f} ms: "
            f"{free_report} ms"
        )
    if max(probes) >= PROBE_BUDGET_SECONDS:
        raise termmeshError(
            f"{workload}: main-thread command exceeded "
            f"{PROBE_BUDGET_SECONDS:.1f}s during teardown: {probe_report} ms "
            f"(frees {free_report} ms)"
        )
    return f"{workload} frees {free_report} ms, probes {probe_report} ms"


def main() -> int:
    reports = [check_workload(workload) for workload in WORKLOADS]
    print("PASS: resistant surface frees stayed bounded; " + "; ".join(reports))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
