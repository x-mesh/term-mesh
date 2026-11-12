#!/usr/bin/env python3
"""A shell that exits must close its pane even after the pane moved to another workspace.

Regression: the Ghostty callback context keeps the workspace id the surface was
created in. After a move, the child-exit action looked the panel up in that old
workspace, found nothing, and dropped the close. The pane stayed open with no
shell behind it (seen on a relay host as a pane that took input and never
answered).
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

MOUNT_TIMEOUT_S = 15.0
CLOSE_TIMEOUT_S = 10.0
POLL_INTERVAL_S = 0.2


def _wait(predicate, timeout_s: float) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(POLL_INTERVAL_S)
    return False


def _surface_ids(c, workspace: str) -> set:
    return {sid for _, sid, _ in c.list_surfaces(workspace)}


def _shell_ready(c, sid: str) -> bool:
    try:
        return bool(c.read_terminal_text(sid).strip())
    except termmeshError:
        return False


def main() -> int:
    with termmesh() as c:
        source_ws = c.current_workspace()
        target_ws = c.new_workspace(select=False)

        moved = c.new_split("right")
        if not _wait(lambda: _shell_ready(c, moved), MOUNT_TIMEOUT_S):
            raise termmeshError(f"shell in {moved} never drew a prompt")

        c.move_surface(moved, workspace=target_ws, focus=False)
        if moved not in _surface_ids(c, target_ws):
            raise termmeshError(f"move failed: {moved} not in target workspace {target_ws}")
        c.select_workspace(target_ws)

        c.send_surface(moved, "exit\n")

        def closed() -> bool:
            return moved not in _surface_ids(c, target_ws) and moved not in _surface_ids(c, source_ws)

        if not _wait(closed, CLOSE_TIMEOUT_S):
            raise termmeshError(
                f"expected {moved} to close after its shell exited; "
                f"target workspace still has {sorted(_surface_ids(c, target_ws))}"
            )

        c.select_workspace(source_ws)

    print("PASS: child exit closes a surface that was moved to another workspace")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
