#!/usr/bin/env python3
"""A tunnel to a link that never answers must fail with ssh's own reason.

The tunnel's ssh was the only ssh in the app with no `ConnectTimeout`. Unset,
OpenSSH waits out the system TCP timeout — tens of seconds — while this side
gave up first and killed it mid-handshake, before ssh had written a word. So
the most common failure on a flaky link was also the only one that never said
why: `socketNeverAppeared(… ssh stderr: )` with an empty tail.

A unit test can pin the two constants' ORDER. Only spawning real ssh shows
which branch that ordering actually reaches, and that is the claim:

  - `outcome == "spawn_failed"` — ssh spent its own budget, reported, exited
  - `outcome == "socket_never_appeared"` — this side's deadline won, which is
    the regression, and its detail is the empty tail that made the failure
    undiagnosable

The target is 198.51.100.1 (TEST-NET-2, RFC 5737): reserved for documentation
and guaranteed not to be routed, so the connect cannot succeed and cannot be
refused quickly by something listening.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

BLACKHOLE = "198.51.100.1"


def main() -> int:
    with termmesh() as c:
        probe = c.peer_tunnel_probe(BLACKHOLE, timeout_s=90)
        if not probe.get("ok"):
            raise termmeshError(f"tunnel probe failed to run: {probe!r}")

        connect_budget = probe.get("ssh_connect_timeout_s")
        deadline = probe.get("forward_socket_deadline_s")
        if not isinstance(connect_budget, int) or not isinstance(deadline, int):
            raise termmeshError(f"probe did not report both budgets: {probe!r}")
        if connect_budget >= deadline:
            raise termmeshError(
                f"ssh's connect budget ({connect_budget}s) must expire before this "
                f"side's deadline ({deadline}s), or ssh is killed before it reports"
            )

        outcome = probe.get("outcome")
        if outcome == "connected":
            raise termmeshError(
                f"{BLACKHOLE} answered — the probe needs an unroutable target: {probe!r}"
            )
        if outcome != "spawn_failed":
            raise termmeshError(
                f"expected ssh to report its own failure (spawn_failed), got "
                f"{outcome!r}: {probe!r}"
            )

        # The point of letting ssh win the race is the sentence it writes on
        # the way out. An empty detail here is the old bug wearing the new
        # error case.
        detail = (probe.get("detail") or "").strip()
        if not detail:
            raise termmeshError(
                f"ssh exited without saying why — the diagnostic is still empty: {probe!r}"
            )

        # It must fail on ssh's clock, not ours: at or after the connect
        # budget, and before the deadline that used to kill it. The upper
        # bound is generous by a poll interval plus scheduling.
        elapsed_ms = probe.get("elapsed_ms") or 0
        if elapsed_ms < connect_budget * 1000 * 0.5:
            raise termmeshError(
                f"failed in {elapsed_ms}ms, far short of ssh's {connect_budget}s connect "
                f"budget — something other than the timeout ended it: {probe!r}"
            )
        if elapsed_ms > deadline * 1000:
            raise termmeshError(
                f"failed in {elapsed_ms}ms, past this side's {deadline}s deadline — "
                f"the deadline won the race again: {probe!r}"
            )

        print(f"PASS: a dead link fails as spawn_failed with ssh's own reason ({elapsed_ms}ms)")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
