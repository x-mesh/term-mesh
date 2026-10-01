#!/usr/bin/env python3
"""browser.eval right after browser.open_split returns promptly. Regression: the first eval on each new browser timed out after 10s."""
from __future__ import annotations

import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

PAGE = b"<!doctype html><title>eval-after-open</title><p>ready</p>"
OPENS = 2
EVAL_BOUND_S = 2.0


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
    elapsed: list[float] = []
    try:
        with termmesh() as c:
            for attempt in range(1, OPENS + 1):
                browser = c.open_browser(f"http://127.0.0.1:{server.server_port}/")
                started = time.monotonic()
                try:
                    result = c._call("browser.eval", {"surface_id": browser, "script": "1+1"}) or {}
                except termmeshError as error:
                    raise termmeshError(
                        f"open #{attempt}: browser.eval right after open failed after "
                        f"{time.monotonic() - started:.2f}s: {error}"
                    ) from error
                took = time.monotonic() - started
                if result.get("value") != 2:
                    raise termmeshError(f"open #{attempt}: expected value 2, got {result!r}")
                if took > EVAL_BOUND_S:
                    raise termmeshError(f"open #{attempt}: expected eval within {EVAL_BOUND_S}s, took {took:.2f}s")
                elapsed.append(took)
                c.close_surface(browser)
    finally:
        server.shutdown()

    timings = ", ".join(f"{t:.2f}s" for t in elapsed)
    print(f"PASS: browser.eval right after open returns on {OPENS} new browsers ({timings})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
