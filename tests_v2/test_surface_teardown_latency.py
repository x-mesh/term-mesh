#!/usr/bin/env python3
"""Keep main-thread socket commands responsive during resistant PTY teardown."""

import threading
import time
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


ITERATIONS = 5
READY_TIMEOUT_SECONDS = 8.0
PROBE_BUDGET_SECONDS = 1.5


def wait_for_marker(client: termmesh, surface_id: str, marker: str) -> None:
    deadline = time.monotonic() + READY_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if marker in client.read_terminal_text(surface_id):
            return
        time.sleep(0.05)
    raise termmeshError(f"HUP-resistant child did not become ready: {surface_id}")


def measure_iteration(index: int) -> float:
    marker = f"TM_TEARDOWN_READY_{index}"
    with termmesh() as setup:
        victim = setup.new_split("right")
        setup.focus_surface(victim)
        setup.send_surface(
            victim,
            "/usr/bin/python3 -c '"
            "import signal,time; "
            "signal.signal(signal.SIGHUP, signal.SIG_IGN); "
            f"print(\"{marker}\", flush=True); "
            "time.sleep(60)'\n",
        )
        wait_for_marker(setup, victim, marker)

    close_error = []
    close_started = threading.Event()

    def close_victim() -> None:
        try:
            with termmesh() as closer:
                close_started.set()
                closer.close_surface(victim)
        except Exception as exc:
            close_error.append(exc)

    close_thread = threading.Thread(target=close_victim, daemon=True)
    close_thread.start()
    if not close_started.wait(timeout=1.0):
        raise termmeshError("surface.close worker did not start")

    # surface.close schedules ghostty_surface_free on MainActor and returns.
    # Probe from another connection after that task has entered synchronous
    # teardown; the old one-second phases delayed this call for about 2.9 s.
    time.sleep(0.05)
    probe_started = time.monotonic()
    try:
        with termmesh() as probe:
            probe.list_surfaces()
        probe_seconds = time.monotonic() - probe_started
    finally:
        close_thread.join(timeout=12.0)

    if close_thread.is_alive():
        raise termmeshError(f"surface.close did not return: {victim}")
    if close_error:
        raise termmeshError(f"surface.close failed: {close_error[0]!r}")
    return probe_seconds


def main() -> int:
    samples = [measure_iteration(index) for index in range(ITERATIONS)]
    worst = max(samples)
    if worst >= PROBE_BUDGET_SECONDS:
        millis = [round(sample * 1000, 1) for sample in samples]
        raise termmeshError(
            f"main-thread probe exceeded {PROBE_BUDGET_SECONDS:.1f}s budget: {millis} ms"
        )

    millis = [round(sample * 1000, 1) for sample in samples]
    print(f"PASS: resistant surface teardown kept probes responsive: {millis} ms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
