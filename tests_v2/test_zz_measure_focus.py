#!/usr/bin/env python3
"""Measure how long the palette is on screen without owning input."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh


def main() -> int:
    samples = []
    with termmesh() as c:
        window_id = c.current_window()
        for _ in range(20):
            state = c.command_palette_results(window_id=window_id, limit=1)
            if state.get("visible"):
                c._call("debug.command_palette.toggle", {"window_id": window_id})
            c._call("debug.command_palette.toggle", {"window_id": window_id})
            state = c.command_palette_results(window_id=window_id, limit=1)
            samples.append(int(state.get("last_focus_wait_ms", -1)))
            c._call("debug.command_palette.toggle", {"window_id": window_id})
    ok = [s for s in samples if s >= 0]
    print(f"samples={samples}")
    if ok:
        print(f"n={len(ok)} min={min(ok)}ms max={max(ok)}ms mean={sum(ok)/len(ok):.1f}ms")
    print(f"never_focused={len([s for s in samples if s < 0])}")
    print("PASS: focus wait measured")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
