#!/usr/bin/env python3
"""P5 render-axis regression infra: `debug.peer.read_grid` reads a surface's
currently rendered grid (viewport text + rows/cols) via the same MainActor
lease -> background-queue pattern `AutoReplyPoller.tick()` uses, so a grid
read never blocks the main thread on `ghostty_surface_read_text`. This is
meant as the foundation every future render-axis regression test (the peer
relay performance proposal's P1-P10 work) can reuse without standing up a
live 2-node peer session — "reading a remote pane's grid" is really just
reading the local surface that renders it.

Covers:
  1. Normal query on a regular local surface: echo a unique marker, poll
     read_terminal_text for it (readiness), then assert read_grid's
     grid_text also contains the marker — cross-verifying the two
     introspection paths agree on what is actually rendered.
  2. Unknown surface_id -> {"ok": False, "error": "unknown_surface"}, not an
     RPC-level exception (an unknown surface is an expected outcome here,
     not a protocol error).
  3. rows/cols are both > 0 for a live surface (a bogus 0x0 would silently
     break any future grid-diffing regression test built on top of this).
"""
import secrets
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def _wait(predicate, timeout_s: float = 10.0, interval_s: float = 0.1) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def main() -> int:
    token = secrets.token_hex(4)
    marker = f"GRIDCHK_{token}"

    with termmesh() as c:
        sid = c.new_surface(panel_type="terminal")
        c.focus_surface(sid)

        if not _wait(lambda: c.read_terminal_text(sid).strip() != "", timeout_s=10):
            raise termmeshError(f"surface {sid} shell prompt never rendered")

        c.send_surface(sid, f"echo {marker}\r")
        if not _wait(lambda: marker in c.read_terminal_text(sid), timeout_s=8):
            raise termmeshError(
                f"marker {marker!r} never echoed to the surface — setup failed "
                f"before read_grid could be exercised. screen:\n{c.read_terminal_text(sid)}"
            )

        # 1. Normal query + cross-verification against read_terminal_text.
        grid = c.read_grid(sid)
        if grid.get("ok") is not True:
            raise termmeshError(f"read_grid on a live surface returned ok!=True: {grid!r}")
        grid_text = str(grid.get("grid_text") or "")
        if marker not in grid_text:
            raise termmeshError(
                f"marker {marker!r} is present via read_terminal_text but missing "
                f"from read_grid's grid_text — the two introspection paths "
                f"disagree. grid_text:\n{grid_text}"
            )

        # 3. rows/cols validity.
        rows = grid.get("rows")
        cols = grid.get("cols")
        if not isinstance(rows, int) or rows <= 0:
            raise termmeshError(f"read_grid rows invalid: {rows!r} (full={grid!r})")
        if not isinstance(cols, int) or cols <= 0:
            raise termmeshError(f"read_grid cols invalid: {cols!r} (full={grid!r})")

        # 2. Unknown surface_id -> ok:false, not an exception.
        bogus = "00000000-0000-0000-0000-000000000000"
        missing = c.read_grid(bogus)
        if missing.get("ok") is not False:
            raise termmeshError(
                f"read_grid on a nonexistent surface_id should return ok:false, "
                f"got: {missing!r}"
            )
        if missing.get("error") != "unknown_surface":
            raise termmeshError(
                f"read_grid unknown-surface error mismatch: expected "
                f"'unknown_surface', got {missing.get('error')!r} (full={missing!r})"
            )

        try:
            c.close_surface(sid)
        except termmeshError:
            pass

    print("PASS: debug.peer.read_grid reads a live surface's grid (cross-verified "
          "against read_terminal_text, valid rows/cols) and reports ok:false + "
          "unknown_surface for a nonexistent surface_id")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
