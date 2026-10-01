#!/usr/bin/env python3
"""A browser.wait returns when its condition holds, even while another client's browser.wait is pending. Regression: the later wait ran inside the earlier one and held it until the later wait timed out."""
from __future__ import annotations

import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

PAGE = b"<!doctype html><title>wait-order</title><p>ready</p>"
READY_AFTER_S = 1.0
SECOND_START_DELAY_S = 0.3
SECOND_TIMEOUT_MS = 3000
FIRST_BOUND_S = 2.5


# The condition reads the server's clock: WebKit throttles timers in the runner's hidden page
# to about once a second, and page globals set right after open did not always survive.
READY_AT = {"monotonic": float("inf")}
READY_CONDITION = (
    "(() => { const r = new XMLHttpRequest(); r.open('GET', '/ready', false); r.send(); "
    "return r.responseText === 'yes'; })()"
)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path.startswith("/ready"):
            body = b"yes" if time.monotonic() >= READY_AT["monotonic"] else b"no"
            content_type = "text/plain"
        else:
            body = PAGE
            content_type = "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> int:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    outcome: dict[str, object] = {}

    def first_wait(browser: str, started: threading.Event) -> None:
        with termmesh() as c1:
            started.set()
            begin = time.monotonic()
            READY_AT["monotonic"] = begin + READY_AFTER_S
            try:
                c1._call("browser.wait", {"surface_id": browser, "function": READY_CONDITION, "timeout_ms": 5000})
                outcome["first"] = time.monotonic() - begin
            except termmeshError as error:
                outcome["first_error"] = f"{error} after {time.monotonic() - begin:.2f}s"

    def second_wait(browser: str) -> None:
        with termmesh() as c2:
            begin = time.monotonic()
            try:
                c2._call("browser.wait", {"surface_id": browser, "function": "false", "timeout_ms": SECOND_TIMEOUT_MS})
                outcome["second_error"] = "wait on a false condition returned success"
            except termmeshError as error:
                if "timeout" not in str(error):
                    outcome["second_error"] = f"expected timeout, got {error}"
            outcome["second"] = time.monotonic() - begin

    try:
        with termmesh() as c:
            browser = c.open_browser(f"http://127.0.0.1:{server.server_port}/")
            c._call("browser.wait", {"surface_id": browser, "text_contains": "ready", "timeout_ms": 10000})

            started = threading.Event()
            first = threading.Thread(target=first_wait, args=(browser, started))
            first.start()
            if not started.wait(15):
                raise termmeshError("first client did not arm its condition")
            time.sleep(SECOND_START_DELAY_S)
            second = threading.Thread(target=second_wait, args=(browser,))
            second.start()
            first.join(30)
            second.join(30)
            c.close_surface(browser)
    finally:
        server.shutdown()

    for key in ("first_error", "second_error"):
        if key in outcome:
            raise termmeshError(f"{key}: {outcome[key]} (outcome={outcome!r})")
    if "first" not in outcome or "second" not in outcome:
        raise termmeshError(f"a client did not finish: {outcome!r}")
    first_took = float(outcome["first"])
    if first_took > FIRST_BOUND_S:
        raise termmeshError(
            f"expected the first wait within {FIRST_BOUND_S}s of its condition at {READY_AFTER_S}s, "
            f"took {first_took:.2f}s (second wait took {float(outcome['second']):.2f}s)"
        )

    print(f"PASS: browser.wait returns at its condition ({first_took:.2f}s) while another client's wait is pending")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
