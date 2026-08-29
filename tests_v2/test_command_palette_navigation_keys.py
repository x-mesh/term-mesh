#!/usr/bin/env python3
"""
Regression test: command palette list navigation keys.

Validates:
- Down: ArrowDown, Ctrl+N, Ctrl+J
- Up: ArrowUp, Ctrl+P, Ctrl+K
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


SOCKET_PATH = os.environ.get("TERMMESH_SOCKET", "/tmp/term-mesh-debug.sock")


def _wait_until(
    predicate,
    timeout_s: float = 4.0,
    interval_s: float = 0.05,
    message: str = "timeout",
) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise termmeshError(message)


def _palette_visible(client: termmesh, window_id: str) -> bool:
    res = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(res.get("visible"))


def _palette_selected_index(client: termmesh, window_id: str) -> int:
    res = client._call("debug.command_palette.selection", {"window_id": window_id}) or {}
    return int(res.get("selected_index") or 0)


def _has_focused_surface(client: termmesh) -> bool:
    try:
        return any(bool(row[2]) for row in client.list_surfaces())
    except Exception:
        return False


def _set_palette_visible(client: termmesh, window_id: str, visible: bool) -> None:
    if _palette_visible(client, window_id) == visible:
        return
    client._call("debug.command_palette.toggle", {"window_id": window_id})
    _wait_until(
        lambda: _palette_visible(client, window_id) == visible,
        message=f"palette visibility did not become {visible}",
    )


def _palette_result_count(client: termmesh, window_id: str) -> int:
    res = client.command_palette_results(window_id=window_id, limit=20)
    return len(res.get("results") or [])


def _palette_input_focused(client: termmesh, window_id: str) -> bool:
    res = client._call(
        "debug.command_palette.rename_input.selection", {"window_id": window_id}
    ) or {}
    return bool(res.get("focused"))


def _palette_debug_state(client: termmesh, window_id: str) -> str:
    """What the palette actually reports, for a failure that says nothing."""
    try:
        results = client.command_palette_results(window_id=window_id, limit=20)
        return (
            f"visible={_palette_visible(client, window_id)} "
            f"field_editor_focused={_palette_input_focused(client, window_id)} "
            f"search_focused={results.get('search_focused')} "
            f"rename_focused={results.get('rename_focused')} "
            f"nav_ignored_empty={results.get('nav_ignored_empty_count')} "
            f"index={_palette_selected_index(client, window_id)} "
            f"mode={results.get('mode')!r} query={results.get('query')!r} "
            f"results={len(results.get('results') or [])}"
        )
    except termmeshError as exc:
        return f"<state unreadable: {exc}>"


def _open_palette_with_query(
    client: termmesh, window_id: str, query: str, min_results: int = 1
) -> None:
    _set_palette_visible(client, window_id, False)
    _set_palette_visible(client, window_id, True)
    client.simulate_type(query)
    # Wait for the typed query itself, not just for a row count: the palette
    # opens holding every command, so `>= min_results` is already true against
    # the pre-typing list and waits for nothing.
    _wait_until(
        lambda: str(
            client.command_palette_results(window_id=window_id, limit=20).get("query") or ""
        ) == query,
        message=f"palette query never became {query!r}",
    )
    _wait_until(
        lambda: _palette_result_count(client, window_id) >= min_results,
        message=f"palette query {query!r} did not produce {min_results} result(s)",
    )
    # Every palette navigation key is an onKeyPress on the search field, so it
    # only fires while that field holds SwiftUI focus — which arrives a run
    # loop pass after the palette opens. `field_editor_focused` is not that
    # signal: it is true for any field editor holding first responder, so
    # typing lands while navigation keys are still dropped.
    _wait_until(
        lambda: bool(
            client.command_palette_results(window_id=window_id, limit=20).get("search_focused")
        ),
        message=f"palette search field never took focus: {_palette_debug_state(client, window_id)}",
    )
    _wait_until(
        lambda: _palette_selected_index(client, window_id) == 0,
        message="palette selected index did not reset to zero",
    )


def _assert_move(client: termmesh, window_id: str, combo: str, start_index: int, expected_index: int) -> None:
    _open_palette_with_query(
        client, window_id, "new", min_results=max(start_index, expected_index) + 1
    )
    # Seeding is this case's precondition, not its assertion — what is under
    # test is where `combo` moves the selection from here. A navigation key
    # can be swallowed with the palette visible, focused and populated
    # (observed: index=0 with 11 rows), so drive the selection to the start
    # index rather than sending once and hoping it landed.
    def _seeded() -> bool:
        index = _palette_selected_index(client, window_id)
        if index == start_index:
            return True
        client.simulate_shortcut("down" if index < start_index else "up")
        return False

    try:
        _wait_until(_seeded, message="seed timeout")
    except termmeshError:
        raise termmeshError(
            f"failed to seed start index {start_index} with {combo}: "
            f"{_palette_debug_state(client, window_id)}"
        )

    # Sample before sending: a key dropped for want of focus leaves no trace
    # afterwards, because focus usually arrives while the wait is still running.
    before = _palette_debug_state(client, window_id)
    client.simulate_shortcut(combo)
    try:
        _wait_until(
            lambda: _palette_visible(client, window_id)
            and _palette_selected_index(client, window_id) == expected_index,
            message="move timeout",
        )
    except termmeshError:
        raise termmeshError(
            f"{combo} did not move selection from {start_index} to {expected_index}: "
            f"before=[{before}] after=[{_palette_debug_state(client, window_id)}]"
        )


def _assert_can_navigate_past_ten_results(client: termmesh, window_id: str) -> None:
    _open_palette_with_query(client, window_id, "")

    for _ in range(12):
        client.simulate_shortcut("down")

    _wait_until(
        lambda: _palette_visible(client, window_id)
        and _palette_selected_index(client, window_id) >= 10,
        message="selection did not move past index 9 (results may be capped)",
    )


def main() -> int:
    with termmesh(SOCKET_PATH) as client:
        client.activate_app()
        time.sleep(0.2)
        client.new_workspace()
        time.sleep(0.2)

        window_id = client.current_window()
        # Isolate this test to one window so stale palettes in other windows
        # cannot steal navigation notifications.
        for row in client.list_windows():
            other_id = str(row.get("id") or "")
            if other_id and other_id != window_id:
                client.close_window(other_id)
        time.sleep(0.2)

        client.focus_window(window_id)
        client.activate_app()
        time.sleep(0.2)
        _wait_until(
            lambda: _has_focused_surface(client),
            timeout_s=5.0,
            message="no focused surface available for command palette context",
        )

        for combo in ("down", "ctrl+n", "ctrl+j"):
            _assert_move(client, window_id, combo, start_index=0, expected_index=1)

        for combo in ("up", "ctrl+p", "ctrl+k"):
            _assert_move(client, window_id, combo, start_index=1, expected_index=0)

        _assert_can_navigate_past_ten_results(client, window_id)

        _set_palette_visible(client, window_id, False)

    print("PASS: command palette navigation keys and uncapped result navigation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
