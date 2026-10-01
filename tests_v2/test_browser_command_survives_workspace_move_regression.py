#!/usr/bin/env python3
"""A browser command whose workspace moves to another window while it waits still succeeds. Regression: the post-command check looked only at the original window and reported not_found."""
from __future__ import annotations

import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

PAGE = b"<!doctype html><title>moved-workspace</title><p>ready</p>"
BUSY_MS = 2000
STARTED = threading.Event()
# The script tells the server it is running, so the move happens while the command waits.
BUSY_SCRIPT = (
    "(() => { const r = new XMLHttpRequest(); r.open('GET', '/started', false); r.send(); "
    f"const end = Date.now() + {BUSY_MS}; while (Date.now() < end) {{}} return 42; }})()"
)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        body = PAGE
        if self.path.startswith("/started"):
            STARTED.set()
            body = b"ok"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> int:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    outcome: dict[str, object] = {}

    def busy_eval(browser: str) -> None:
        with termmesh() as c1:
            try:
                outcome["result"] = c1._call("browser.eval", {"surface_id": browser, "script": BUSY_SCRIPT})
            except termmeshError as error:
                outcome["error"] = error

    window = None
    try:
        with termmesh() as c:
            original = c.current_workspace()
            workspace = c.new_workspace()
            browser = c.open_browser(f"http://127.0.0.1:{server.server_port}/")
            c._call("browser.wait", {"surface_id": browser, "text_contains": "ready", "timeout_ms": 10000})
            window = c.new_window()

            worker = threading.Thread(target=busy_eval, args=(browser,))
            worker.start()
            if not STARTED.wait(15):
                raise termmeshError("the busy script never started in the page")
            c.move_workspace_to_window(workspace, window, focus=False)
            worker.join(30)

            c.select_workspace(original)
            c.close_window(window)
            window = None
    finally:
        if window is not None:
            try:
                with termmesh() as c:
                    c.close_window(window)
            except termmeshError:
                pass
        server.shutdown()

    if "error" in outcome:
        raise termmeshError(f"expected success after the workspace moved windows, got {outcome['error']}")
    result = outcome.get("result")
    if not isinstance(result, dict) or result.get("value") != 42:
        raise termmeshError(f"expected value 42 after the workspace moved windows, got {result!r}")

    print("PASS: a browser command succeeds when its workspace moves to another window mid-command")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
