#!/usr/bin/env python3
"""Opening the palette hands it input focus before the command returns.

This pins the command's contract, not any one mechanism behind it. The
palette used to be on screen while input still went to whatever held focus
before it, so everything sent right after the open was lost — typing, and
every navigation key, since each one is an onKeyPress on the search field.
The AppKit first responder is moved by the overlay's own async focus work
and its 80ms timer, so what makes this assertion hold is the open command
waiting for that to happen. A change that stops it waiting fails here.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def _palette_state(c: termmesh, window_id: str) -> dict:
    return c.command_palette_results(window_id=window_id, limit=1)


def main() -> int:
    with termmesh() as c:
        window_id = c.current_window()

        state = _palette_state(c, window_id)
        if state.get("visible"):
            c._call("debug.command_palette.toggle", {"window_id": window_id})

        opened = c._call("debug.command_palette.toggle", {"window_id": window_id}) or {}
        if opened.get("input_focus_ready") is False:
            raise termmeshError(f"open command gave up waiting for input focus: {opened!r}")

        # No polling: the very first query after the command returns must
        # already show the palette owning input. An open that returns before
        # focus has moved fails here.
        state = _palette_state(c, window_id)
        if not state.get("visible"):
            raise termmeshError(f"palette did not open: {state!r}")
        if not state.get("first_responder_in_palette"):
            raise termmeshError(
                "palette did not own input focus on the first query after opening: "
                f"{state!r}"
            )

        c._call("debug.command_palette.toggle", {"window_id": window_id})

    print("PASS: opening the command palette gives it input focus before returning")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
