#!/usr/bin/env python3
"""A program status report from a moved pane must land in the workspace that now owns it.

Regression: the Ghostty callback context keeps the workspace id the surface was
created in. After a move, OSC 7501 reports went to that old workspace, which
does not hold the panel, so the status was silently dropped.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

MOUNT_TIMEOUT_S = 15.0
REPORT_TIMEOUT_S = 10.0
POLL_INTERVAL_S = 0.2
REPORT_APP = "moved-status-probe"


def _wait(predicate, timeout_s: float) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(POLL_INTERVAL_S)
    return False


def _shell_ready(c, sid: str) -> bool:
    try:
        return bool(c.read_terminal_text(sid).strip())
    except termmeshError:
        return False


def _has_status(c, workspace: str, sid: str) -> bool:
    return any(
        str(entry.get("surface_id", "")).upper() == sid.upper()
        for entry in c.program_statuses(workspace)
    )


def main() -> int:
    with termmesh() as c:
        source_ws = c.current_workspace()
        target_ws = c.new_workspace(select=False)

        moved = c.new_split("right")
        if not _wait(lambda: _shell_ready(c, moved), MOUNT_TIMEOUT_S):
            raise termmeshError(f"shell in {moved} never drew a prompt")

        c.move_surface(moved, workspace=target_ws, focus=False)
        c.select_workspace(target_ws)

        c.send_surface(moved, f"printf '\\033]7501;state=working:app={REPORT_APP}\\033\\\\'\n")

        if not _wait(lambda: _has_status(c, target_ws, moved), REPORT_TIMEOUT_S):
            raise termmeshError(
                f"expected a program status for {moved} in its new workspace {target_ws}; "
                f"target holds {c.program_statuses(target_ws)}, source holds {c.program_statuses(source_ws)}"
            )

        c.close_surface(moved)
        c.select_workspace(source_ws)

    print("PASS: program status from a moved surface reaches its current workspace")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
