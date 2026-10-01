#!/usr/bin/env python3
"""surface.send_turn to a terminal whose surface has not started runs once the surface starts. Regression: the turn stayed in the paste queue until the next send."""
from __future__ import annotations

import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

START_TIMEOUT_S = 10.0
# The first paste on a new surface waits up to about 4s for the shell to start.
DELIVERY_TIMEOUT_S = 15.0


def terminal_health(c: termmesh, workspace: str) -> dict:
    for row in c.surface_health(workspace):
        if row.get("type") == "terminal":
            return row
    raise termmeshError(f"workspace {workspace} has no terminal surface")


def main() -> int:
    marker = Path(tempfile.gettempdir()) / f"termmesh_send_turn_unstarted_{os.getpid()}.txt"
    marker.unlink(missing_ok=True)
    with termmesh() as c:
        original = c.current_workspace()
        workspace = c.new_workspace(select=False)
        try:
            health = terminal_health(c, workspace)
            if health.get("started") is not False:
                raise termmeshError(f"precondition: expected an unstarted terminal in an unselected workspace, got {health}")

            c._call("surface.send_turn", {
                "workspace_id": workspace,
                "surface_id": health["id"],
                "text": f"echo delivered >> {marker}",
            })
            c.select_workspace(workspace)

            deadline = time.monotonic() + START_TIMEOUT_S
            while time.monotonic() < deadline and terminal_health(c, workspace).get("started") is not True:
                time.sleep(0.1)
            if terminal_health(c, workspace).get("started") is not True:
                raise termmeshError(f"selecting the workspace did not start its terminal within {START_TIMEOUT_S}s")

            deadline = time.monotonic() + DELIVERY_TIMEOUT_S
            while time.monotonic() < deadline and not marker.exists():
                time.sleep(0.2)
            if not marker.exists():
                raise termmeshError(f"the queued turn did not run within {DELIVERY_TIMEOUT_S}s after the terminal started")
            # A replayed paste or a doubled Return would append a second line.
            time.sleep(1.0)
            runs = marker.read_text().splitlines()
            if runs != ["delivered"]:
                raise termmeshError(f"expected the queued turn to run exactly once, got {runs!r}")
        finally:
            c.select_workspace(original)
            c.close_workspace(workspace)
            marker.unlink(missing_ok=True)

    print("PASS: a turn sent before the terminal started runs once the terminal starts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
