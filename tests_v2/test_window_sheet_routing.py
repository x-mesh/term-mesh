#!/usr/bin/env python3
"""Every main window owns Project/Agent Team sheets, including after the initial window closes."""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def wait_for_sheet_state(c: termmesh, window_id: str, *, active_sheet, attached: bool) -> dict:
    deadline = time.monotonic() + 8.0
    last = {}
    while time.monotonic() < deadline:
        last = c.sheet_state(window_id)
        if (
            last.get("active_sheet") == active_sheet
            and bool(last.get("attached_sheet")) is attached
        ):
            return last
        time.sleep(0.05)
    raise termmeshError(
        f"sheet state did not converge for {window_id}: "
        f"expected active_sheet={active_sheet!r}, attached={attached}; last={last}"
    )


def wait_for_coordinator(c: termmesh, window_id: str) -> dict:
    deadline = time.monotonic() + 8.0
    last = {}
    while time.monotonic() < deadline:
        last = c.sheet_state(window_id)
        if last.get("coordinator_registered") is True:
            return last
        time.sleep(0.05)
    raise termmeshError(f"sheet coordinator never registered for {window_id}: {last}")


def main() -> int:
    with termmesh() as c:
        windows = c.list_windows()
        if len(windows) != 1:
            raise termmeshError(f"expected one initial window, got {windows}")
        initial_id = str(windows[0]["id"])
        wait_for_coordinator(c, initial_id)

        secondary_id = c.new_window()
        wait_for_coordinator(c, secondary_id)

        c.request_sheet(secondary_id, "team")
        wait_for_sheet_state(
            c,
            secondary_id,
            active_sheet="team-creation",
            attached=True,
        )
        initial_state = c.sheet_state(initial_id)
        if initial_state.get("active_sheet") is not None or initial_state.get("attached_sheet"):
            raise termmeshError(
                f"addressed team sheet leaked into initial window: {initial_state}"
            )

        c.dismiss_sheet(secondary_id)
        wait_for_sheet_state(c, secondary_id, active_sheet=None, attached=False)

        c.close_window(initial_id)
        remaining = c.list_windows()
        if [str(row.get("id")) for row in remaining] != [secondary_id]:
            raise termmeshError(
                f"secondary window did not survive initial close: {remaining}"
            )

        c.request_sheet(secondary_id, "project")
        wait_for_sheet_state(
            c,
            secondary_id,
            active_sheet="project-creation",
            attached=True,
        )
        c.dismiss_sheet(secondary_id)
        wait_for_sheet_state(c, secondary_id, active_sheet=None, attached=False)

    print("PASS: every main window owns addressed Agent Team and Project sheets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
