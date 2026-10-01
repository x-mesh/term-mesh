#!/usr/bin/env python3
"""A browser command whose surface closes while it waits reports not_found. Regression: it returned success for the closed surface."""
from __future__ import annotations

import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

PAGE = b"<!doctype html><title>closed-surface</title><p>ready</p>"
BUSY_MS = 2000
CLOSE_AFTER_S = 0.5
BUSY_SCRIPT = f"(() => {{ const end = Date.now() + {BUSY_MS}; while (Date.now() < end) {{}} return 42; }})()"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)


def main() -> int:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    outcome: dict[str, object] = {}

    def busy_eval(browser: str, sent: threading.Event) -> None:
        with termmesh() as c1:
            sent.set()
            try:
                outcome["result"] = c1._call("browser.eval", {"surface_id": browser, "script": BUSY_SCRIPT})
            except termmeshError as error:
                outcome["error"] = error

    try:
        with termmesh() as c:
            browser = c.open_browser(f"http://127.0.0.1:{server.server_port}/")
            c._call("browser.wait", {"surface_id": browser, "text_contains": "ready", "timeout_ms": 10000})

            sent = threading.Event()
            worker = threading.Thread(target=busy_eval, args=(browser, sent))
            worker.start()
            if not sent.wait(15):
                raise termmeshError("the eval client did not start")
            time.sleep(CLOSE_AFTER_S)
            c.close_surface(browser)
            worker.join(30)
    finally:
        server.shutdown()

    if "result" in outcome:
        raise termmeshError(f"expected not_found for a surface closed mid-command, got success {outcome['result']!r}")
    error = outcome.get("error")
    if error is None:
        raise termmeshError("the eval client did not finish")
    if "not_found" not in str(error):
        raise termmeshError(f"expected not_found for a surface closed mid-command, got {error}")

    print("PASS: a browser command reports not_found when its surface closes while it waits")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
