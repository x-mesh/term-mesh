#!/usr/bin/env python3
"""Force cleanup removes seven stale peer rows without the 25-second timeout."""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def _wait_status(client, timeout_s: float) -> dict:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        status = dict(client._call("debug.peer.shells.status", {}) or {})
        if not status.get("pending"):
            return status
        time.sleep(0.05)
    raise termmeshError("peer shell cleanup status timed out")


def main() -> int:
    with termmesh() as client:
        client._call("debug.peer.shells.fixture", {"stale_count": 7})
        fixture = _wait_status(client, 15)
        if not fixture.get("ok"):
            raise termmeshError(f"fixture failed: {fixture!r}")
        host = fixture["host"]
        stale = list(fixture["surface_ids"])
        survivor = fixture["survivor_id"]

        started = time.monotonic()
        client._call(
            "debug.peer.shells.close",
            {"host": host, "surface_ids": stale, "force": True},
        )
        closed = _wait_status(client, 10)
        elapsed = time.monotonic() - started
        if not closed.get("ok") or closed.get("closed") != 7:
            raise termmeshError(f"force cleanup failed after {elapsed:.3f}s: {closed!r}")
        if elapsed >= 10:
            raise termmeshError(f"force cleanup was too slow: {elapsed:.3f}s")

        client._call("debug.peer.shells.inspect", {"host": host})
        inspected = _wait_status(client, 10)
        if not inspected.get("ok"):
            raise termmeshError(f"post-cleanup inspect failed: {inspected!r}")
        remaining = {item["id"] for item in inspected.get("items", [])}
        if remaining != {survivor}:
            raise termmeshError(
                f"expected only survivor after force cleanup; remaining={remaining!r}"
            )

    print("PASS: force cleanup removes seven stale rows without a 25s timeout")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
