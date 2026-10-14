#!/usr/bin/env python3
"""Cmd-clicking a terminal link opens the embedded browser without wedging the app.

Regression: Ghostty fires open_url while it holds the clicked surface's renderer
mutex. The embedded-browser handler opened the browser synchronously, which moved
focus off the terminal and called ghostty_surface_set_focus on that same mutex, so
the main thread waited on itself forever.

Relies on the default link settings (open terminal links in the term-mesh browser,
empty host whitelist).
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

URL_PREFIX = "https://example.com/"
URL_LINE_COUNT = 80
DONE_MARKER = "LINKS_DONE"
CLICK_TIMEOUT_S = 8.0
RESPONSE_DEADLINE_S = 15.0


def call(c: termmesh, method: str, params: dict, timeout_s: float):
    """Call once; after a timeout reconnect so a late reply cannot be read as the next answer."""
    try:
        return c._call(method, params, timeout_s=timeout_s)
    except termmeshError as exc:
        if "Timed out" in str(exc):
            c.close()
            c.connect()
        raise


def wait_for(predicate, timeout_s: float, interval_s: float = 0.2):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval_s)
    return None


def main() -> int:
    with termmesh() as c:
        workspace_id = c.new_workspace(select=True)
        surfaces = (c._call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
        terminals = [s for s in surfaces if s.get("type") == "terminal"]
        if len(terminals) != 1:
            raise termmeshError(f"expected one terminal in the new workspace, got {surfaces}")
        terminal_id = str(terminals[0]["id"])

        # Build the URL from parts so the shell never sees a literal URL; zsh's
        # url-quote-magic would escape the `;` that ends the loop. send_surface
        # unescapes `\\` and `\n`, so printf's `\n` is written as `\\\\n`.
        # The done marker prints after the loop and is split on the command line
        # (`LINKS DONE`), so seeing `LINKS_DONE` means every link line is already
        # on screen and the middle row the click targets holds a link.
        c.send_surface(
            terminal_id,
            f"clear; for i in $(seq {URL_LINE_COUNT}); do printf 'https%s//example.com/%020d\\\\n' : 0; done; "
            "printf '%s_%s\\\\n' LINKS DONE\n",
        )
        expected_line = URL_PREFIX + "0" * 20

        def screen_lines() -> list:
            return [line.strip() for line in c.read_terminal_text(terminal_id).splitlines()]

        def links_printed() -> bool:
            lines = screen_lines()
            return DONE_MARKER in lines and lines.count(expected_line) >= 10

        if not wait_for(links_printed, timeout_s=15.0):
            lines = screen_lines()
            raise termmeshError(
                f"terminal did not finish printing the link lines "
                f"(links={lines.count(expected_line)}, done={DONE_MARKER in lines})"
            )

        c.activate_app()
        c.focus_surface(terminal_id)
        if not wait_for(lambda: c.is_terminal_focused(terminal_id), timeout_s=5.0):
            raise termmeshError("terminal never became focused; the click would not exercise the focus change")

        panels = c.layout_debug().get("selectedPanels") or []
        panel = next((p for p in panels if p.get("panelId") == terminal_id), None)
        frame = (panel or {}).get("paneFrame")
        if not frame:
            raise termmeshError(f"no pane frame for terminal {terminal_id}: {panels}")
        # The middle row holds a link, and 100pt from the left edge is inside it.
        x = float(frame["x"]) + min(100.0, float(frame["width"]) / 4)
        y = float(frame["y"]) + float(frame["height"]) / 2

        try:
            click = call(
                c,
                "debug.window.click",
                {"x": x, "y": y, "modifiers": "cmd"},
                timeout_s=CLICK_TIMEOUT_S,
            ) or {}
        except termmeshError as exc:
            raise termmeshError(
                f"Cmd-click on a terminal link did not return within {CLICK_TIMEOUT_S}s "
                f"(main thread blocked after open_url): {exc}"
            )
        if click.get("hit") != "GhosttyNSView":
            raise termmeshError(f"click at ({x}, {y}) missed the terminal view: {click}")

        last_error = None

        def browser_surface():
            nonlocal last_error
            try:
                listed = call(c, "surface.list", {"workspace_id": workspace_id}, timeout_s=3.0) or {}
            except termmeshError as exc:
                last_error = exc
                return None
            return next(
                (s for s in listed.get("surfaces") or [] if s.get("type") == "browser"),
                None,
            )

        browser = wait_for(browser_surface, timeout_s=RESPONSE_DEADLINE_S)
        if browser is None:
            raise termmeshError(
                f"no browser surface after Cmd-clicking a terminal link (last error: {last_error})"
            )

        url = c.get_url(str(browser["id"]))
        if not url.startswith(URL_PREFIX):
            raise termmeshError(f"browser opened {url!r}, expected a URL starting with {URL_PREFIX!r}")
        if not wait_for(lambda: not c.is_terminal_focused(terminal_id), timeout_s=5.0):
            raise termmeshError("terminal kept focus after the browser opened; the focus change never ran")

        c.close_workspace(workspace_id)

    print("PASS: Cmd-clicking a terminal link opens the embedded browser and the app stays responsive")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
